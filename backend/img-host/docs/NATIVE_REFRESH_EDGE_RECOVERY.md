# Bounded native refresh-edge recovery in draft #9

Additive to [NATIVE_SESSION_CORRECTION.md](NATIVE_SESSION_CORRECTION.md). This addresses the two
remaining introduced P2s reviewed at `df7d22ae39296d0728ceb6dd093459e44509ab8f`, not full issue
#6 acceptance, general #5 lifecycle or rollout. **Keep EMAIL_CONVERSION_ENABLED unset and PR #9
draft.** No backend, reset #8, configuration, dependency, envelope version or retention policy change.

## Validated returned refresh response ages while storage is unavailable

The production actor now holds a store-bound `ValidatedRefresh` capability, minted ONLY after
fresh response decoding, nonempty tokens/user ID, Bearer type, positive finite future expiry and
source-account validation (legacy unknown ID retains its existing migration policy). The constructor
is file-private to the store implementation. The capability records the ORIGINAL exact source
snapshot and producing store identity; it cannot be used on another store or replayed after CAS.

`commitReturnedRefresh` alone can persist that already-validated response after its access expires.
It does not bypass source CAS or write another credential format. Generic fresh login/adoption
`commit` remains nonempty-token/future-expiry strict; legacy import remains empty-destination-only.
Expired access is NOT returned as valid authorization: after persisting the returned refresh token,
the actor checks the exact committed snapshot and rotates that returned token once if access aged.
The consumed original token is never reposted just because persistence failed. A renewed response
that cannot be persisted remains pending against its new exact source, for explicit local retry.
One invocation performs at most one additional renewal, never an unbounded loop. Locks still use
four nonblocking attempts / three asynchronous 100 ms delays per commit; Security failures stop
immediately. AuthState treats local persistence/renewal unavailability as observable, not logout
or subscription reset. Malformed fresh responses do not acquire aging permission.

One injected session clock now reaches the actual actor, Keychain/atomic store fresh validation and
AuthState response construction in new tests. Production defaults remain Date; no backend clock,
challenge TTL or broader timing policy was changed.

## Own A->B commit survives read acknowledgement failure

The store returns the exact successful write receipt (including its revision bytes) without a
second read. The actor records its own exact source-to-commit transition before clearing pending.
A final helper snapshot can still fail under real contention, as can the coordinator's subsequent
validation read. The actor retains bounded process-memory provenance: unacknowledged root,
immediate predecessor and latest committed snapshot, not an unbounded revision history.

On retry, the conversion checks its LIVE source lease before awaiting preflight. Only the actor
may resolve a stale snapshot to an EXACT proven own committed revision, including its own aged
persistence/renewal chain. It never resolves by user ID/token value alone. A successfully observed
foreign revision or tombstone clears provenance; a read error does not. The coordinator then
checks cancellation/epoch, live lease, memory source account and exact current durable snapshot
before any challenge/start/complete dispatch. A failed post-success read preserves the email
stage/code/password and issues no completion POST; successful explicit retry uses the same
challenge/code and one eventual completion. A new login/logout (even same ID) still invalidates
the lease. Identical credentials written under a FOREIGN new revision still fail provenance.
Recovery after uncertain completion remains login-only, not old-token refresh or code resend.

The two narrow synchronous observation callbacks default to no-op. Hosted tests use them to
hold a real independent-open-descriptor flock AFTER successful commit and BEFORE the exact final
helper or coordinator read. They do not inject a fake lock-success/failure facade. No production
network, Security syscall, Keychain or lock is replaced by a second orchestration model.

## Evidence and limits

`RefreshEdgeTests` executes the actual production actor/store/AuthState/coordinator, synthetic
single-use HTTP rotation and Security data, shared session clock, and real file-lock contention.
It adds aging/renewal persistence and supersession cases, both precise read windows, logout/
account switch/same-ID relogin/foreign-same-ID-revision negatives in both windows, strict fresh
login/adoption/malformed refresh checks and store-bound capability/replay checks. All prior 62
cases/assertions remain unchanged. SwiftPM automatically registers the new suite; existing four
native Sources registrations and hosted platform/full-app-extension gates remain in force.
Exact named execution/build results belong in the additive refresh-edge report, not this design.

The actor is genuinely owned/invoked by AuthService; singleton URLSession/composition/Settings
are source-inspected and unsigned-compiled, not full-app runtime evidence. Before durable commit,
pending capabilities and acknowledgement receipts are PROCESS MEMORY ONLY. No crash/power-loss
or cross-process pending-response/coalescing guarantee, new credential store, mixed-version
upgrade qualification or server rollback is claimed. Lost HTTP responses, revocation/network
policy and arbitrary concurrent unrelated lifecycle remain #5/owner qualification. No destructive
corruption repair policy is invented. Real Apple/SES/relay/D1, signed Keychain/app-group/extension,
physical library/renewal, accessibility/translations, reset #8 integration/combined races,
notification retry/retention, JWT/API-key policy and dependency advisory gates remain incomplete.
