// Authentication endpoint handlers
import { EmailMessage } from 'cloudflare:email';
import { Database } from './database';
import { Auth } from './auth';
import { AppleAuth } from './apple-auth';
import { Analytics } from './analytics';
import { RateLimiter } from './rate-limiter';
import { resolveAuthenticatedUser } from './request-auth';

interface Env {
  DB: D1Database;
  JWT_SECRET: string;
  EMAIL_FROM?: string;
  BASE_URL?: string;
  APPLE_CLIENT_ID?: string;
  APPLE_MAC_CLIENT_ID?: string;
  SEND_EMAIL?: SendEmail;
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

// Send email via Cloudflare Email Workers
async function sendEmail(to: string, subject: string, body: string, env: Env): Promise<boolean> {
  const from = env.EMAIL_FROM || 'noreply@imghost.isolated.tech';

  // Fall back to console logging in local dev (SEND_EMAIL binding not available)
  if (!env.SEND_EMAIL) {
    console.log(`[EMAIL] To: ${to}, Subject: ${subject}\n${body}`);
    return true;
  }

  const rawEmail = [
    `From: imghost <${from}>`,
    `To: ${to}`,
    `Subject: ${subject}`,
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=UTF-8',
    '',
    body,
  ].join('\r\n');

  const message = new EmailMessage(from, to, rawEmail);
  await env.SEND_EMAIL.send(message);
  return true;
}

/**
 * Enhanced registration with email verification and JWT tokens
 * POST /auth/register
 */
export async function handleRegisterV2(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);
  const analytics = new Analytics(env.DB);
  const rateLimiter = new RateLimiter(env.DB);

  try {
    // Rate limiting for registration
    const clientIp = request.headers.get('CF-Connecting-IP') || 'unknown';
    const rateLimitCheck = await rateLimiter.checkIpRateLimit(clientIp, '/auth/register', { windowMs: 3600000, maxRequests: 5 }); // 5 per hour

    if (!rateLimitCheck.allowed) {
      return json({
        error: 'Too many registration attempts. Please try again later.',
        retry_after: Math.ceil((rateLimitCheck.reset - Date.now()) / 1000)
      }, 429);
    }

    const body = await request.json() as { email: string; password: string };
    const { email, password } = body;

    if (!email || !password) {
      return json({ error: 'Email and password required' }, 400);
    }

    // Validate email format
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email)) {
      return json({ error: 'Invalid email format' }, 400);
    }

    // Validate password strength
    if (password.length < 8) {
      return json({ error: 'Password must be at least 8 characters long' }, 400);
    }

    // Check if user already exists
    const existingUser = await db.getUserByEmail(email);
    if (existingUser) {
      return json({ error: 'Email already registered' }, 409);
    }

    // Hash password using PBKDF2
    const passwordHash = await Auth.hashPassword(password);
    const apiToken = Auth.generateApiToken();

    // Create user on free tier
    const user = await db.createUser(email, passwordHash, apiToken, 'free');

    // Create free subscription (always active, no expiry)
    await db.createSubscription(user.id, 'free', 'active');

    // Generate email verification token
    const verificationToken = Auth.generateSecureToken();
    await db.setEmailVerificationToken(user.id, verificationToken, 24 * 60 * 60 * 1000); // 24 hours

    // Send verification email
    const baseUrl = env.BASE_URL || 'https://your-domain.com';
    const verificationLink = `${baseUrl}/auth/verify-email?token=${encodeURIComponent(verificationToken)}`;
    await sendEmail(
      email,
      'Verify your email address',
      `Welcome to imghost! Please verify your email by clicking this link: ${verificationLink}\n\nThis link expires in 24 hours.`,
      env
    );

    // Create JWT tokens
    const jwtSecret = env.JWT_SECRET || 'default-secret-change-in-production';

    const accessToken = await Auth.createJWT(
      {
        sub: user.id,
        email: user.email,
        tier: user.subscription_tier,
        type: 'access'
      },
      3600, // 1 hour
      jwtSecret
    );

    const refreshToken = Auth.generateSecureToken();
    await db.createRefreshToken(user.id, refreshToken, 30 * 24 * 60 * 60 * 1000); // 30 days

    return json({
      access_token: accessToken,
      refresh_token: refreshToken,
      api_token: apiToken, // For backward compatibility
      expires_in: 3600,
      token_type: 'Bearer',
      user_id: user.id,
      email: user.email,
      subscription_tier: user.subscription_tier,
      email_verified: false,
      message: 'Registration successful. Please check your email to verify your account.'
    }, 201);
  } catch (error) {
    console.error('Register error:', error);
    return json({ error: 'Invalid request body' }, 400);
  }
}

