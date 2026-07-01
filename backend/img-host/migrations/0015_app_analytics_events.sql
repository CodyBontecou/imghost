-- Privacy-safe native app analytics event store.
-- Deliberately stores only validated, coarse onboarding, paywall, purchase, and usage fields.
-- Do not add emails, filenames, URLs, raw request IPs, user agents, or raw device identifiers.

CREATE TABLE IF NOT EXISTS app_analytics_events (
  id TEXT PRIMARY KEY,
  received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  install_id TEXT NOT NULL,
  event_name TEXT NOT NULL,
  app_version TEXT,
  build_number TEXT,
  platform TEXT,
  onboarding_step TEXT,
  paywall_context TEXT,
  subscription_status TEXT,
  tier TEXT,
  trial_days_bucket TEXT,
  product_id TEXT,
  billing_period TEXT,
  purchase_outcome TEXT,
  auth_method TEXT,
  auth_outcome TEXT,
  upload_source TEXT,
  upload_outcome TEXT,
  file_type_group TEXT,
  file_size_bucket TEXT,
  error_category TEXT,
  cta TEXT,
  tab TEXT,
  payload_json TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_app_analytics_events_received_at
  ON app_analytics_events(received_at);

CREATE INDEX IF NOT EXISTS idx_app_analytics_events_event_received
  ON app_analytics_events(event_name, received_at);

CREATE INDEX IF NOT EXISTS idx_app_analytics_events_install_event_received
  ON app_analytics_events(install_id, event_name, received_at);

CREATE INDEX IF NOT EXISTS idx_app_analytics_events_paywall_received
  ON app_analytics_events(paywall_context, received_at);

CREATE INDEX IF NOT EXISTS idx_app_analytics_events_subscription_received
  ON app_analytics_events(subscription_status, received_at);

CREATE INDEX IF NOT EXISTS idx_app_analytics_events_product_received
  ON app_analytics_events(product_id, received_at);
