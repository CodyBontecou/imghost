// Database utilities and types for D1

export interface User {
  id: string;
  email: string;
  password_hash: string;
  created_at: number;
  subscription_tier: 'trial' | 'pro' | 'enterprise';
  api_token: string;
  storage_limit_bytes: number;
  email_verified: number;
  email_verification_token?: string | null;
  email_verification_token_expires?: number | null;
  password_reset_token?: string | null;
  password_reset_token_expires?: number | null;
  apple_user_id?: string | null;
}

export interface RefreshToken {
  id: string;
  user_id: string;
  token: string;
  expires_at: number;
  created_at: number;
  revoked: number;
}

export interface RateLimit {
  id: string;
  identifier: string;
  endpoint: string;
  request_count: number;
  window_start: number;
}

export interface Image {
  id: string;
  user_id: string;
  r2_key: string;
  filename: string;
  size_bytes: number;
  content_type: string;
  created_at: number;
  delete_token: string;
}

export interface Subscription {
  id: string;
  user_id: string;
  tier: 'trial' | 'pro' | 'enterprise';
  status: 'active' | 'cancelled' | 'past_due' | 'trialing' | 'expired';
  stripe_customer_id?: string;
  stripe_subscription_id?: string;
  apple_original_transaction_id?: string;
  apple_product_id?: string;
  trial_ends_at?: number;
  current_period_start?: number;
  current_period_end?: number;
  cancel_at_period_end: boolean;
  created_at: number;
  updated_at: number;
}

export interface StorageUsage {
  user_id: string;
  image_count: number;
  total_bytes_used: number;
}

export interface TierLimits {
  tier: string;
  storage_limit_bytes: number;
  max_file_size_bytes: number;
  max_images: number | null;
  features: string; // JSON string
}

export interface ExportJob {
  id: string;
  user_id: string;
  status: 'processing' | 'completed' | 'failed';
  image_count: number;
  archive_size: number;
  download_url: string | null;
  expires_at: number | null;
  error_message: string | null;
  created_at: number;
  completed_at: number | null;
}

export class Database {
  constructor(private db: D1Database) {}

  // Helper to get storage limit for tier
  private getStorageLimitForTier(tier: 'trial' | 'pro' | 'enterprise'): number {
    switch (tier) {
      case 'trial': return 10000000000;   // 10GB
      case 'pro': return 10000000000;     // 10GB
      case 'enterprise': return 100000000000; // 100GB
      default: return 10000000000;        // 10GB default
    }
  }

