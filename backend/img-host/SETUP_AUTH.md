# Authentication setup and password-reset verification

The Worker uses D1, PBKDF2 passwords, JWTs and **Amazon SES v2** (`src/ses.ts`).
SendGrid/Postmark `EMAIL_API_KEY` is not used. No email body, verification code or
reset code is logged, even when credentials are missing. Missing SES credentials
fail delivery instead of pretending an email was sent.

## Configuration (owner-managed; not performed by issue CI)

Keep `JWT_SECRET`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in Worker secrets
(or an untracked `.dev.vars` for a disposable test Worker). Never commit them.
The SES identity and IAM permission must allow `ses:SendEmail` for the selected
sender. Configure these non-secret variables:

```toml
[vars]
EMAIL_FROM = "noreply@your-verified-domain.com"
AWS_REGION = "us-east-1"
```

`EMAIL_FROM` defaults to `noreply@isolated.tech`; `AWS_REGION` defaults to
`us-east-1`. Verify the sender identity in **that region**. SES sandbox status is
region-specific and only permits verified recipients or the mailbox simulator.
An SES API 200 means acceptance, not proof of inbox delivery. An authorized owner
must verify delivery, bounce/suppression status and any production-access needs.

For Sign in with Apple private-relay recipients, the owner must register the
outbound source with Apple and meet its SPF/DKIM authentication requirements.
When SES uses its own envelope sender, Apple's documentation requires aligned
DKIM with the registered header From domain. Do not assume API acceptance proves
relay forwarding. A user can also have disabled forwarding.

References verified for this implementation:
- [SES v2 SendEmail](https://docs.aws.amazon.com/ses/latest/APIReference-V2/API_SendEmail.html)
- [SES sandbox restrictions](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html)
- [Apple private email relay configuration](https://developer.apple.com/help/account/capabilities/configure-private-email-relay-service/)
- [D1 result metadata (`meta.changes`)](https://developers.cloudflare.com/d1/worker-api/return-object/)

Use the existing database schema/migrations for a new disposable environment.
This reset fix needs **no migration**, makes no changes to account IDs, Apple
links, API keys, subscriptions or images, and does not touch device-local data.
Do not rerun initialization or destructive migrations on existing accounts.

## Password-reset contract

1. In imghost on iOS or macOS choose **Forgot Password**, enter the account's
   stored email and request a code. For Apple accounts this may be the private
   relay address rather than the user's personal inbox address.
2. The email contains the full copyable reset token on its own line, not a
   numeric verification code and not a URL. It names **Enter Code** and the
   **Reset Code** field used by both native clients. Labels are localized in the
   app; these are their English equivalents.
3. Return to the app's request-success screen, choose Enter Code, paste the entire
   token, and enter/confirm a password of at least 8 characters.
4. Sign in with the same email and new password. Apple-only accounts acquire a
   password on the existing user row; Apple sign-in remains linked to that row.

`POST /auth/forgot-password` and `POST /auth/reset-password` JSON contracts are
unchanged. Tokens are 32 random bytes encoded as base64, bound to the user's
password-reset fields, expire after one hour, are replaced on another request,
and are atomically cleared when the password changes. Expiry is rechecked after
hashing so concurrent/expired/replaced challenges cannot update the password.
Existing refresh tokens for that user are revoked; legacy API keys remain valid
for backwards compatibility and existing access JWTs expire normally (one hour).
Confirmation-mail failure does not undo a committed reset or tell the client
that its already-consumed code failed.

For emails sent by an older backend, `GET /auth/reset-password?token=...` now
shows the code with instructions to return to the native app. It is **not a web
password form**. GET never consumes a token (including mail-scanner visits).
The page escapes input, has no scripts/third-party assets, forbids framing,
suppresses referrers, and is non-cacheable/non-indexable. Existing query-string
links can still be retained by a user's mail provider/browser; new emails omit
URLs to avoid that exposure. The page does not validate codes; POST does.

Never obtain codes from production logs or paste secrets into issue reports.
Do not run `examples/test-auth.sh` against production: it creates accounts and
prints session/API credentials; it is a legacy disposable-environment helper,
not the CI regression suite.

## Deterministic CI (no cloud accounts/secrets required)

`.github/workflows/backend-tests.yml` runs **all** registered Vitest files,
including `tests/password-reset.test.ts`, on a public GitHub-hosted Ubuntu runner
with Node 22 and at most two workers. The reset suite executes real production
SQL against an in-memory Node SQLite database, adapts `first/run/meta.changes`
to D1, calls the actual Worker routes, uses real PBKDF2 and the SES signing code,
and replaces only the outbound fetch with a test transport. It uses `schema.sql`
as the fixture; it does not prove migration ordering or live D1 behavior.

The existing lockfile requires `npm ci --legacy-peer-deps` because its unused
coverage-v8 4 plugin has a Vitest 4 peer while the suite uses Vitest 3. CI does not
invoke that plugin. No new dependencies are required for this fix.

Named coverage includes ordinary/Apple-only same-account login, data/API key
preservation, refresh revocation, email instructions, legacy GET safety, invalid/
wrong-purpose/expired/replaced/reused tokens, concurrent consumption, expiry or
replacement during hashing, invalid password/token types, request rate limits,
missing credentials/SES rejection/network failure without secret logs, and
confirmation delivery failure after a successful reset.

## Required owner/device QA before considering the issue complete

In an authorized **nonproduction** environment with disposable ordinary and
Apple/private-relay accounts, on both a physical iOS device and macOS:

- Record app/backend version and platform; verify the actual received email has
  a copyable code, localized screen navigation, and no advertised broken link.
- Complete reset by copying from Mail to the app (including base64 `+`, `/`, `=`);
  no console, URL parsing or sign-up should be needed. Confirm password mismatch
  feedback and successful same-email login. Confirm Apple sign-in still works.
- Capture non-secret before/after user ID, image count and subscription tier;
  confirm existing images, subscriptions and device-local data remain unchanged.
- Confirm expired/invalid/reused/replaced codes are rejected and request another
  code when needed. Confirm an old email link displays native instructions.
- Verify SES delivery **and Apple relay forwarding**, not just HTTP acceptance;
  record delivery/bounce metadata, never codes, passwords or message bodies.

This lane does not deploy, change SES/Apple account settings, send real mail or
claim native runtime/device verification. Backend unit CI cannot substitute for
these delivery and physical-device checks.
