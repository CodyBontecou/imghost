import SwiftUI

struct MacOnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0

    private let pages: [(titleKey: String, subtitleKey: String)] = [
        ("onboarding.page1.title", "onboarding.page1.subtitle"),
        ("onboarding.page2.title", "onboarding.page2.subtitle"),
        ("onboarding.page3.title", "onboarding.page3.subtitle"),
        ("onboarding.page4.title", "onboarding.page4.subtitle"),
        ("onboarding.page5.title", "onboarding.page5.subtitle"),
    ]

    var body: some View {
        ZStack {
            Color.brutalBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar
                HStack {
                    Image("AppIconImage")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Spacer()

                    Text(verbatim: String(format: String(localized: "onboarding.page_indicator"), currentPage + 1, pages.count))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.brutalTextTertiary)
                }
                .padding(.horizontal, 48)
                .padding(.top, 24)

                Spacer()

                // Main content
                VStack(alignment: .leading, spacing: 16) {
                    Text(LocalizedStringKey(pages[currentPage].titleKey))
                        .font(.system(size: 64, weight: .black))
                        .foregroundStyle(Color.white)
                        .lineSpacing(-4)

                    HStack {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 24, height: 1)

                        Text(LocalizedStringKey(pages[currentPage].subtitleKey))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.brutalTextSecondary)
                            .tracking(2)
                            .textCase(.uppercase)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 48)
                .animation(.easeInOut(duration: 0.3), value: currentPage)

                Spacer()

                // Bottom controls
                HStack {
                    // Progress indicators
                    HStack(spacing: 4) {
                        ForEach(0..<pages.count, id: \.self) { index in
                            Rectangle()
                                .fill(index == currentPage ? Color.white : Color.white.opacity(0.2))
                                .frame(width: index == currentPage ? 24 : 12, height: 2)
                                .animation(.easeInOut(duration: 0.2), value: currentPage)
                        }
                    }

                    Spacer()

                    HStack(spacing: 12) {
                        if currentPage < pages.count - 1 {
                            Button(action: { hasCompletedOnboarding = true }) {
                                Text("onboarding.button.skip")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.brutalTextSecondary)
                                    .tracking(1)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }

                        Button(action: {
                            if currentPage == pages.count - 1 {
                                hasCompletedOnboarding = true
                            } else {
                                currentPage += 1
                            }
                        }) {
                            Text(currentPage == pages.count - 1
                                 ? "onboarding.button.start"
                                 : "onboarding.button.next")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.black)
                                .tracking(1)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(Color.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 32)
            }
        }
    }
}
