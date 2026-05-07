# App Review Reply — macOS v1.4.0 (build 11) resubmission

Hi App Review Team,

Thank you for the review. We addressed each item in macOS 1.4.0 build 11.

## Demo account

The demo account has been created and verified with full access:

- **Email:** `test@example.com`
- **Password:** `test123`

This account is active, email-verified, and has the Ultimate tier enabled through 2030 so all upload/export/settings features are available during review.

## Account registration is no longer required before purchase

The app now includes **Continue without account** on the welcome/sign-in screen. This creates an anonymous device account without collecting email, name, or other personal information. Reviewers and users can enter the app, view upgrade options, and purchase via StoreKit before providing any personal information. The UI explains that an email account can be used later only if the user wants access on other devices.

## In-App Purchase references

The macOS binary now only requests and displays the submitted Starter products:

| Display Name | Product ID | Type |
|---|---|---|
| Starter Monthly | `imghost.pro.monthly` | Auto-Renewable Subscription |
| Starter Yearly | `imghost.pro.yearly` | Auto-Renewable Subscription |

References to the unsubmitted 100 GB / Pro macOS products were removed from the macOS paywall and comparison UI.

## Main window reopening

We added menu-based window reopening and fixed the menu bar action:

- **File → Open imghost** reopens the main window.
- **Window → Open imghost** reopens the main window.
- The menu bar popover’s **Open app** action now recreates/focuses the main SwiftUI window after it has been closed.

Best regards,
Cody Bontecou
