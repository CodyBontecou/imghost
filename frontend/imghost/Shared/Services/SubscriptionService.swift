import Foundation

/// Service for communicating with backend subscription endpoints
final class SubscriptionService {
    static let shared = SubscriptionService()

    private let baseURL = Config.backendURL
    private let keychainService = KeychainService.shared

    private init() {}

    // MARK: - Public Methods

    /// Verify a purchase with the backend
    func verifyPurchase(
        signedTransaction: String,
        productId: String,
        originalTransactionId: String,
        expiresDate: Date?
    ) async throws {
        guard let token = keychainService.loadAccessToken() else {
            throw SubscriptionError.notAuthenticated
        }

        let url = URL(string: "\(baseURL)/subscription/verify-purchase")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "signedTransaction": signedTransaction,
            "productId": productId,
            "originalTransactionId": originalTransactionId,
            "expiresDate": expiresDate?.timeIntervalSince1970 ?? 0
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SubscriptionError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw SubscriptionError.notAuthenticated
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw SubscriptionError.serverError(errorResponse.error)
            }
            throw SubscriptionError.serverError("Verification failed with status \(httpResponse.statusCode)")
        }

        let result = try JSONDecoder().decode(VerifyPurchaseResponse.self, from: data)

        if !result.success {
            throw SubscriptionError.serverError(result.error ?? "Verification failed")
        }
    }

    /// Get current subscription status from backend (with automatic token refresh on 401)
    func getSubscriptionStatus() async throws -> SubscriptionStatusResponse {
        do {
            return try await fetchSubscriptionStatus()
        } catch SubscriptionError.notAuthenticated {
            // Token might be expired — try refreshing and retry once
            print("[SubscriptionService] Token expired or missing, attempting refresh...")
            do {
                try await AuthService.shared.refreshTokens()
                return try await fetchSubscriptionStatus()
            } catch {
                print("[SubscriptionService] Token refresh failed: \(error)")
                throw SubscriptionError.notAuthenticated
            }
        }
    }

    /// Raw fetch for subscription status (no retry logic)
    private func fetchSubscriptionStatus() async throws -> SubscriptionStatusResponse {
        guard let token = keychainService.loadAccessToken() else {
            throw SubscriptionError.notAuthenticated
        }

        let url = URL(string: "\(baseURL)/subscription/status")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SubscriptionError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw SubscriptionError.notAuthenticated
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw SubscriptionError.serverError(errorResponse.error)
            }
            throw SubscriptionError.serverError("Failed to get status with code \(httpResponse.statusCode)")
        }

        return try JSONDecoder().decode(SubscriptionStatusResponse.self, from: data)
    }

    /// Restore purchases with backend
    func restorePurchases(transactions: [String]) async throws {
        guard let token = keychainService.loadAccessToken() else {
            throw SubscriptionError.notAuthenticated
        }

        let url = URL(string: "\(baseURL)/subscription/restore")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "signedTransactions": transactions
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SubscriptionError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw SubscriptionError.notAuthenticated
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw SubscriptionError.serverError(errorResponse.error)
            }
            throw SubscriptionError.serverError("Restore failed with status \(httpResponse.statusCode)")
        }

        let result = try JSONDecoder().decode(RestorePurchasesResponse.self, from: data)

        if !result.success {
            if let expiredAt = result.expiredAt {
                throw SubscriptionError.subscriptionExpired(expiredAt)
            }
            throw SubscriptionError.serverError(result.error ?? result.message ?? "Restore failed")
        }
    }
}

// MARK: - Errors

enum SubscriptionError: LocalizedError, Equatable {
    case notAuthenticated
    case invalidResponse
    case serverError(String)
    case subscriptionExpired(String)
    case noActiveSubscription

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Please sign in to continue"
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let message):
            return message
        case .subscriptionExpired(let date):
            return "Your subscription expired on \(date)"
        case .noActiveSubscription:
            return "No active subscription found"
        }
    }
}

// MARK: - Helper Types
// Note: Uses ErrorResponse from AuthResponse.swift
