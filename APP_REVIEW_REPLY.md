# App Review Reply — macOS v1.4.0 (build 13) resubmission

Hi App Review Team,

Thank you for the review. We addressed Guideline 5.1.1(v) in macOS 1.4.0 build 13.

Users can now view and purchase In-App Purchase products before providing any personal information:

- The welcome/sign-in screen now has a primary **View plans without account** action.
- This creates an anonymous device session with no email, name, or other personal information.
- After choosing that action, the app opens the upgrade/paywall sheet automatically so reviewers can purchase the submitted StoreKit products immediately.
- Anonymous users bypass email verification; email registration is optional and described only as a way to access purchases/uploads on other devices later.
- If an anonymous free-tier user attempts an upload, the app opens the upgrade sheet and states that no email account is required to subscribe.
- The production backend was also updated so anonymous upload gating is returned as a subscription/upgrade prompt, not an account-registration requirement.

Submitted macOS products in this build:

| Display Name | Product ID | Type |
|---|---|---|
| Starter Monthly | `imghost.pro.monthly` | Auto-Renewable Subscription |
| Starter Yearly | `imghost.pro.yearly` | Auto-Renewable Subscription |

Demo account, if you prefer to test with an existing account:

- **Email:** `test@example.com`
- **Password:** `test123`

Best regards,
Cody Bontecou
