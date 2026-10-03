# Native adoption follow-up to draft #9 (not rollout approval)

Refs https://github.com/CodyBontecou/imghost/issues/6 and https://github.com/CodyBontecou/imghost/issues/5.
This adds native Settings/adoption to the historical staged contract in [EMAIL_CONVERSION.md](EMAIL_CONVERSION.md).
The additive [NATIVE_SESSION_CORRECTION.md](NATIVE_SESSION_CORRECTION.md) supersedes session/preflight/
logout details below for five introduced defects; historical observations and evidence remain preserved.
Keep `EMAIL_CONVERSION_ENABLED` **unset**, PR #9 **draft** and the issue **open**. No deployment or real account/email/billing operations are authorized.

## Discoverability and proof

Both Account Settings surfaces offer **Add email/password login** for non-anonymous accounts.
The server, not an inferred email/provider heuristic, decides whether the account is Apple-linked.
A disabled endpoint or unreachable service explains unavailability, keeps Apple access and offers retry.
The shared sheet requests a challenge first, then a **new interactive** native Apple authorization.
`EmailConversionAppleProof.configure` sets `ASAuthorizationAppleIDRequest.nonce` to the server nonce
**verbatim**, not its hash. Only that authorization's identity token goes to `start`; no Apple login,
registration, account merge or unlink call is used. The destination is frozen when the challenge is requested.
The sheet collects the independent destination code plus a password and matching confirmation.

Completion is followed by ordinary `AuthService.login`. The real coordinator requires the same source
user ID, canonical destination, verified email and a non-anonymous response **before** local adoption.
A lost completion response is uncertain, not rollback: an explicit recovery button tries ordinary login
only, never resubmits the code or registers another account. Closing invalidates pending callbacks and
scrubs in-memory codes/passwords; it cannot undo an already committed server transaction.

## Durable replacement boundary

`AtomicSessionStore` stores access token, refresh token, expiry, user ID and revision in **one** generic
password Keychain item (`atomicSession.v1`). On existing items it calls `SecItemUpdate` once; on first
adoption it calls `SecItemAdd` once. It never deletes the old item to replace it, never writes the three
legacy JWT items, and never treats read/decode/permission failures as missing credentials.
Legacy credentials remain physically preserved and are used only when no authoritative item exists.
A durable logout tombstone prevents their resurrection. The legacy upload-token API is separate.

All native app and extension readers/writers use this same store through `KeychainService`. A shared
app-group file lock plus a process lock serializes snapshots/compare-and-commit across instances.
Refresh captures a whole session before HTTP and rejects a late response if another operation changed
it while awaiting. This also rejects refresh resurrection after logout. A missing app-group container
fails closed rather than degrading to an in-process-only lock. Migration no longer deletes legacy items.

`AuthState.adoptConversion` compares the captured session, commits it synchronously, then publishes
memory without an intervening await. It preserves the source user ID, storage usage/limit/image count,
local history and subscription state. It does **not** call ordinary `setAuthenticated`, sync, logout,
subscription reset or history clearing. A scoped AuthState lease also suppresses background auth checks
and Settings user-info publication while completion/login/recovery owns the source session; an old
refresh-token rejection must not log out the user midway through adoption. Closing, failed availability
checks and successful adoption release the lease. Failed writes leave memory untouched. A failed comparison or
post-server login/write failure exposes recovery rather than claiming server rollback. Stale in-process
AuthState checks cannot overwrite/logout an adopted session. This is not full issue #5 completion.

## Executable verification surface

`NativeAdoptionTests.swift` runs the real coordinator, `AuthState` and production Security adapter
with injected HTTP/login/Security syscall results. It does not implement a second adoption state model
or require production network/Keychain/StoreKit transactions. Tests include add/update/read faults,
corrupt authoritative data, old/new same-ID preservation, late refresh from another store, durable
logout, cancellation/closing, mismatched completion/login, recovery and disabled rollout retry.
`EmailConversionServiceTests.swift` retains all seven prior transport cases unchanged.

`Package.swift` explicitly compiles these real sources and registers both suites. The Xcode project
registers native UI/coordinator in both apps and the store/service/composition in both apps and both
extensions. The read-only public-hosted Action runs SwiftPM XCTest, iOS simulator XCTest, iOS shared
source typecheck, project validation and unsigned full-app/extension iOS/macOS compilation. Builds are
not launched: app launch normally uses production URLs. Run URLs, exact heads, named executed cases
and failed iterations are recorded in the additive factory follow-up report, not inferred from badge green.

## Remaining gates

- PR #8 reset atomicity remains separate; no merge/cherry-pick/duplicate repair here. Integrate by an
  authorized owner and add combined reset/conversion race tests **before enabling**.
- Real Apple fresh proof/nonce, SES/private relay delivery, deployed D1 schema/runtime/batch parity,
  physical iOS/macOS same-account library/Keychain/app-group sharing and subscription renewal remain
  external evidence. Hosted syscall fault injection does not prove actual entitled Keychain behavior,
  OS cross-process access or crash/power-loss persistence on hardware.
- Physical clipboard/accessibility QA and reviewed translations for new English-fallback localized
  strings remain external. Notification retry/alerting and abandoned-challenge/audit retention remain.
- Broad login/logout/expiration/upload/StoreKit lifecycle acceptance stays with issue #5. In particular,
  late unrelated ordinary-login responses and account-switch synchronization are not fully qualified by
  this conversion-specific suite. No full AuthState/StoreKit lifecycle completion is claimed.
- Fourteen inherited dependency advisories are unchanged/unqualified. Session/API-key retention and
  rollout policy still require owner security review. Do not treat client green as security clearance.

Public APIs: [SecItemUpdate](https://developer.apple.com/documentation/security/secitemupdate(_:_:)),
[SecItemAdd](https://developer.apple.com/documentation/security/secitemadd(_:_:)),
[native nonce](https://developer.apple.com/documentation/authenticationservices/asauthorizationopenidrequest/nonce).
