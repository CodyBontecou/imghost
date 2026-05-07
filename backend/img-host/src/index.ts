import { Database } from './database';
import { Auth } from './auth';
import { resolveAuthenticatedUser } from './request-auth';
import { ExportService } from './export';
import { Analytics } from './analytics';
import { RateLimiter, getIpRateLimitConfig } from './rate-limiter';
import { ContentModerator, HiveModerationClient, NCMECReporter, computeFileSha256 } from './content-moderation';
import {
  parseTransformParams,
  isTransformableContentType,
  buildCloudflareImageOptions,
  getBestFormat,
  type ImageTransformOptions,
} from './image-optimization';
import {
  handleRegisterV2,
  handleLoginV2,
  handleRefreshToken,
  handleForgotPassword,
  handleResetPassword,
  handleVerifyEmail,
  handleResendVerification,
  handleAppleSignIn,
  handleAnonymousSignIn,
  handleDeleteAccount
} from './auth-handlers';
import {
  handleVerifyPurchase,
  handleSubscriptionStatus,
  handleRestorePurchases,
  checkSubscriptionAccess
} from './subscription-handlers';
import type { ExportJobResponse } from './types';

// CORS configuration
const ALLOWED_ORIGINS = [
  'https://imghost.isolated.tech',
  'http://localhost:3000', // Local development
];

function getCorsHeaders(origin: string | null): Record<string, string> {
  const headers: Record<string, string> = {
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-API-Key, X-DMCA-API-Key',
    'Access-Control-Max-Age': '86400',
  };

  if (origin && ALLOWED_ORIGINS.includes(origin)) {
    headers['Access-Control-Allow-Origin'] = origin;
    headers['Access-Control-Allow-Credentials'] = 'true';
  }

  return headers;
}

function handleOptions(request: Request): Response {
  const origin = request.headers.get('Origin');
  const corsHeaders = getCorsHeaders(origin);

  return new Response(null, {
    status: 204,
    headers: corsHeaders,
  });
}

function addCorsHeaders(response: Response, origin: string | null): Response {
  const corsHeaders = getCorsHeaders(origin);
  const newHeaders = new Headers(response.headers);

  for (const [key, value] of Object.entries(corsHeaders)) {
    newHeaders.set(key, value);
  }

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: newHeaders,
  });
}

export interface Env {
  IMAGES: R2Bucket;
  DB: D1Database;
  UPLOAD_TOKEN: string; // Legacy - kept for backward compatibility
  JWT_SECRET: string;
  EMAIL_FROM?: string;
  BASE_URL?: string;
  APPLE_BUNDLE_ID?: string;
  AWS_ACCESS_KEY_ID?: string;
  AWS_SECRET_ACCESS_KEY?: string;
  AWS_REGION?: string;
  /** Hive Moderation API key for AI-powered content scanning (CSAM, NSFW) */
  HIVE_API_KEY?: string;
  /** NCMEC CyberTipline API key — mandatory reporting for CSAM detections */
  NCMEC_API_KEY?: string;
  /** Shared secret for privileged DMCA takedown API access */
  DMCA_API_KEY?: string;
}

const MAX_FILE_SIZE = 500 * 1024 * 1024;        // 500MB max (Cloudflare Workers limit)
const FREE_MAX_FILE_SIZE = 50_000_000;          // 50MB max per file for free tier
const FREE_STORAGE_LIMIT = 1_000_000_000;       // 1GB total for free tier
const FREE_DAILY_UPLOADS = 20;                  // max uploads per 24h for free tier (storage is the real cap)

function generateId(): string {
  return crypto.randomUUID().slice(0, 8);
}

function generateDeleteToken(): string {
  return crypto.randomUUID();
}

function getExtension(filename: string): string {
  const parts = filename.split('.');
  return parts.length > 1 ? parts.pop()!.toLowerCase() : 'png';
}

function getClientIp(request: Request): string {
  // Try CF-Connecting-IP first (Cloudflare)
  const cfIp = request.headers.get('CF-Connecting-IP');
  if (cfIp) return cfIp;

  // Fallback to X-Forwarded-For
  const forwardedFor = request.headers.get('X-Forwarded-For');
  if (forwardedFor) {
    return forwardedFor.split(',')[0].trim();
  }

  // Default fallback
  return 'unknown';
}

function json(data: unknown, status = 200, headers?: Record<string, string>, origin?: string | null): Response {
  const corsHeaders = getCorsHeaders(origin ?? null);
  const responseHeaders = new Headers({
    'Content-Type': 'application/json',
    ...corsHeaders,
    ...headers,
  });

  return new Response(JSON.stringify(data), {
    status,
    headers: responseHeaders,
  });
}

