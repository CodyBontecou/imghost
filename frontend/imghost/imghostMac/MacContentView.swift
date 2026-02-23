import SwiftUI

struct MacContentView: View {
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var subscriptionState: SubscriptionState
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    enum SidebarItem: String, CaseIterable, Identifiable {
        case media = "Media"
        case settings = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .media: return "square.grid.2x2"
            case .settings: return "gearshape"
            }
        }
    }

    @State private var selectedItem: SidebarItem = .media

    var body: some View {
        Group {
            if authState.isLoading {
                loadingView
            } else if !hasCompletedOnboarding {
                MacOnboardingView()
            } else if !authState.isAuthenticated {
                MacLoginView()
            } else if !authState.isEmailVerified {
                MacEmailVerificationView()
            } else if subscriptionState.shouldShowPaywall {
                MacPaywallView()
            } else {
                mainApp
            }
        }
        .background(Color.brutalBackground)
    }

    // MARK: - Main App

    private var mainApp: some View {
        HStack(spacing: 0) {
            sidebar
            
            Divider()
                .background(Color.brutalBorder)
            
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            // App branding header (with drag area for hidden title bar)
            HStack(spacing: 8) {
                Image("AppIconImage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Text("IMGHOST")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .tracking(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 36) // Extra top padding for traffic lights
            .padding(.bottom, 12)

            Divider().background(Color.brutalBorder)

            // Nav items
            VStack(spacing: 2) {
                ForEach(SidebarItem.allCases) { item in
                    Button(action: { selectedItem = item }) {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: 13))
                                .frame(width: 20)

                            Text(item.rawValue.uppercased())
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .tracking(1.5)

                            Spacer()
                        }
                        .foregroundStyle(selectedItem == item ? Color.white : Color.brutalTextSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            selectedItem == item
                                ? Color.brutalSurfaceElevated
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 4)

            Spacer()
        }
        .frame(width: 200)
        .background(Color.brutalSurface)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedItem {
        case .media:
            MacMediaView()
        case .settings:
            MacSettingsView()
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        ZStack {
            Color.brutalBackground.ignoresSafeArea()
            VStack(spacing: 24) {
                Image("AppIconImage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                BrutalLoading(text: "Loading")
            }
        }
    }
}