/**
 * Enhanced login with JWT tokens
 * POST /auth/login
 */
export async function handleLoginV2(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);
  const rateLimiter = new RateLimiter(env.DB);

  try {
    // Rate limiting for login
    const clientIp = request.headers.get('CF-Connecting-IP') || 'unknown';
    const rateLimitCheck = await rateLimiter.checkIpRateLimit(clientIp, '/auth/login', { windowMs: 900000, maxRequests: 10 }); // 10 per 15 minutes

    if (!rateLimitCheck.allowed) {
      return json({
        error: 'Too many login attempts. Please try again later.',
        retry_after: Math.ceil((rateLimitCheck.reset - Date.now()) / 1000)
      }, 429);
    }

    const body = await request.json() as { email: string; password: string };
    const { email, password } = body;

    if (!email || !password) {
      return json({ error: 'Email and password required' }, 400);
    }

    // Get user
    const user = await db.getUserByEmail(email);
    if (!user) {
      return json({ error: 'Invalid credentials' }, 401);
    }

    // Verify password
    const isValid = await Auth.verifyPassword(password, user.password_hash);
    if (!isValid) {
      return json({ error: 'Invalid credentials' }, 401);
    }

    // Create JWT tokens
    const jwtSecret = env.JWT_SECRET || 'default-secret-change-in-production';

    const accessToken = await Auth.createJWT(
      {
        sub: user.id,
        email: user.email,
        tier: user.subscription_tier,
        type: 'access'
      },
      3600, // 1 hour
      jwtSecret
    );

    const refreshToken = Auth.generateSecureToken();
    await db.createRefreshToken(user.id, refreshToken, 30 * 24 * 60 * 60 * 1000); // 30 days

    return json({
      access_token: accessToken,
      refresh_token: refreshToken,
      api_token: user.api_token, // For backward compatibility
      expires_in: 3600,
      token_type: 'Bearer',
      user_id: user.id,
      email: user.email,
      subscription_tier: user.subscription_tier,
      email_verified: user.email_verified === 1
    });
  } catch (error) {
    console.error('Login error:', error);
    return json({ error: 'Invalid request body' }, 400);
  }
}

/**
 * Refresh access token using refresh token
 * POST /auth/refresh
 */
export async function handleRefreshToken(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);

  try {
    const body = await request.json() as { refresh_token: string };
    const { refresh_token } = body;

    if (!refresh_token) {
      return json({ error: 'Refresh token required' }, 400);
    }

    // Verify refresh token
    const tokenRecord = await db.getRefreshToken(refresh_token);
    if (!tokenRecord) {
      return json({ error: 'Invalid or expired refresh token' }, 401);
    }

    // Get user
    const user = await db.getUserById(tokenRecord.user_id);
    if (!user) {
      return json({ error: 'User not found' }, 404);
    }

    // Create new access token
    const jwtSecret = env.JWT_SECRET || 'default-secret-change-in-production';

    const accessToken = await Auth.createJWT(
      {
        sub: user.id,
        email: user.email,
        tier: user.subscription_tier,
        type: 'access'
      },
      3600, // 1 hour
      jwtSecret
    );

    // Optionally rotate refresh token (recommended for security)
    const newRefreshToken = Auth.generateSecureToken();
    await db.revokeRefreshToken(refresh_token);
    await db.createRefreshToken(user.id, newRefreshToken, 30 * 24 * 60 * 60 * 1000);

    return json({
      access_token: accessToken,
      refresh_token: newRefreshToken,
      expires_in: 3600,
      token_type: 'Bearer',
      user_id: user.id,
      email: user.email,
      subscription_tier: user.subscription_tier
    });
  } catch (error) {
    console.error('Refresh token error:', error);
    return json({ error: 'Invalid request body' }, 400);
  }
}