async function handleUpload(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);
  const analytics = new Analytics(env.DB);
  const rateLimiter = new RateLimiter(env.DB);
  const moderator = new ContentModerator(env.DB);

  const user = await resolveAuthenticatedUser(request, env, db);
  if (!user) {
    return json({ error: 'Unauthorized' }, 401);
  }

  // Check if email is verified
  if (user.email_verified !== 1) {
    return json({ error: 'Email verification required', email_verified: false }, 403);
  }

  const isFreeUser = user.subscription_tier === 'free';

  if (!isFreeUser) {
    // Paid/trial users: require an active subscription
    const subscriptionCheck = await checkSubscriptionAccess(user.id, db);
    if (!subscriptionCheck.hasAccess) {
      return json({
        error: 'Subscription required',
        subscription_required: true,
        reason: subscriptionCheck.reason,
        current_tier: subscriptionCheck.tier,
        current_status: subscriptionCheck.status,
      }, 403);
    }
  } else {
    // Free users: enforce daily upload rate limit
    const rateLimiter = new RateLimiter(env.DB);
    const uploadLimit = await rateLimiter.checkUserRateLimit(
      user.id,
      '/upload',
      { windowMs: 24 * 60 * 60 * 1000, maxRequests: FREE_DAILY_UPLOADS }
    );
    if (!uploadLimit.allowed) {
      return json({
        error: 'Daily upload limit reached for free tier',
        upgrade_required: true,
        limit: FREE_DAILY_UPLOADS,
        resets_at: new Date(uploadLimit.reset).toISOString(),
      }, 429);
    }
  }

  // Check if user is suspended
  const suspension = await rateLimiter.checkUserSuspension(user.id);
  if (suspension.suspended) {
    return json({
      error: 'Account suspended',
      reason: suspension.reason,
      suspended_until: suspension.until,
    }, 403);
  }

  // Check for unusual upload patterns
  const patternCheck = await moderator.detectUnusualUploadPattern(user.id);
  if (patternCheck.suspicious) {
    // Log for monitoring but don't block yet (could be legitimate bulk upload)
    console.warn('Unusual upload pattern detected:', {
      userId: user.id,
      reasons: patternCheck.reasons,
    });

    // Flag for manual review if severity is high
    if (patternCheck.reasons.length >= 2) {
      await moderator.flagContent(
        'pending_upload',
        'suspicious',
        0.7,
        'system',
        { pattern_reasons: patternCheck.reasons }
      );
    }
  }

  // Parse form data
  let formData: FormData;
  try {
    formData = await request.formData();
  } catch {
    return json({ error: 'Invalid form data' }, 400);
  }

  const file = formData.get('image') as unknown as File | null;
  if (!file || typeof file === 'string') {
    return json({ error: 'Missing image field' }, 400);
  }

  // Validate content type - allow images, videos, audio, documents, and common file types
  const allowedTypes = [
    'image/',
    'video/',
    'audio/',
    'application/pdf',
    'application/zip',
    'application/gzip',
    'application/json',
    'application/xml',
    'application/octet-stream',
    'text/',
  ];
  
  const isAllowedType = allowedTypes.some(type => file.type.startsWith(type));
  if (!isAllowedType) {
    return json({ error: 'Unsupported file type' }, 400);
  }

  // Advanced file type validation and malware scanning
  // MUST run before file.arrayBuffer() as that consumes the stream
  const malwareScan = await moderator.scanForMalware(file);

  // Read file into ArrayBuffer ONCE to avoid stream consumption issues
  const fileBuffer = await file.arrayBuffer();
  if (malwareScan.flagged) {
    const highConfidenceFlags = malwareScan.flags.filter(f => f.confidence >= 0.8);
    if (highConfidenceFlags.length > 0) {
      // Log the issue for monitoring
      console.error('File validation failed:', {
        userId: user.id,
        filename: file.name,
        fileType: file.type,
        fileSize: file.size,
        flags: malwareScan.flags,
      });

      // Provide helpful error message with details
      const reasons = highConfidenceFlags.map(f => f.reason);
      return json({
        error: 'File rejected',
        reason: 'Security check failed',
        details: reasons.join('; '),
        file_type: file.type,
        hint: 'If this is a valid file, try re-saving it or converting to a common format like JPEG or PNG.',
      }, 400);
    }
  }

  // Hash the file and check against the blocklist (catches re-uploads of removed content)
  const fileHash = await computeFileSha256(fileBuffer);
  const isBlocked = await moderator.checkHashBlocklist(fileHash);
  if (isBlocked) {
    console.warn('Blocked hash upload attempt:', { userId: user.id, fileHash });
    return json({ error: 'File rejected', reason: 'This content has been removed' }, 451);
  }

  // AI-powered content moderation via Hive (CSAM, NSFW) — only images
  if (file.type.startsWith('image/') && env.HIVE_API_KEY) {
    const hiveClient = new HiveModerationClient(env.HIVE_API_KEY);
    const hiveResult = await hiveClient.classify(fileBuffer);

    if (hiveResult.csam) {
      // Add hash to blocklist immediately so re-uploads are caught instantly
      await moderator.addToHashBlocklist(fileHash, 'csam');

      // Report to NCMEC (mandatory for US service providers — 18 USC §2258A)
      if (env.NCMEC_API_KEY) {
        const ncmec = new NCMECReporter(env.NCMEC_API_KEY);
        const clientIp = getClientIp(request);
        const reportId = await ncmec.report({
          imageId: fileHash,
          imageHash: fileHash,
          uploadedAt: new Date(),
          uploaderIp: clientIp,
        });
        console.error('CSAM detected — NCMEC report filed:', { fileHash, reportId });
      }

      return json({ error: 'File rejected' }, 451);
    }

    if (hiveResult.blocked && hiveResult.nsfw) {
      // Flag for review but allow upload (NSFW is not illegal by itself)
      await moderator.flagContent('pending_upload', 'nsfw', hiveResult.confidence, 'system', {
        fileHash,
        hive_confidence: hiveResult.confidence,
      });
    }
  }

  // Validate file size — free tier has a 5MB per-file cap
  if (isFreeUser && file.size > FREE_MAX_FILE_SIZE) {
    return json({
      error: 'Free tier limit: files must be under 5MB',
      upgrade_required: true,
      limit_bytes: FREE_MAX_FILE_SIZE,
    }, 413);
  }

  // Validate file size against absolute maximum (500MB paid plan limit)
  if (file.size > MAX_FILE_SIZE) {
    return json({ error: 'File exceeds 500MB limit' }, 400);
  }

  // Check storage limit
  const hasSpace = await db.checkStorageLimit(user.id, file.size);
  if (!hasSpace) {
    const usage = await db.getStorageUsage(user.id);
    return json({
      error: isFreeUser
        ? 'Free tier storage limit reached (1 GB). Upgrade to Starter for 10 GB.'
        : 'Storage limit exceeded',
      upgrade_required: isFreeUser,
      current_usage: usage.total_bytes_used,
      limit: user.storage_limit_bytes,
    }, 403);
  }

  // Generate ID and delete token
  const id = generateId();
  const deleteToken = generateDeleteToken();
  const ext = getExtension(file.name);
  const key = `${id}.${ext}`;

  // Upload to R2 using the ArrayBuffer we already read
  await env.IMAGES.put(key, fileBuffer, {
    httpMetadata: {
      contentType: file.type,
    },
    customMetadata: {
      deleteToken,
      originalName: file.name,
      userId: user.id,
    },
  });

  // All images are permanent; storage quota is the limiting factor for free users
  const expiresAt = null;

  // Save image metadata to database
  const image = await db.createImage(
    user.id,
    key,
    file.name,
    file.size,
    file.type,
    deleteToken,
    expiresAt
  );

  // Flag low-confidence issues for review (don't block upload)
  if (malwareScan.flagged) {
    for (const flag of malwareScan.flags) {
      await moderator.flagContent(
        image.id,
        flag.type,
        flag.confidence,
        'system',
        { reason: flag.reason }
      );
    }
  }

  // Log API usage
  await db.logApiUsage(user.id, '/upload', 'POST', 200);

  // Build response URLs
  const url = new URL(request.url);
  const host = url.origin;

  return json({
    url: `${host}/${key}`,
    id: image.id,
    deleteUrl: `${host}/delete/${image.id}?token=${deleteToken}`,
    expires_at: image.expires_at ? new Date(image.expires_at).toISOString() : null,
  });
}

