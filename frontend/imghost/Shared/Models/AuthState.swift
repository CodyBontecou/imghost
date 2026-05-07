import Foundation
import SwiftUI

@MainActor
final class AuthState: ObservableObject {
    static let shared = AuthState()

    @Published var isAuthenticated = false
    @Published var isEmailVerified = false
    @Published var currentUser: User?
    @Published var isLoading = true

    private let keychainService = KeychainService.shared

    private init() {}

    /// Check authentication status on app launch
    func checkAuthStatus() async {
        isLoading = true

        // Check if we have tokens stored
        guard keychainService.hasValidTokens else {
            isAuthenticated = false
            isEmailVerified = false
            currentUser = nil
            isLoading = false
            return
        }

        // Try to get current user to validate token
        do {
            let user = try await AuthService.shared.getCurrentUser()
            currentUser = user
            isAuthenticated = true
            isEmailVerified = user.emailVerified

            // Sync images from backend after successful auth check
            await syncImagesFromBackend()
        } catch {
            // Token might be expired, try to refresh
            do {
                try await AuthService.shared.refreshTokens()
                let user = try await AuthService.shared.getCurrentUser()
                currentUser = user
                isAuthenticated = true
                isEmailVerified = user.emailVerified

                // Sync images from backend after successful token refresh
                await syncImagesFromBackend()
            } catch {
                // Refresh failed, user needs to log in again
                logout()
            }
        }

        isLoading = false
    }

    /// Set authenticated state after successful login/register
    func setAuthenticated(response: AuthResponse) async {
        // Save tokens (log errors instead of silently swallowing)
        do {
            try keychainService.saveAccessToken(response.accessToken)
        } catch {
            print("[AuthState] ⚠️ Failed to save access token to keychain: \(error)")
        }

        do {
            try keychainService.saveRefreshToken(response.refreshToken)
        } catch {
            print("[AuthState] ⚠️ Failed to save refresh token to keychain: \(error)")
        }

        // Calculate and save expiry
        let expiry = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        do {
            try keychainService.saveTokenExpiry(expiry)
        } catch {
            print("[AuthState] ⚠️ Failed to save token expiry to keychain: \(error)")
        }

        // Update state
        isAuthenticated = true
        isEmailVerified = response.emailVerified

        // Create user from response (subscription status comes from SubscriptionState)
        currentUser = User(
            id: response.userId,
            email: response.email,
            emailVerified: response.emailVerified,
            storageUsedBytes: 0,
            storageLimitBytes: 0,
            imageCount: nil,
            isAnonymous: response.isAnonymous
        )

        // Sync images from backend after login
        await syncImagesFromBackend()
    }

    /// Sync images from backend to local storage
    private func syncImagesFromBackend() async {
        #if !SHARE_EXTENSION
        do {
            try await ImageSyncService.shared.syncImages()
        } catch {
            // Sync failures are non-fatal - user can still use the app
            print("Image sync failed: \(error.localizedDescription)")
        }
        #endif
    }

    /// Update email verified status
    func setEmailVerified(_ verified: Bool) {
        isEmailVerified = verified
        if let user = currentUser {
            currentUser = User(
                id: user.id,
                email: user.email,
                emailVerified: verified,
                storageUsedBytes: user.storageUsedBytes,
                storageLimitBytes: user.storageLimitBytes,
                imageCount: user.imageCount,
                isAnonymous: user.isAnonymous
            )
        }
    }

    /// Update current user
    func updateUser(_ user: User) {
        currentUser = user
        isEmailVerified = user.emailVerified
    }

    /// Logout and clear all tokens
    func logout() {
        keychainService.clearAllTokens()
        isAuthenticated = false
        isEmailVerified = false
        currentUser = nil

        // Reset subscription state (not available in share extension)
        #if !SHARE_EXTENSION
        SubscriptionState.shared.reset()
        #endif
    }
}
