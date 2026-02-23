import SwiftUI

// MARK: - Brutal Colors (macOS compatible - no UIColor references)

extension Color {
    static let brutalBackground = Color.black
    static let brutalSurface = Color(white: 0.08)
    static let brutalSurfaceElevated = Color(white: 0.12)
    static let brutalBorder = Color(white: 0.2)
    static let brutalTextPrimary = Color.white
    static let brutalTextSecondary = Color(white: 0.6)
    static let brutalTextTertiary = Color(white: 0.4)
    static let brutalAccent = Color.white
    static let brutalError = Color(hex: "FF453A")
    static let brutalSuccess = Color(hex: "30D158")
    static let brutalWarning = Color(hex: "FFD60A")
}

// MARK: - Hex Color Init (for macOS)

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Brutal Typography

enum BrutalTypography {
    case displayLarge
    case displayMedium
    case displaySmall
    case titleLarge
    case titleMedium
    case titleSmall
    case bodyLarge
    case bodyMedium
    case bodySmall
    case mono
    case monoSmall
    case monoLarge

    var font: Font {
        switch self {
        case .displayLarge: return .system(size: 72, weight: .black)
        case .displayMedium: return .system(size: 56, weight: .black)
        case .displaySmall: return .system(size: 40, weight: .black)
        case .titleLarge: return .system(size: 28, weight: .bold)
        case .titleMedium: return .system(size: 20, weight: .bold)
        case .titleSmall: return .system(size: 16, weight: .bold)
        case .bodyLarge: return .system(size: 15, weight: .regular)
        case .bodyMedium: return .system(size: 13, weight: .regular)
        case .bodySmall: return .system(size: 11, weight: .regular)
        case .mono: return .system(size: 13, weight: .medium, design: .monospaced)
        case .monoSmall: return .system(size: 11, weight: .medium, design: .monospaced)
        case .monoLarge: return .system(size: 15, weight: .medium, design: .monospaced)
        }
    }
}

extension View {
    func brutalTypography(_ style: BrutalTypography, color: Color = .brutalTextPrimary) -> some View {
        self
            .font(style.font)
            .foregroundStyle(color)
    }
}

// MARK: - Brutal Buttons

struct BrutalPrimaryButton: View {
    let title: String
    let action: () -> Void
    var isLoading: Bool = false
    var isDisabled: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                        .scaleEffect(0.8)
                } else {
                    Text(title.uppercased())
                        .brutalTypography(.mono, color: .black)
                        .tracking(1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(isDisabled ? Color.brutalTextTertiary : Color.white)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isLoading)
    }
}

struct BrutalSecondaryButton: View {
    let title: String
    let action: () -> Void
    var isLoading: Bool = false
    var isDisabled: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                } else {
                    Text(title.uppercased())
                        .brutalTypography(.mono, color: isDisabled ? .brutalTextTertiary : .white)
                        .tracking(1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                Rectangle()
                    .stroke(isDisabled ? Color.brutalTextTertiary : Color.brutalBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isLoading)
    }
}

struct BrutalTextButton: View {
    let title: String
    let action: () -> Void
    var color: Color = .brutalTextSecondary

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .brutalTypography(.monoSmall, color: color)
                .tracking(1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Brutal Card

struct BrutalCard<Content: View>: View {
    let content: Content
    var backgroundColor: Color = .brutalSurface
    var showBorder: Bool = true

    init(backgroundColor: Color = .brutalSurface, showBorder: Bool = true, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.backgroundColor = backgroundColor
        self.showBorder = showBorder
    }

    var body: some View {
        content
            .padding(16)
            .background(backgroundColor)
            .overlay(
                Rectangle()
                    .stroke(showBorder ? Color.brutalBorder : Color.clear, lineWidth: 1)
            )
    }
}

// MARK: - Brutal Divider

struct BrutalDivider: View {
    var label: String? = nil

    var body: some View {
        HStack(spacing: 16) {
            Rectangle()
                .fill(Color.brutalBorder)
                .frame(height: 1)

            if let label = label {
                Text(label.uppercased())
                    .brutalTypography(.monoSmall, color: .brutalTextTertiary)
                    .tracking(2)

                Rectangle()
                    .fill(Color.brutalBorder)
                    .frame(height: 1)
            }
        }
    }
}

// MARK: - Brutal Section Header

struct BrutalSectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                .tracking(2)

            if let subtitle = subtitle {
                Text(subtitle)
                    .brutalTypography(.bodySmall, color: .brutalTextTertiary)
            }
        }
    }
}

// MARK: - Brutal Avatar

struct BrutalAvatar: View {
    let text: String
    var size: CGFloat = 40

    private var initial: String {
        String(text.first ?? "?").uppercased()
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white)
            Text(initial)
                .font(.system(size: size * 0.45, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.black)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Brutal Progress Bar

struct BrutalProgressBar: View {
    let progress: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.brutalBorder)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: geometry.size.width * CGFloat(progress))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Brutal Badge

struct BrutalBadge: View {
    let text: String
    var style: BadgeStyle = .default

    enum BadgeStyle {
        case `default`, success, warning, error

        var backgroundColor: Color {
            switch self {
            case .default: return .brutalBorder
            case .success: return .brutalSuccess.opacity(0.2)
            case .warning: return .brutalWarning.opacity(0.2)
            case .error: return .brutalError.opacity(0.2)
            }
        }

        var textColor: Color {
            switch self {
            case .default: return .brutalTextSecondary
            case .success: return .brutalSuccess
            case .warning: return .brutalWarning
            case .error: return .brutalError
            }
        }
    }

    var body: some View {
        Text(text.uppercased())
            .brutalTypography(.monoSmall, color: style.textColor)
            .tracking(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(style.backgroundColor)
    }
}

// MARK: - Brutal Loading

struct BrutalLoading: View {
    var text: String = "Loading"
    @State private var dotCount = 0

    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            Text(text.uppercased() + String(repeating: ".", count: dotCount))
                .brutalTypography(.mono, color: .brutalTextSecondary)
                .tracking(2)
        }
        .onReceive(timer) { _ in
            dotCount = (dotCount + 1) % 4
        }
    }
}

// MARK: - Brutal Empty State

struct BrutalEmptyState: View {
    let title: String
    let subtitle: String
    var action: (() -> Void)? = nil
    var actionTitle: String? = nil

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Text(title.uppercased())
                    .brutalTypography(.titleMedium)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .brutalTypography(.bodyMedium, color: .brutalTextSecondary)
                    .multilineTextAlignment(.center)
            }

            if let action = action, let actionTitle = actionTitle {
                BrutalSecondaryButton(title: actionTitle, action: action)
                    .frame(width: 160)
            }
        }
        .padding(32)
    }
}

// MARK: - GoogleSpacing (macOS copy)

enum GoogleSpacing {
    static let xxxs: CGFloat = 4
    static let xxs: CGFloat = 8
    static let xs: CGFloat = 12
    static let sm: CGFloat = 16
    static let md: CGFloat = 20
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 40
    static let xxxl: CGFloat = 48
    static let huge: CGFloat = 64
}
