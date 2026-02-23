import SwiftUI

struct MacSettingsView: View {
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var subscriptionState: SubscriptionState

    @State private var showDeleteAccountConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var selectedLinkFormat: LinkFormat
    @State private var customTemplate: String
    @State private var selectedQuality: UploadQuality
    @State private var showExportView = false

    private let linkFormatService = LinkFormatService.shared
    private let qualityService = UploadQualityService.shared

    init() {
        _selectedLinkFormat = State(initialValue: LinkFormatService.shared.currentFormat)
        _customTemplate = State(initialValue: LinkFormatService.shared.customTemplate)
        _selectedQuality = State(initialValue: UploadQualityService.shared.currentQuality)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("SETTINGS")
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
                    // Account section
                    accountSection

                    // Subscription section
                    subscriptionSection

                    // Storage section
                    storageSection

                    // Link Format section
                    linkFormatSection

                    // Upload Quality section
                    uploadQualitySection

                    // Data section
                    dataSection

                    // Danger Zone
                    dangerZone
                }
                .padding(24)
            }
        }
        .background(Color.brutalBackground)
        .alert("Delete Account", isPresented: $showDeleteAccountConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Account", role: .destructive) { deleteAccount() }
        } message: {
            Text("This will permanently delete your account and all uploaded images. This cannot be undone.")
        }
    }

    // MARK: - Account Section

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrutalSectionHeader(title: "Account")

            if let user = authState.currentUser {
                HStack(spacing: 12) {
                    BrutalAvatar(text: user.email, size: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.email)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white)

                        HStack(spacing: 6) {
                            Circle()
                                .fill(user.emailVerified ? Color.brutalSuccess : Color.brutalWarning)
                                .frame(width: 6, height: 6)
                            Text(user.emailVerified ? "VERIFIED" : "UNVERIFIED")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.brutalTextSecondary)
                                .tracking(1)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.brutalSurface)
                .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
            }

            Button(action: logout) {
                Text("SIGN OUT")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.brutalTextSecondary)
                    .tracking(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Subscription Section

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrutalSectionHeader(title: "Subscription")

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(subscriptionState.status.displayName.uppercased())
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.white)

                    if let days = subscriptionState.trialDaysRemaining,
                       subscriptionState.status == .trialing {
                        Text("\(days) days remaining")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.brutalTextSecondary)
                    }
                }

                Spacer()

                subscriptionBadge
            }
            .padding(12)
            .background(Color.brutalSurface)
            .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))

            if subscriptionState.status == .subscribed || subscriptionState.status == .trialing {
                Button(action: {
                    MacURLOpener.open("https://apps.apple.com/account/subscriptions")
                }) {
                    Text("MANAGE SUBSCRIPTION")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)
                        .tracking(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var subscriptionBadge: some View {
        switch subscriptionState.status {
        case .trialing:
            BrutalBadge(text: "TRIAL", style: .warning)
        case .subscribed:
            BrutalBadge(text: "ACTIVE", style: .success)
        case .cancelled:
            BrutalBadge(text: "CANCELLED", style: .warning)
        case .expired, .trialExpired:
            BrutalBadge(text: "EXPIRED", style: .error)
        default:
            EmptyView()
        }
    }

    // MARK: - Storage Section

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrutalSectionHeader(title: "Storage")

            if let user = authState.currentUser {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(user.storageUsedFormatted)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white)
                        Text("of \(user.storageLimitFormatted)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.brutalTextSecondary)
                        Spacer()
                        Text(String(format: "%.0f%%", user.storagePercentUsed))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.brutalTextTertiary)
                    }

                    BrutalProgressBar(progress: user.storagePercentUsed / 100)
                        .frame(height: 4)

                    if let imageCount = user.imageCount {
                        Text("\(imageCount) files")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.brutalTextTertiary)
                    }
                }
                .padding(12)
                .background(Color.brutalSurface)
                .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
            }
        }
    }

    // MARK: - Link Format Section

    private var linkFormatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrutalSectionHeader(title: "Link Format", subtitle: "Format used when copying links")

            VStack(spacing: 8) {
                ForEach(LinkFormat.allCases) { format in
                    Button(action: {
                        selectedLinkFormat = format
                        linkFormatService.currentFormat = format
                    }) {
                        HStack(spacing: 10) {
                            Circle()
                                .stroke(selectedLinkFormat == format ? Color.white : Color.brutalBorder, lineWidth: 2)
                                .frame(width: 16, height: 16)
                                .overlay(
                                    Circle()
                                        .fill(selectedLinkFormat == format ? Color.white : Color.clear)
                                        .frame(width: 8, height: 8)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(format.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.white)
                                Text(format.previewExample)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.brutalTextTertiary)
                            }

                            Spacer()
                        }
                        .padding(10)
                        .background(selectedLinkFormat == format ? Color.brutalSurfaceElevated : Color.brutalSurface)
                        .overlay(
                            Rectangle()
                                .stroke(selectedLinkFormat == format ? Color.white : Color.brutalBorder, lineWidth: selectedLinkFormat == format ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                if selectedLinkFormat == .custom {
                    MacBrutalTextField(label: "Custom Template", text: $customTemplate)
                        .onChange(of: customTemplate) { _, newValue in
                            linkFormatService.customTemplate = newValue
                        }
                }
            }
        }
    }

    // MARK: - Upload Quality Section

    private var uploadQualitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrutalSectionHeader(title: "Upload Quality", subtitle: "Quality preset for image uploads")

            VStack(spacing: 8) {
                ForEach(UploadQuality.allCases) { quality in
                    Button(action: {
                        selectedQuality = quality
                        qualityService.currentQuality = quality
                    }) {
                        HStack(spacing: 10) {
                            Circle()
                                .stroke(selectedQuality == quality ? Color.white : Color.brutalBorder, lineWidth: 2)
                                .frame(width: 16, height: 16)
                                .overlay(
                                    Circle()
                                        .fill(selectedQuality == quality ? Color.white : Color.clear)
                                        .frame(width: 8, height: 8)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(quality.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.white)
                                Text(quality.description)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.brutalTextTertiary)
                            }

                            Spacer()

                            Text(quality.estimatedReduction)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.brutalTextSecondary)
                        }
                        .padding(10)
                        .background(selectedQuality == quality ? Color.brutalSurfaceElevated : Color.brutalSurface)
                        .overlay(
                            Rectangle()
                                .stroke(selectedQuality == quality ? Color.white : Color.brutalBorder, lineWidth: selectedQuality == quality ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Data Section

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrutalSectionHeader(title: "Data")

            Button(action: { showExportView = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 12))
                    Text("EXPORT ALL DATA")
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
    }

    // MARK: - Danger Zone

    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrutalSectionHeader(title: "Danger Zone")

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.brutalError)
            }

            Button(action: { showDeleteAccountConfirm = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                    Text(isDeleting ? "DELETING..." : "DELETE ACCOUNT")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1)
                }
                .foregroundStyle(Color.brutalError)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .overlay(Rectangle().stroke(Color.brutalError.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
        }
    }

    // MARK: - Actions

    private func logout() {
        authState.logout()
    }

    private func deleteAccount() {
        isDeleting = true
        errorMessage = nil

        Task {
            do {
                try await AuthService.shared.deleteAccount()
                await MainActor.run {
                    authState.logout()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isDeleting = false
                }
            }
        }
    }
}