async function handleGet(request: Request, env: Env, key: string): Promise<Response> {
  const url = new URL(request.url);

  // Parse transform parameters
  const { options, errors, hasTransforms } = parseTransformParams(url);

  // Return validation errors early (before fetching from R2)
  if (errors.length > 0) {
    return json({
      error: 'Invalid parameters',
      details: errors,
    }, 400);
  }

  // Fetch image from R2
  const object = await env.IMAGES.get(key);

  if (!object) {
    return json({ error: 'Not found' }, 404);
  }

  // Enforce DMCA takedowns at read-time
  const db = new Database(env.DB);
  const imageRecord = await db.getImageByR2Key(key) as ({ dmca_taken_down?: number } | null);
  if (imageRecord?.dmca_taken_down === 1) {
    return json(
      { error: 'Unavailable for legal reasons' },
      451,
      { 'Access-Control-Allow-Origin': '*' }
    );
  }

  const contentType = object.httpMetadata?.contentType || 'application/octet-stream';

  // If transforms requested, validate content type
  if (hasTransforms && !isTransformableContentType(contentType)) {
    return json({
      error: 'Unsupported media type for transformation',
      content_type: contentType,
      hint: 'Image transformations only work with JPEG, PNG, GIF, WebP, AVIF, and SVG files.',
    }, 415);
  }

  // If no transforms, serve original image directly
  if (!hasTransforms) {
    const headers = new Headers();
    headers.set('Content-Type', contentType);
    headers.set('Cache-Control', 'public, max-age=31536000');
    headers.set('ETag', object.httpEtag);
    headers.set('Access-Control-Allow-Origin', '*');

    return new Response(object.body, { headers });
  }

  // Apply image transformations using Cloudflare Image Resizing
  // Handle format=auto by checking Accept header
  const transformOptions = { ...options };
  if (transformOptions.format === 'auto') {
    const acceptHeader = request.headers.get('Accept');
    transformOptions.format = getBestFormat(acceptHeader);
  }

  // Build Cloudflare image options
  const cfImageOptions = buildCloudflareImageOptions(transformOptions);

  // Use Cloudflare Image Resizing via fetch with cf.image
  // The image needs to be accessible via URL for CF to transform it
  const imageUrl = `${url.origin}/${key}`;

  try {
    const transformedResponse = await fetch(imageUrl, {
      cf: {
        image: cfImageOptions,
        cacheEverything: true,
        cacheTtl: 86400, // 24 hours
      },
    });

    // Check if transformation was successful
    if (!transformedResponse.ok) {
      // If CF Image Resizing fails, fall back to original
      console.error('Image transformation failed:', transformedResponse.status);

      const headers = new Headers();
      headers.set('Content-Type', contentType);
      headers.set('Cache-Control', 'public, max-age=31536000');
      headers.set('ETag', object.httpEtag);
      headers.set('Access-Control-Allow-Origin', '*');

      return new Response(object.body, { headers });
    }

    // Build response headers for transformed image
    const headers = new Headers(transformedResponse.headers);
    headers.set('Cache-Control', 'public, max-age=31536000');
    headers.set('Vary', 'Accept'); // Important for format=auto
    headers.set('X-Image-Optimized', 'true');
    headers.set('Access-Control-Allow-Origin', '*');

    return new Response(transformedResponse.body, {
      status: 200,
      headers,
    });
  } catch (error) {
    // If transformation fails, fall back to serving original
    console.error('Image transformation error:', error);

    const headers = new Headers();
    headers.set('Content-Type', contentType);
    headers.set('Cache-Control', 'public, max-age=31536000');
    headers.set('ETag', object.httpEtag);
    headers.set('Access-Control-Allow-Origin', '*');

    return new Response(object.body, { headers });
  }
}