  // User operations
  async createUser(
    email: string,
    passwordHash: string,
    apiToken: string,
    tier: 'trial' | 'pro' | 'enterprise' = 'trial'
  ): Promise<User> {
    const id = crypto.randomUUID();
    const createdAt = Date.now();
    const storageLimitBytes = this.getStorageLimitForTier(tier);

    await this.db
      .prepare(
        `INSERT INTO users (id, email, password_hash, created_at, subscription_tier, api_token, storage_limit_bytes)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      )
      .bind(id, email, passwordHash, createdAt, tier, apiToken, storageLimitBytes)
      .run();

    return {
      id,
      email,
      password_hash: passwordHash,
      created_at: createdAt,
      subscription_tier: tier,
      api_token: apiToken,
      storage_limit_bytes: storageLimitBytes,
      email_verified: 0,
    };
  }

  async getUserByEmail(email: string): Promise<User | null> {
    const result = await this.db
      .prepare('SELECT * FROM users WHERE email = ?')
      .bind(email)
      .first<User>();
    return result || null;
  }

  async getUserByApiToken(apiToken: string): Promise<User | null> {
    const result = await this.db
      .prepare('SELECT * FROM users WHERE api_token = ?')
      .bind(apiToken)
      .first<User>();
    return result || null;
  }

  async getUserById(id: string): Promise<User | null> {
    const result = await this.db
      .prepare('SELECT * FROM users WHERE id = ?')
      .bind(id)
      .first<User>();
    return result || null;
  }

  async getUserByAppleId(appleUserId: string): Promise<User | null> {
    const result = await this.db
      .prepare('SELECT * FROM users WHERE apple_user_id = ?')
      .bind(appleUserId)
      .first<User>();
    return result || null;
  }

  async linkAppleIdToUser(userId: string, appleUserId: string): Promise<void> {
    await this.db
      .prepare('UPDATE users SET apple_user_id = ? WHERE id = ?')
      .bind(appleUserId, userId)
      .run();
  }

  async createAppleUser(
    email: string,
    appleUserId: string,
    tier: 'trial' | 'pro' | 'enterprise' = 'trial'
  ): Promise<User> {
    const id = crypto.randomUUID();
    const createdAt = Date.now();
    const storageLimitBytes = this.getStorageLimitForTier(tier);
    const apiToken = crypto.randomUUID();

    // Use special marker for Apple-only accounts (no password)
    const passwordHash = 'APPLE_SIGN_IN_ONLY';

    await this.db
      .prepare(
        `INSERT INTO users (id, email, password_hash, created_at, subscription_tier, api_token, storage_limit_bytes, email_verified, apple_user_id)
         VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)`
      )
      .bind(id, email, passwordHash, createdAt, tier, apiToken, storageLimitBytes, appleUserId)
      .run();

    return {
      id,
      email,
      password_hash: passwordHash,
      created_at: createdAt,
      subscription_tier: tier,
      api_token: apiToken,
      storage_limit_bytes: storageLimitBytes,
      email_verified: 1,
      apple_user_id: appleUserId,
    };
  }

  async updateUserTier(userId: string, tier: 'trial' | 'pro' | 'enterprise'): Promise<void> {
    const storageLimitBytes = this.getStorageLimitForTier(tier);
    await this.db
      .prepare('UPDATE users SET subscription_tier = ?, storage_limit_bytes = ? WHERE id = ?')
      .bind(tier, storageLimitBytes, userId)
      .run();
  }

  // Image operations
  async createImage(
    userId: string,
    r2Key: string,
    filename: string,
    sizeBytes: number,
    contentType: string,
    deleteToken: string
  ): Promise<Image> {
    const id = crypto.randomUUID().slice(0, 8);
    const createdAt = Date.now();

    await this.db
      .prepare(
        `INSERT INTO images (id, user_id, r2_key, filename, size_bytes, content_type, created_at, delete_token)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .bind(id, userId, r2Key, filename, sizeBytes, contentType, createdAt, deleteToken)
      .run();

    return {
      id,
      user_id: userId,
      r2_key: r2Key,
      filename,
      size_bytes: sizeBytes,
      content_type: contentType,
      created_at: createdAt,
      delete_token: deleteToken,
    };
  }

  async getImageByR2Key(r2Key: string): Promise<Image | null> {
    const result = await this.db
      .prepare('SELECT * FROM images WHERE r2_key = ?')
      .bind(r2Key)
      .first<Image>();
    return result || null;
  }

  async getImageById(id: string): Promise<Image | null> {
    const result = await this.db
      .prepare('SELECT * FROM images WHERE id = ?')
      .bind(id)
      .first<Image>();
    return result || null;
  }

  async getImagesByUserId(userId: string, limit = 100, offset = 0): Promise<Image[]> {
    const result = await this.db
      .prepare('SELECT * FROM images WHERE user_id = ? ORDER BY created_at DESC LIMIT ? OFFSET ?')
      .bind(userId, limit, offset)
      .all<Image>();
    return result.results || [];
  }

  async deleteImage(id: string): Promise<boolean> {
    const result = await this.db
      .prepare('DELETE FROM images WHERE id = ?')
      .bind(id)
      .run();
    return result.success;
  }

  async verifyDeleteToken(id: string, deleteToken: string): Promise<boolean> {
    const result = await this.db
      .prepare('SELECT delete_token FROM images WHERE id = ?')
      .bind(id)
      .first<{ delete_token: string }>();

    return result?.delete_token === deleteToken;
  }

  // Storage usage operations
  async getStorageUsage(userId: string): Promise<StorageUsage> {
    const result = await this.db
      .prepare('SELECT * FROM storage_usage WHERE user_id = ?')
      .bind(userId)
      .first<StorageUsage>();

    return result || { user_id: userId, image_count: 0, total_bytes_used: 0 };
  }

  async checkStorageLimit(userId: string, additionalBytes: number): Promise<boolean> {
    const user = await this.getUserById(userId);
    if (!user) return false;

    const usage = await this.getStorageUsage(userId);
    return (usage.total_bytes_used + additionalBytes) <= user.storage_limit_bytes;
  }