/**
 * Request password reset
 * POST /auth/forgot-password
 */
export async function handleForgotPassword(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);
  const rateLimiter = new RateLimiter(env.DB);

  try {
    // Rate limiting
    const clientIp = request.headers.get('CF-Connecting-IP') || 'unknown';
    const rateLimitCheck = await rateLimiter.checkIpRateLimit(clientIp, '/auth/forgot-password', { windowMs: 3600000, maxRequests: 3 }); // 3 per hour

    if (!rateLimitCheck.allowed) {
      return json({
        error: 'Too many password reset requests. Please try again later.',
        retry_after: Math.ceil((rateLimitCheck.reset - Date.now()) / 1000)
      }, 429);
    }

    const body = await request.json() as { email: string };
    const { email } = body;

    if (!email) {
      return json({ error: 'Email required' }, 400);
    }

    // Get user
    const user = await db.getUserByEmail(email);

    // Always return success to prevent email enumeration
    if (!user) {
      return json({
        message: 'If an account exists with this email, you will receive password reset instructions.'
      });
    }

    // Generate password reset token
    const resetToken = Auth.generateSecureToken();
    await db.setPasswordResetToken(user.id, resetToken, 60 * 60 * 1000); // 1 hour

    // Send reset email
    const baseUrl = env.BASE_URL || 'https://your-domain.com';
    const resetLink = `${baseUrl}/auth/reset-password?token=${encodeURIComponent(resetToken)}`;
    await sendEmail(
      email,
      'Password Reset Request',
      `You requested a password reset. Click this link to reset your password: ${resetLink}\n\nThis link expires in 1 hour.\n\nIf you didn't request this, please ignore this email.`,
      env
    );

    return json({
      message: 'If an account exists with this email, you will receive password reset instructions.'
    });
  } catch (error) {
    console.error('Forgot password error:', error);
    return json({ error: 'Invalid request body' }, 400);
  }
}

/**
 * Reset password with token
 * POST /auth/reset-password
 */
export async function handleResetPassword(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);

  try {
    const body = await request.json() as { token: string; new_password: string };
    const { token, new_password } = body;

    if (!token || !new_password) {
      return json({ error: 'Token and new password required' }, 400);
    }

    // Validate password strength
    if (new_password.length < 8) {
      return json({ error: 'Password must be at least 8 characters long' }, 400);
    }

    // Verify token
    const user = await db.getUserByPasswordResetToken(token);
    if (!user) {
      return json({ error: 'Invalid or expired reset token' }, 400);
    }

    // Hash new password
    const passwordHash = await Auth.hashPassword(new_password);

    // Update password and clear reset token
    await db.updatePassword(user.id, passwordHash);

    // Revoke all refresh tokens for security
    await db.revokeAllUserRefreshTokens(user.id);

    // Send confirmation email
    await sendEmail(
      user.email,
      'Password Changed',
      'Your password has been successfully changed. If you did not make this change, please contact support immediately.',
      env
    );

    return json({
      message: 'Password successfully reset. Please log in with your new password.'
    });
  } catch (error) {
    console.error('Reset password error:', error);
    return json({ error: 'Invalid request body' }, 400);
  }
}

/**
 * Verify email address
 * POST /auth/verify-email
 */
