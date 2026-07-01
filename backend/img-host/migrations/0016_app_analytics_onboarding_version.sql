-- Add explicit onboarding experiment/version dimension for funnel comparisons.
-- Keeps future onboarding copy/layout/paywall tests from mixing with earlier data.

ALTER TABLE app_analytics_events ADD COLUMN onboarding_version TEXT;

CREATE INDEX IF NOT EXISTS idx_app_analytics_events_onboarding_version_received
  ON app_analytics_events(onboarding_version, event_name, received_at);
