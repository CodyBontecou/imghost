import Foundation
import SwiftUI

@MainActor
final class AuthState: ObservableObject {
    struct Dependencies {
        let sessions: AtomicSessionStore
        let user: () async throws -> User
        let refresh: () async throws -> Void
        let sync: () async -> Void
        let resetSubscription: () -> Void
    }
    @Published var isAuthenticated = false
    @Published var isEmailVerified = false
    @Published var currentUser: User?
    @Published var isLoading = true
    private let dependencies: Dependencies
    private var generation = 0
    private var conversionLease: UUID?

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    var isAnonymous: Bool { currentUser?.isAnonymous == true }
    var hasVerifiedEmailOrAnonymous: Bool { isEmailVerified || isAnonymous }
    var requiresEmailVerification: Bool { isAuthenticated && !hasVerifiedEmailOrAnonymous }

    func checkAuthStatus() async {
        // Completion revokes the old refresh token before local login/adoption. Background
        // expiry checks must not erase/publish over the source session while this flow owns it.
        guard conversionLease == nil else { return }
        let start = generation
        isLoading = true
        defer { if start == generation { isLoading = false } }
        // A Keychain read failure is not proof of logout. Preserve state and durable credentials.
        guard let snapshot = try? dependencies.sessions.snapshot() else { return }
        guard snapshot.session != nil else {
            if start == generation { publish(nil) }
            return
        }
        do {
            let user = try await dependencies.user()
            guard start == generation, conversionLease == nil else { return }
            publish(user)
            await dependencies.sync()
        } catch {
            guard start == generation else { return }
            do {
                try await dependencies.refresh()
                let user = try await dependencies.user()
                guard start == generation, conversionLease == nil else { return }
                publish(user)
                await dependencies.sync()
            } catch {
                guard start == generation else { return }
                // Do not erase a newer app/extension session on a stale request failure.
                guard let now = try? dependencies.sessions.snapshot(), now == snapshot else { return }
                logout()
            }
        }
    }

    /// Ordinary login also uses one durable write; memory is unchanged if persistence fails.
    func setAuthenticated(response: AuthResponse) async throws {
        let snapshot = try dependencies.sessions.snapshot()
        try dependencies.sessions.commit(Self.session(response), replacing: snapshot)
        generation += 1
        publish(User(id: response.userId, email: response.email, emailVerified: response.emailVerified,
                     storageUsedBytes: 0, storageLimitBytes: 0, imageCount: nil, isAnonymous: response.isAnonymous))
        isLoading = false
        await dependencies.sync()
    }

    /// Synchronous commit-to-publication boundary: no await/cancellation between durable write
    /// and memory publication. Preserve quota/library/subscription; never route through logout.
    func adoptConversion(_ response: AuthResponse, sourceUserID: String,
                         replacing snapshot: AtomicSessionStore.Snapshot) throws {
        guard let user = currentUser, isAuthenticated, user.id == sourceUserID,
              response.userId == sourceUserID, response.emailVerified,
              response.isAnonymous != true else { throw EmailConversionService.Failure.wrongAccount }
        try dependencies.sessions.commit(Self.session(response), replacing: snapshot)
        generation += 1
        isLoading = false
        publish(User(id: user.id, email: response.email, emailVerified: true,
                     storageUsedBytes: user.storageUsedBytes, storageLimitBytes: user.storageLimitBytes,
                     imageCount: user.imageCount, isAnonymous: user.isAnonymous))
    }

    func beginConversionLease() throws -> (UUID, AtomicSessionStore.Snapshot) {
        guard conversionLease == nil else { throw AtomicSessionStore.Failure.changedSession }
        let snapshot = try conversionSnapshot()
        let lease = UUID()
        conversionLease = lease
        generation += 1 // Invalidate auth checks already awaiting a pre-conversion response.
        isLoading = false
        return (lease, snapshot)
    }

    func endConversionLease(_ lease: UUID) {
        if conversionLease == lease { conversionLease = nil }
    }

    func conversionSnapshot() throws -> AtomicSessionStore.Snapshot {
        let snapshot = try dependencies.sessions.snapshot()
        guard isAuthenticated, let user = currentUser, user.isAnonymous != true,
              let session = snapshot.session,
              session.userID == nil || session.userID == user.id else {
            throw EmailConversionService.Failure.reauthenticate
        }
        return snapshot
    }

    private static func session(_ response: AuthResponse) -> AccountSession {
        AccountSession(accessToken: response.accessToken, refreshToken: response.refreshToken,
                       expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)), userID: response.userId)
    }

    private func publish(_ user: User?) {
        currentUser = user
        isEmailVerified = user.map { $0.emailVerified || $0.isAnonymous == true } ?? false
        isAuthenticated = user != nil
    }

    func setEmailVerified(_ verified: Bool) {
        guard let user = currentUser else { return }
        generation += 1
        publish(User(id: user.id, email: user.email, emailVerified: verified,
                     storageUsedBytes: user.storageUsedBytes, storageLimitBytes: user.storageLimitBytes,
                     imageCount: user.imageCount, isAnonymous: user.isAnonymous))
    }

    func updateUser(_ user: User) {
        guard conversionLease == nil else { return }
        generation += 1
        publish(user)
    }

    func logout() {
        do {
            let snapshot = try dependencies.sessions.snapshot()
            try dependencies.sessions.commit(nil, replacing: snapshot)
        } catch { return } // Keep memory intact if the durable logout cannot be committed.
        generation += 1
        publish(nil)
        isLoading = false
        dependencies.resetSubscription()
    }
}
