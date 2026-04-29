import SwiftUI

struct DiscordBanner: View {
    @AppStorage("discordPromoDismissed") private var dismissed = false

    static let inviteURL = URL(string: "https://discord.gg/RaQYS4t6gn")!

    var body: some View {
        if !dismissed {
            content
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.brutalTextPrimary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("discord.banner.title")
                    .brutalTypography(.monoSmall, color: .brutalTextPrimary)
                    .tracking(1)
                Text("discord.banner.subtitle")
                    .brutalTypography(.bodySmall, color: .brutalTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("discord.banner.accessibility_label"))

            Link(destination: Self.inviteURL) {
                Text("discord.banner.button.join")
                    .brutalTypography(.monoSmall, color: .black)
                    .tracking(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.brutalAccent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("discord.banner.button.join.accessibility_label"))

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    dismissed = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.brutalTextSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("discord.banner.button.dismiss.accessibility_label"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.brutalSurface)
        .overlay(
            Rectangle()
                .stroke(Color.brutalBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

#Preview {
    ZStack {
        Color.brutalBackground.ignoresSafeArea()
        VStack {
            DiscordBanner()
            Spacer()
        }
    }
    .preferredColorScheme(.dark)
}
