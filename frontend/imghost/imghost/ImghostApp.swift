import SwiftUI
import StoreKit

@main
struct ImghostApp: App {
    @StateObject private var authState = AuthState.shared
    @StateObject private var subscriptionState = SubscriptionState.shared
    @State private var deepLinkToLogin = false

    init() {
        // Start listening for StoreKit transactions immediately
        Task {
            await StoreKitManager.shared.startListening()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authState)
                .environmentObject(subscriptionState)
                .task {
                    // Migrate tokens from legacy keychain access group
                    // so the share extension can read them.
                    KeychainService.shared.migrateFromLegacyAccessGroupIfNeeded()

                    // Check auth status first
                    await authState.checkAuthStatus()

                    // Load StoreKit products
                    await StoreKitManager.shared.loadProducts()

                    // Check subscription status if authenticated
                    if authState.isAuthenticated && authState.isEmailVerified {
                        await subscriptionState.checkStatus()
                    }
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    private func handleDeepLink(_ url: URL) {
        // Handle imghost://login - user was redirected from share extension
        if url.scheme == "imghost" && url.host == "login" {
            // If already authenticated, the ContentView will show the main app
            // If not authenticated, ContentView will show LoginView automatically
            // We just need to ensure we're checking auth status
            Task {
                await authState.checkAuthStatus()
            }
        }
    }
}
