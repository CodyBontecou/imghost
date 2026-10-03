import Foundation
import SwiftUI

/// Real Settings orchestration; no registration/unlinking, global logout or local-data reset.
@MainActor
final class EmailConversionCoordinator: ObservableObject {
    enum Stage: Equatable { case idle, apple, email, recovery, done }
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
    private var snapshot: AtomicSessionStore.Snapshot?
    private var sourceID: String?
    private var epoch = UUID()
    private var notificationPending = false
    private var chosenDestination = ""

    init(service: EmailConversionService, authState: AuthState,
         login: @escaping (String, String) async throws -> AuthResponse) {
        self.service = service
        self.authState = authState
        self.login = login
    }

    func begin() async {
        guard !busy else { return }
        epoch = UUID()
        let operation = epoch
        busy = true
        message = nil
        defer { if operation == epoch { busy = false } }
        do {
            guard Self.validEmail(destination) else { throw EmailConversionService.Failure.invalidInput }
            chosenDestination = Self.canonical(destination)
            let captured = try authState.conversionSnapshot()
            sourceID = authState.currentUser?.id
            snapshot = captured
            let result = try await service.challenge(accessToken: captured.session!.accessToken)
            try Task.checkCancellation()
            guard operation == epoch else { return }
            guard !result.nonce.isEmpty, !result.challengeID.isEmpty,
                  result.expiresAt > Date().timeIntervalSince1970 * 1000 else {
                throw EmailConversionService.Failure.invalidInput
            }
            challenge = result
            stage = .apple
        } catch { if operation == epoch { message = Self.errorMessage(error) } }
    }

    func authorize(identityToken: String) async {
        guard !busy, stage == .apple, let challenge, let token = snapshot?.session?.accessToken else { return }
        let operation = epoch
        busy = true
        message = nil
        defer { if operation == epoch { busy = false } }
        do {
            guard !identityToken.isEmpty, challenge.expiresAt > Date().timeIntervalSince1970 * 1000 else {
                throw EmailConversionService.Failure.invalidInput
            }
            try await service.start(challenge: challenge, identityToken: identityToken,
                                    destinationEmail: chosenDestination, accessToken: token)
            try Task.checkCancellation()
            guard operation == epoch else { return }
            stage = .email
        } catch { if operation == epoch { message = Self.errorMessage(error) } }
    }

    func appleAuthorizationFailed(cancelled: Bool) {
        message = cancelled ? String(localized: "Apple authorization cancelled. Your credentials are unchanged. You can try again.")
            : String(localized: "Apple authorization failed. Try again with a new authorization, or restart this flow.")
    }

    func complete() async {
        guard !busy, stage == .email, let challenge, let snapshot, let sourceID else { return }
        let operation = epoch
        let chosenPassword = password
        busy = true
        message = nil
        defer { if operation == epoch { busy = false } }
        do {
            let result = try await service.complete(challenge: challenge, code: code, password: password,
                passwordConfirmation: confirmation, sourceUserID: sourceID,
                accessToken: snapshot.session!.accessToken)
            guard operation == epoch else { return }
            // The server committed. Every subsequent error has a recovery path, not a rollback claim.
            stage = .recovery
            notificationPending = result.notificationPending
            guard Self.canonical(result.email) == chosenDestination else {
                throw EmailConversionService.Failure.wrongAccount
            }
            try Task.checkCancellation()
            guard operation == epoch else { return }
            try await verifyAndAdopt(replacing: snapshot, password: chosenPassword, operation: operation)
        } catch {
            guard operation == epoch else { return }
            if (error as? EmailConversionService.Failure) == .uncertainCompletion ||
                (error as? EmailConversionService.Failure) == .wrongAccount || error is CancellationError {
                stage = .recovery
            }
            message = stage == .recovery ? Self.recoveryMessage : Self.errorMessage(error)
        }
    }

    /// Explicit recovery after lost response/login or persistence failure. Do not resend a consumed code.
    func recover() async {
        guard !busy, stage == .recovery else { return }
        let operation = epoch
        busy = true
        defer { if operation == epoch { busy = false } }
        do {
            guard password == confirmation, (8...1024).contains(password.utf16.count) else {
                throw EmailConversionService.Failure.invalidInput
            }
            let current = try authState.conversionSnapshot()
            try await verifyAndAdopt(replacing: current, password: password, operation: operation)
        } catch { if operation == epoch { message = Self.recoveryMessage } }
    }

    private func verifyAndAdopt(replacing snapshot: AtomicSessionStore.Snapshot, password: String, operation: UUID) async throws {
        let response = try await login(chosenDestination, password)
        try Task.checkCancellation()
        guard operation == epoch else { return }
        guard response.userId == sourceID, response.emailVerified, response.isAnonymous != true,
              Self.canonical(response.email) == chosenDestination, let sourceID else {
            throw EmailConversionService.Failure.wrongAccount
        }
        try authState.adoptConversion(response, sourceUserID: sourceID, replacing: snapshot)
        stage = .done
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
        busy = false
        stage = .idle
        message = nil
        challenge = nil
        snapshot = nil
        password = ""
        confirmation = ""
        code = ""
    }

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
        switch error as? EmailConversionService.Failure {
        case .unavailable: return String(localized: "Email/password conversion is not available yet, or the service cannot be reached. Keep using Apple sign-in. Retry later; do not register another account.")
        case .reauthenticate: return String(localized: "Fresh sign-in is required. Keep Apple access and reopen this flow after signing in.")
        case .destinationUnavailable: return String(localized: "This email or challenge is unavailable. Accounts cannot be merged. Restart with an unoccupied email.")
        case .tooManyRequests: return String(localized: "Too many requests. Wait before restarting with a new Apple authorization.")
        case .invalidInput: return String(localized: "Check the email, code and matching passwords (8–1024 characters). If the challenge expired, restart with a new Apple authorization.")
        default: return recoveryMessage
        }
    }
}