async function handleDelete(request: Request, env: Env, id: string): Promise<Response> {
  const db = new Database(env.DB);
  const url = new URL(request.url);
  const token = url.searchParams.get('token');

  if (!token) {
    return json({ error: 'Missing token' }, 400);
  }

  // Get image from database
  const image = await db.getImageById(id);
  if (!image) {
    return json({ error: 'Not found' }, 404);
  }

  // Validate delete token
  const isValid = await db.verifyDeleteToken(id, token);
  if (!isValid) {
    return json({ error: 'Invalid token' }, 403);
  }

  // Delete from R2
  await env.IMAGES.delete(image.r2_key);

  // Delete from database
  await db.deleteImage(id);

  // Log API usage
  await db.logApiUsage(image.user_id, `/delete/${id}`, 'DELETE', 200);

  return json({ deleted: true });
}

async function handleRegister(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);
  const rateLimiter = new RateLimiter(env.DB);
  const clientIp = getClientIp(request);

  // Check IP-based rate limit for registration
  const ipRateLimit = await rateLimiter.checkIpRateLimit(
    clientIp,
    '/auth/register',
    getIpRateLimitConfig('/auth/register')
  );

  if (!ipRateLimit.allowed) {
    return json(
      {
        error: 'Too many registration attempts',
        retry_after: new Date(ipRateLimit.reset).toISOString(),
      },
      429,
      {
        'X-RateLimit-Limit': ipRateLimit.limit.toString(),
        'X-RateLimit-Remaining': ipRateLimit.remaining.toString(),
        'X-RateLimit-Reset': ipRateLimit.reset.toString(),
      }
    );
  }

  try {
    const body = await request.json() as { email: string; password: string };
    const { email, password } = body;

    if (!email || !password) {
      return json({ error: 'Email and password required' }, 400);
    }

    // Check failed attempts for this email
    const failedCheck = await rateLimiter.checkFailedAttempts(email, 'register');
    if (!failedCheck.allowed) {
      const lockoutMinutes = failedCheck.lockedUntil
        ? Math.ceil((failedCheck.lockedUntil - Date.now()) / (60 * 1000))
        : 0;

      return json({
        error: 'Too many failed attempts',
        locked_until: failedCheck.lockedUntil,
        retry_in_minutes: lockoutMinutes,
        requires_captcha: failedCheck.requiresCaptcha,
      }, 429);
    }

    // Validate email format
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email)) {
      await rateLimiter.recordFailedAttempt(email, 'register');
      return json({ error: 'Invalid email format' }, 400);
    }

    // Check if user already exists
    const existingUser = await db.getUserByEmail(email);
    if (existingUser) {
      await rateLimiter.recordFailedAttempt(email, 'register');
      return json({ error: 'Email already registered' }, 409);
    }

    // Hash password and generate API token
    const passwordHash = await Auth.hashPassword(password);
    const apiToken = Auth.generateApiToken();

    // Create user
    const user = await db.createUser(email, passwordHash, apiToken, 'trial');

    // Create trial subscription
    await db.createSubscription(user.id, 'trial', 'trialing');

    // Clear any failed attempts on successful registration
    await rateLimiter.clearFailedAttempts(email, 'register');

    return json({
      user_id: user.id,
      email: user.email,
      api_token: apiToken,
      subscription_tier: user.subscription_tier,
    }, 201);
  } catch (error) {
    console.error('Register error:', error);
    return json({ error: 'Invalid request body' }, 400);
  }
}

