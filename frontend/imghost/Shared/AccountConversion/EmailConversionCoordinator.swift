import Foundation
import SwiftUI

/// Real Settings orchestration; no registration/unlinking, global logout or local-data reset.
@MainActor
final class EmailConversionCoordinator: ObservableObject {
    enum Stage: Equatable { case idle, apple, email, recovery, invalidated, done }
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var challenge: EmailConversionService.Challenge?
    @Published var destination = ""
    @Published var code = ""
    @Published var password = ""
    @Published var confirmation = ""
    private let service: EmailConversionService
    private let authState: AuthState
    private let login: (String, String) async throws -> AuthResponse
    private let prepareSession: (AtomicSessionStore.Snapshot) async throws -> AtomicSessionStore.Snapshot
    private let beforeValidationRead: () throws -> Void
    private var snapshot: AtomicSessionStore.Snapshot?
    private var sourceID: String?
    private var epoch = UUID()
    private var notificationPending = false
    private var chosenDestination = ""
    private var lease: UUID?

    init(service: EmailConversionService, authState: AuthState,
         prepareSession: @escaping (AtomicSessionStore.Snapshot) async throws -> AtomicSessionStore.Snapshot,
         beforeValidationRead: @escaping () throws -> Void = {},
         login: @escaping (String, String) async throws -> AuthResponse) {
        self.service = service
        self.authState = authState
        self.prepareSession = prepareSession
        self.beforeValidationRead = beforeValidationRead
        self.login = login
    }

    func begin() async {
        guard !busy, stage == .idle else { return }
        epoch = UUID()
        let operation = epoch
        busy = true
        message = nil
        defer { if operation == epoch { busy = false } }
        do {
            guard Self.validEmail(destination) else { throw EmailConversionService.Failure.invalidInput }
            chosenDestination = Self.canonical(destination)
            let (lease, captured) = try authState.beginConversionLease()
            self.lease = lease
            sourceID = authState.currentUser?.id
            snapshot = captured
            let ready = try await prepare(operation: operation)
            let result = try await service.challenge(accessToken: ready.session!.accessToken)
            try Task.checkCancellation()
            guard operation == epoch else { return }
            try validate(ready)
            guard !result.nonce.isEmpty, !result.challengeID.isEmpty,
                  result.expiresAt > Date().timeIntervalSince1970 * 1000 else {
                throw EmailConversionService.Failure.invalidInput
            }
            challenge = result
            stage = .apple
        } catch {
            if operation == epoch {
                releaseLease()
                snapshot = nil
                sourceID = nil
                if error is AuthState.ConversionFailure { stage = .invalidated }
                message = Self.errorMessage(error)
            }
        }
    }

    func authorize(identityToken: String) async {
        guard !busy, stage == .apple, let challenge else { return }
        let operation = epoch
        busy = true
        message = nil
        defer { if operation == epoch { busy = false } }
        do {
            let ready = try await prepare(operation: operation)
            guard !identityToken.isEmpty, challenge.expiresAt > Date().timeIntervalSince1970 * 1000 else {
                throw EmailConversionService.Failure.invalidInput
            }
            try await service.start(challenge: challenge, identityToken: identityToken,
                                    destinationEmail: chosenDestination, accessToken: ready.session!.accessToken)
            try Task.checkCancellation()
            guard operation == epoch else { return }
            try validate(ready)
            stage = .email
        } catch {
            if operation == epoch {
                if error is AuthState.ConversionFailure { invalidate() }
                message = Self.errorMessage(error)
            }
        }
    }

    func appleAuthorizationFailed(cancelled: Bool) {
        guard stage == .apple else { return }
        message = cancelled ? String(localized: "Apple authorization cancelled. Your credentials are unchanged. You can try again.")
            : String(localized: "Apple authorization failed. Try again with a new authorization, or restart this flow.")
    }

    func complete() async {
        guard !busy, stage == .email, let challenge, let sourceID else { return }
        let operation = epoch
        let chosenPassword = password
        var dispatched = false
        busy = true
        message = nil
        defer { if operation == epoch { busy = false } }
        do {
            let ready = try await prepare(operation: operation)
            dispatched = true
            let result = try await service.complete(challenge: challenge, code: code, password: password,
                passwordConfirmation: confirmation, sourceUserID: sourceID,
                accessToken: ready.session!.accessToken)
            guard operation == epoch else { return }
            // The server committed. Every subsequent error has a recovery path, not a rollback claim.
            stage = .recovery
            notificationPending = result.notificationPending
            guard Self.canonical(result.email) == chosenDestination else {
                throw EmailConversionService.Failure.wrongAccount
            }
            try Task.checkCancellation()
            try await verifyAndAdopt(replacing: ready, password: chosenPassword, operation: operation)
        } catch {
            guard operation == epoch else { return }
            if !dispatched, error is AuthState.ConversionFailure {
                invalidate()
                message = Self.errorMessage(error)
                return
            }
            if (error as? EmailConversionService.Failure) == .uncertainCompletion ||
                (error as? EmailConversionService.Failure) == .wrongAccount ||
                (dispatched && error is CancellationError) {
                stage = .recovery
            }
            message = stage == .recovery ? Self.recoveryMessage : Self.errorMessage(error)
        }
    }

