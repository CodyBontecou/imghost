-- Users table
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  created_at INTEGER NOT NULL, -- Unix timestamp
  subscription_tier TEXT NOT NULL DEFAULT 'free', -- 'free', 'pro', 'enterprise'
  api_token TEXT UNIQUE NOT NULL,
  storage_limit_bytes INTEGER NOT NULL DEFAULT 10000000000, -- 10GB for trial tier
  UNIQUE(email),
  UNIQUE(api_token)
);

CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_api_token ON users(api_token);

-- Images table
CREATE TABLE IF NOT EXISTS images (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  r2_key TEXT UNIQUE NOT NULL,
  filename TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  content_type TEXT NOT NULL,
  created_at INTEGER NOT NULL, -- Unix timestamp
  delete_token TEXT NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_images_user_id ON images(user_id);
CREATE INDEX IF NOT EXISTS idx_images_r2_key ON images(r2_key);
CREATE INDEX IF NOT EXISTS idx_images_delete_token ON images(delete_token);
CREATE INDEX IF NOT EXISTS idx_images_created_at ON images(created_at);

-- Subscriptions table
CREATE TABLE IF NOT EXISTS subscriptions (
  id TEXT PRIMARY KEY,
  user_id TEXT UNIQUE NOT NULL,
  tier TEXT NOT NULL, -- 'free', 'pro', 'enterprise'
  status TEXT NOT NULL, -- 'active', 'cancelled', 'past_due', 'trialing'
  stripe_customer_id TEXT,
  stripe_subscription_id TEXT,
  current_period_start INTEGER, -- Unix timestamp
  current_period_end INTEGER, -- Unix timestamp
  cancel_at_period_end INTEGER NOT NULL DEFAULT 0, -- Boolean: 0 or 1
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_user_id ON subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_stripe_customer_id ON subscriptions(stripe_customer_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_stripe_subscription_id ON subscriptions(stripe_subscription_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_status ON subscriptions(status);

-- Storage usage view (computed from images table)
-- This is a view that aggregates storage usage per user
CREATE VIEW IF NOT EXISTS storage_usage AS
SELECT
  user_id,
  COUNT(*) as image_count,
  COALESCE(SUM(size_bytes), 0) as total_bytes_used
FROM images
GROUP BY user_id;

-- Tier limits configuration table
CREATE TABLE IF NOT EXISTS tier_limits (
  tier TEXT PRIMARY KEY,
  storage_limit_bytes INTEGER NOT NULL,
  max_file_size_bytes INTEGER NOT NULL,
  max_images INTEGER, -- NULL means unlimited
  features TEXT -- JSON string of feature flags
);

-- Insert default tier limits
INSERT OR REPLACE INTO tier_limits (tier, storage_limit_bytes, max_file_size_bytes, max_images, features) VALUES
  ('trial', 10000000000, 50000000, NULL, '{"custom_domains":false,"analytics":false,"api_access":true}'), -- 10GB storage, 50MB per file, unlimited images
  ('pro', 10000000000, 50000000, NULL, '{"custom_domains":true,"analytics":true,"api_access":true}'), -- 10GB storage, 50MB per file, unlimited images
  ('enterprise', 100000000000, 100000000, NULL, '{"custom_domains":true,"analytics":true,"api_access":true,"priority_support":true}'); -- 100GB storage, 100MB per file, unlimited images

-- API usage tracking (optional - for rate limiting and analytics)
CREATE TABLE IF NOT EXISTS api_usage (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  endpoint TEXT NOT NULL,
  method TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  response_status INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_api_usage_user_id ON api_usage(user_id);
CREATE INDEX IF NOT EXISTS idx_api_usage_timestamp ON api_usage(timestamp);

-- Analytics tables for tracking usage, engagement, and business metrics

-- Daily aggregated metrics for system-wide analytics
CREATE TABLE IF NOT EXISTS analytics_daily_metrics (
  date TEXT PRIMARY KEY, -- Format: YYYY-MM-DD
  total_uploads INTEGER NOT NULL DEFAULT 0,
  total_bytes_uploaded INTEGER NOT NULL DEFAULT 0,
  total_deletions INTEGER NOT NULL DEFAULT 0,
  new_users INTEGER NOT NULL DEFAULT 0,
  active_users INTEGER NOT NULL DEFAULT 0, -- DAU
  total_api_calls INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL -- Unix timestamp
);

CREATE INDEX IF NOT EXISTS idx_analytics_daily_date ON analytics_daily_metrics(date);

-- Image format analytics
CREATE TABLE IF NOT EXISTS analytics_image_formats (
  id TEXT PRIMARY KEY,
  date TEXT NOT NULL, -- Format: YYYY-MM-DD
  content_type TEXT NOT NULL,
  upload_count INTEGER NOT NULL DEFAULT 0,
  total_bytes INTEGER NOT NULL DEFAULT 0,
  avg_size_bytes INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  UNIQUE(date, content_type)
);

CREATE INDEX IF NOT EXISTS idx_analytics_formats_date ON analytics_image_formats(date);
CREATE INDEX IF NOT EXISTS idx_analytics_formats_content_type ON analytics_image_formats(content_type);

-- User engagement tracking
CREATE TABLE IF NOT EXISTS analytics_user_engagement (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  date TEXT NOT NULL, -- Format: YYYY-MM-DD
  uploads_count INTEGER NOT NULL DEFAULT 0,
  deletions_count INTEGER NOT NULL DEFAULT 0,
  api_calls_count INTEGER NOT NULL DEFAULT 0,
  last_activity_timestamp INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  UNIQUE(user_id, date)
);

CREATE INDEX IF NOT EXISTS idx_analytics_engagement_user ON analytics_user_engagement(user_id);
CREATE INDEX IF NOT EXISTS idx_analytics_engagement_date ON analytics_user_engagement(date);

-- Subscription conversion tracking
CREATE TABLE IF NOT EXISTS analytics_subscription_events (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  event_type TEXT NOT NULL, -- 'signup', 'upgrade', 'downgrade', 'cancel', 'reactivate', 'churn'
  from_tier TEXT, -- Previous tier (NULL for signup)
  to_tier TEXT NOT NULL, -- New tier
  timestamp INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_analytics_sub_events_user ON analytics_subscription_events(user_id);
CREATE INDEX IF NOT EXISTS idx_analytics_sub_events_type ON analytics_subscription_events(event_type);
CREATE INDEX IF NOT EXISTS idx_analytics_sub_events_timestamp ON analytics_subscription_events(timestamp);

-- Revenue metrics (aggregated monthly)
CREATE TABLE IF NOT EXISTS analytics_revenue_metrics (
  month TEXT PRIMARY KEY, -- Format: YYYY-MM
  mrr INTEGER NOT NULL DEFAULT 0, -- Monthly Recurring Revenue in cents
  arr INTEGER NOT NULL DEFAULT 0, -- Annual Recurring Revenue in cents
  new_mrr INTEGER NOT NULL DEFAULT 0, -- New MRR from new subscriptions
  expansion_mrr INTEGER NOT NULL DEFAULT 0, -- MRR from upgrades
  contraction_mrr INTEGER NOT NULL DEFAULT 0, -- MRR lost from downgrades
  churned_mrr INTEGER NOT NULL DEFAULT 0, -- MRR lost from cancellations
  active_subscriptions INTEGER NOT NULL DEFAULT 0,
  free_users INTEGER NOT NULL DEFAULT 0,
  pro_users INTEGER NOT NULL DEFAULT 0,
  enterprise_users INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_analytics_revenue_month ON analytics_revenue_metrics(month);

-- Storage growth tracking (daily snapshots)
CREATE TABLE IF NOT EXISTS analytics_storage_snapshots (
  id TEXT PRIMARY KEY,
  date TEXT NOT NULL, -- Format: YYYY-MM-DD
  total_users INTEGER NOT NULL DEFAULT 0,
  total_images INTEGER NOT NULL DEFAULT 0,
  total_bytes_stored INTEGER NOT NULL DEFAULT 0,
  avg_bytes_per_user INTEGER NOT NULL DEFAULT 0,
  avg_images_per_user INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_analytics_storage_date ON analytics_storage_snapshots(date);

-- Feature usage tracking
CREATE TABLE IF NOT EXISTS analytics_feature_usage (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  feature_name TEXT NOT NULL, -- e.g., 'share', 'album', 'tag', 'custom_domain'
  usage_count INTEGER NOT NULL DEFAULT 0,
  first_used_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  UNIQUE(user_id, feature_name)
);

CREATE INDEX IF NOT EXISTS idx_analytics_feature_user ON analytics_feature_usage(user_id);
CREATE INDEX IF NOT EXISTS idx_analytics_feature_name ON analytics_feature_usage(feature_name);

-- User opt-out preferences (GDPR compliance)
CREATE TABLE IF NOT EXISTS analytics_privacy_settings (
  user_id TEXT PRIMARY KEY,
  analytics_enabled INTEGER NOT NULL DEFAULT 1, -- Boolean: 0 or 1
  data_retention_days INTEGER NOT NULL DEFAULT 90,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_analytics_privacy_user ON analytics_privacy_settings(user_id);
-- Rate limiting tables and abuse prevention schema

-- Rate limit tracking table (for user-based rate limiting)
CREATE TABLE IF NOT EXISTS rate_limits (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  endpoint TEXT NOT NULL,
  window_start INTEGER NOT NULL, -- Unix timestamp for the start of the current window
  request_count INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  UNIQUE(user_id, endpoint, window_start)
);

CREATE INDEX IF NOT EXISTS idx_rate_limits_user_endpoint ON rate_limits(user_id, endpoint, window_start);
CREATE INDEX IF NOT EXISTS idx_rate_limits_window_start ON rate_limits(window_start);

-- IP-based rate limiting (for unauthenticated requests)
CREATE TABLE IF NOT EXISTS ip_rate_limits (
  id TEXT PRIMARY KEY,
  ip_address TEXT NOT NULL,
  endpoint TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  request_count INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(ip_address, endpoint, window_start)
);

CREATE INDEX IF NOT EXISTS idx_ip_rate_limits_ip_endpoint ON ip_rate_limits(ip_address, endpoint, window_start);
CREATE INDEX IF NOT EXISTS idx_ip_rate_limits_window_start ON ip_rate_limits(window_start);

-- Failed login attempts tracking (for exponential backoff and CAPTCHA triggers)
CREATE TABLE IF NOT EXISTS failed_attempts (
  id TEXT PRIMARY KEY,
  identifier TEXT NOT NULL, -- email or IP address
  attempt_type TEXT NOT NULL, -- 'login' or 'register'
  attempt_count INTEGER NOT NULL DEFAULT 1,
  last_attempt_at INTEGER NOT NULL,
  locked_until INTEGER, -- NULL if not locked, timestamp if locked
  created_at INTEGER NOT NULL,
  UNIQUE(identifier, attempt_type)
);

CREATE INDEX IF NOT EXISTS idx_failed_attempts_identifier ON failed_attempts(identifier, attempt_type);
CREATE INDEX IF NOT EXISTS idx_failed_attempts_locked_until ON failed_attempts(locked_until);

-- Abuse reports table
CREATE TABLE IF NOT EXISTS abuse_reports (
  id TEXT PRIMARY KEY,
  reported_image_id TEXT NOT NULL,
  reported_user_id TEXT NOT NULL,
  reporter_user_id TEXT, -- NULL if reported by anonymous user
  reporter_ip TEXT,
  reason TEXT NOT NULL, -- 'nsfw', 'copyright', 'malware', 'other'
  description TEXT,
  status TEXT NOT NULL DEFAULT 'pending', -- 'pending', 'reviewing', 'resolved', 'dismissed'
  created_at INTEGER NOT NULL,
  reviewed_at INTEGER,
  reviewed_by TEXT, -- admin user ID
  resolution_notes TEXT,
  FOREIGN KEY (reported_image_id) REFERENCES images(id) ON DELETE CASCADE,
  FOREIGN KEY (reported_user_id) REFERENCES users(id) ON DELETE CASCADE,
  FOREIGN KEY (reporter_user_id) REFERENCES users(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_abuse_reports_image_id ON abuse_reports(reported_image_id);
CREATE INDEX IF NOT EXISTS idx_abuse_reports_user_id ON abuse_reports(reported_user_id);
CREATE INDEX IF NOT EXISTS idx_abuse_reports_status ON abuse_reports(status);
CREATE INDEX IF NOT EXISTS idx_abuse_reports_created_at ON abuse_reports(created_at);

-- Content moderation flags table
CREATE TABLE IF NOT EXISTS content_flags (
  id TEXT PRIMARY KEY,
  image_id TEXT NOT NULL,
  flag_type TEXT NOT NULL, -- 'nsfw', 'copyright', 'malware', 'suspicious'
  confidence_score REAL, -- 0.0 to 1.0 for automated detection
  flagged_by TEXT, -- 'system' or user_id if manually flagged
  metadata TEXT, -- JSON string with additional details
  created_at INTEGER NOT NULL,
  FOREIGN KEY (image_id) REFERENCES images(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_content_flags_image_id ON content_flags(image_id);
CREATE INDEX IF NOT EXISTS idx_content_flags_flag_type ON content_flags(flag_type);
CREATE INDEX IF NOT EXISTS idx_content_flags_created_at ON content_flags(created_at);

-- User suspensions table
CREATE TABLE IF NOT EXISTS user_suspensions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  reason TEXT NOT NULL,
  suspended_at INTEGER NOT NULL,
  suspended_until INTEGER, -- NULL for permanent suspension
  suspended_by TEXT, -- 'system' or admin user ID
  notes TEXT,
  is_active INTEGER NOT NULL DEFAULT 1, -- Boolean: 0 or 1
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_user_suspensions_user_id ON user_suspensions(user_id);
CREATE INDEX IF NOT EXISTS idx_user_suspensions_active ON user_suspensions(is_active);
CREATE INDEX IF NOT EXISTS idx_user_suspensions_until ON user_suspensions(suspended_until);

-- Update tier_limits table to include daily rate limits
ALTER TABLE tier_limits ADD COLUMN daily_upload_limit INTEGER;
ALTER TABLE tier_limits ADD COLUMN daily_api_limit INTEGER;

-- Update tier limits with rate limit values
UPDATE tier_limits SET daily_upload_limit = 0, daily_api_limit = 100 WHERE tier = 'free'; -- Block uploads for free tier (subscription required)
UPDATE tier_limits SET daily_upload_limit = 1000, daily_api_limit = 10000 WHERE tier = 'pro';
UPDATE tier_limits SET daily_upload_limit = NULL, daily_api_limit = NULL WHERE tier = 'enterprise'; -- NULL means unlimited

-- Add trial tier for subscription-required flow (Pro features during trial)
INSERT OR REPLACE INTO tier_limits (tier, storage_limit_bytes, max_file_size_bytes, max_images, features, daily_upload_limit, daily_api_limit) VALUES
  ('trial', 10000000000, 50000000, NULL, '{"custom_domains":false,"analytics":false,"api_access":true}', 100, 5000); -- 10GB storage, 50MB per file, unlimited images

-- Add Apple subscription columns to subscriptions table
ALTER TABLE subscriptions ADD COLUMN apple_original_transaction_id TEXT;
ALTER TABLE subscriptions ADD COLUMN apple_product_id TEXT;
ALTER TABLE subscriptions ADD COLUMN trial_ends_at INTEGER; -- Unix timestamp when trial expires

CREATE INDEX IF NOT EXISTS idx_subscriptions_apple_transaction ON subscriptions(apple_original_transaction_id);

-- Add email verification and password reset columns to users table (if not already present)
ALTER TABLE users ADD COLUMN email_verified INTEGER NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN email_verification_token TEXT;
ALTER TABLE users ADD COLUMN email_verification_token_expires INTEGER;
ALTER TABLE users ADD COLUMN password_reset_token TEXT;
ALTER TABLE users ADD COLUMN password_reset_token_expires INTEGER;
ALTER TABLE users ADD COLUMN apple_user_id TEXT;
ALTER TABLE users ADD COLUMN is_anonymous INTEGER NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_users_apple_user_id ON users(apple_user_id);
CREATE INDEX IF NOT EXISTS idx_users_is_anonymous ON users(is_anonymous);

-- Refresh tokens table for JWT auth
CREATE TABLE IF NOT EXISTS refresh_tokens (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  token TEXT UNIQUE NOT NULL,
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  revoked INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user_id ON refresh_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_token ON refresh_tokens(token);

-- Export jobs table for bulk data export
CREATE TABLE IF NOT EXISTS export_jobs (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'processing', -- 'processing', 'completed', 'failed'
  image_count INTEGER NOT NULL DEFAULT 0,
  archive_size INTEGER NOT NULL DEFAULT 0,
  download_url TEXT,
  expires_at INTEGER,
  error_message TEXT,
  created_at INTEGER NOT NULL,
  completed_at INTEGER,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_export_jobs_user_id ON export_jobs(user_id);
CREATE INDEX IF NOT EXISTS idx_export_jobs_status ON export_jobs(status);

-- Export rate limits
CREATE TABLE IF NOT EXISTS export_rate_limits (
  user_id TEXT PRIMARY KEY,
  last_export_at INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
