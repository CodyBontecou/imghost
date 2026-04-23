// Rate limiting utilities for preventing abuse

export interface RateLimitConfig {
  windowMs: number; // Time window in milliseconds
  maxRequests: number; // Maximum requests per window
}

export interface RateLimitResult {
  allowed: boolean;
  limit: number;
  remaining: number;
  reset: number; // Unix timestamp when the limit resets
}

export interface FailedAttemptResult {
  allowed: boolean;
  remainingAttempts: number;
  lockedUntil: number | null;
  requiresCaptcha: boolean;
}

export class RateLimiter {
  constructor(private db: D1Database) {}

  /**
   * Check user-based rate limit for authenticated requests
   */
  async checkUserRateLimit(
    userId: string,
    endpoint: string,
    config: RateLimitConfig
  ): Promise<RateLimitResult> {
    const now = Date.now();
    const windowStart = Math.floor(now / config.windowMs) * config.windowMs;
    const reset = windowStart + config.windowMs;

    // If maxRequests is 0, always deny (e.g., free tier with no upload allowance)
    if (config.maxRequests <= 0) {
      return {
        allowed: false,
        limit: 0,
        remaining: 0,
        reset,
      };
    }

    try {
      return await this.checkUserRateLimitCurrentSchema(userId, endpoint, config, now, windowStart, reset);
    } catch (error) {
      if (!this.isLegacyRateLimitSchemaError(error)) {
        throw error;
      }

      // Backward compatibility for deployments that still have the old 0002 schema
      // (identifier column instead of user_id, and no created_at/updated_at).
      console.warn('[RateLimiter] Falling back to legacy rate_limits schema');
      return await this.checkUserRateLimitLegacySchema(userId, endpoint, config, windowStart, reset);
    }
  }

  private async checkUserRateLimitCurrentSchema(
    userId: string,
    endpoint: string,
    config: RateLimitConfig,
    now: number,
    windowStart: number,
    reset: number
  ): Promise<RateLimitResult> {
    const existing = await this.db
      .prepare(
        'SELECT * FROM rate_limits WHERE user_id = ? AND endpoint = ? AND window_start = ?'
      )
      .bind(userId, endpoint, windowStart)
      .first<{ request_count: number }>();

    if (!existing) {
      const id = crypto.randomUUID();
      await this.db
        .prepare(
          `INSERT INTO rate_limits (id, user_id, endpoint, window_start, request_count, created_at, updated_at)
           VALUES (?, ?, ?, ?, 1, ?, ?)`
        )
        .bind(id, userId, endpoint, windowStart, now, now)
        .run();

      return {
        allowed: true,
        limit: config.maxRequests,
        remaining: config.maxRequests - 1,
        reset,
      };
    }

    if (existing.request_count >= config.maxRequests) {
      return {
        allowed: false,
        limit: config.maxRequests,
        remaining: 0,
        reset,
      };
    }

    await this.db
      .prepare(
        'UPDATE rate_limits SET request_count = request_count + 1, updated_at = ? WHERE user_id = ? AND endpoint = ? AND window_start = ?'
      )
      .bind(now, userId, endpoint, windowStart)
      .run();

    return {
      allowed: true,
      limit: config.maxRequests,
      remaining: config.maxRequests - existing.request_count - 1,
      reset,
    };
  }

  private async checkUserRateLimitLegacySchema(
    userId: string,
    endpoint: string,
    config: RateLimitConfig,
    windowStart: number,
    reset: number
  ): Promise<RateLimitResult> {
    const existing = await this.db
      .prepare(
        'SELECT * FROM rate_limits WHERE identifier = ? AND endpoint = ? AND window_start = ?'
      )
      .bind(userId, endpoint, windowStart)
      .first<{ request_count: number }>();

    if (!existing) {
      const id = crypto.randomUUID();
      await this.db
        .prepare(
          `INSERT INTO rate_limits (id, identifier, endpoint, request_count, window_start)
           VALUES (?, ?, ?, 1, ?)`
        )
        .bind(id, userId, endpoint, windowStart)
        .run();

      return {
        allowed: true,
        limit: config.maxRequests,
        remaining: config.maxRequests - 1,
        reset,
      };
    }

    if (existing.request_count >= config.maxRequests) {
      return {
        allowed: false,
        limit: config.maxRequests,
        remaining: 0,
        reset,
      };
    }

    await this.db
      .prepare(
        'UPDATE rate_limits SET request_count = request_count + 1 WHERE identifier = ? AND endpoint = ? AND window_start = ?'
      )
      .bind(userId, endpoint, windowStart)
      .run();

    return {
      allowed: true,
      limit: config.maxRequests,
      remaining: config.maxRequests - existing.request_count - 1,
      reset,
    };
  }

  private isLegacyRateLimitSchemaError(error: unknown): boolean {
    const message = String((error as Error | undefined)?.message ?? error ?? '').toLowerCase();
    if (!message.includes('rate_limits')) return false;

    return (
      message.includes('user_id') ||
      message.includes('created_at') ||
      message.includes('updated_at')
    );
  }