export async function handleVerifyEmail(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);

  try {
    const url = new URL(request.url);
    const token = url.searchParams.get('token');

    if (!token) {
      // Try getting token from body for POST requests
      const body = await request.json() as { token?: string };
      if (!body.token) {
        return json({ error: 'Verification token required' }, 400);
      }

      // Use token from body
      const user = await db.getUserByVerificationToken(body.token);
      if (!user) {
        return json({ error: 'Invalid or expired verification token' }, 400);
      }

      // Mark email as verified
      await db.markEmailAsVerified(user.id);

      // Send welcome email
      await sendEmail(
        user.email,
        'Email Verified - Welcome!',
        'Your email has been successfully verified. You now have full access to all features!',
        env
      );

      return json({
        message: 'Email successfully verified!',
        email_verified: true
      });
    }

    // Token from query parameter (for GET requests)
    const user = await db.getUserByVerificationToken(token);
    if (!user) {
      return json({ error: 'Invalid or expired verification token' }, 400);
    }

    // Mark email as verified
    await db.markEmailAsVerified(user.id);

    // Send welcome email
    await sendEmail(
      user.email,
      'Email Verified - Welcome!',
      'Your email has been successfully verified. You now have full access to all features!',
      env
    );

    return json({
      message: 'Email successfully verified!',
      email_verified: true
    });
  } catch (error) {
    console.error('Verify email error:', error);
    return json({ error: 'Invalid request' }, 400);
  }
}

/**
 * Resend email verification
 * POST /auth/resend-verification
 */
export async function handleResendVerification(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);
  const rateLimiter = new RateLimiter(env.DB);

  try {
    // Rate limiting
    const clientIp = request.headers.get('CF-Connecting-IP') || 'unknown';
    const rateLimitCheck = await rateLimiter.checkIpRateLimit(clientIp, '/auth/resend-verification', { windowMs: 3600000, maxRequests: 3 }); // 3 per hour

    if (!rateLimitCheck.allowed) {
      return json({
        error: 'Too many requests. Please try again later.',
        retry_after: Math.ceil((rateLimitCheck.reset - Date.now()) / 1000)
      }, 429);
    }

    const body = await request.json() as { email: string };
    const { email } = body;

    if (!email) {
      return json({ error: 'Email required' }, 400);
    }

    // Get user
    const user = await db.getUserByEmail(email);
    if (!user) {
      // Return success to prevent email enumeration
      return json({ message: 'If your email is registered, you will receive a verification email.' });
    }

    // Check if already verified
    if (user.email_verified === 1) {
      return json({ error: 'Email already verified' }, 400);
    }

    // Generate new verification token
    const verificationToken = Auth.generateSecureToken();
    await db.setEmailVerificationToken(user.id, verificationToken, 24 * 60 * 60 * 1000); // 24 hours

    // Send verification email
    const baseUrl = env.BASE_URL || 'https://your-domain.com';
    const verificationLink = `${baseUrl}/auth/verify-email?token=${encodeURIComponent(verificationToken)}`;
    await sendEmail(
      email,
      'Verify your email address',
      `Please verify your email by clicking this link: ${verificationLink}\n\nThis link expires in 24 hours.`,
      env
    );

    return json({
      message: 'If your email is registered, you will receive a verification email.'
    });
  } catch (error) {
    console.error('Resend verification error:', error);
    return json({ error: 'Invalid request body' }, 400);
  }
}

/**
 * Delete user account and all associated data
 * DELETE /auth/account
 * Requires: JWT access token or API key
 */
export async function handleDeleteAccount(request: Request, env: Env, r2Bucket: R2Bucket): Promise<Response> {
  const db = new Database(env.DB);

  try {
    // Verify authentication (JWT access token or API key)
    const user = await resolveAuthenticatedUser(request, env, db);
    if (!user) {
      return json({ error: 'Unauthorized' }, 401);
    }

    // Delete all user data from database and get R2 keys
    const { deletedImages } = await db.deleteUserAccount(user.id);

    // Delete all images from R2 storage
    for (const r2Key of deletedImages) {
      try {
        await r2Bucket.delete(r2Key);
      } catch (error) {
        // Log but don't fail - the database records are already deleted
        console.error(`Failed to delete R2 object ${r2Key}:`, error);
      }
    }

    return json({
      message: 'Account and all data have been permanently deleted',
      deleted_images_count: deletedImages.length
    });
  } catch (error) {
    console.error('Delete account error:', error);
    return json({ error: 'Failed to delete account' }, 500);
  }
}

