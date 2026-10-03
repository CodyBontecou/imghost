-- Staged self-service Apple -> email/password credentials on the SAME user.
-- No image/subscription/R2 changes. Enable only after native/delivery QA.
CREATE TABLE email_conversion_challenges (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  purpose TEXT NOT NULL CHECK (purpose = 'apple_to_email'),
  phase TEXT NOT NULL CHECK (phase IN ('source', 'email', 'complete')),
  source_email TEXT NOT NULL,
  source_password_hash TEXT NOT NULL,
  apple_user_id TEXT NOT NULL,
  nonce TEXT NOT NULL,
  destination_email TEXT,
  email_token_hash TEXT,
  expires_at INTEGER NOT NULL,
  completed_operation TEXT
);
CREATE INDEX idx_email_conversion_expiry ON email_conversion_challenges(expires_at);

-- Restricted database audit, never public recovery logs. No email/token/password.
CREATE TABLE email_conversion_events (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  notification_pending INTEGER NOT NULL DEFAULT 1
);
