import SwiftUI
import StoreKit
import AppKit

@main
struct ImghostMacApp: App {
    @StateObject private var authState = AuthState.shared
    @StateObject private var subscriptionState = SubscriptionState.shared
    @StateObject private var storeKit = StoreKitManager.shared
    @StateObject private var menuBarManager = MenuBarManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("imghost", id: "main") {
            MacContentView()
                .environmentObject(authState)
                .environmentObject(subscriptionState)
                .environmentObject(storeKit)
                .frame(minWidth: 960, minHeight: 560)
                .onAppear {
                    // Set up menu bar icon and make its Open App item recreate the window if closed.
                    menuBarManager.setup(openMainWindow: openMainWindow)

                    Task {
                        // Migrate tokens from legacy keychain access group
                        // so the share extension can read them.
                        KeychainService.shared.migrateFromLegacyAccessGroupIfNeeded()

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
            CommandGroup(replacing: .newItem) {
                Button("Open imghost") { openMainWindow() }
                    .keyboardShortcut("n", modifiers: [.command])
            }

            CommandGroup(after: .windowArrangement) {
                Button("Open imghost") { openMainWindow() }
                    .keyboardShortcut("0", modifiers: [.command])
            }
        }

        Settings {
            TabView {
                MacSettingsView()
                    .environmentObject(authState)
                    .environmentObject(subscriptionState)
                    .environmentObject(storeKit)
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }

                MacFeedbackSettingsView()
                    .tabItem {
                        Label("Feedback", systemImage: "envelope")
                    }
            }
            .frame(width: 480, height: 560)
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            NSApplication.shared.windows
                .filter {
                    $0.level == .normal &&
                    $0.canBecomeMain &&
                    !$0.title.localizedCaseInsensitiveContains("Settings")
                }
                .first?
                .makeKeyAndOrderFront(nil)
        }
    }
}
