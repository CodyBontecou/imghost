-- Migration: 0013_freemium_tiers
-- Description: Freemium model — free tier gets 1 GB (no TTL), add Ultimate 1 TB tier
-- Pricing: Starter 10 GB @ $2/mo | Pro 100 GB @ $7.50/mo | Ultimate 1 TB @ $25/mo
-- Date: 2026-04-23

-- ── 1. Update free-tier users to 1 GB storage ────────────────────────────────
UPDATE users
SET storage_limit_bytes = 1000000000
WHERE subscription_tier = 'free';

-- ── 2. Clear any pending expires_at for free-tier images (no more 7-day TTL) ─
UPDATE images
SET expires_at = NULL
WHERE expires_at IS NOT NULL
  AND user_id IN (SELECT id FROM users WHERE subscription_tier = 'free');

-- ── 3. Update tier_limits table ───────────────────────────────────────────────

-- Free: 1 GB total, 50 MB per file
INSERT OR REPLACE INTO tier_limits (tier, storage_limit_bytes, max_file_size_bytes, max_images, features)
VALUES (
  'free',
  1000000000,
  50000000,
  NULL,
  '{"custom_domains":false,"analytics":false,"api_access":false,"exports":false,"transforms":false}'
);

-- Starter (mapped to 'pro' tier internally): 10 GB, 500 MB per file @ $2/mo
INSERT OR REPLACE INTO tier_limits (tier, storage_limit_bytes, max_file_size_bytes, max_images, features)
VALUES (
  'pro',
  10000000000,
  524288000,
  NULL,
  '{"custom_domains":false,"analytics":true,"api_access":true,"exports":true,"transforms":true}'
);

-- Pro (mapped to 'enterprise' internally): 100 GB, 500 MB per file @ $7.50/mo
INSERT OR REPLACE INTO tier_limits (tier, storage_limit_bytes, max_file_size_bytes, max_images, features)
VALUES (
  'enterprise',
  100000000000,
  524288000,
  NULL,
  '{"custom_domains":true,"analytics":true,"api_access":true,"exports":true,"transforms":true}'
);

-- Ultimate: 1 TB, 500 MB per file @ $25/mo
INSERT OR REPLACE INTO tier_limits (tier, storage_limit_bytes, max_file_size_bytes, max_images, features)
VALUES (
  'ultimate',
  1000000000000,
  524288000,
  NULL,
  '{"custom_domains":true,"analytics":true,"api_access":true,"exports":true,"transforms":true,"priority_support":true}'
);

-- Also keep trial tier at Starter limits (10 GB) for trial periods
INSERT OR REPLACE INTO tier_limits (tier, storage_limit_bytes, max_file_size_bytes, max_images, features)
VALUES (
  'trial',
  10000000000,
  524288000,
  NULL,
  '{"custom_domains":false,"analytics":true,"api_access":true,"exports":true,"transforms":true}'
);
