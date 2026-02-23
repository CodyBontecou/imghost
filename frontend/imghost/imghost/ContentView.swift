import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authState: AuthState
    @StateObject private var subscriptionState = SubscriptionState.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var selectedTab = 0

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                // First time user - show onboarding
                OnboardingView()
            } else if authState.isLoading || subscriptionState.isLoading {
                // Loading state with brutal design
                ZStack {
                    Color.brutalBackground.ignoresSafeArea()

                    VStack(spacing: 24) {
                        Image("AppIconImage")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        BrutalLoading()
                    }
                }
                .preferredColorScheme(.dark)
            } else if !authState.isAuthenticated {
                // Not logged in - show login
                LoginView()
            } else if !authState.isEmailVerified {
                // Logged in but email not verified
                EmailVerificationView()
            } else if subscriptionState.shouldShowPaywall {
                // Authenticated but no subscription - show paywall
                PaywallView()
                    .environmentObject(subscriptionState)
                    .preferredColorScheme(.dark)
            } else {
                // Fully authenticated with subscription access - show main app
                TabView(selection: $selectedTab) {
                    HistoryView()
                        .tabItem {
                            Label("Media", systemImage: "square.grid.2x2")
                        }
                        .tag(0)

                    UploadView()
                        .tabItem {
                            Label("Upload", systemImage: "arrow.up.circle")
                        }
                        .tag(1)

                    NavigationStack {
                        SettingsView()
                    }
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .tag(2)
                }
                .tint(.white)
                .preferredColorScheme(.dark)
                .environmentObject(subscriptionState)
            }
        }
        .task {
            // Check subscription status when authenticated
            if authState.isAuthenticated && authState.isEmailVerified {
                await subscriptionState.checkStatus()
            }
        }
        .onChange(of: authState.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated && authState.isEmailVerified {
                // Check subscription status on login
                Task {
                    await subscriptionState.checkStatus()
                }
            } else if !isAuthenticated {
                // Reset subscription state on logout
                subscriptionState.reset()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthState.shared)
}