async function handleLogin(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);
  const rateLimiter = new RateLimiter(env.DB);
  const clientIp = getClientIp(request);

  // Check IP-based rate limit for login
  const ipRateLimit = await rateLimiter.checkIpRateLimit(
    clientIp,
    '/auth/login',
    getIpRateLimitConfig('/auth/login')
  );

  if (!ipRateLimit.allowed) {
    return json(
      {
        error: 'Too many login attempts',
        retry_after: new Date(ipRateLimit.reset).toISOString(),
      },
      429,
      {
        'X-RateLimit-Limit': ipRateLimit.limit.toString(),
        'X-RateLimit-Remaining': ipRateLimit.remaining.toString(),
        'X-RateLimit-Reset': ipRateLimit.reset.toString(),
      }
    );
  }

  try {
    const body = await request.json() as { email: string; password: string };
    const { email, password } = body;

    if (!email || !password) {
      return json({ error: 'Email and password required' }, 400);
    }

    // Check failed attempts for this email
    const failedCheck = await rateLimiter.checkFailedAttempts(email, 'login');
    if (!failedCheck.allowed) {
      const lockoutMinutes = failedCheck.lockedUntil
        ? Math.ceil((failedCheck.lockedUntil - Date.now()) / (60 * 1000))
        : 0;

      return json({
        error: 'Account temporarily locked due to failed login attempts',
        locked_until: failedCheck.lockedUntil,
        retry_in_minutes: lockoutMinutes,
        requires_captcha: failedCheck.requiresCaptcha,
      }, 429);
    }

    // Get user
    const user = await db.getUserByEmail(email);
    if (!user) {
      await rateLimiter.recordFailedAttempt(email, 'login');
      await rateLimiter.recordFailedAttempt(clientIp, 'login');
      return json({ error: 'Invalid credentials' }, 401);
    }

    // Check if user is suspended
    const suspension = await rateLimiter.checkUserSuspension(user.id);
    if (suspension.suspended) {
      return json({
        error: 'Account suspended',
        reason: suspension.reason,
        suspended_until: suspension.until,
      }, 403);
    }

    // Verify password
    const isValid = await Auth.verifyPassword(password, user.password_hash);
    if (!isValid) {
      await rateLimiter.recordFailedAttempt(email, 'login');
      await rateLimiter.recordFailedAttempt(clientIp, 'login');
      return json({ error: 'Invalid credentials' }, 401);
    }

    // Clear failed attempts on successful login
    await rateLimiter.clearFailedAttempts(email, 'login');
    await rateLimiter.clearFailedAttempts(clientIp, 'login');

    return json({
      user_id: user.id,
      email: user.email,
      api_token: user.api_token,
      subscription_tier: user.subscription_tier,
    });
  } catch (error) {
    console.error('Login error:', error);
    return json({ error: 'Invalid request body' }, 400);
  }
}

async function handleGetUser(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);

  const user = await resolveAuthenticatedUser(request, env, db);
  if (!user) {
    return json({ error: 'Unauthorized' }, 401);
  }

  // Get storage usage
  const usage = await db.getStorageUsage(user.id);

  // checkSubscriptionAccess may downgrade an expired trial → free (updating storage_limit_bytes).
  // Re-fetch the user after so we always return the authoritative limit.
  const subscriptionAccess = await checkSubscriptionAccess(user.id, db);
  const currentUser = await db.getUserById(user.id) ?? user;

  // Get subscription record (after any status updates above)
  const subscription = await db.getSubscriptionByUserId(user.id);

  // Calculate trial days remaining
  let trialDaysRemaining: number | undefined;
  if (subscription?.status === 'trialing' && subscription?.trial_ends_at) {
    const msRemaining = subscription.trial_ends_at - Date.now();
    trialDaysRemaining = Math.max(0, Math.ceil(msRemaining / (24 * 60 * 60 * 1000)));
  }

  return json({
    user_id: currentUser.id,
    email: currentUser.email,
    subscription_tier: currentUser.subscription_tier,
    subscription_status: subscription?.status || 'none',
    has_subscription_access: subscriptionAccess.hasAccess,
    email_verified: currentUser.email_verified === 1,
    is_anonymous: currentUser.is_anonymous === 1,
    storage_limit_bytes: currentUser.storage_limit_bytes,
    storage_used_bytes: usage.total_bytes_used,
    image_count: usage.image_count,
    trial_ends_at: subscription?.trial_ends_at ? new Date(subscription.trial_ends_at).toISOString() : undefined,
    trial_days_remaining: trialDaysRemaining,
    current_period_end: subscription?.current_period_end ? new Date(subscription.current_period_end).toISOString() : undefined,
  });
}

async function handleGetImages(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);

  const user = await resolveAuthenticatedUser(request, env, db);
  if (!user) {
    return json({ error: 'Unauthorized' }, 401);
  }

  // Parse query params
  const url = new URL(request.url);
  const limit = parseInt(url.searchParams.get('limit') || '100');
  const offset = parseInt(url.searchParams.get('offset') || '0');

  const images = await db.getImagesByUserId(user.id, limit, offset);

  // Build full URLs for each image
  const host = url.origin;
  const imagesWithUrls = images.map(img => ({
    id: img.id,
    filename: img.filename,
    url: `${host}/${img.r2_key}`,
    delete_url: `${host}/delete/${img.id}?token=${img.delete_token}`,
    size_bytes: img.size_bytes,
    content_type: img.content_type,
    created_at: img.created_at,
  }));

  return json({
    images: imagesWithUrls,
    count: images.length,
  });
}

