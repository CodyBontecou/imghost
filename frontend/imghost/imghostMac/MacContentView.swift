import SwiftUI

struct MacContentView: View {
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var subscriptionState: SubscriptionState
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    enum SidebarItem: String, CaseIterable, Identifiable {
        case history = "History"
        case upload = "Upload"
        case settings = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .history: return "clock"
            case .upload: return "arrow.up.square"
            case .settings: return "gearshape"
            }
        }
    }

    @State private var selectedItem: SidebarItem = .history

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
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        List(SidebarItem.allCases, selection: $selectedItem) { item in
            Label {
                Text(item.rawValue.uppercased())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(1.5)
            } icon: {
                Image(systemName: item.icon)
                    .font(.system(size: 14))
            }
            .tag(item)
            .listRowBackground(
                selectedItem == item
                    ? Color.brutalSurfaceElevated
                    : Color.clear
            )
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.brutalSurface)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        .toolbar(removing: .sidebarToggle)
        .safeAreaInset(edge: .top) {
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
            .padding(.vertical, 12)
            .background(Color.brutalSurface)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedItem {
        case .history:
            MacHistoryView()
        case .upload:
            MacUploadView()
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
