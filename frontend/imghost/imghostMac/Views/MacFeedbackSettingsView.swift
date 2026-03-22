import SwiftUI

struct MacFeedbackSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("FEEDBACK")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .tracking(2)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.brutalSurface)

                Divider().background(Color.brutalBorder)

                VStack(alignment: .leading, spacing: 24) {
                    // Send Feedback button
                    VStack(alignment: .leading, spacing: 12) {
                        BrutalSectionHeader(title: String(localized: "settings.section.feedback"))

                        Text("settings.feedback.mac.description")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.brutalTextSecondary)

                        Button(action: { FeedbackHelper.openMailClient() }) {
                            HStack(spacing: 8) {
                                Image(systemName: "envelope")
                                    .font(.system(size: 12))
                                Text("settings.feedback.button.send")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .tracking(1)
                            }
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    // Diagnostics block
                    VStack(alignment: .leading, spacing: 12) {
                        BrutalSectionHeader(title: String(localized: "settings.feedback.diagnostics.title"))

                        Text("settings.feedback.diagnostics.description")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.brutalTextSecondary)

                        Text(FeedbackHelper.diagnosticsBlock)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.brutalTextSecondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.brutalSurface)
                            .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                    }
                }
                .padding(24)
            }
        }
        .background(Color.brutalBackground)
    }
}

#Preview {
    MacFeedbackSettingsView()
        .frame(width: 480, height: 400)
        .preferredColorScheme(.dark)
}
