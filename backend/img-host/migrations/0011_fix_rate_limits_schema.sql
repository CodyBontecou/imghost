-- Migration: 0011_fix_rate_limits_schema
-- Description: Fix rate_limits table to use user_id instead of identifier
--              (migration 0004 was silently skipped because 0002 already created
--              the table with a different schema using CREATE TABLE IF NOT EXISTS)
-- Date: 2026-03-23

-- Drop the old rate_limits table (created by migration 0002 with 'identifier' column)
DROP TABLE IF EXISTS rate_limits;

-- Recreate with the correct schema expected by rate-limiter.ts
CREATE TABLE rate_limits (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  endpoint TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  request_count INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  UNIQUE(user_id, endpoint, window_start)
);

CREATE INDEX idx_rate_limits_user_endpoint ON rate_limits(user_id, endpoint, window_start);
CREATE INDEX idx_rate_limits_window_start ON rate_limits(window_start);
