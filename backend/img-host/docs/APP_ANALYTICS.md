# Native App Analytics

Privacy-safe native app analytics are ingested at:

```http
POST /v1/events
Content-Type: application/json
```

Payload shape:

```json
{
  "installId": "00000000-0000-4000-8000-000000000001",
  "events": [
    {
      "eventId": "00000000-0000-4000-8000-000000000002",
      "eventName": "onboarding_step_viewed",
      "properties": {
        "platform": "ios",
        "appVersion": "1.2",
        "buildNumber": "34",
        "onboardingStep": "host_images",
        "onboardingVersion": "v1"
      }
    }
  ]
}
```

The backend validates event/property allowlists and stores rows in `app_analytics_events`.
Do not store emails, filenames, URLs, file paths, IPs, user agents, device names, or media contents.

Useful funnel queries:

```sql
SELECT event_name, COUNT(*) AS events, COUNT(DISTINCT install_id) AS installs
FROM app_analytics_events
WHERE received_at >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days')
GROUP BY event_name
ORDER BY events DESC;
```

```sql
WITH onboarding_cohort AS (
  SELECT install_id, MAX(onboarding_version) AS onboarding_version
  FROM app_analytics_events
  WHERE event_name = 'onboarding_started'
    AND received_at >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days')
  GROUP BY install_id
)
SELECT
  cohort.onboarding_version,
  COUNT(DISTINCT CASE WHEN events.event_name = 'onboarding_started' THEN events.install_id END) AS onboard_started,
  COUNT(DISTINCT CASE WHEN events.event_name = 'onboarding_completed' THEN events.install_id END) AS onboard_completed,
  COUNT(DISTINCT CASE WHEN events.event_name = 'paywall_shown' THEN events.install_id END) AS paywall_seen,
  COUNT(DISTINCT CASE WHEN events.event_name = 'purchase_started' THEN events.install_id END) AS purchase_started,
  COUNT(DISTINCT CASE WHEN events.event_name = 'purchase_finished' AND events.purchase_outcome = 'succeeded' THEN events.install_id END) AS purchase_succeeded
FROM app_analytics_events events
JOIN onboarding_cohort cohort ON cohort.install_id = events.install_id
WHERE events.received_at >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days')
GROUP BY cohort.onboarding_version;
```
