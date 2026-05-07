-- Migration: 0014_anonymous_accounts
-- Description: Mark anonymous device accounts so users can use and purchase without providing personal information.
-- Date: 2026-05-07

ALTER TABLE users ADD COLUMN is_anonymous INTEGER NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_users_is_anonymous ON users(is_anonymous);
