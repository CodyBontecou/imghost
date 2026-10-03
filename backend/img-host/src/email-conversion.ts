import { Auth } from './auth';
import { AppleAuth } from './apple-auth';
import { Database } from './database';
import { RateLimiter } from './rate-limiter';
import { sendEmailSES } from './ses';

export interface EmailConversionEnv {
  DB: D1Database;
  JWT_SECRET: string;
  /** Deliberately absent/off until native clients, delivery and runtime QA pass. */
  EMAIL_CONVERSION_ENABLED?: string;
  APPLE_CLIENT_ID?: string;
  APPLE_MAC_CLIENT_ID?: string;
  EMAIL_FROM?: string;
  AWS_ACCESS_KEY_ID?: string;
  AWS_SECRET_ACCESS_KEY?: string;
  AWS_REGION?: string;
}

interface Challenge {
  id: string;
  user_id: string;
  purpose: string;
  phase: string;
  source_email: string;
  source_password_hash: string;
  apple_user_id: string;
  nonce: string;
  destination_email: string | null;
  email_token_hash: string | null;
  expires_at: number;
}

const SOURCE_TTL = 5 * 60 * 1000;
const EMAIL_TTL = 10 * 60 * 1000;
const PURPOSE = 'apple_to_email';

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

async function digest(token: string): Promise<string> {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token));
  return Array.from(new Uint8Array(bytes), b => b.toString(16).padStart(2, '0')).join('');
}

async function mail(env: EmailConversionEnv, to: string, subject: string, body: string): Promise<void> {
  // No console fallback. A pretend delivery would bypass destination verification.
  if (!env.AWS_ACCESS_KEY_ID || !env.AWS_SECRET_ACCESS_KEY || !env.EMAIL_FROM) {
    throw new Error('Email unavailable');
  }
  await sendEmailSES(to, subject, body, env.EMAIL_FROM,
    env.AWS_ACCESS_KEY_ID, env.AWS_SECRET_ACCESS_KEY, env.AWS_REGION || 'us-east-1');
}

