# Bounded native session corrections to draft #9

This is additive to [NATIVE_EMAIL_CONVERSION.md](NATIVE_EMAIL_CONVERSION.md) and the original
[EMAIL_CONVERSION.md](EMAIL_CONVERSION.md). It addresses the five introduced session defects in
an independent source review at `fbb75ef308072855607dbc72ad85e8614dd9a5f2`. It is not issue #6
acceptance, full issue #5 coverage, production support approval or rollout authorization.
**Keep EMAIL_CONVERSION_ENABLED unset and PR #9 draft.** No backend behavior or reset #8 repair
is changed here; combined reset/conversion qualification remains required.

## Source authority before dispatch

A conversion lease now dies on successful durable ordinary login/session replacement (including
same-ID login), conversion adoption, or logout. Failed durable logout does not pretend the source
changed. The production coordinator checks the live lease, memory account and exact durable
snapshot before each challenge/start/complete request and after prerequisites await. Refresh is
permitted only for that captured session; the renewed snapshot must still belong to the same
live lease/account before dispatch. It never silently switches an existing flow to another login.

Account/logout changes before dispatch invalidate the flow with close/reopen guidance. Requests
already sent cannot be cancelled transactionally: callbacks cannot adopt over logout/replacement,
and completion uncertainty still explains that the server may have committed. Recovery is only
ordinary same-ID email login followed by durable adoption. **Recovery does not refresh the old
session or resend the code**, because completion may already have revoked that refresh token.

## Returned refresh response and bounded persistence

`AuthService` owns a `SessionRefreshCoordinator` actor. Ordinary refresh, ordinary token preflight
and conversion preflight all invoke this same production collaborator, not a test-only facade.
It performs the real `/auth/refresh` request, response validation and store compare/commit.
A busy actor fails observably rather than launching concurrent in-process rotations. Other
processes remain serialized only at the shared store boundary; backend single-use rotation still
arbitrates simultaneous HTTP refreshes.

After receiving and validating replacement tokens, the actor retains one pending replacement
and its captured source snapshot until saved or provably superseded. File/process locks are
nonblocking. Commit contention permits **four attempts / three asynchronous 100 ms delays**;
Security failures stop immediately with an observable persistence error. Cancellation during a
retry delay also retains the response. An explicit retry drains that pending response locally,
without issuing another refresh POST. Changed snapshot/tombstone rejects and discards the stale
replacement, never overwrites a new account, and never resurrects logout. New-account refresh
can proceed after the stale pending result is discarded.

`AuthState.checkAuthStatus` treats local storage/decode/persistence/in-progress errors as storage
unavailability, not proof of session expiry: it does not run another HTTP refresh or logout/reset
subscription for these failures. Native Settings/login surfaces expose sanitized recovery guidance.
No tokens, passwords, codes, customer details or raw provider errors are logged.

**Boundary:** the pending response is process memory, not a second persistent credential format.
Termination/crash before successful Keychain commit loses that buffer. No server rollback, cross-
process pending-response recovery, power-loss durability or lockout immunity is claimed. Preserved
credentials/Apple access and explicit reauthentication remain recovery options. Actual entitled
Keychain/access-group/crash behavior is still an external release/rollout gate; these source changes
and syscall tests do not establish it. Lost HTTP refresh responses and full multi-process refresh
coalescing remain broader lifecycle qualification, not solved by local persistence retry.

## Expired legacy access and fresh-response validation

The actual `KeychainService` migration adapter is injectable at Security syscalls and executed by
the test package. Both historical access groups are snapshotted coherently under the production
lock. Only a completely empty destination can import a complete legacy session; an ordinarily
expired access token is allowed **only on that import path**, so its refresh credential survives
and ordinary production preflight can recover. Fresh login/refresh/conversion commits still
require nonempty tokens and future expiry. Legacy items are not deleted. An authoritative item,
including tombstone, corruption or permission failure, is not absence or permission to migrate
from another group. An inaccessible obsolete entitlement is skipped without modifying that group.
Signed/current and mixed-version extension access still need authorized device qualification.

## Observable logout and corruption policy

`AuthState.logout` returns success/failure and publishes a sanitized error. Memory, credentials,
lease and subscription remain intact until a durable tombstone succeeds. Both Settings buttons
show failure and become **Retry sign out**; explicit successful retry clears the error and publishes
logout/reset once. Login screens also show storage guidance after cold-start or persistence failure.

Corruption is fail-closed, not a trigger to delete the authoritative item or resurrect legacy JWTs.
The app exposes close/retry/private-support guidance. A destructive repair/reset policy is **not**
authorized or invented here. Persistent corrupt-item remediation requires an owner-approved
identity/repair policy and signed device evidence; synthetic green cannot close that gate.

## Executable evidence surface

`SessionCorrectionTests` exercises production file-lock contention using an independent open
file descriptor, actual refresh HTTP/validation/pending/CAS/retry orchestration, actual Security-
injected Keychain migration, actual AuthState and actual Settings coordinator. The original 32
client cases remain registered and asserted; the native fixture now supplies production refresh
preflight rather than bypassing it. The package compiles KeychainService/Config/ImghostError, and
the refresh collaborator is in all four app/extension Sources phases. Hosted Actions execute both
platform suites, iOS typecheck and unsigned full iOS/macOS app/extension builds; app binaries are
not launched against production URLs. Exact heads, named executions and failures belong in the
additive correction report. None of these tests qualify real Apple proof, SES/relay inboxes, D1,
local library/subscriber renewal, translations, clipboard/accessibility or all #5 lifecycle races.
