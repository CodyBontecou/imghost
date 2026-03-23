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
    @State private var confirmBeforeUpload: Bool
    @State private var showExportView = false
    @State private var showPaywall = false

    // Export state
    @State private var exportState: MacExportState = .idle
    @State private var exportedFileURL: URL? = nil
    @State private var currentJobId: String? = nil

    private let linkFormatService = LinkFormatService.shared
    private let qualityService = UploadQualityService.shared

    init() {
        _selectedLinkFormat = State(initialValue: LinkFormatService.shared.currentFormat)
        _customTemplate = State(initialValue: LinkFormatService.shared.customTemplate)
        _selectedQuality = State(initialValue: UploadQualityService.shared.currentQuality)
        _confirmBeforeUpload = State(initialValue: UploadQualityService.shared.confirmBeforeUpload)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("settings.title")
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
        .task {
            // Always fetch fresh subscription status when Settings opens
            await subscriptionState.checkStatus()
        }
        .alert(String(localized: "settings.alert.delete_account.title"), isPresented: $showDeleteAccountConfirm) {
            Button(String(localized: "settings.alert.delete_account.button.cancel"), role: .cancel) {}
            Button(String(localized: "settings.alert.delete_account.button.confirm"), role: .destructive) { deleteAccount() }
        } message: {
            Text("settings.alert.delete_account.message")
        }
        .sheet(isPresented: $showPaywall) {
            MacPaywallView(allowDismiss: true)
                .environmentObject(subscriptionState)
                .frame(width: 540, height: 620)
        }
        .sheet(isPresented: $showExportView, onDismiss: resetExportState) {
            MacExportView(
                exportState: $exportState,
                exportedFileURL: exportedFileURL,
                onStartExport: startExport,
                onCancelExport: cancelExport,
                onDismiss: { showExportView = false }
            )
            .frame(width: 420, height: 380)
        }
    }

    // MARK: - Account Section

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrutalSectionHeader(title: String(localized: "settings.section.account"))

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
                            Text(user.emailVerified ? String(localized: "settings.account.status.verified") : String(localized: "settings.account.status.unverified"))
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
                Text("settings.account.button.sign_out")
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
            BrutalSectionHeader(title: String(localized: "settings.section.subscription"))

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(subscriptionState.status.displayName.uppercased())
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.white)

                    if let days = subscriptionState.trialDaysRemaining,
                       subscriptionState.status == .trialing {
                        Text(verbatim: String(format: String(localized: "settings.subscription.days_remaining"), days))
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

            // Free tier limits notice
            if subscriptionState.isFree {
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 11))
                    Text(String(localized: "free.tier.limits"))
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(Color.brutalTextSecondary)
            }

            if subscriptionState.status == .subscribed || subscriptionState.status == .trialing {
                Button(action: {
                    MacURLOpener.open("https://apps.apple.com/account/subscriptions")
                }) {
                    Text("settings.subscription.button.manage")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)
                        .tracking(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            // Upgrade button for free / expired
            if subscriptionState.isFree || subscriptionState.shouldShowPaywall {
                Button(action: { showPaywall = true }) {
                    Text("settings.subscription.button.upgrade")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.black)
                        .tracking(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var subscriptionBadge: some View {
        switch subscriptionState.status {
        case .free:
            BrutalBadge(text: String(localized: "settings.badge.free"), style: .default)
        case .trialing:
            BrutalBadge(text: String(localized: "settings.badge.trial"), style: .warning)
        case .subscribed:
            BrutalBadge(text: String(localized: "settings.badge.active"), style: .success)
        case .cancelled:
            BrutalBadge(text: String(localized: "settings.badge.cancelled"), style: .warning)
        case .expired, .trialExpired:
            BrutalBadge(text: String(localized: "settings.badge.expired"), style: .error)
        default:
            EmptyView()
        }
    }

    // MARK: - Storage Section

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrutalSectionHeader(title: String(localized: "settings.section.storage"))

            if let user = authState.currentUser {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(user.storageUsedFormatted)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white)
                        Text(verbatim: String(format: String(localized: "settings.storage.of_limit"), user.storageLimitFormatted))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.brutalTextSecondary)
                        Spacer()
                        Text(verbatim: String(format: String(localized: "settings.storage.percent_format"), user.storagePercentUsed))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.brutalTextTertiary)
                    }

                    BrutalProgressBar(progress: user.storagePercentUsed / 100)
                        .frame(height: 4)

                    if let imageCount = user.imageCount {
                        Text(verbatim: String(format: String(localized: "settings.storage.file_count"), imageCount))
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
            BrutalSectionHeader(title: String(localized: "settings.section.link_format"), subtitle: String(localized: "settings.section.link_format.subtitle"))

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
                    MacBrutalTextField(label: String(localized: "settings.link_format.custom_field"), text: $customTemplate)
                        .onChange(of: customTemplate) { _, newValue in
                            linkFormatService.customTemplate = newValue
                        }
                }
            }
        }
    }

    // MARK: - Upload Section

    private var uploadQualitySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            BrutalSectionHeader(title: String(localized: "settings.section.upload"), subtitle: String(localized: "settings.section.upload.subtitle"))

            // Default resolution picker
            VStack(alignment: .leading, spacing: 10) {
                Text("settings.upload.label.resolution")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.brutalTextSecondary)
                    .tracking(1.5)

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
                                    HStack(spacing: 6) {
                                        Text(quality.displayName)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(Color.white)
                                        if quality == .original {
                                            Text("settings.upload.label.default_badge")
                                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                .foregroundStyle(Color.brutalTextTertiary)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                                                .tracking(0.5)
                                        }
                                    }
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

            // Confirm before uploading toggle
            VStack(alignment: .leading, spacing: 10) {
                Text("settings.upload.label.behavior")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.brutalTextSecondary)
                    .tracking(1.5)

                Button(action: {
                    confirmBeforeUpload.toggle()
                    qualityService.confirmBeforeUpload = confirmBeforeUpload
                }) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.upload.toggle.confirm_label")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white)
                            Text("settings.upload.toggle.confirm_hint")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.brutalTextTertiary)
                        }

                        Spacer()

                        // Toggle pill
                        ZStack {
                            Capsule()
                                .fill(confirmBeforeUpload ? Color.white : Color.brutalSurface)
                                .frame(width: 36, height: 20)
                                .overlay(Capsule().stroke(Color.brutalBorder, lineWidth: 1))

                            Circle()
                                .fill(confirmBeforeUpload ? Color.black : Color.brutalTextTertiary)
                                .frame(width: 14, height: 14)
                                .offset(x: confirmBeforeUpload ? 8 : -8)
                                .animation(.easeInOut(duration: 0.15), value: confirmBeforeUpload)
                        }
                    }
                    .padding(10)
                    .background(Color.brutalSurface)
                    .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Data Section

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrutalSectionHeader(title: String(localized: "settings.section.data"))

            Button(action: {
                if subscriptionState.isFree {
                    showPaywall = true
                } else {
                    showExportView = true
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: subscriptionState.isFree ? "lock.fill" : "arrow.down.doc")
                        .font(.system(size: 12))
                    Text(subscriptionState.isFree
                         ? String(localized: "free.tier.export_blocked")
                         : String(localized: "settings.data.button.export"))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1)
                }
                .foregroundStyle(subscriptionState.isFree ? Color.brutalTextTertiary : Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .overlay(Rectangle().stroke(subscriptionState.isFree ? Color.brutalBorder.opacity(0.5) : Color.brutalBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Danger Zone

    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrutalSectionHeader(title: String(localized: "settings.section.danger"))

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.brutalError)
            }

            Button(action: { showDeleteAccountConfirm = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                    Text(isDeleting ? String(localized: "settings.danger.button.deleting") : String(localized: "settings.danger.button.delete_account"))
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

    // MARK: - Export Actions

    private func startExport() {
        Task {
            await MainActor.run { exportState = .starting }

            do {
                let jobId = try await ExportService.shared.startExport()
                await MainActor.run { currentJobId = jobId }

                let finalStatus = try await ExportService.shared.pollUntilComplete(jobId: jobId) { status in
                    Task { @MainActor in
                        switch status {
                        case .processing(let progress):
                            exportState = .exporting(progress: progress)
                        case .failed(let error):
                            exportState = .error(error)
                        default:
                            break
                        }
                    }
                }

                if case .completed(let downloadUrl) = finalStatus {
                    await MainActor.run { exportState = .downloading(progress: 0.0) }

                    let fileURL = try await ExportService.shared.downloadArchive(jobId: jobId) { progress in
                        Task { @MainActor in
                            exportState = .downloading(progress: progress)
                        }
                    }

                    await MainActor.run {
                        exportedFileURL = fileURL
                        exportState = .complete
                    }
                    _ = downloadUrl
                }
            } catch {
                await MainActor.run {
                    exportState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func cancelExport() {
        guard let jobId = currentJobId else {
            resetExportState()
            return
        }
        Task {
            try? await ExportService.shared.cancelExport(jobId: jobId)
            await MainActor.run { resetExportState() }
        }
    }

    private func resetExportState() {
        exportState = .idle
        exportedFileURL = nil
        currentJobId = nil
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
