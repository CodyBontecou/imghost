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
      "eventName": "paywall_shown",
      "properties": {
        "platform": "ios",
        "appVersion": "1.2",
        "buildNumber": "34",
        "paywallContext": "settings",
        "subscriptionStatus": "trialing",
        "tier": "trial"
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
SELECT
  COUNT(DISTINCT CASE WHEN event_name = 'onboarding_started' THEN install_id END) AS onboard_started,
  COUNT(DISTINCT CASE WHEN event_name = 'onboarding_completed' THEN install_id END) AS onboard_completed,
  COUNT(DISTINCT CASE WHEN event_name = 'paywall_shown' THEN install_id END) AS paywall_seen,
  COUNT(DISTINCT CASE WHEN event_name = 'purchase_started' THEN install_id END) AS purchase_started,
  COUNT(DISTINCT CASE WHEN event_name = 'purchase_finished' AND purchase_outcome = 'succeeded' THEN install_id END) AS purchase_succeeded
FROM app_analytics_events
WHERE received_at >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days');
```