  // Subscription operations
  async createSubscription(
    userId: string,
    tier: 'trial' | 'pro' | 'enterprise',
    status: 'active' | 'cancelled' | 'past_due' | 'trialing' | 'expired',
    stripeCustomerId?: string,
    stripeSubscriptionId?: string,
    trialDurationMs?: number
  ): Promise<Subscription> {
    const id = crypto.randomUUID();
    const now = Date.now();

    // Set trial_ends_at and current_period_end for trial subscriptions
    const trialEndsAt = (status === 'trialing' && trialDurationMs)
      ? now + trialDurationMs
      : null;
    const currentPeriodEnd = trialEndsAt;

    await this.db
      .prepare(
        `INSERT INTO subscriptions (id, user_id, tier, status, stripe_customer_id, stripe_subscription_id, cancel_at_period_end, trial_ends_at, current_period_end, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)`
      )
      .bind(id, userId, tier, status, stripeCustomerId || null, stripeSubscriptionId || null, trialEndsAt, currentPeriodEnd, now, now)
      .run();

    return {
      id,
      user_id: userId,
      tier,
      status,
      stripe_customer_id: stripeCustomerId,
      stripe_subscription_id: stripeSubscriptionId,
      trial_ends_at: trialEndsAt || undefined,
      current_period_end: currentPeriodEnd || undefined,
      cancel_at_period_end: false,
      created_at: now,
      updated_at: now,
    };
  }

  // Create subscription with Apple IAP details
  async createAppleSubscription(
    userId: string,
    tier: 'trial' | 'pro',
    status: 'active' | 'trialing' | 'expired',
    appleOriginalTransactionId: string,
    appleProductId: string,
    currentPeriodEnd: number,
    trialEndsAt?: number
  ): Promise<Subscription> {
    const id = crypto.randomUUID();
    const now = Date.now();

    await this.db
      .prepare(
        `INSERT INTO subscriptions (id, user_id, tier, status, apple_original_transaction_id, apple_product_id, current_period_start, current_period_end, trial_ends_at, cancel_at_period_end, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)`
      )
      .bind(id, userId, tier, status, appleOriginalTransactionId, appleProductId, now, currentPeriodEnd, trialEndsAt || null, now, now)
      .run();

    // Also update user tier
    await this.updateUserTier(userId, tier);

    return {
      id,
      user_id: userId,
      tier,
      status,
      apple_original_transaction_id: appleOriginalTransactionId,
      apple_product_id: appleProductId,
      current_period_start: now,
      current_period_end: currentPeriodEnd,
      trial_ends_at: trialEndsAt,
      cancel_at_period_end: false,
      created_at: now,
      updated_at: now,
    };
  }

  // Get subscription by Apple transaction ID
  async getSubscriptionByAppleTransactionId(transactionId: string): Promise<Subscription | null> {
    const result = await this.db
      .prepare('SELECT * FROM subscriptions WHERE apple_original_transaction_id = ?')
      .bind(transactionId)
      .first<Subscription>();
    return result || null;
  }

  // Update subscription with Apple IAP details
  async updateSubscriptionWithApple(
    userId: string,
    tier: 'trial' | 'pro',
    status: 'active' | 'trialing' | 'expired',
    appleOriginalTransactionId: string,
    appleProductId: string,
    currentPeriodEnd: number,
    trialEndsAt?: number
  ): Promise<void> {
    const now = Date.now();

    await this.db
      .prepare(
        `UPDATE subscriptions
         SET tier = ?, status = ?, apple_original_transaction_id = ?, apple_product_id = ?,
             current_period_end = ?, trial_ends_at = ?, updated_at = ?
         WHERE user_id = ?`
      )
      .bind(tier, status, appleOriginalTransactionId, appleProductId, currentPeriodEnd, trialEndsAt || null, now, userId)
      .run();

    // Also update user tier
    await this.updateUserTier(userId, tier);
  }