/**
 * Sign in with Apple
 * POST /auth/apple
 *
 * Request body:
 * {
 *   identity_token: string,    // JWT from ASAuthorizationAppleIDCredential
 *   user_identifier: string,   // User ID from ASAuthorizationAppleIDCredential
 *   email?: string,           // Only provided on first sign-in
 *   full_name?: {             // Only provided on first sign-in
 *     given_name?: string,
 *     family_name?: string
 *   }
 * }
 */
export async function handleAppleSignIn(request: Request, env: Env): Promise<Response> {
  const db = new Database(env.DB);
  const rateLimiter = new RateLimiter(env.DB);

  try {
    // Rate limiting
    const clientIp = request.headers.get('CF-Connecting-IP') || 'unknown';
    const rateLimitCheck = await rateLimiter.checkIpRateLimit(
      clientIp,
      '/auth/apple',
      { windowMs: 900000, maxRequests: 10 } // 10 per 15 minutes
    );

    if (!rateLimitCheck.allowed) {
      return json({
        error: 'Too many sign-in attempts. Please try again later.',
        retry_after: Math.ceil((rateLimitCheck.reset - Date.now()) / 1000)
      }, 429);
    }

    const body = await request.json() as {
      identity_token: string;
      user_identifier: string;
      email?: string;
      full_name?: {
        given_name?: string;
        family_name?: string;
      };
    };

    const { identity_token, user_identifier, email: providedEmail } = body;

    if (!identity_token || !user_identifier) {
      return json({ error: 'identity_token and user_identifier are required' }, 400);
    }

    // Verify the identity token with Apple
    // Accept both iOS and macOS bundle IDs
    const iosClientId = env.APPLE_CLIENT_ID || 'com.codybontecou.imghost';
    const macClientId = env.APPLE_MAC_CLIENT_ID || `${iosClientId}.mac`;
    const tokenPayload = await AppleAuth.verifyIdentityToken(identity_token, [iosClientId, macClientId]);

    if (!tokenPayload) {
      return json({ error: 'Invalid Apple identity token' }, 401);
    }

    // Verify the user identifier matches the token's subject
    if (tokenPayload.sub !== user_identifier) {
      return json({ error: 'User identifier mismatch' }, 401);
    }

    const appleUserId = tokenPayload.sub;
    const email = tokenPayload.email || providedEmail;

    if (!email) {
      return json({ error: 'Email is required for sign-in' }, 400);
    }

    // Try to find existing user by Apple ID
    let user = await db.getUserByAppleId(appleUserId);

    if (!user) {
      // Check if user exists with this email (account linking)
      user = await db.getUserByEmail(email);

      if (user) {
        // Link Apple ID to existing account
        await db.linkAppleIdToUser(user.id, appleUserId);

        // Mark email as verified (Apple verifies emails)
        if (user.email_verified !== 1) {
          await db.markEmailAsVerified(user.id);
          user.email_verified = 1;
        }
      } else {
        // Create new user with Apple credentials on free tier
        user = await db.createAppleUser(email, appleUserId, 'free');

        // Create free subscription (always active, no expiry)
        await db.createSubscription(user.id, 'free', 'active');
      }
    }

    // Create JWT tokens (same as regular login)
    const jwtSecret = env.JWT_SECRET || 'default-secret-change-in-production';

    const accessToken = await Auth.createJWT(
      {
        sub: user.id,
        email: user.email,
        tier: user.subscription_tier,
        type: 'access'
      },
      3600, // 1 hour
      jwtSecret
    );

    const refreshToken = Auth.generateSecureToken();
    await db.createRefreshToken(user.id, refreshToken, 30 * 24 * 60 * 60 * 1000); // 30 days

    return json({
      access_token: accessToken,
      refresh_token: refreshToken,
      api_token: user.api_token,
      expires_in: 3600,
      token_type: 'Bearer',
      user_id: user.id,
      email: user.email,
      subscription_tier: user.subscription_tier,
      email_verified: true // Always true for Apple Sign-In
    });
  } catch (error) {
    console.error('Apple Sign-In error:', error);
    return json({ error: 'Authentication failed' }, 500);
  }
}