async function handleAbuseReport(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);
  const moderator = new ContentModerator(env.DB);
  const clientIp = getClientIp(request);

  // Get optional user auth (abuse reports can be anonymous)
  const authenticatedUser = await resolveAuthenticatedUser(request, env, db);
  const reporterUserId = authenticatedUser?.id || null;

  try {
    const body = await request.json() as {
      image_id: string;
      reason: 'nsfw' | 'copyright' | 'malware' | 'spam' | 'other';
      description?: string;
    };

    const { image_id, reason, description } = body;

    if (!image_id || !reason) {
      return json({ error: 'image_id and reason are required' }, 400);
    }

    // Get image to find the reported user
    const image = await db.getImageById(image_id);
    if (!image) {
      return json({ error: 'Image not found' }, 404);
    }

    // Submit abuse report
    const report = await moderator.submitAbuseReport(
      image_id,
      image.user_id,
      reporterUserId,
      clientIp,
      reason,
      description || null
    );

    return json({
      report_id: report.id,
      status: report.status,
      message: 'Thank you for your report. We will review it shortly.',
    }, 201);
  } catch (error) {
    console.error('Abuse report error:', error);
    return json({ error: 'Invalid request body' }, 400);
  }
}

async function handleDmcaTakedown(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);
  const moderator = new ContentModerator(env.DB);
  const rateLimiter = new RateLimiter(env.DB);
  const clientIp = getClientIp(request);

  // Strong abuse protection: DMCA endpoint requires a shared secret
  if (!env.DMCA_API_KEY) {
    return json({ error: 'DMCA endpoint is not configured' }, 503);
  }

  const providedKey = request.headers.get('X-DMCA-API-Key') ?? '';
  if (providedKey !== env.DMCA_API_KEY) {
    return json({ error: 'Unauthorized' }, 401);
  }

  // Additional request-level protection
  const ipRateLimit = await rateLimiter.checkIpRateLimit(clientIp, '/api/dmca-takedown', {
    windowMs: 60 * 60 * 1000,
    maxRequests: 20,
  });

  if (!ipRateLimit.allowed) {
    return json(
      {
        error: 'Too many DMCA requests',
        retry_after: new Date(ipRateLimit.reset).toISOString(),
      },
      429,
      {
        'X-RateLimit-Limit': ipRateLimit.limit.toString(),
        'X-RateLimit-Remaining': ipRateLimit.remaining.toString(),
        'X-RateLimit-Reset': ipRateLimit.reset.toString(),
      }
    );
  }

  try {
    const body = await request.json() as {
      image_id: string;
      reported_url: string;
      complainant_email: string;
      description: string;
      file_hash?: string;
    };

    const { image_id, reported_url, complainant_email, description, file_hash } = body;

    if (!image_id || !reported_url || !complainant_email || !description) {
      return json({ error: 'image_id, reported_url, complainant_email, and description are required' }, 400);
    }

    // Basic email format check
    if (!complainant_email.includes('@')) {
      return json({ error: 'Invalid complainant_email' }, 400);
    }

    const image = await db.getImageById(image_id);
    if (!image) {
      return json({ error: 'Image not found' }, 404);
    }

    const takedown = await moderator.createDmcaTakedown({
      imageId: image_id,
      reportedUrl: reported_url,
      complainantEmail: complainant_email,
      description,
      fileHash: file_hash,
    });

    return json({
      takedown_id: takedown.id,
      status: takedown.status,
      message: 'DMCA takedown request received. The content has been removed pending review.',
    }, 201);
  } catch (error) {
    console.error('DMCA takedown error:', error);
    return json({ error: 'Invalid request body' }, 400);
  }
}

function handleHealth(): Response {
  return json({ status: 'ok' });
}

async function handleExportInitiate(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const db = new Database(env.DB);

  const user = await resolveAuthenticatedUser(request, env, db);
  if (!user) {
    return json({ error: 'Unauthorized' }, 401);
  }

  // Free tier cannot export — images expire after 7 days anyway
  if (user.subscription_tier === 'free') {
    return json({
      error: 'Export is not available on the free tier',
      upgrade_required: true,
    }, 403);
  }

  // Check rate limit (5 per hour)
  const canExport = await db.checkExportRateLimit(user.id);
  if (!canExport) {
    return json({ error: 'Rate limit exceeded. You can only export 5 times per hour.' }, 429);
  }

  // Create export job
  const job = await db.createExportJob(user.id);

  // Update rate limit
  await db.updateExportRateLimit(user.id);

  // Process export asynchronously using waitUntil for fire-and-forget background processing
  const exportService = new ExportService(db, env.IMAGES);
  ctx.waitUntil(exportService.processExportJob(job.id, user.id));

  const url = new URL(request.url);
  const host = url.origin;

  const response: ExportJobResponse = {
    jobId: job.id,
    status: job.status,
    imageCount: job.image_count,
  };

  return json(response, 202); // 202 Accepted - processing started
}