/** Gated POST-only API. No administrative override, merging or Apple unlinking. */
export async function handleEmailConversion(request: Request, env: EmailConversionEnv): Promise<Response> {
  if (env.EMAIL_CONVERSION_ENABLED !== 'true') return json({ error: 'Not found' }, 404);
  const step = new URL(request.url).pathname.split('/').pop();
  if (request.method !== 'POST' || !['challenge', 'start', 'complete'].includes(step || '')) {
    return json({ error: 'Not found' }, 404);
  }
  // Require a real configured secret and access JWT; legacy API keys are not ownership proof.
  if (!env.JWT_SECRET || env.JWT_SECRET === 'default-secret-change-in-production') {
    return json({ error: 'Conversion unavailable' }, 503);
  }

  try {
    const bearer = Auth.extractBearerToken(request.headers.get('Authorization'));
    const payload = bearer ? await Auth.verifyJWT(bearer, env.JWT_SECRET) : null;
    if (!payload || payload.type !== 'access' || !Number.isFinite(payload.exp) ||
        payload.exp <= Math.floor(Date.now() / 1000)) return json({ error: 'Unauthorized' }, 401);
    const db = new Database(env.DB);
    const user = await db.getUserById(payload.sub);
    if (!user) return json({ error: 'Unauthorized' }, 401);
    if (!user.apple_user_id || user.is_anonymous === 1) {
      return json({ error: 'An Apple-linked account is required' }, 403);
    }
    const limit = await new RateLimiter(env.DB).checkUserRateLimit(user.id,
      `/auth/email-conversion/${step}`, { windowMs: 15 * 60 * 1000, maxRequests: 10 });
    if (!limit.allowed) return json({ error: 'Too many requests' }, 429);

    if (step === 'challenge') {
      const id = crypto.randomUUID();
      const nonce = Auth.generateSecureToken();
      const expires = Date.now() + SOURCE_TTL;
      // One active conversion per account; starting again invalidates all previous proofs/codes.
      await env.DB.prepare(`INSERT INTO email_conversion_challenges
        (id, user_id, purpose, phase, source_email, source_password_hash, apple_user_id, nonce, expires_at)
        VALUES (?, ?, ?, 'source', ?, ?, ?, ?, ?)
        ON CONFLICT(user_id) DO UPDATE SET id = excluded.id, purpose = excluded.purpose,
          phase = 'source', source_email = excluded.source_email,
          source_password_hash = excluded.source_password_hash, apple_user_id = excluded.apple_user_id,
          nonce = excluded.nonce, expires_at = excluded.expires_at,
          destination_email = NULL, email_token_hash = NULL, completed_operation = NULL`)
        .bind(id, user.id, PURPOSE, user.email, user.password_hash, user.apple_user_id, nonce, expires).run();
      return json({ challenge_id: id, nonce, expires_at: expires });
    }

    let body: Record<string, unknown>;
    try {
      const parsed = await request.json();
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error();
      body = parsed as Record<string, unknown>;
    } catch { return json({ error: 'Invalid request body' }, 400); }
    if (typeof body.challenge_id !== 'string' || body.challenge_id.length > 100) {
      return json({ error: 'Challenge required' }, 400);
    }
    const challenge = await env.DB.prepare(`SELECT * FROM email_conversion_challenges
      WHERE id = ? AND user_id = ? AND purpose = ? AND expires_at > ?`)
      .bind(body.challenge_id, user.id, PURPOSE, Date.now()).first<Challenge>();
    if (!challenge || challenge.source_email !== user.email ||
        challenge.source_password_hash !== user.password_hash || challenge.apple_user_id !== user.apple_user_id) {
      return json({ error: 'Invalid or expired challenge' }, 400);
    }

    if (step === 'start') {
      if (challenge.phase !== 'source' || typeof body.identity_token !== 'string' ||
          body.identity_token.length > 16000 || typeof body.destination_email !== 'string') {
        return json({ error: 'Fresh Apple proof and destination email required' }, 400);
      }
      // Apple nonce is passed verbatim to ASAuthorizationAppleIDRequest.nonce.
      const ios = env.APPLE_CLIENT_ID || 'com.codybontecou.imghost';
      const proof = await AppleAuth.verifyIdentityToken(body.identity_token,
        [ios, env.APPLE_MAC_CLIENT_ID || `${ios}.mac`], {
          nonce: challenge.nonce, issuedAfter: Math.floor((challenge.expires_at - SOURCE_TTL) / 1000),
        });
      if (!proof || proof.sub !== user.apple_user_id) return json({ error: 'Invalid Apple proof' }, 401);
      const destination = body.destination_email.trim().toLowerCase();
      // ASCII only for this staged contract; no implicit Unicode/case remapping of existing accounts.
      if (destination.length > 254 || !/^[\x21-\x7e]+$/.test(destination) ||
          !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(destination)) return json({ error: 'Invalid email' }, 400);
      const conflict = await env.DB.prepare('SELECT id FROM users WHERE lower(email) = lower(?)')
        .bind(destination).first();
      if (conflict) return json({ error: 'Destination unavailable; accounts cannot be merged' }, 409);
      const code = Auth.generateSecureToken();
      const codeHash = await digest(code);
      // Both mail deliveries must be accepted before the proof transitions to the email phase.
      // A delivery failure leaves all credentials untouched; starting again replaces the challenge.
      await mail(env, user.email, 'imghost login email change requested',
        'A fresh Apple authorization requested a login email/password change on your existing imghost account. ' +
        'Your library and subscription will not move. Apple access will remain enabled. ' +
        'If you did not request this, contact support privately. Never send passwords or codes to support.');
      await mail(env, destination, 'imghost login email verification code',
        `Your account conversion code is:\n\n${code}\n\nEnter this code in Account settings with your chosen password. ` +
        'It expires in 10 minutes and only works for the signed-in account that requested it. ' +
        'Ignore this email if you did not request it. Never send this code or your password to support.');
      const changed = await env.DB.prepare(`UPDATE email_conversion_challenges
        SET phase = 'email', destination_email = ?, email_token_hash = ?, expires_at = ?
        WHERE id = ? AND user_id = ? AND purpose = ? AND phase = 'source' AND expires_at > ?
          AND EXISTS (SELECT 1 FROM users WHERE id = ? AND email = ? AND password_hash = ? AND apple_user_id = ?)`)
        .bind(destination, codeHash, Date.now() + EMAIL_TTL, challenge.id, user.id, PURPOSE, Date.now(),
          user.id, challenge.source_email, challenge.source_password_hash, challenge.apple_user_id).run();
      if (changed.meta.changes !== 1) return json({ error: 'Challenge replaced or expired; start again' }, 400);
      return json({ challenge_id: challenge.id, message: 'Enter the code sent to your destination email.' });
    }

    if (challenge.phase !== 'email' || typeof body.code !== 'string' || body.code.length > 200 ||
        typeof body.new_password !== 'string' || body.new_password.length < 8 || body.new_password.length > 1024) {
      return json({ error: 'Email code and password (8–1024 characters) required' }, 400);
    }
    const codeHash = await digest(body.code.trim());
    if (codeHash !== challenge.email_token_hash) return json({ error: 'Invalid or expired code' }, 400);
    const passwordHash = await Auth.hashPassword(body.new_password);
    const operation = crypto.randomUUID();
    const now = Date.now(); // Recheck expiry, snapshots, conflict and single-use AFTER hashing.
    const results = await env.DB.batch([
      env.DB.prepare(`UPDATE users SET email = ?, password_hash = ?, email_verified = 1,
        email_verification_token = NULL, email_verification_token_expires = NULL,
        password_reset_token = NULL, password_reset_token_expires = NULL
        WHERE id = ? AND email = ? AND password_hash = ? AND apple_user_id = ?
          AND NOT EXISTS (SELECT 1 FROM users WHERE lower(email) = lower(?) AND id <> ?)
          AND EXISTS (SELECT 1 FROM email_conversion_challenges WHERE id = ? AND user_id = ?
            AND purpose = ? AND phase = 'email' AND email_token_hash = ? AND expires_at > ?)`)
        .bind(challenge.destination_email, passwordHash, user.id, challenge.source_email,
          challenge.source_password_hash, challenge.apple_user_id, challenge.destination_email, user.id,
          challenge.id, user.id, PURPOSE, codeHash, now),
      // changes() is the preceding UPDATE's count in this D1 transaction, not a stale read.
      env.DB.prepare(`UPDATE email_conversion_challenges SET phase = 'complete',
        email_token_hash = NULL, nonce = '', source_password_hash = '', completed_operation = ?
        WHERE id = ? AND changes() = 1`).bind(operation, challenge.id),
      env.DB.prepare(`UPDATE refresh_tokens SET revoked = 1 WHERE user_id = ?
        AND EXISTS (SELECT 1 FROM email_conversion_challenges WHERE completed_operation = ?)`)
        .bind(user.id, operation),
      env.DB.prepare(`INSERT INTO email_conversion_events (id, user_id, created_at)
        SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM email_conversion_challenges WHERE completed_operation = ?)`)
        .bind(operation, user.id, now, operation),
    ]);
    if (results[0].meta.changes !== 1) return json({ error: 'Challenge expired, replaced or destination unavailable' }, 409);

    // Credential change is already committed. Email/network failure must not report a failed conversion.
    let notificationPending = false;
    try {
      const notice = 'Your existing imghost account now has a verified login email and password. ' +
        'Apple sign-in still works. Refresh sessions were revoked; access tokens expire within one hour. ' +
        'API keys are unchanged. Your library and subscription are unchanged. ' +
        'If you did not make this change, contact support privately; never share passwords or codes.';
      await mail(env, challenge.source_email, 'imghost login email changed', notice);
      await mail(env, challenge.destination_email!, 'imghost login email changed', notice);
      await env.DB.prepare('UPDATE email_conversion_events SET notification_pending = 0 WHERE id = ?')
        .bind(operation).run();
    } catch { notificationPending = true; }
    return json({ user_id: user.id, email: challenge.destination_email, email_verified: true,
      apple_access_retained: true, notification_pending: notificationPending,
      message: 'Conversion completed. Log in with your new email and password.' });
  } catch {
    // Never log request, token, mail provider body, passwords, emails or customer details.
    console.error('Email conversion unavailable');
    return json({ error: 'Conversion unavailable; credentials were not intentionally removed. Apple sign-in remains available.' }, 503);
  }
}
