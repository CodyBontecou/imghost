import Foundation
import AuthenticationServices

struct AppleSignInResult {
    let identityToken: String
    let userIdentifier: String
    let email: String?
    let fullName: PersonNameComponents?
}

final class AuthService {
    static let shared = AuthService()

    private let keychainService = KeychainService.shared
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    private var baseURL: String {
        Config.backendURL
    }

    // MARK: - Authentication

    func register(email: String, password: String) async throws -> AuthResponse {
        AppAnalytics.shared.trackAuthStarted(method: .emailRegister)
        let url = URL(string: "\(baseURL)/auth/register")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["email": email, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        switch httpResponse.statusCode {
        case 201:
            let response = try JSONDecoder().decode(AuthResponse.self, from: data)
            AppAnalytics.shared.trackAuthFinished(method: .emailRegister, outcome: .succeeded)
            return response
        case 409:
            throw AuthError.emailAlreadyRegistered
        case 429:
            throw AuthError.tooManyRequests
        default:
            let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthError.serverError(errorResponse?.error ?? "Registration failed")
        }
    }

    func login(email: String, password: String) async throws -> AuthResponse {
        AppAnalytics.shared.trackAuthStarted(method: .emailLogin)
        let url = URL(string: "\(baseURL)/auth/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["email": email, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        switch httpResponse.statusCode {
        case 200:
            let response = try JSONDecoder().decode(AuthResponse.self, from: data)
            AppAnalytics.shared.trackAuthFinished(method: .emailLogin, outcome: .succeeded)
            return response
        case 401:
            throw AuthError.invalidCredentials
        case 403:
            throw AuthError.accountSuspended
        case 429:
            throw AuthError.tooManyRequests
        default:
            let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthError.serverError(errorResponse?.error ?? "Login failed")
        }
    }

    func continueAnonymously() async throws -> AuthResponse {
        AppAnalytics.shared.trackAuthStarted(method: .anonymous)
        let url = URL(string: "\(baseURL)/auth/anonymous")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        switch httpResponse.statusCode {
        case 201:
            let response = try JSONDecoder().decode(AuthResponse.self, from: data)
            AppAnalytics.shared.trackAuthFinished(method: .anonymous, outcome: .succeeded)
            return response
        case 429:
            throw AuthError.tooManyRequests
        default:
            let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthError.serverError(errorResponse?.error ?? "Could not continue without an account")
        }
    }

    func signInWithApple(result: AppleSignInResult) async throws -> AuthResponse {
        AppAnalytics.shared.trackAuthStarted(method: .apple)
        let url = URL(string: "\(baseURL)/auth/apple")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "identity_token": result.identityToken,
            "user_identifier": result.userIdentifier
        ]

        if let email = result.email {
            body["email"] = email
        }

        if let fullName = result.fullName {
            var nameDict: [String: String] = [:]
            if let givenName = fullName.givenName {
                nameDict["given_name"] = givenName
            }
            if let familyName = fullName.familyName {
                nameDict["family_name"] = familyName
            }
            if !nameDict.isEmpty {
                body["full_name"] = nameDict
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        switch httpResponse.statusCode {
        case 200:
            let response = try JSONDecoder().decode(AuthResponse.self, from: data)
            AppAnalytics.shared.trackAuthFinished(method: .apple, outcome: .succeeded)
            return response
        case 401:
            // Parse actual error from server for Apple Sign-In
            let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthError.serverError(errorResponse?.error ?? "Apple Sign-In failed")
        case 429:
            throw AuthError.tooManyRequests
        default:
            let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthError.serverError(errorResponse?.error ?? "Apple Sign-In failed")
        }
    }

    func refreshTokens() async throws {
        guard let refreshToken = keychainService.loadRefreshToken() else {
            throw AuthError.noRefreshToken
        }

        let url = URL(string: "\(baseURL)/auth/refresh")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["refresh_token": refreshToken]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        guard httpResponse.statusCode == 200 else {
            throw AuthError.refreshFailed
        }

        let refreshResponse = try JSONDecoder().decode(RefreshResponse.self, from: data)

        // Save new tokens
        try keychainService.saveAccessToken(refreshResponse.accessToken)
        try keychainService.saveRefreshToken(refreshResponse.refreshToken)
        let expiry = Date().addingTimeInterval(TimeInterval(refreshResponse.expiresIn))
        try keychainService.saveTokenExpiry(expiry)
    }

    func logout() {
        keychainService.clearAllTokens()
    }

    // MARK: - Password Reset

    func forgotPassword(email: String) async throws {
        let url = URL(string: "\(baseURL)/auth/forgot-password")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["email": email]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        switch httpResponse.statusCode {
        case 200:
            return // Success - email sent (or not if email doesn't exist, but we don't reveal that)
        case 429:
            throw AuthError.tooManyRequests
        default:
            let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthError.serverError(errorResponse?.error ?? "Request failed")
        }
    }

    func resetPassword(token: String, newPassword: String) async throws {
        let url = URL(string: "\(baseURL)/auth/reset-password")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["token": token, "new_password": newPassword]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        switch httpResponse.statusCode {
        case 200:
            return // Success
        case 400:
            let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            if errorResponse?.error.contains("expired") == true {
                throw AuthError.tokenExpired
            }
            throw AuthError.invalidToken
        default:
            let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthError.serverError(errorResponse?.error ?? "Password reset failed")
        }
    }

    // MARK: - Email Verification

    func verifyEmail(token: String) async throws {
        let url = URL(string: "\(baseURL)/auth/verify-email")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["token": token]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        switch httpResponse.statusCode {
        case 200:
            return // Success
        case 400:
            throw AuthError.invalidToken
        default:
            let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthError.serverError(errorResponse?.error ?? "Verification failed")
        }
    }

    func resendVerification(email: String) async throws {
        let url = URL(string: "\(baseURL)/auth/resend-verification")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["email": email]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        switch httpResponse.statusCode {
        case 200:
            return // Success (or email doesn't exist, but we don't reveal that)
        case 400:
            let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            if errorResponse?.error.contains("already verified") == true {
                throw AuthError.alreadyVerified
            }
            throw AuthError.serverError(errorResponse?.error ?? "Request failed")
        case 429:
            throw AuthError.tooManyRequests
        default:
            let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthError.serverError(errorResponse?.error ?? "Request failed")
        }
    }

    // MARK: - Account Deletion

    func deleteAccount() async throws {
        // Ensure we have a valid token, refresh if needed
        try await ensureValidToken()

        guard let accessToken = keychainService.loadAccessToken() else {
            throw AuthError.notAuthenticated
        }

        let url = URL(string: "\(baseURL)/auth/account")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        switch httpResponse.statusCode {
        case 200:
            // Clear local tokens after successful deletion
            keychainService.clearAllTokens()
            return
        case 401:
            // Token is invalid even after refresh attempt - session is expired
            throw AuthError.sessionExpired
        default:
            let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthError.serverError(errorResponse?.error ?? "Failed to delete account")
        }
    }

    // MARK: - User Info

    func getCurrentUser() async throws -> User {
        // Ensure we have a valid token, refresh if needed
        try await ensureValidToken()

        guard let accessToken = keychainService.loadAccessToken() else {
            throw AuthError.notAuthenticated
        }

        let url = URL(string: "\(baseURL)/user")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        switch httpResponse.statusCode {
        case 200:
            return try JSONDecoder().decode(User.self, from: data)
        case 401:
            // Token is invalid even after refresh attempt - session is expired
            throw AuthError.sessionExpired
        default:
            let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw AuthError.serverError(errorResponse?.error ?? "Failed to get user info")
        }
    }

    // MARK: - Token Management

    /// Check if token is expired or about to expire (within 5 minutes)
    func isTokenExpired() -> Bool {
        guard let expiry = keychainService.loadTokenExpiry() else {
            return true
        }
        // Consider expired if less than 5 minutes remaining
        return expiry.timeIntervalSinceNow < 300
    }

    /// Ensure we have a valid access token, refreshing if needed
    func ensureValidToken() async throws {
        if isTokenExpired() {
            try await refreshTokens()
        }
    }
}

// MARK: - Auth Errors

enum AuthError: LocalizedError {
    case networkError
    case invalidCredentials
    case emailAlreadyRegistered
    case accountSuspended
    case tooManyRequests
    case noRefreshToken
    case refreshFailed
    case invalidToken
    case tokenExpired          // For password reset / verification codes
    case sessionExpired        // For access tokens - user needs to re-login
    case alreadyVerified
    case notAuthenticated
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .networkError:
            return "Network error. Please check your connection."
        case .invalidCredentials:
            return "Invalid email or password."
        case .emailAlreadyRegistered:
            return "This email is already registered."
        case .accountSuspended:
            return "Your account has been suspended."
        case .tooManyRequests:
            return "Too many requests. Please try again later."
        case .noRefreshToken:
            return "Please log in again."
        case .refreshFailed:
            return "Session expired. Please log in again."
        case .invalidToken:
            return "Invalid or expired code."
        case .tokenExpired:
            return "This code has expired. Please request a new one."
        case .sessionExpired:
            return "Your session has expired. Please log in again."
        case .alreadyVerified:
            return "Your email is already verified."
        case .notAuthenticated:
            return "Please log in to continue."
        case .serverError(let message):
            return message
        }
    }
}
