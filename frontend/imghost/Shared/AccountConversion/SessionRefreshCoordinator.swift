import Foundation

/// Production refresh orchestration used by AuthService, including conversion preflight.
/// HTTP rotation is single-use. Retain a returned replacement until it is durably saved,
/// or a compare-and-commit proves another session/logout superseded it. Never resend the
/// old refresh token merely because local persistence is temporarily unavailable.
actor SessionRefreshCoordinator {
    typealias Transport = EmailConversionService.Transport
    enum Failure: LocalizedError {
        case inProgress, persistenceUnavailable, noRefreshToken, rejected, invalidResponse
        var errorDescription: String? {
            switch self {
            case .inProgress, .persistenceUnavailable:
                return String(localized: "Secure session storage is unavailable or busy. The returned session has not been saved. Retry this action; do not create another account. If this persists, keep Apple access and contact support privately.")
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
        case .inProgress, .persistenceUnavailable: return true
        default: return false
        }
    }
    private struct Pending {
        let source: AtomicSessionStore.Snapshot
        let replacement: AccountSession
    }
    private let sessions: AtomicSessionStore
    private let baseURL: URL
    private let transport: Transport
    private let now: () -> Date
    private let retryDelay: () async throws -> Void
    private var pending: Pending?
    private var busy = false

    init(sessions: AtomicSessionStore, baseURL: URL,
         now: @escaping () -> Date = Date.init,
         retryDelay: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) },
         transport: @escaping Transport) {
        self.sessions = sessions
        self.baseURL = baseURL
        self.now = now
        self.retryDelay = retryDelay
        self.transport = transport
    }

    func refresh(replacing expected: AtomicSessionStore.Snapshot? = nil) async throws {
        guard !busy else { throw Failure.inProgress }
        busy = true
        defer { busy = false }
        if let pending {
            if let expected, pending.source != expected {
                // A durable new login/logout must not strand a stale pending response that
                // prevents the new account from refreshing. Discard only after observing it.
                if try sessions.snapshot() != pending.source { self.pending = nil }
                throw AtomicSessionStore.Failure.changedSession
            }
            try await persistReturnedSession()
            return
        }
        let captured = try sessions.snapshot()
        if let expected, captured != expected { throw AtomicSessionStore.Failure.changedSession }
        guard let source = captured.session else { throw Failure.noRefreshToken }
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": source.refreshToken])
        let (data, response) = try await transport(request)
        guard response.statusCode == 200 else { throw Failure.rejected }
        guard let result = try? JSONDecoder().decode(RefreshResponse.self, from: data),
              !result.userId.isEmpty, !result.accessToken.isEmpty, !result.refreshToken.isEmpty,
              result.expiresIn > 0 else { throw Failure.invalidResponse }
        guard source.userID == nil || source.userID == result.userId else {
            throw AtomicSessionStore.Failure.changedSession
        }
        pending = Pending(source: captured, replacement: AccountSession(accessToken: result.accessToken,
            refreshToken: result.refreshToken, expiresAt: now().addingTimeInterval(TimeInterval(result.expiresIn)),
            userID: result.userId))
        // Do not check cancellation/discard the received tokens before this persistence boundary.
        try await persistReturnedSession()
    }

    /// Returns the exact current snapshot. Conversion must independently revalidate its live
    /// source lease after this await; never use this API to refresh after uncertain completion.
    func ensureValidSession(replacing expected: AtomicSessionStore.Snapshot? = nil) async throws -> AtomicSessionStore.Snapshot {
        let captured = try sessions.snapshot()
        if let expected, captured != expected { throw AtomicSessionStore.Failure.changedSession }
        guard let source = captured.session else { throw Failure.noRefreshToken }
        if pending != nil || source.expiresAt.timeIntervalSince(now()) < 300 {
            try await refresh(replacing: captured)
        }
        let current = try sessions.snapshot()
        guard let session = current.session,
              source.userID == nil || source.userID == session.userID else {
            throw AtomicSessionStore.Failure.changedSession
        }
        return current
    }

    private func persistReturnedSession() async throws {
        guard let returned = pending else { return }
        // Four immediate/nonblocking commit attempts and at most three asynchronous delays.
        // Persistent Security failures are visible and retained for an explicit local retry.
        for attempt in 0..<4 {
            do {
                try sessions.commit(returned.replacement, replacing: returned.source)
                pending = nil
                return
            } catch AtomicSessionStore.Failure.changedSession {
                pending = nil
                throw AtomicSessionStore.Failure.changedSession
            } catch AtomicSessionStore.Failure.invalidSession {
                pending = nil
                throw Failure.invalidResponse
            } catch AtomicSessionStore.Failure.lockUnavailable {
                guard attempt < 3 else { throw Failure.persistenceUnavailable }
                do { try await retryDelay() }
                catch { throw Failure.persistenceUnavailable } // Retain returned tokens on cancellation.
            } catch {
                throw Failure.persistenceUnavailable
            }
        }
    }
}
