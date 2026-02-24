import SwiftUI
import StoreKit

@main
struct ImghostMacApp: App {
    @StateObject private var authState = AuthState.shared
    @StateObject private var subscriptionState = SubscriptionState.shared
    @StateObject private var storeKit = StoreKitManager.shared
    @StateObject private var menuBarManager = MenuBarManager.shared

    var body: some Scene {
        WindowGroup {
            MacContentView()
                .environmentObject(authState)
                .environmentObject(subscriptionState)
                .environmentObject(storeKit)
                .frame(minWidth: 960, minHeight: 560)
                .onAppear {
                    // Set up menu bar icon
                    menuBarManager.setup()

                    Task {
                        await authState.checkAuthStatus()
                        storeKit.startListening()
                        await storeKit.loadProducts()
                        if authState.isAuthenticated {
                            await subscriptionState.checkStatus()
                        }
                    }
                }
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            MacSettingsView()
                .environmentObject(authState)
                .environmentObject(subscriptionState)
                .environmentObject(storeKit)
                .frame(width: 480, height: 560)
        }
    }
}
