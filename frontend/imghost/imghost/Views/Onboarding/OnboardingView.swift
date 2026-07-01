import SwiftUI

struct OnboardingPage: Identifiable {
    let id = UUID()
    let titleKey: String
    let subtitleKey: String
}

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0
    @State private var hasTrackedStart = false

    private let pages: [OnboardingPage] = [
        OnboardingPage(titleKey: "onboarding.page1.title", subtitleKey: "onboarding.page1.subtitle"),
        OnboardingPage(titleKey: "onboarding.page2.title", subtitleKey: "onboarding.page2.subtitle"),
        OnboardingPage(titleKey: "onboarding.page3.title", subtitleKey: "onboarding.page3.subtitle"),
        OnboardingPage(titleKey: "onboarding.page4.title", subtitleKey: "onboarding.page4.subtitle"),
        OnboardingPage(titleKey: "onboarding.page5.title", subtitleKey: "onboarding.page5.subtitle"),
    ]

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar with logo
                HStack {
                    Spacer()
                    Image("AppIconImage")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(.horizontal, GoogleSpacing.lg)
                .padding(.top, GoogleSpacing.sm)

                // Main content
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        if index == pages.count - 1 {
                            // Last page: tier comparison
                            OnboardingTierComparisonView()
                                .tag(index)
                        } else {
                            BrutalOnboardingPageView(
                                page: page,
                                pageNumber: index + 1,
                                totalPages: pages.count
                            )
                            .tag(index)
                        }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Bottom section
                VStack(spacing: GoogleSpacing.md) {
                    // Minimal line indicators
                    HStack(spacing: GoogleSpacing.xxs) {
                        ForEach(0..<pages.count, id: \.self) { index in
                            Rectangle()
                                .fill(index == currentPage ? Color.white : Color.white.opacity(0.2))
                                .frame(width: index == currentPage ? 24 : 12, height: 2)
                                .animation(.easeInOut(duration: 0.2), value: currentPage)
                        }
                    }

                    // Action buttons
                    if currentPage == pages.count - 1 {
                        // Final page: two clear CTAs
                        VStack(spacing: GoogleSpacing.sm) {
                            Button(action: { completeOnboarding() }) {
                                Text("onboarding.button.start")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.black)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(Color.white)
                            }
                        }
                        .padding(.horizontal, GoogleSpacing.lg)
                    } else {
                        HStack(spacing: GoogleSpacing.sm) {
                            Button(action: { skipOnboarding() }) {
                                Text("onboarding.button.skip")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(
                                        Rectangle()
                                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                    )
                            }

                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    currentPage += 1
                                }
                            }) {
                                Text("onboarding.button.next")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.black)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(Color.white)
                            }
                        }
                        .padding(.horizontal, GoogleSpacing.lg)
                    }
                }
                .padding(.bottom, GoogleSpacing.xxl)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !hasTrackedStart else { return }
            hasTrackedStart = true
            AppAnalytics.shared.trackOnboardingStarted(step: analyticsStep)
            AppAnalytics.shared.trackOnboardingStepViewed(analyticsStep)
        }
        .onChange(of: currentPage) { _, _ in
            AppAnalytics.shared.trackOnboardingStepViewed(analyticsStep)
        }
    }

    private var analyticsStep: AppAnalyticsOnboardingStep {
        AppAnalyticsOnboardingStep.step(forPage: currentPage)
    }

    private func skipOnboarding() {
        AppAnalytics.shared.trackOnboardingSkipped(step: analyticsStep)
        hasCompletedOnboarding = true
    }

    private func completeOnboarding() {
        AppAnalytics.shared.trackOnboardingCompleted(step: analyticsStep)
        hasCompletedOnboarding = true
    }
}

struct BrutalOnboardingPageView: View {
    let page: OnboardingPage
    let pageNumber: Int
    let totalPages: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
                .frame(height: GoogleSpacing.xl)

            // Page counter
            Text(String(format: String(localized: "onboarding.page_indicator"), pageNumber, totalPages))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.bottom, GoogleSpacing.sm)

            // Giant title
            Text(LocalizedStringKey(page.titleKey))
                .font(.system(size: 72, weight: .black))
                .foregroundStyle(.white)
                .lineSpacing(-8)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            // Subtitle at bottom
            HStack {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 24, height: 1)

                Text(LocalizedStringKey(page.subtitleKey))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .tracking(2)
                    .textCase(.uppercase)
            }
            .padding(.bottom, GoogleSpacing.xxxl)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GoogleSpacing.lg)
    }
}

// MARK: - Tier Comparison (final onboarding page)

struct OnboardingTierComparisonView: View {
    private let rows: [(label: String, free: String, pro: String)] = [
        ("Storage",       "50 MB",      "10 GB"),
        ("Max File",      "5 MB",       "500 MB"),
        ("Links",         "7 days",     "Permanent"),
        ("Export ZIP",    "✕",          "✓"),
        ("Transforms",    "✕",          "✓"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: GoogleSpacing.xl)

            Text("FREE\nTO\nSTART")
                .font(.system(size: 64, weight: .black))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, GoogleSpacing.lg)

            // Tier comparison table
            VStack(spacing: 0) {
                // Header row
                HStack {
                    Text("")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("FREE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .tracking(2)
                        .frame(width: 80, alignment: .center)
                    Text("PRO")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .tracking(2)
                        .frame(width: 80, alignment: .center)
                }
                .padding(.bottom, 8)

                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 1)

                ForEach(rows, id: \.label) { row in
                    HStack {
                        Text(row.label)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.free)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(row.free == "✕" ? .white.opacity(0.3) : .white.opacity(0.5))
                            .frame(width: 80, alignment: .center)
                        Text(row.pro)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(row.pro == "✓" ? Color.green : .white)
                            .frame(width: 80, alignment: .center)
                    }
                    .padding(.vertical, 10)

                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GoogleSpacing.lg)
    }
}

#Preview {
    OnboardingView()
}