  // Update subscription status and tier
  async updateSubscriptionTierAndStatus(
    userId: string,
    tier: 'trial' | 'pro' | 'enterprise',
    status: 'active' | 'cancelled' | 'past_due' | 'trialing' | 'expired'
  ): Promise<void> {
    const now = Date.now();
    await this.db
      .prepare('UPDATE subscriptions SET tier = ?, status = ?, updated_at = ? WHERE user_id = ?')
      .bind(tier, status, now, userId)
      .run();

    // Also update user tier
    await this.updateUserTier(userId, tier);
  }

  async getSubscriptionByUserId(userId: string): Promise<Subscription | null> {
    const result = await this.db
      .prepare('SELECT * FROM subscriptions WHERE user_id = ?')
      .bind(userId)
      .first<Subscription>();
    return result || null;
  }

  async updateSubscriptionStatus(
    userId: string,
    status: 'active' | 'cancelled' | 'past_due' | 'trialing' | 'expired'
  ): Promise<void> {
    const now = Date.now();
    await this.db
      .prepare('UPDATE subscriptions SET status = ?, updated_at = ? WHERE user_id = ?')
      .bind(status, now, userId)
      .run();
  }

  // Tier limits operations
  async getTierLimits(tier: string): Promise<TierLimits | null> {
    const result = await this.db
      .prepare('SELECT * FROM tier_limits WHERE tier = ?')
      .bind(tier)
      .first<TierLimits>();
    return result || null;
  }

  // API usage tracking
  async logApiUsage(
    userId: string,
    endpoint: string,
    method: string,
    responseStatus: number
  ): Promise<void> {
    const id = crypto.randomUUID();
    const timestamp = Date.now();

    await this.db
      .prepare(
        'INSERT INTO api_usage (id, user_id, endpoint, method, timestamp, response_status) VALUES (?, ?, ?, ?, ?, ?)'
      )
      .bind(id, userId, endpoint, method, timestamp, responseStatus)
      .run();
  }

  // Cleanup old API usage logs (for maintenance)
  async cleanupOldApiUsage(daysToKeep = 30): Promise<void> {
    const cutoffTimestamp = Date.now() - (daysToKeep * 24 * 60 * 60 * 1000);
    await this.db
      .prepare('DELETE FROM api_usage WHERE timestamp < ?')
      .bind(cutoffTimestamp)
      .run();
  }

  // Email verification operations
  async setEmailVerificationToken(userId: string, token: string, expiresInMs: number): Promise<void> {
    const expiresAt = Date.now() + expiresInMs;
    await this.db
      .prepare('UPDATE users SET email_verification_token = ?, email_verification_token_expires = ? WHERE id = ?')
      .bind(token, expiresAt, userId)
      .run();
  }

  async getUserByVerificationToken(token: string): Promise<User | null> {
    const now = Date.now();
    const result = await this.db
      .prepare('SELECT * FROM users WHERE email_verification_token = ? AND email_verification_token_expires > ?')
      .bind(token, now)
      .first<User>();
    return result || null;
  }

  async markEmailAsVerified(userId: string): Promise<void> {
    await this.db
      .prepare('UPDATE users SET email_verified = 1, email_verification_token = NULL, email_verification_token_expires = NULL WHERE id = ?')
      .bind(userId)
      .run();
  }

  // Password reset operations
  async setPasswordResetToken(userId: string, token: string, expiresInMs: number): Promise<void> {
    const expiresAt = Date.now() + expiresInMs;
    await this.db
      .prepare('UPDATE users SET password_reset_token = ?, password_reset_token_expires = ? WHERE id = ?')
      .bind(token, expiresAt, userId)
      .run();
  }

  async getUserByPasswordResetToken(token: string): Promise<User | null> {
    const now = Date.now();
    const result = await this.db
      .prepare('SELECT * FROM users WHERE password_reset_token = ? AND password_reset_token_expires > ?')
      .bind(token, now)
      .first<User>();
    return result || null;
  }

  async updatePassword(userId: string, passwordHash: string): Promise<void> {
    await this.db
      .prepare('UPDATE users SET password_hash = ?, password_reset_token = NULL, password_reset_token_expires = NULL WHERE id = ?')
      .bind(passwordHash, userId)
      .run();
  }

