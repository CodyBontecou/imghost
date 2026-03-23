-- Migration: 0010_free_tier
-- Description: Add free tier with 50MB storage and 7-day image TTL
-- Date: 2026-03-22

-- Add expires_at column to images for TTL-based deletion (NULL = permanent)
ALTER TABLE images ADD COLUMN expires_at INTEGER;

-- Index for efficient daily cleanup queries
CREATE INDEX IF NOT EXISTS idx_images_expires_at ON images(expires_at) WHERE expires_at IS NOT NULL;

-- Insert free tier limits
-- 50MB total storage (52428800 bytes), 5MB per file (5242880 bytes)
INSERT OR REPLACE INTO tier_limits (tier, storage_limit_bytes, max_file_size_bytes, max_images, features)
VALUES (
  'free',
  52428800,
  5242880,
  NULL,
  '{"custom_domains":false,"analytics":false,"api_access":false,"exports":false,"transforms":false}'
);

-- Update paid tier features to mark exports/transforms as available
UPDATE tier_limits
SET features = '{"custom_domains":false,"analytics":true,"api_access":true,"exports":true,"transforms":true}'
WHERE tier IN ('trial', 'pro');

UPDATE tier_limits
SET features = '{"custom_domains":true,"analytics":true,"api_access":true,"exports":true,"transforms":true}'
WHERE tier = 'enterprise';