async function handleExportStatus(request: Request, env: Env, jobId: string): Promise<Response> {
  const db = new Database(env.DB);

  const user = await resolveAuthenticatedUser(request, env, db);
  if (!user) {
    return json({ error: 'Unauthorized' }, 401);
  }

  // Get export job
  const job = await db.getExportJob(jobId);
  if (!job) {
    return json({ error: 'Export job not found' }, 404);
  }

  // Verify ownership
  if (job.user_id !== user.id) {
    return json({ error: 'Forbidden' }, 403);
  }

  const url = new URL(request.url);
  const host = url.origin;

  const response: ExportJobResponse = {
    jobId: job.id,
    status: job.status,
    imageCount: job.image_count,
    archiveSize: job.archive_size > 0 ? job.archive_size : undefined,
    downloadUrl: job.download_url ? `${host}/api/export/${job.id}/download` : undefined,
    expiresAt: job.expires_at ? new Date(job.expires_at).toISOString() : undefined,
    errorMessage: job.error_message || undefined,
  };

  return json(response);
}

async function handleExportDownload(request: Request, env: Env, jobId: string): Promise<Response> {
  const db = new Database(env.DB);

  const user = await resolveAuthenticatedUser(request, env, db);
  if (!user) {
    return json({ error: 'Unauthorized' }, 401);
  }

  // Get export job
  const job = await db.getExportJob(jobId);
  if (!job) {
    return json({ error: 'Export job not found' }, 404);
  }

  // Verify ownership
  if (job.user_id !== user.id) {
    return json({ error: 'Forbidden' }, 403);
  }

  // Check if job is completed
  if (job.status !== 'completed') {
    return json({ error: 'Export is not ready yet', status: job.status }, 400);
  }

  // Check if expired
  if (job.expires_at && job.expires_at < Date.now()) {
    return json({ error: 'Export has expired' }, 410); // 410 Gone
  }

  // Get archive from R2
  if (!job.download_url) {
    return json({ error: 'Download URL not available' }, 500);
  }

  const object = await env.IMAGES.get(job.download_url);
  if (!object) {
    return json({ error: 'Archive not found' }, 404);
  }

  // Return the ZIP file
  const headers = new Headers();
  headers.set('Content-Type', 'application/zip');
  headers.set('Content-Disposition', `attachment; filename="export_${jobId}.zip"`);
  headers.set('Content-Length', object.size.toString());

  return new Response(object.body, { headers });
}

async function handleLanding(env: Env): Promise<Response> {
  const object = await env.IMAGES.get('landing.html');
  if (!object) {
    return new Response('Landing page not found', { status: 404 });
  }

  const headers = new Headers();
  headers.set('Content-Type', 'text/html; charset=utf-8');
  headers.set('Cache-Control', 'public, max-age=3600'); // 1 hour cache

  return new Response(object.body, { headers });
}

async function handleStaticPage(env: Env, filename: string): Promise<Response> {
  const object = await env.IMAGES.get(filename);
  if (!object) {
    return new Response('Page not found', { status: 404 });
  }

  const headers = new Headers();
  headers.set('Content-Type', 'text/html; charset=utf-8');
  headers.set('Cache-Control', 'public, max-age=3600'); // 1 hour cache

  return new Response(object.body, { headers });
}

// ─── Scheduled Cron: delete expired free-tier images ─────────────────────────