  // Refresh token operations
  async createRefreshToken(userId: string, token: string, expiresInMs: number): Promise<RefreshToken> {
    const id = crypto.randomUUID();
    const createdAt = Date.now();
    const expiresAt = createdAt + expiresInMs;

    await this.db
      .prepare(
        'INSERT INTO refresh_tokens (id, user_id, token, expires_at, created_at, revoked) VALUES (?, ?, ?, ?, ?, 0)'
      )
      .bind(id, userId, token, expiresAt, createdAt)
      .run();

    return {
      id,
      user_id: userId,
      token,
      expires_at: expiresAt,
      created_at: createdAt,
      revoked: 0,
    };
  }

  async getRefreshToken(token: string): Promise<RefreshToken | null> {
    const result = await this.db
      .prepare('SELECT * FROM refresh_tokens WHERE token = ? AND revoked = 0 AND expires_at > ?')
      .bind(token, Date.now())
      .first<RefreshToken>();
    return result || null;
  }

  async revokeRefreshToken(token: string): Promise<void> {
    await this.db
      .prepare('UPDATE refresh_tokens SET revoked = 1 WHERE token = ?')
      .bind(token)
      .run();
  }

  async revokeAllUserRefreshTokens(userId: string): Promise<void> {
    await this.db
      .prepare('UPDATE refresh_tokens SET revoked = 1 WHERE user_id = ?')
      .bind(userId)
      .run();
  }

  async cleanupExpiredRefreshTokens(): Promise<void> {
    const now = Date.now();
    await this.db
      .prepare('DELETE FROM refresh_tokens WHERE expires_at < ?')
      .bind(now)
      .run();
  }

  // Rate limiting operations
  async checkRateLimit(
    identifier: string,
    endpoint: string,
    maxRequests: number,
    windowMs: number
  ): Promise<{ allowed: boolean; remainingRequests: number; resetTime: number }> {
    const now = Date.now();
    const windowStart = Math.floor(now / windowMs) * windowMs;

    // Try to get or create rate limit record
    const existing = await this.db
      .prepare('SELECT * FROM rate_limits WHERE identifier = ? AND endpoint = ? AND window_start = ?')
      .bind(identifier, endpoint, windowStart)
      .first<RateLimit>();

    if (!existing) {
      // Create new rate limit record
      const id = crypto.randomUUID();
      await this.db
        .prepare(
          'INSERT INTO rate_limits (id, identifier, endpoint, request_count, window_start) VALUES (?, ?, ?, 1, ?)'
        )
        .bind(id, identifier, endpoint, windowStart)
        .run();

      return {
        allowed: true,
        remainingRequests: maxRequests - 1,
        resetTime: windowStart + windowMs,
      };
    }

    if (existing.request_count >= maxRequests) {
      return {
        allowed: false,
        remainingRequests: 0,
        resetTime: windowStart + windowMs,
      };
    }

    // Increment request count
    await this.db
      .prepare('UPDATE rate_limits SET request_count = request_count + 1 WHERE id = ?')
      .bind(existing.id)
      .run();

    return {
      allowed: true,
      remainingRequests: maxRequests - existing.request_count - 1,
      resetTime: windowStart + windowMs,
    };
  }

  async cleanupOldRateLimits(windowMs: number): Promise<void> {
    const cutoffTime = Date.now() - windowMs;
    await this.db
      .prepare('DELETE FROM rate_limits WHERE window_start < ?')
      .bind(cutoffTime)
      .run();
  }

  // Export job operations
  async createExportJob(userId: string): Promise<ExportJob> {
    const id = `export_${crypto.randomUUID().slice(0, 8)}`;
    const createdAt = Date.now();

    await this.db
      .prepare(
        `INSERT INTO export_jobs (id, user_id, status, image_count, archive_size, created_at)
         VALUES (?, ?, 'processing', 0, 0, ?)`
      )
      .bind(id, userId, createdAt)
      .run();

    return {
      id,
      user_id: userId,
      status: 'processing',
      image_count: 0,
      archive_size: 0,
      download_url: null,
      expires_at: null,
      error_message: null,
      created_at: createdAt,
      completed_at: null,
    };
  }

  async getExportJob(jobId: string): Promise<ExportJob | null> {
    const result = await this.db
      .prepare('SELECT * FROM export_jobs WHERE id = ?')
      .bind(jobId)
      .first<ExportJob>();
    return result || null;
  }

