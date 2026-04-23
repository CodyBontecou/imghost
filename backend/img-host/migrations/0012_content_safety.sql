-- Migration 0012: Content Safety Infrastructure
-- Adds tables for hash blocklist (prevents re-upload of removed content)
-- and DMCA takedown tracking.

-- Hash blocklist: stores SHA-256 hashes of content that must never be hosted.
-- Reason values: 'csam' | 'copyright' | 'malware'
CREATE TABLE IF NOT EXISTS blocked_hashes (
  hash       TEXT    NOT NULL PRIMARY KEY,
  reason     TEXT    NOT NULL CHECK (reason IN ('csam', 'copyright', 'malware')),
  blocked_at INTEGER NOT NULL
);

-- DMCA takedown records
CREATE TABLE IF NOT EXISTS dmca_takedowns (
  id                TEXT    NOT NULL PRIMARY KEY,
  image_id          TEXT    NOT NULL,
  reported_url      TEXT    NOT NULL,
  complainant_email TEXT    NOT NULL,
  description       TEXT,
  status            TEXT    NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'actioned', 'counter_noticed', 'dismissed')),
  created_at        INTEGER NOT NULL,
  actioned_at       INTEGER,
  FOREIGN KEY (image_id) REFERENCES images(id) ON DELETE CASCADE
);

-- Column on images to track DMCA takedowns
-- NOTE: Cloudflare D1/SQLite does not support `ADD COLUMN IF NOT EXISTS`.
-- Migrations run once, so a plain ADD COLUMN is correct here.
ALTER TABLE images ADD COLUMN dmca_taken_down INTEGER NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_dmca_takedowns_image_id ON dmca_takedowns(image_id);
CREATE INDEX IF NOT EXISTS idx_dmca_takedowns_status   ON dmca_takedowns(status);