    /// Explicit recovery logs in only. Completion may have revoked the old refresh token;
    /// do NOT run preflight/refresh or rebase this flow onto a new login/account here.
    func recover() async {
        guard !busy, stage == .recovery else { return }
        let operation = epoch
        busy = true
        defer { if operation == epoch { busy = false } }
        do {
            guard let lease, let sourceID else { throw AuthState.ConversionFailure.sourceChanged }
            try authState.validateConversionLease(lease, sourceUserID: sourceID)
            guard password == confirmation, (8...1024).contains(password.utf16.count) else {
                throw EmailConversionService.Failure.invalidInput
            }
            let current = try authState.conversionSnapshot()
            try await verifyAndAdopt(replacing: current, password: password, operation: operation)
        } catch {
            if operation == epoch {
                message = Self.recoveryMessage
                if error is AuthState.ConversionFailure { message! += " " + Self.sourceChangedMessage }
            }
        }
    }

    private func prepare(operation: UUID) async throws -> AtomicSessionStore.Snapshot {
        guard let captured = snapshot else { throw AuthState.ConversionFailure.sourceChanged }
        // A failed read acknowledgement can leave this flow holding A after its own durable
        // refresh B. The production actor alone may prove that EXACT transition; never rebase
        // from a same-ID snapshot here. A new login/logout still invalidates the live lease.
        try validateLease()
        let ready: AtomicSessionStore.Snapshot
        do { ready = try await prepareSession(captured) }
        catch AtomicSessionStore.Failure.changedSession { throw AuthState.ConversionFailure.sourceChanged }
        try Task.checkCancellation()
        guard operation == epoch else { throw CancellationError() }
        // No await between validating the renewed source and dispatching a new server write.
        try validateLease()
        guard let lease, let sourceID else { throw AuthState.ConversionFailure.sourceChanged }
        try beforeValidationRead() // Observation seam: tests hold the real independent-descriptor lock.
        try authState.validateConversionSession(lease, sourceUserID: sourceID, replacing: ready)
        snapshot = ready
        return ready
    }

    private func validateLease() throws {
        guard let lease, let sourceID else { throw AuthState.ConversionFailure.sourceChanged }
        try authState.validateConversionLease(lease, sourceUserID: sourceID)
    }

    private func validate(_ captured: AtomicSessionStore.Snapshot) throws {
        try validateLease()
        try authState.validateConversionSession(lease!, sourceUserID: sourceID!, replacing: captured)
    }

    private func verifyAndAdopt(replacing snapshot: AtomicSessionStore.Snapshot, password: String, operation: UUID) async throws {
        try validate(snapshot)
        let response = try await login(chosenDestination, password)
        try Task.checkCancellation()
        guard operation == epoch else { return }
        try validate(snapshot)
        guard response.userId == sourceID, response.emailVerified, response.isAnonymous != true,
              Self.canonical(response.email) == chosenDestination, let sourceID else {
            throw EmailConversionService.Failure.wrongAccount
        }
        try authState.adoptConversion(response, sourceUserID: sourceID, replacing: snapshot)
        stage = .done
        releaseLease()
        self.snapshot = nil
        challenge = nil
        message = notificationPending
            ? String(localized: "New email login verified and saved on this device. Apple access remains. Confirmation delivery is pending.")
            : String(localized: "New email login verified and saved on this device. Apple access remains. Your library and subscription were not reset.")
        self.password = ""
        confirmation = ""
        code = ""
    }

    func cancel() {
        // Invalidates callbacks, not the server transaction. Never claim remote rollback.
        epoch = UUID()
        releaseLease()
        busy = false
        stage = .idle
        message = nil
        challenge = nil
        snapshot = nil
        sourceID = nil
        chosenDestination = ""
        notificationPending = false
        password = ""
        confirmation = ""
        code = ""
    }

    private func invalidate() {
        releaseLease()
        stage = .invalidated
        snapshot = nil
        password = ""
        confirmation = ""
        code = ""
    }

    private func releaseLease() {
        if let lease { authState.endConversionLease(lease) }
        lease = nil
    }

    static let sourceChangedMessage = String(localized: "The signed-in account or session changed. This flow cannot continue or switch accounts. Close and reopen Account settings for the intended account. Requests already sent may have completed; Apple access remains.")
    static let recoveryMessage = String(localized: "The server may have changed your login email, but this device has not saved the new session. Apple access remains. Check new email login to recover; do not create another account. If that fails, reopen this flow or sign in with Apple.")
    private static func canonical(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    private static func validEmail(_ email: String) -> Bool {
        let value = canonical(email)
        return value.count <= 254 && value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
            && value.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil
    }
    private static func errorMessage(_ error: Error) -> String {
        if error is AuthState.ConversionFailure { return sourceChangedMessage }
        if error is AtomicSessionStore.Failure || error is DecodingError || SessionRefreshCoordinator.isLocalFailure(error) {
            return AuthState.storageGuidance
        }
        switch error as? EmailConversionService.Failure {
        case .unavailable: return String(localized: "Email/password conversion is not available yet, or the service cannot be reached. Keep using Apple sign-in. Retry later; do not register another account.")
        case .reauthenticate: return String(localized: "Fresh sign-in is required. Keep Apple access and reopen this flow after signing in.")
        case .destinationUnavailable: return String(localized: "This email or challenge is unavailable. Accounts cannot be merged. Restart with an unoccupied email.")
        case .tooManyRequests: return String(localized: "Too many requests. Wait before restarting with a new Apple authorization.")
        case .invalidInput: return String(localized: "Check the email, code and matching passwords (8–1024 characters). If the challenge expired, restart with a new Apple authorization.")
        default: return String(localized: "Could not verify this request. No new local session was saved. Keep Apple access and restart or retry.")
        }
    }
}