  /**
   * Check IP-based rate limit for unauthenticated requests
   */
  async checkIpRateLimit(
    ipAddress: string,
    endpoint: string,
    config: RateLimitConfig
  ): Promise<RateLimitResult> {
    const now = Date.now();
    const windowStart = Math.floor(now / config.windowMs) * config.windowMs;
    const reset = windowStart + config.windowMs;

    // Get or create rate limit record
    const existing = await this.db
      .prepare(
        'SELECT * FROM ip_rate_limits WHERE ip_address = ? AND endpoint = ? AND window_start = ?'
      )
      .bind(ipAddress, endpoint, windowStart)
      .first<{ request_count: number }>();

    if (!existing) {
      // Create new record
      const id = crypto.randomUUID();
      await this.db
        .prepare(
          `INSERT INTO ip_rate_limits (id, ip_address, endpoint, window_start, request_count, created_at, updated_at)
           VALUES (?, ?, ?, ?, 1, ?, ?)`
        )
        .bind(id, ipAddress, endpoint, windowStart, now, now)
        .run();

      return {
        allowed: true,
        limit: config.maxRequests,
        remaining: config.maxRequests - 1,
        reset,
      };
    }

    // Check if limit exceeded
    if (existing.request_count >= config.maxRequests) {
      return {
        allowed: false,
        limit: config.maxRequests,
        remaining: 0,
        reset,
      };
    }

    // Increment count
    await this.db
      .prepare(
        'UPDATE ip_rate_limits SET request_count = request_count + 1, updated_at = ? WHERE ip_address = ? AND endpoint = ? AND window_start = ?'
      )
      .bind(now, ipAddress, endpoint, windowStart)
      .run();

    return {
      allowed: true,
      limit: config.maxRequests,
      remaining: config.maxRequests - existing.request_count - 1,
      reset,
    };
  }

  /**
   * Track failed login/register attempts with exponential backoff
   */
  async recordFailedAttempt(
    identifier: string, // email or IP
    attemptType: 'login' | 'register'
  ): Promise<FailedAttemptResult> {
    const now = Date.now();

    const existing = await this.db
      .prepare(
        'SELECT * FROM failed_attempts WHERE identifier = ? AND attempt_type = ?'
      )
      .bind(identifier, attemptType)
      .first<{
        attempt_count: number;
        locked_until: number | null;
        last_attempt_at: number;
      }>();

    if (!existing) {
      // First failed attempt
      const id = crypto.randomUUID();
      await this.db
        .prepare(
          `INSERT INTO failed_attempts (id, identifier, attempt_type, attempt_count, last_attempt_at, created_at)
           VALUES (?, ?, ?, 1, ?, ?)`
        )
        .bind(id, identifier, attemptType, now, now)
        .run();

      return {
        allowed: true,
        remainingAttempts: 4, // 5 attempts total before first lockout
        lockedUntil: null,
        requiresCaptcha: false,
      };
    }

    // Check if currently locked
    if (existing.locked_until && existing.locked_until > now) {
      return {
        allowed: false,
        remainingAttempts: 0,
        lockedUntil: existing.locked_until,
        requiresCaptcha: true,
      };
    }

    // Reset count if last attempt was more than 1 hour ago
    const oneHourAgo = now - 60 * 60 * 1000;
    if (existing.last_attempt_at < oneHourAgo) {
      await this.db
        .prepare(
          'UPDATE failed_attempts SET attempt_count = 1, last_attempt_at = ?, locked_until = NULL WHERE identifier = ? AND attempt_type = ?'
        )
        .bind(now, identifier, attemptType)
        .run();

      return {
        allowed: true,
        remainingAttempts: 4,
        lockedUntil: null,
        requiresCaptcha: false,
      };
    }

    // Increment count and apply exponential backoff
    const newCount = existing.attempt_count + 1;
    let lockedUntil: number | null = null;
    let requiresCaptcha = newCount >= 3; // Require CAPTCHA after 3 failed attempts

    // Exponential backoff: 1 min, 5 min, 15 min, 1 hour, 24 hours
    if (newCount >= 5) {
      const lockoutMinutes = [1, 5, 15, 60, 1440][Math.min(newCount - 5, 4)];
      lockedUntil = now + lockoutMinutes * 60 * 1000;
    }

    await this.db
      .prepare(
        'UPDATE failed_attempts SET attempt_count = ?, last_attempt_at = ?, locked_until = ? WHERE identifier = ? AND attempt_type = ?'
      )
      .bind(newCount, now, lockedUntil, identifier, attemptType)
      .run();

    return {
      allowed: lockedUntil === null,
      remainingAttempts: Math.max(0, 5 - newCount),
      lockedUntil,
      requiresCaptcha,
    };
  }

