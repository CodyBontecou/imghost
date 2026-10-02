# Apple → verified email/password: staged contract and investigation

Refs https://github.com/CodyBontecou/imghost/issues/6

**Partial implementation, disabled by default, not a supported production recovery flow yet.**
Do not enable `EMAIL_CONVERSION_ENABLED=true` until the gates below pass. No deployment,
account writes, real email delivery or hardware QA have been performed for this change.
This is a self-service design, **not** an administrative override/runbook. An address,
support message, receipt or payment claim alone never authorizes conversion. Do not
register a second account as a workaround: it has a different user/library/subscription.
Do not paste customer details, identity tokens, passwords or codes into public tickets.

## Observed limits at the issue base

At `f8e36e34bce5cf6f87a4bcd53221ee64c3cdec2a`, `createAppleUser` uses
`APPLE_SIGN_IN_ONLY`; reset changes only `password_hash` at the current email.
`createUser` allocates a new UUID; there is no email-change route or native Settings
conversion UI. Thus registering another address cannot preserve identity. These are
source observations, not reproduction on a customer account or a guessed delivery cause.
Existing PR https://github.com/CodyBontecou/imghost/pull/8 addresses reset-code delivery
and atomic reset consumption; this change does not duplicate that work.

## API and threat model

Three POST-only, no-store routes under `/auth/email-conversion/`, gated by the env flag.
Migration `0017_email_conversion.sql` must be present first. No API key, refresh JWT,
missing/default JWT secret, anonymous account, or unlinked email-only account is accepted.
Access JWT alone only allocates a challenge: it cannot authorize a credential change.

1. `challenge` with current access JWT returns `challenge_id`, `nonce`, `expires_at`
   (epoch **milliseconds**). One pending challenge per account; another request replaces
   all earlier proofs/codes. Source challenge expires in 5 minutes.
2. Request a **new interactive** Apple authorization, passing the returned nonce
   **verbatim** to `ASAuthorizationAppleIDRequest.nonce`. Do not use a cached identity
   token or a support assertion. `start` sends `{challenge_id, identity_token,
   destination_email}` with the same account's access JWT. Server verifies the signature,
   issuer, configured iOS/macOS audience, nonce, source Apple subject, token expiry and
   issue time since challenge issuance (up to 30 seconds future clock tolerance).
   `nonce_supported=false` is not an exemption. The supplied Apple/email name is not
   used as account identity. Challenge is rechecked after mail submission.
3. Server canonicalizes destination to trimmed lowercase ASCII, rejects existing
   destinations case-insensitively (including the current address), notifies the original
   address and submits a separate 256-bit code to the destination mailbox. Both SES
   submissions must succeed. Only a SHA-256 digest of the email code is stored. No code
   is returned in the API response or URL. Ten-minute email phase is account/purpose-bound;
   completing does not allow changing the destination again. Resending means restarting
   with a new Apple authorization. Ten requests per account/step per 15-minute window
   use the existing rate limiter (not a strict concurrent-request quota).
4. `complete` sends `{challenge_id, code, new_password}` with the same account's access
   JWT. Password length is 8–1024 UTF-16 units, matching JavaScript string length; clients
   require password confirmation. Single-use consumption, source email/password/Apple-ID
   snapshots, expiry and destination conflict are rechecked **after hashing**. A D1 batch
   transaction updates only login credentials/verification fields, consumes the challenge,
   revokes refresh tokens and appends a restricted audit event. A SQL failure rolls back
   all these operations. Conflict never merges accounts or requests a re-upload/repurchase.

`complete` returns `{user_id, email, email_verified, apple_access_retained,
notification_pending, message}`. It deliberately does **not** return auth tokens. Log
in normally at `/auth/login` with the returned canonical email/password; verify the same
user ID. Apple remains linked permanently in this staged API. **There is no unlink API.**
This is additive authentication, not immediate replacement of Apple.

## Compatibility, sessions, notification and retry

- Preserve users.id, API key, Apple ID, creation time, quota and tier. Do not modify any
  images, ownership, R2 keys, metadata, delete tokens, TTLs, public URL construction or
  subscription rows (Stripe IDs, Apple original transaction ID/product, status, periods,
  trial/expiry, cancellation/renewal). No R2 operations occur.
- Old reset/verification tokens are invalidated. All refresh tokens are revoked in the
  commit transaction. Refresh rotation now conditionally consumes/replaces a token in
  one transaction, so a refresh read before conversion cannot mint a session afterwards.
- Access JWTs remain usable until their existing expiry (normally ≤1 hour); requests
  resolve current database account information by user ID. API keys remain valid for
  backward compatibility. This is **not** an immediate all-device/API-key logout; do not
  advertise it as one. A stolen API key requires a separate rotation policy.
- Original-account notice is submitted **before** email phase activation. Success notices
  go to both addresses. If post-commit confirmation fails, return committed success with
  `notification_pending=true` and retain that bit in `email_conversion_events`. Never
  report a committed conversion as failed merely because a notification failed.
- No password/code/customer details enter application logs. The new sender has no console
  fallback. SES provider error bodies are not logged by this handler. Notices contain no
  destination address at the original mailbox and no passwords, codes (except the
  independent destination verification email) or subscription/customer details.
- No credentials change during challenge/start; invalid proofs, codes, collisions, expiry,
  replacement, hashing or transaction failures retain Apple and the current credentials.
  If the completion response is lost, try ordinary login at the chosen canonical email
  or Apple to inspect the account. Do not register again or automatically unlink Apple.
  If a known completion failed, start again rather than reusing the code.