  async updateExportJob(
    jobId: string,
    status: 'processing' | 'completed' | 'failed',
    imageCount: number,
    archiveSize: number,
    downloadUrl?: string,
    expiresAt?: number,
    errorMessage?: string
  ): Promise<void> {
    const completedAt = status !== 'processing' ? Date.now() : null;

    await this.db
      .prepare(
        `UPDATE export_jobs
         SET status = ?, image_count = ?, archive_size = ?, download_url = ?,
             expires_at = ?, completed_at = ?, error_message = ?
         WHERE id = ?`
      )
      .bind(status, imageCount, archiveSize, downloadUrl || null, expiresAt || null, completedAt, errorMessage || null, jobId)
      .run();
  }

  async checkExportRateLimit(userId: string): Promise<boolean> {
    const oneHourAgo = Date.now() - (60 * 60 * 1000);
    const maxExportsPerHour = 5;

    const result = await this.db
      .prepare('SELECT export_count, window_start FROM export_rate_limits WHERE user_id = ?')
      .bind(userId)
      .first<{ export_count: number; window_start: number }>();

    if (!result) {
      return true; // No previous export, allowed
    }

    // If window has expired, allow (will reset on update)
    if (result.window_start < oneHourAgo) {
      return true;
    }

    // Check if under limit within current window
    return result.export_count < maxExportsPerHour;
  }

  async updateExportRateLimit(userId: string): Promise<void> {
    const now = Date.now();
    const oneHourAgo = now - (60 * 60 * 1000);

    // Check if we need to reset the window
    const existing = await this.db
      .prepare('SELECT window_start FROM export_rate_limits WHERE user_id = ?')
      .bind(userId)
      .first<{ window_start: number }>();

    if (!existing || existing.window_start < oneHourAgo) {
      // Start new window
      await this.db
        .prepare(
          `INSERT INTO export_rate_limits (user_id, last_export_at, export_count, window_start)
           VALUES (?, ?, 1, ?)
           ON CONFLICT(user_id) DO UPDATE SET last_export_at = ?, export_count = 1, window_start = ?`
        )
        .bind(userId, now, now, now, now)
        .run();
    } else {
      // Increment count in existing window
      await this.db
        .prepare(
          `UPDATE export_rate_limits SET last_export_at = ?, export_count = export_count + 1 WHERE user_id = ?`
        )
        .bind(now, userId)
        .run();
    }
  }

  async cleanupExpiredExports(): Promise<void> {
    const now = Date.now();
    await this.db
      .prepare('DELETE FROM export_jobs WHERE expires_at IS NOT NULL AND expires_at < ?')
      .bind(now)
      .run();
  }

  // Delete user account and all associated data
  async deleteUserAccount(userId: string): Promise<{ deletedImages: string[] }> {
    // Get all user images first (we need the r2 keys to delete from storage)
    const images = await this.getImagesByUserId(userId, 10000, 0);
    const r2Keys = images.map(img => img.r2_key);

    // Delete all related data in order (respecting foreign key constraints)
    // Delete images
    await this.db
      .prepare('DELETE FROM images WHERE user_id = ?')
      .bind(userId)
      .run();

    // Delete subscriptions
    await this.db
      .prepare('DELETE FROM subscriptions WHERE user_id = ?')
      .bind(userId)
      .run();

    // Delete refresh tokens
    await this.db
      .prepare('DELETE FROM refresh_tokens WHERE user_id = ?')
      .bind(userId)
      .run();

    // Delete export jobs
    await this.db
      .prepare('DELETE FROM export_jobs WHERE user_id = ?')
      .bind(userId)
      .run();

    // Delete export rate limits
    await this.db
      .prepare('DELETE FROM export_rate_limits WHERE user_id = ?')
      .bind(userId)
      .run();

    // Delete API usage logs
    await this.db
      .prepare('DELETE FROM api_usage WHERE user_id = ?')
      .bind(userId)
      .run();

    // Delete storage usage record (if it exists as a separate table with triggers)
    await this.db
      .prepare('DELETE FROM storage_usage WHERE user_id = ?')
      .bind(userId)
      .run();

    // Finally delete the user
    await this.db
      .prepare('DELETE FROM users WHERE id = ?')
      .bind(userId)
      .run();

    return { deletedImages: r2Keys };
  }
}
