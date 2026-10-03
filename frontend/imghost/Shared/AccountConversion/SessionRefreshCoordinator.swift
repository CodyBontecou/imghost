import Foundation

/// Production refresh orchestration used by AuthService, including conversion preflight.
/// Retain a validated returned response through local failure. Retain one exact own-commit
/// receipt through read acknowledgement failure, never rebind just because user IDs match.
actor SessionRefreshCoordinator {
    typealias Transport = EmailConversionService.Transport
    enum Failure: LocalizedError {
        case inProgress, persistenceUnavailable, renewalUnavailable, noRefreshToken, rejected, invalidResponse
        var errorDescription: String? {
            switch self {
            case .inProgress, .persistenceUnavailable:
                return String(localized: "Secure session storage is unavailable or busy. The returned session has not been saved. Retry this action; do not create another account. If this persists, keep Apple access and contact support privately.")
            case .renewalUnavailable:
                return String(localized: "The saved session could not be renewed or verified yet. Retry this action. Keep Apple access and contact support privately if this persists; do not create another account.")
            case .noRefreshToken, .rejected:
                return String(localized: "Please sign in again to continue.")
            case .invalidResponse:
                return String(localized: "The session response could not be verified. Keep Apple access and sign in again; do not create another account.")
            }
        }
    }
    nonisolated static func isLocalFailure(_ error: Error) -> Bool {
        guard let failure = error as? Failure else { return false }
        switch failure {
        case .inProgress, .persistenceUnavailable, .renewalUnavailable: return true
        default: return false
        }
    }
    private struct Transition {
        let source: AtomicSessionStore.Snapshot
        let previous: AtomicSessionStore.Snapshot
        let committed: AtomicSessionStore.Snapshot
    }
    private let sessions: AtomicSessionStore
    private let baseURL: URL
    private let transport: Transport
    private let now: () -> Date
    private let retryDelay: () async throws -> Void
    /// Synchronous observation seam for precise post-commit read contention, not a lock facade.
    private let beforeAcknowledgementRead: () throws -> Void
    private var pending: AtomicSessionStore.ValidatedRefresh?
    private var ownTransition: Transition?
    private var busy = false

    init(sessions: AtomicSessionStore, baseURL: URL,
         now: @escaping () -> Date = Date.init,
         retryDelay: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) },
         beforeAcknowledgementRead: @escaping () throws -> Void = {},
         transport: @escaping Transport) {
        self.sessions = sessions
        self.baseURL = baseURL
        self.now = now
        self.retryDelay = retryDelay
        self.beforeAcknowledgementRead = beforeAcknowledgementRead
        self.transport = transport
    }

    func refresh(replacing expected: AtomicSessionStore.Snapshot? = nil) async throws {
        guard !busy else { throw Failure.inProgress }
        busy = true
        defer { busy = false }
        let committed: AtomicSessionStore.Snapshot
        if let pending {
            if let expected, pending.source != expected {
                // Discard only after an actual read proves replacement/logout, not contention.
                if try sessions.snapshot() != pending.source {
                    self.pending = nil
                    ownTransition = nil
                }
                throw AtomicSessionStore.Failure.changedSession
            }
            committed = try await persistReturnedSession()
        } else {
            let captured = try sessions.snapshot()
            try validateExpected(expected, actual: captured)
            committed = try await rotate(captured)
        }
        if let session = committed.session, session.expiresAt <= now() {
            // The validated response aged while unsaved. Its refresh token is now durable;
            // rotate THAT token once, never resend its consumed source or use expired access.
            guard try sessions.snapshot() == committed else {
                ownTransition = nil
                throw AtomicSessionStore.Failure.changedSession
            }
            let renewed = try await rotate(committed)
            guard let session = renewed.session, session.expiresAt > now() else {
                throw Failure.renewalUnavailable // Bounded: no loop, leave durable credential/receipt.
            }
        }
    }

    private func rotate(_ captured: AtomicSessionStore.Snapshot) async throws -> AtomicSessionStore.Snapshot {
        guard let source = captured.session else { throw Failure.noRefreshToken }
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": source.refreshToken])
        let (data, response) = try await transport(request)
        guard response.statusCode == 200 else { throw Failure.rejected }
        guard let result = try? JSONDecoder().decode(RefreshResponse.self, from: data) else { throw Failure.invalidResponse }
        do {
            pending = try sessions.validateReturnedRefresh(result, replacing: captured, receivedAt: now())
        } catch AtomicSessionStore.Failure.invalidSession {
            throw Failure.invalidResponse
        }
        // No cancellation check may discard a validated returned token before persistence.
        return try await persistReturnedSession()
    }

    /// An exact own A->B commit may be acknowledged on retry after a failed final read.
    /// Conversion MUST revalidate its live lease after this await. No uncertain-completion use.
    func ensureValidSession(replacing expected: AtomicSessionStore.Snapshot? = nil) async throws -> AtomicSessionStore.Snapshot {
        let captured = try sessions.snapshot()
        try validateExpected(expected, actual: captured)
        guard let source = captured.session else { throw Failure.noRefreshToken }
        if pending != nil || source.expiresAt.timeIntervalSince(now()) < 300 {
            try await refresh(replacing: captured)
        }
        try beforeAcknowledgementRead()
        let current = try sessions.snapshot()
        try validateExpected(captured, actual: current)
        guard let session = current.session, session.expiresAt > now() else { throw Failure.renewalUnavailable }
        return current
    }

    private func validateExpected(_ expected: AtomicSessionStore.Snapshot?, actual: AtomicSessionStore.Snapshot) throws {
        if let transition = ownTransition, transition.committed != actual {
            ownTransition = nil // An observed foreign revision/tombstone breaks the provenance chain.
        }
        guard let expected, expected != actual else { return }
        guard let transition = ownTransition,
              transition.source == expected || transition.previous == expected,
              transition.committed == actual else { throw AtomicSessionStore.Failure.changedSession }
    }

    private func recordCommit(from source: AtomicSessionStore.Snapshot, to committed: AtomicSessionStore.Snapshot) {
        // Root, immediate predecessor and committed snapshot only: bounded process memory,
        // not an unbounded history or a second persistent credential store.
        // Preserve an unacknowledged root through our own aged-response persistence + renewal.
        let root = ownTransition?.committed == source ? ownTransition!.source : source
        ownTransition = Transition(source: root, previous: source, committed: committed)
    }

    private func persistReturnedSession() async throws -> AtomicSessionStore.Snapshot {
        guard let returned = pending else { throw Failure.renewalUnavailable }
        // Four nonblocking commit attempts / at most three asynchronous delays. Security
        // failure and cancellation retain the validated capability for an explicit retry.
        for attempt in 0..<4 {
            do {
                let committed = try sessions.commitReturnedRefresh(returned)
                recordCommit(from: returned.source, to: committed)
                pending = nil
                return committed
            } catch AtomicSessionStore.Failure.changedSession {
                pending = nil
                ownTransition = nil
                throw AtomicSessionStore.Failure.changedSession
            } catch AtomicSessionStore.Failure.invalidSession {
                // Capability misuse is not access aging. Keep local failure observable.
                throw Failure.persistenceUnavailable
            } catch AtomicSessionStore.Failure.lockUnavailable {
                guard attempt < 3 else { throw Failure.persistenceUnavailable }
                do { try await retryDelay() }
                catch { throw Failure.persistenceUnavailable }
            } catch {
                throw Failure.persistenceUnavailable
            }
        }
        throw Failure.persistenceUnavailable
    }
}