- Audit stores internal user ID, operation UUID, time and notification-pending bit only.
  Pending challenges necessarily contain account snapshots in the restricted database;
  password snapshot/code digest/nonce are scrubbed on success. There is no credential
  rollback/admin API. A user who still has Apple access can repeat the verified flow to
  another unoccupied destination; never restore an unverified email from a support claim.

## Criterion → registered behavioral evidence

| Issue requirement | Evidence in this branch | Remaining evidence |
| --- | --- | --- |
| Fresh source ownership + independent destination proof | Real RSA/Web Crypto signature tests, wrong nonce/subject/audience/issuer/expiry/iat tests; wrong email code leaves snapshots unchanged; native service sends new identity-token contract | Actual interactive Apple nonce on both devices; independent inbox delivery |
| Expiring single-use account/purpose binding; no merge | Exact expiry boundary, after-hash expiry/replacement, cross-account, reset/verification purpose, source reuse, concurrent/replayed completion, case-insensitive conflict before/after mail | D1 Worker runtime parity, edge concurrency |
| User/image/storage/subscription preservation | Real production migrations + SQLite SQL; full image/subscription/storage snapshots; user equality excluding credential fields; both new email login and retained Apple login return original ID/API key | Device local library, real subscriber entitlement/renewal (authorized nonproduction only) |
| Login before optional Apple removal, safe retry | Same-ID login/Apple route tests; atomic batch failure/retry; Swift lost-response, account mismatch, invalid input, conflict and notification-failure tests; no unlink route | Settings UX is **not implemented**; same-account AuthState/Keychain adoption and iOS/macOS login QA |
| Define session/API-key policy + notify | Revocation/preserved-key tests; in-flight refresh revocation race; normal refresh rollback/replay; original+destination notice transport assertions; pending notification audit test | SES/relay acceptance versus actual inbox delivery; durable notification retry/alerting |
| Admin authorization/identity/audit/rollback | Not applicable: no admin path added; users choose passwords, Apple retained; restricted minimal audit | No admin conversion may be performed from these docs |
| Backend and client coverage coordinated with issue 5 | `tests/email-conversion.test.ts` registered by existing Vitest glob, all backend tests in backend-tests.yml. Shared `EmailConversionService.swift` registered in iOS/macOS app Sources; `Tests/AccountConversionTests` in Package.swift and macOS PR Action, plus iOS simulator typecheck | Broader AuthState/Keychain/StoreKit tests stay at https://github.com/CodyBontecou/imghost/issues/5; service tests are not full app/device coverage |

## Owner gates / next work (issue remains open)

1. Integrate/review PR 8's atomic reset consumption **before enabling**. Base's unconditional
   `updatePassword` could otherwise complete an old, in-flight reset after conversion and
   overwrite the chosen password; this branch invalidates stored tokens but intentionally
   does not duplicate PR 8. Add a combined reset-vs-conversion regression after integration.
2. Build discoverable Account Settings flows for iOS/macOS, localized copy, fresh Apple
   authorization with nonce, password confirmation, code entry, same-user login verification,
   uncertain-completion recovery and transactional Keychain/state updates. Preserve local
   history/subscription; do not log out/delete local data just to convert. Broader client
   lifecycle test seams are tracked in issue 5. Service-level XCTest here is only a foundation.
3. Authorized nonproduction Apple/SES/relay delivery and physical iOS/macOS QA. Synthetic
   signing keys/mocked SES responses prove contracts, not real Apple identity/delivery.
   Test real subscription entitlements/renewals without billing changes or repurchase.
4. Verify D1 batch `changes()`/rollback behavior and migration parity in a nonproduction
   Worker. Unit adapter uses real SQLite transactions but is not Cloudflare runtime proof.
   First cloud run failed applying historical migrations in order: 0004 indexes `user_id`
   on 0002's `identifier`-based rate table. Fixture now uses the existing 0011 repair
   **before** 0004; no historical production migration was changed. Verify actual deployed
   schema/migration procedure independently, not by assuming a clean chronological replay.
5. Add durable retry/alerting for `notification_pending` without credential/customer logs;
   define restricted audit retention and expire/scrub abandoned challenge snapshots. There
   is currently no background notification retry or scheduled challenge cleanup. One row
   per user bounds pending-row growth; it does not replace a retention policy.
6. Review security/UX and session/API-key policy. Keep flag **unset**, PR draft, issue open
   until these gates pass. This lane never deploys, merges or changes real accounts.

## Public references checked

- [Native nonce property](https://developer.apple.com/documentation/authenticationservices/asauthorizationopenidrequest/nonce): value is verifiable in the identity token; iOS 13+/macOS 10.15+.
- [Verify an Apple user](https://developer.apple.com/documentation/signinwithapple/verifying-a-user) and [id_token claims](https://developer.apple.com/documentation/signinwithapplejs/authorizationi/id_token): issuer/audience/expiry/nonce, iat and stable subject. Existing backend uses Apple's RSA keys/RS256; conversion fails closed for other algorithms rather than inventing new support.
- [D1 batch](https://developers.cloudflare.com/d1/worker-api/d1-database/#batch): sequential transaction, entire batch rolls back on statement failure, results in input order.
- [SQLite changes()](https://www.sqlite.org/lang_corefunc.html#changes): prior statement change count; used immediately after conditional credential/token update.
