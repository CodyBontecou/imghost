# App Review Reply — macOS v1.4.0 (build 14) resubmission

Hi App Review Team,

Thank you for the detailed review and screenshot. We addressed the Guideline 2.1(b) issue where the sandbox purchase flow could show “We are temporarily unable to process your request” when buying a subscription on macOS.

Changes in macOS 1.4.0 build 14:

- The macOS purchase call now uses StoreKit 2’s `purchase(confirmIn:)` API on macOS 15.2+ and passes the active app window explicitly. This ensures the sandbox purchase confirmation UI has a valid window context even when the paywall is opened from a SwiftUI sheet.
- The purchase flow still falls back to the standard StoreKit 2 purchase API on older macOS versions.
- The macOS paywall localization keys shown in the review screenshot have been added so plan labels and billing controls display user-facing text instead of localization keys.
- We rechecked the submitted subscription configuration in App Store Connect: both Starter products are approved, priced, localized, and available in new territories.

Submitted macOS products in this build:

| Display Name | Product ID | Type | Status |
|---|---|---|---|
| Pro Monthly | `imghost.pro.monthly` | Auto-Renewable Subscription | Approved |
| Pro Yearly | `imghost.pro.yearly` | Auto-Renewable Subscription | Approved |

Demo account, if you prefer to test with an existing account:

- **Email:** `test@example.com`
- **Password:** `test123`

The “View plans without account” path remains available and does not collect an email address before showing or purchasing the subscriptions.

Best regards,
Cody Bontecou