async function runExpiredImageCleanup(env: Env): Promise<void> {
  const db = new Database(env.DB);
  const r2Keys = await db.deleteExpiredImages();

  if (r2Keys.length === 0) {
    console.log('[cleanup] No expired images to delete');
    return;
  }

  let deleted = 0;
  let failed = 0;
  for (const key of r2Keys) {
    try {
      await env.IMAGES.delete(key);
      deleted++;
    } catch (err) {
      console.error(`[cleanup] Failed to delete R2 object ${key}:`, err);
      failed++;
    }
  }
  console.log(`[cleanup] Deleted ${deleted} expired images (${failed} R2 failures)`);
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;
    const origin = request.headers.get('Origin');

    // Handle CORS preflight requests
    if (method === 'OPTIONS') {
      return handleOptions(request);
    }

    // Helper to add CORS headers to response
    const withCors = (response: Response) => addCorsHeaders(response, origin);

    try {
      // GET / - Serve landing page (no CORS needed for HTML)
      if (method === 'GET' && path === '/') {
        return await handleLanding(env);
      }

      // GET /privacy or /privacy.html - Serve privacy policy
      if (method === 'GET' && (path === '/privacy' || path === '/privacy.html')) {
        return await handleStaticPage(env, 'privacy.html');
      }

      // GET /terms or /terms.html - Serve terms of service
      if (method === 'GET' && (path === '/terms' || path === '/terms.html')) {
        return await handleStaticPage(env, 'terms.html');
      }

      // GET /favicon.png - Serve favicon
      if (method === 'GET' && path === '/favicon.png') {
        const object = await env.IMAGES.get('favicon.png');
        if (!object) {
          return new Response('Not found', { status: 404 });
        }
        const headers = new Headers();
        headers.set('Content-Type', 'image/png');
        headers.set('Cache-Control', 'public, max-age=86400'); // 1 day cache
        return new Response(object.body, { headers });
      }

      // GET /logo.png - Serve logo
      if (method === 'GET' && path === '/logo.png') {
        const object = await env.IMAGES.get('logo.png');
        if (!object) {
          return new Response('Not found', { status: 404 });
        }
        const headers = new Headers();
        headers.set('Content-Type', 'image/png');
        headers.set('Cache-Control', 'public, max-age=86400'); // 1 day cache
        return new Response(object.body, { headers });
      }

      // POST /auth/register - Enhanced with JWT and email verification
      if (method === 'POST' && path === '/auth/register') {
        return withCors(await handleRegisterV2(request, env));
      }

      // POST /auth/login - Enhanced with JWT tokens
      if (method === 'POST' && path === '/auth/login') {
        return withCors(await handleLoginV2(request, env));
      }

      // POST /auth/anonymous - Create an anonymous device account (no personal info required)
      if (method === 'POST' && path === '/auth/anonymous') {
        return withCors(await handleAnonymousSignIn(request, env));
      }

      // POST /auth/refresh - Refresh access token
      if (method === 'POST' && path === '/auth/refresh') {
        return withCors(await handleRefreshToken(request, env));
      }

      // POST /auth/forgot-password - Request password reset
      if (method === 'POST' && path === '/auth/forgot-password') {
        return withCors(await handleForgotPassword(request, env));
      }

      // POST /auth/reset-password - Reset password with token
      if (method === 'POST' && path === '/auth/reset-password') {
        return withCors(await handleResetPassword(request, env));
      }

      // POST /auth/verify-email - Verify email address
      if (method === 'POST' && path === '/auth/verify-email' || (method === 'GET' && path === '/auth/verify-email')) {
        return withCors(await handleVerifyEmail(request, env));
      }

      // POST /auth/resend-verification - Resend verification email
      if (method === 'POST' && path === '/auth/resend-verification') {
        return withCors(await handleResendVerification(request, env));
      }

      // POST /auth/apple - Sign in with Apple
      if (method === 'POST' && path === '/auth/apple') {
        return withCors(await handleAppleSignIn(request, env));
      }

      // DELETE /auth/account - Delete user account and all data
      if (method === 'DELETE' && path === '/auth/account') {
        return withCors(await handleDeleteAccount(request, env, env.IMAGES));
      }

      // POST /subscription/verify-purchase - Verify App Store purchase
      if (method === 'POST' && path === '/subscription/verify-purchase') {
        return withCors(await handleVerifyPurchase(request, env));
      }

      // GET /subscription/status - Get subscription status
      if (method === 'GET' && path === '/subscription/status') {
        return withCors(await handleSubscriptionStatus(request, env));
      }

      // POST /subscription/restore - Restore purchases
      if (method === 'POST' && path === '/subscription/restore') {
        return withCors(await handleRestorePurchases(request, env));
      }

      // GET /user
      if (method === 'GET' && path === '/user') {
        return withCors(await handleGetUser(request, env));
      }

      // GET /images
      if (method === 'GET' && path === '/images') {
        return withCors(await handleGetImages(request, env));
      }

      // POST /upload
      if (method === 'POST' && path === '/upload') {
        return withCors(await handleUpload(request, env));
      }

      // POST /api/abuse-report - Submit abuse report
      if (method === 'POST' && path === '/api/abuse-report') {
        return withCors(await handleAbuseReport(request, env));
      }

      // POST /api/dmca-takedown - Submit DMCA takedown request
      if (method === 'POST' && path === '/api/dmca-takedown') {
        return withCors(await handleDmcaTakedown(request, env));
      }

      // POST /api/export - Initiate export job
      if (method === 'POST' && path === '/api/export') {
        return withCors(await handleExportInitiate(request, env, ctx));
      }

      // GET /api/export/{job_id}/status - Check export status
      if (method === 'GET' && path.startsWith('/api/export/')) {
        const parts = path.split('/');
        if (parts.length === 5 && parts[4] === 'status') {
          const jobId = parts[3];
          return withCors(await handleExportStatus(request, env, jobId));
        }
        if (parts.length === 5 && parts[4] === 'download') {
          const jobId = parts[3];
          return withCors(await handleExportDownload(request, env, jobId));
        }
      }

      // GET /health
      if (method === 'GET' && path === '/health') {
        return withCors(handleHealth());
      }

      // DELETE /delete/<id>
      if (method === 'DELETE' && path.startsWith('/delete/')) {
        const id = path.slice('/delete/'.length);
        if (!id) {
          return withCors(json({ error: 'Missing id' }, 400));
        }
        return withCors(await handleDelete(request, env, id));
      }

      // GET /<id>.<ext> - serve image (no CORS needed for images)
      if (method === 'GET') {
        const match = path.match(/^\/([a-zA-Z0-9]+\.[a-zA-Z0-9]+)$/);
        if (match) {
          return await handleGet(request, env, match[1]);
        }
      }

      return withCors(json({ error: 'Not found' }, 404));
    } catch (error) {
      console.error('Error:', error);
      return withCors(json({ error: 'Internal server error' }, 500));
    }
  },

  // Runs daily at 2 AM UTC (configured in wrangler.toml)
  async scheduled(_event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(runExpiredImageCleanup(env));
  },
};