  /**
   * Check if an identifier is currently locked due to failed attempts
   */
  async checkFailedAttempts(
    identifier: string,
    attemptType: 'login' | 'register'
  ): Promise<FailedAttemptResult> {
    const now = Date.now();

    const existing = await this.db
      .prepare(
        'SELECT * FROM failed_attempts WHERE identifier = ? AND attempt_type = ?'
      )
      .bind(identifier, attemptType)
      .first<{
        attempt_count: number;
        locked_until: number | null;
        last_attempt_at: number;
      }>();

    if (!existing) {
      return {
        allowed: true,
        remainingAttempts: 5,
        lockedUntil: null,
        requiresCaptcha: false,
      };
    }

    // Check if currently locked
    if (existing.locked_until && existing.locked_until > now) {
      return {
        allowed: false,
        remainingAttempts: 0,
        lockedUntil: existing.locked_until,
        requiresCaptcha: true,
      };
    }

    // Reset count if last attempt was more than 1 hour ago
    const oneHourAgo = now - 60 * 60 * 1000;
    if (existing.last_attempt_at < oneHourAgo) {
      return {
        allowed: true,
        remainingAttempts: 5,
        lockedUntil: null,
        requiresCaptcha: false,
      };
    }

    return {
      allowed: true,
      remainingAttempts: Math.max(0, 5 - existing.attempt_count),
      lockedUntil: null,
      requiresCaptcha: existing.attempt_count >= 3,
    };
  }

  /**
   * Clear failed attempts after successful login
   */
  async clearFailedAttempts(
    identifier: string,
    attemptType: 'login' | 'register'
  ): Promise<void> {
    await this.db
      .prepare(
        'DELETE FROM failed_attempts WHERE identifier = ? AND attempt_type = ?'
      )
      .bind(identifier, attemptType)
      .run();
  }

  /**
   * Check if user is currently suspended
   */
  async checkUserSuspension(userId: string): Promise<{
    suspended: boolean;
    reason?: string;
    until?: number | null;
  }> {
    const now = Date.now();

    const suspension = await this.db
      .prepare(
        `SELECT * FROM user_suspensions
         WHERE user_id = ? AND is_active = 1
         AND (suspended_until IS NULL OR suspended_until > ?)
         ORDER BY suspended_at DESC LIMIT 1`
      )
      .bind(userId, now)
      .first<{
        reason: string;
        suspended_until: number | null;
      }>();

    if (!suspension) {
      return { suspended: false };
    }

    return {
      suspended: true,
      reason: suspension.reason,
      until: suspension.suspended_until,
    };
  }

  /**
   * Suspend a user for policy violations
   */
  async suspendUser(
    userId: string,
    reason: string,
    durationMs: number | null, // null for permanent
    suspendedBy: string = 'system'
  ): Promise<void> {
    const now = Date.now();
    const suspendedUntil = durationMs ? now + durationMs : null;
    const id = crypto.randomUUID();

    await this.db
      .prepare(
        `INSERT INTO user_suspensions (id, user_id, reason, suspended_at, suspended_until, suspended_by, is_active)
         VALUES (?, ?, ?, ?, ?, ?, 1)`
      )
      .bind(id, userId, reason, now, suspendedUntil, suspendedBy)
      .run();
  }

  /**
   * Cleanup old rate limit records (for maintenance)
   */
  async cleanupOldRateLimits(hoursToKeep = 24): Promise<void> {
    const cutoffTimestamp = Date.now() - hoursToKeep * 60 * 60 * 1000;

    await this.db
      .prepare('DELETE FROM rate_limits WHERE window_start < ?')
      .bind(cutoffTimestamp)
      .run();

    await this.db
      .prepare('DELETE FROM ip_rate_limits WHERE window_start < ?')
      .bind(cutoffTimestamp)
      .run();
  }
}

/**
 * Get rate limit configuration based on subscription tier
 * Note: Upload limits have been removed - storage limits handle resource control.
 * Only API rate limits remain for abuse prevention.
 */
export function getRateLimitConfig(
  tier: string,
  endpoint: string
): RateLimitConfig {
  const dailyMs = 24 * 60 * 60 * 1000; // 24 hours in milliseconds

  // Tier-based API limits per day (uploads are unlimited, controlled by storage limits)
  const tierLimits: Record<string, number> = {
    free: 100,
    trial: 5000,
    starter: 5000,
    pro: 50000,
    business: 999999,
    enterprise: 999999,
  };

  const apiLimit = tierLimits[tier] || tierLimits.free;

  return {
    windowMs: dailyMs,
    maxRequests: apiLimit,
  };
}

/**
 * IP-based rate limits for unauthenticated endpoints (stricter)
 */
export function getIpRateLimitConfig(endpoint: string): RateLimitConfig {
  const hourMs = 60 * 60 * 1000;

  // Registration/Login: 10 attempts per hour
  if (endpoint.includes('/auth/register') || endpoint.includes('/auth/login')) {
    return {
      windowMs: hourMs,
      maxRequests: 10,
    };
  }

  // Default: 100 requests per hour
  return {
    windowMs: hourMs,
    maxRequests: 100,
  };
}
