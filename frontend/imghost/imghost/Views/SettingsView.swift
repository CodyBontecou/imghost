import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var subscriptionState: SubscriptionState

    @State private var isLoadingUser = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showClearConfirmation = false
    @State private var showDeleteAccountConfirmation = false
    @State private var isDeletingAccount = false
    @State private var selectedLinkFormat: LinkFormat = LinkFormatService.shared.currentFormat
    @State private var customLinkTemplate: String = LinkFormatService.shared.customTemplate
    @State private var showCustomFormatSheet = false
    @State private var selectedUploadQuality: UploadQuality = UploadQualityService.shared.currentQuality
    @State private var confirmBeforeUpload: Bool = UploadQualityService.shared.confirmBeforeUpload

    // Paywall state
    @State private var showPaywall = false

    // Export state
    @State private var showingExportSheet = false
    @State private var exportState: ExportState = .idle
    @State private var currentJobId: String?
    @State private var exportProgress: Double = 0.0
    @State private var exportError: String?
    @State private var exportedFileURL: URL?
    @State private var showingFileMover = false
    @State private var showMailCompose = false

    enum ExportState {
        case idle
        case starting
        case exporting(progress: Double)
        case downloading(progress: Double)
        case complete
        case savingToPhotos(progress: Double)
        case savedToPhotos(count: Int)
        case error(String)
    }

    var body: some View {
        ZStack {
            Color.brutalBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    headerSection

                    // Profile Section
                    if let user = authState.currentUser {
                        VStack(spacing: 0) {
                            BrutalSectionHeader(title: String(localized: "settings.section.account"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)

                            BrutalCard {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(user.email)
                                        .brutalTypography(.bodyLarge)
                                        .lineLimit(1)

                                    if user.emailVerified {
                                        Text("settings.account.email_verified")
                                            .brutalTypography(.monoSmall, color: .brutalSuccess)
                                            .tracking(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 24)
                        }
                        .padding(.bottom, 24)
                    }

                    // Storage Section
                    if let user = authState.currentUser {
                        VStack(spacing: 0) {
                            BrutalSectionHeader(title: String(localized: "settings.section.storage"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)

                            BrutalCard {
                                VStack(spacing: 16) {
                                    HStack {
                                        Text(user.storageUsedFormatted)
                                            .brutalTypography(.titleLarge)

                                        Text("/")
                                            .brutalTypography(.titleLarge, color: .brutalTextTertiary)

                                        Text(user.storageLimitFormatted)
                                            .brutalTypography(.titleLarge, color: .brutalTextSecondary)

                                        Spacer()

                                        Text(String(format: "%.2f%%", user.storagePercentUsed))
                                            .brutalTypography(.mono, color: user.storagePercentUsed > 90 ? .brutalError : .brutalTextSecondary)
                                    }

                                    BrutalProgressBar(progress: Double(user.storagePercentUsed) / 100.0)
                                }
                            }
                            .padding(.horizontal, 24)
                        }
                        .padding(.bottom, 24)
                    }

                    // Subscription Section
                    SubscriptionStatusView()
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)

                    // Upgrade / Subscribe button
                    if !subscriptionState.hasAccess || subscriptionState.status == .trialing || subscriptionState.isFree {
                        BrutalPrimaryButton(
                            title: subscriptionState.status == .trialing
                                ? String(localized: "settings.subscription.button.upgrade")
                                : String(localized: "settings.subscription.button.subscribe")
                        ) {
                            showPaywall = true
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    } else {
                        Spacer().frame(height: 12)
                    }

                    // Upload Section
                    VStack(spacing: 0) {
                        BrutalSectionHeader(title: String(localized: "settings.section.upload"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 4)

                        Text("settings.upload.label.resolution")
                            .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                            .tracking(1.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)

                        BrutalCard(showBorder: true) {
                            VStack(spacing: 0) {
                                ForEach(Array(UploadQuality.allCases.enumerated()), id: \.element.id) { index, quality in
                                    if index > 0 {
                                        Rectangle()
                                            .fill(Color.brutalBorder)
                                            .frame(height: 1)
                                    }

                                    Button {
                                        selectedUploadQuality = quality
                                        UploadQualityService.shared.currentQuality = quality
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack(spacing: 8) {
                                                    Text(quality.displayName)
                                                        .brutalTypography(.bodyMedium)
                                                    if quality == .original {
                                                        Text("settings.upload.label.default_badge")
                                                            .brutalTypography(.monoSmall, color: .brutalTextTertiary)
                                                            .tracking(0.5)
                                                            .padding(.horizontal, 5)
                                                            .padding(.vertical, 2)
                                                            .overlay(
                                                                Rectangle()
                                                                    .stroke(Color.brutalBorder, lineWidth: 1)
                                                            )
                                                    }
                                                }

                                                Text(quality.description)
                                                    .brutalTypography(.monoSmall, color: .brutalTextTertiary)
                                            }

                                            Spacer()

                                            Text(quality.estimatedReduction)
                                                .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                                                .padding(.trailing, 8)

                                            if selectedUploadQuality == quality {
                                                Text("*")
                                                    .brutalTypography(.titleLarge, color: .brutalSuccess)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 12)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 24)

                        Text("settings.upload.hint")
                            .brutalTypography(.monoSmall, color: .brutalTextTertiary)
                            .padding(.top, 12)
                            .padding(.bottom, 20)

                        // Confirm before uploading
                        Text("settings.upload.label.behavior")
                            .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                            .tracking(1.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)

                        BrutalCard(showBorder: true) {
                            Button {
                                confirmBeforeUpload.toggle()
                                UploadQualityService.shared.confirmBeforeUpload = confirmBeforeUpload
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("settings.upload.toggle.confirm_label")
                                            .brutalTypography(.bodyMedium)
                                        Text("settings.upload.toggle.confirm_hint")
                                            .brutalTypography(.monoSmall, color: .brutalTextTertiary)
                                    }

                                    Spacer()

                                    // Toggle pill
                                    ZStack {
                                        Capsule()
                                            .fill(confirmBeforeUpload ? Color.white : Color.brutalSurface)
                                            .frame(width: 44, height: 26)
                                            .overlay(Capsule().stroke(Color.brutalBorder, lineWidth: 1))

                                        Circle()
                                            .fill(confirmBeforeUpload ? Color.black : Color.brutalTextTertiary)
                                            .frame(width: 18, height: 18)
                                            .offset(x: confirmBeforeUpload ? 9 : -9)
                                            .animation(.easeInOut(duration: 0.15), value: confirmBeforeUpload)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 24)

                    // Link Format Section
                    VStack(spacing: 0) {
                        BrutalSectionHeader(title: String(localized: "settings.section.link_format"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)

                        BrutalCard(showBorder: true) {
                            VStack(spacing: 0) {
                                ForEach(Array(LinkFormat.allCases.enumerated()), id: \.element.id) { index, format in
                                    if index > 0 {
                                        Rectangle()
                                            .fill(Color.brutalBorder)
                                            .frame(height: 1)
                                    }

                                    Button {
                                        selectedLinkFormat = format
                                        LinkFormatService.shared.currentFormat = format
                                        if format == .custom {
                                            showCustomFormatSheet = true
                                        }
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(format.displayName)
                                                    .brutalTypography(.bodyMedium)

                                                Text(format == .custom ? customLinkTemplate : format.previewExample)
                                                    .brutalTypography(.monoSmall, color: .brutalTextTertiary)
                                                    .lineLimit(1)
                                            }

                                            Spacer()

                                            if selectedLinkFormat == format {
                                                Text("*")
                                                    .brutalTypography(.titleLarge, color: .brutalSuccess)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 12)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 24)

                        // Edit custom format button
                        if selectedLinkFormat == .custom {
                            Button {
                                showCustomFormatSheet = true
                            } label: {
                                HStack {
                                    Text("settings.link_format.button.edit_custom")
                                        .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                                        .tracking(1)
                                    Image(systemName: "pencil")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.brutalTextSecondary)
                                }
                            }
                            .padding(.top, 12)
                        }

                        // Template variables hint
                        HStack(spacing: 8) {
                            Text("settings.link_format.variables_label")
                                .brutalTypography(.monoSmall, color: .brutalTextTertiary)
                            Text("settings.link_format.var.url")
                                .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                            Text("settings.link_format.var.filename")
                                .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                        }
                        .padding(.top, 12)
                    }
                    .padding(.bottom, 24)

                    // Actions Section
                    VStack(spacing: 0) {
                        BrutalSectionHeader(title: String(localized: "settings.section.actions"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)

                        BrutalCard(showBorder: true) {
                            VStack(spacing: 0) {
                                BrutalRow(
                                    title: String(localized: "settings.action.clear_history.title"),
                                    subtitle: String(localized: "settings.action.clear_history.subtitle"),
                                    destructive: true
                                ) {
                                    showClearConfirmation = true
                                }

                                Rectangle()
                                    .fill(Color.brutalBorder)
                                    .frame(height: 1)

                                BrutalRow(
                                    title: String(localized: "settings.action.export.title"),
                                    subtitle: subscriptionState.isFree
                                        ? String(localized: "settings.action.export.subtitle_free")
                                        : String(localized: "settings.action.export.subtitle"),
                                    showChevron: true
                                ) {
                                    if subscriptionState.isFree {
                                        showPaywall = true
                                    } else {
                                        showingExportSheet = true
                                    }
                                }

                                Rectangle()
                                    .fill(Color.brutalBorder)
                                    .frame(height: 1)

                                BrutalRow(
                                    title: String(localized: "settings.action.delete_account.title"),
                                    subtitle: String(localized: "settings.action.delete_account.subtitle"),
                                    destructive: true
                                ) {
                                    showDeleteAccountConfirmation = true
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 24)

                    // Feedback Section
                    VStack(spacing: 0) {
                        BrutalSectionHeader(title: String(localized: "settings.section.feedback"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)

                        BrutalCard(showBorder: true) {
                            BrutalRow(
                                title: String(localized: "settings.feedback.button.send"),
                                subtitle: String(localized: "settings.feedback.button.send.subtitle"),
                                showChevron: true
                            ) {
                                if FeedbackHelper.canSendMail {
                                    showMailCompose = true
                                } else if let url = FeedbackHelper.mailtoURL() {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 24)

                    // Legal Section
                    VStack(spacing: 0) {
                        BrutalSectionHeader(title: String(localized: "settings.section.legal"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)

                        BrutalCard(showBorder: true) {
                            VStack(spacing: 0) {
                                Link(destination: URL(string: "https://imghost.isolated.tech/terms")!) {
                                    HStack {
                                        Text("settings.legal.terms")
                                            .brutalTypography(.bodyMedium)
                                        Spacer()
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 12))
                                            .foregroundColor(.brutalTextSecondary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Rectangle()
                                    .fill(Color.brutalBorder)
                                    .frame(height: 1)

                                Link(destination: URL(string: "https://imghost.isolated.tech/privacy")!) {
                                    HStack {
                                        Text("settings.legal.privacy")
                                            .brutalTypography(.bodyMedium)
                                        Spacer()
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 12))
                                            .foregroundColor(.brutalTextSecondary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 24)

                    // Server Info
                    HStack(spacing: 8) {
                        Text("●")
                            .brutalTypography(.monoSmall, color: .brutalSuccess)

                        Text(Config.backendURL)
                            .brutalTypography(.monoSmall, color: .brutalTextTertiary)
                    }
                    .padding(.bottom, 24)

                    // Sign Out
                    BrutalSecondaryButton(title: String(localized: "settings.button.sign_out")) {
                        authState.logout()
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 48)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.brutalBackground, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            if authState.currentUser == nil || authState.currentUser?.storageUsedBytes == 0 {
                refreshUserInfo()
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button(String(localized: "settings.alert.ok"), role: .cancel) {}
        } message: {
            Text(verbatim: alertMessage)
        }
        .confirmationDialog(
            String(localized: "settings.alert.clear_history.title"),
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.alert.clear_history.button.confirm"), role: .destructive) {
                clearHistory()
            }
            Button(String(localized: "settings.alert.clear_history.button.cancel"), role: .cancel) {}
        } message: {
            Text("settings.alert.clear_history.message")
        }
        .confirmationDialog(
            String(localized: "settings.alert.delete_account.title"),
            isPresented: $showDeleteAccountConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.alert.delete_account.button.confirm"), role: .destructive) {
                deleteAccount()
            }
            Button(String(localized: "settings.alert.delete_account.button.cancel"), role: .cancel) {}
        } message: {
            Text("settings.alert.delete_account.message")
        }
        .sheet(isPresented: $showCustomFormatSheet) {
            CustomLinkFormatSheet(
                template: $customLinkTemplate,
                onSave: {
                    LinkFormatService.shared.customTemplate = customLinkTemplate
                }
            )
        }
        .sheet(isPresented: $showPaywall) {
            NavigationStack {
                PaywallView()
                    .environmentObject(subscriptionState)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                showPaywall = false
                            } label: {
                                Image(systemName: "xmark")
                                    .foregroundColor(.white)
                            }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showMailCompose) {
            MailComposeView()
        }
        .sheet(isPresented: $showingExportSheet) {
            BrutalExportSheetView(
                exportState: $exportState,
                exportProgress: $exportProgress,
                exportError: $exportError,
                exportedFileURL: exportedFileURL,
                onStartExport: { startExport() },
                onCancelExport: { cancelExport() },
                onSaveToFiles: {
                    // Dismiss export sheet first, then show file mover
                    showingExportSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showingFileMover = true
                    }
                },
                onSaveToPhotos: { saveToPhotos() },
                onDismiss: { resetExportState() }
            )
            .presentationDetents([.medium, .large])
        }
        .fileMover(isPresented: $showingFileMover, file: exportedFileURL) { result in
            switch result {
            case .success(let url):
                print("File saved to: \(url)")
                resetExportState()
            case .failure(let error):
                print("Failed to save file: \(error)")
                // Re-show export sheet on failure so user can try again
                showingExportSheet = true
            }
        }
        .onChange(of: subscriptionState.hasAccess) { _, hasAccess in
            // Auto-dismiss paywall after successful purchase
            if hasAccess && showPaywall {
                showPaywall = false
            }
        }
        .preferredColorScheme(.dark)
    }

    private func refreshUserInfo() {
        isLoadingUser = true

        Task {
            do {
                let user = try await AuthService.shared.getCurrentUser()
                await MainActor.run {
                    authState.updateUser(user)
                    isLoadingUser = false
                }
            } catch {
                await MainActor.run {
                    showError(title: String(localized: "settings.error.title"), message: String(format: String(localized: "settings.error.load_account"), error.localizedDescription))
                    isLoadingUser = false
                }
            }
        }
    }

    private func clearHistory() {
        do {
            try HistoryService.shared.clear()
            showError(title: String(localized: "settings.success.history_cleared.title"), message: String(localized: "settings.success.history_cleared.message"))
        } catch {
            showError(title: String(localized: "settings.error.title"), message: String(format: String(localized: "settings.error.clear_history"), error.localizedDescription))
        }
    }

    private func deleteAccount() {
        isDeletingAccount = true

        Task {
            do {
                try await AuthService.shared.deleteAccount()
                await MainActor.run {
                    isDeletingAccount = false
                    // Clear local history as well
                    try? HistoryService.shared.clear()
                    // Logout will update the UI state
                    authState.logout()
                }
            } catch {
                await MainActor.run {
                    isDeletingAccount = false
                    showError(title: String(localized: "settings.error.title"), message: String(format: String(localized: "settings.error.delete_account"), error.localizedDescription))
                }
            }
        }
    }

    private func showError(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }

    private func startExport() {
        Task {
            do {
                exportState = .starting
                exportError = nil

                // Start the export job
                let jobId = try await ExportService.shared.startExport()
                currentJobId = jobId

                // Poll for status updates
                let finalStatus = try await ExportService.shared.pollUntilComplete(jobId: jobId) { status in
                    switch status {
                    case .pending:
                        exportState = .exporting(progress: 0.0)
                    case .processing(let progress):
                        exportState = .exporting(progress: progress)
                    case .completed:
                        // Will be handled after polling completes
                        break
                    case .failed(let error):
                        exportState = .error(error)
                    }
                }

                // Download the archive if completed
                if case .completed = finalStatus {
                    exportState = .downloading(progress: 0.0)

                    let fileURL = try await ExportService.shared.downloadArchive(jobId: jobId) { progress in
                        _ = Task { @MainActor in
                            exportState = .downloading(progress: progress)
                        }
                    }

                    await MainActor.run {
                        exportedFileURL = fileURL
                        exportState = .complete
                    }
                }
            } catch {
                await MainActor.run {
                    exportState = .error(error.localizedDescription)
                    exportError = error.localizedDescription
                }
            }
        }
    }

    private func cancelExport() {
        guard let jobId = currentJobId else { return }

        Task {
            do {
                try await ExportService.shared.cancelExport(jobId: jobId)
                await MainActor.run {
                    resetExportState()
                }
            } catch {
                print("Failed to cancel export: \(error)")
            }
        }
    }

    private func resetExportState() {
        exportState = .idle
        currentJobId = nil
        exportProgress = 0.0
        exportError = nil
        exportedFileURL = nil
    }

    private func saveToPhotos() {
        Task {
            do {
                await MainActor.run {
                    exportState = .savingToPhotos(progress: 0.0)
                }

                // Fetch user's images from the server
                guard let accessToken = KeychainService.shared.loadAccessToken() else {
                    throw PhotosExportError.notAuthorized
                }

                let backendUrl = Config.backendURL
                guard let url = URL(string: "\(backendUrl)/images") else {
                    throw PhotosExportError.noImages
                }

                var request = URLRequest(url: url)
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

                let (data, _) = try await URLSession.shared.data(for: request)

                struct ImagesResponse: Codable {
                    let images: [ImageItem]
                }
                struct ImageItem: Codable {
                    let url: String
                }

                let response = try JSONDecoder().decode(ImagesResponse.self, from: data)
                let imageURLs = response.images.compactMap { URL(string: $0.url) }

                guard !imageURLs.isEmpty else {
                    throw PhotosExportError.noImages
                }

                // Save to photos
                let savedCount = try await PhotosExportService.shared.saveToPhotos(
                    imageURLs: imageURLs
                ) { progress in
                    Task { @MainActor in
                        exportState = .savingToPhotos(progress: progress)
                    }
                }

                await MainActor.run {
                    exportState = .savedToPhotos(count: savedCount)
                }
            } catch {
                await MainActor.run {
                    exportState = .error(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - View Sections (extracted to help compiler type-check)

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.title")
                .font(.system(size: 56, weight: .black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            HStack {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 24, height: 1)

                Text("settings.subtitle")
                    .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                    .tracking(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 32)
    }
}

// MARK: - Custom Link Format Sheet

struct CustomLinkFormatSheet: View {
    @Binding var template: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editingTemplate: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.brutalBackground.ignoresSafeArea()

                VStack(spacing: 24) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text("settings.custom_format.title")
                            .font(.system(size: 40, weight: .black))
                            .foregroundStyle(.white)
                            .lineSpacing(-4)

                        Text("settings.custom_format.description")
                            .brutalTypography(.bodyMedium, color: .brutalTextSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)

                    // Template input
                    VStack(alignment: .leading, spacing: 12) {
                        Text("settings.custom_format.label.template")
                            .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                            .tracking(2)

                        TextField(String(localized: "settings.custom_format.placeholder"), text: $editingTemplate, axis: .vertical)
                            .textFieldStyle(.plain)
                            .brutalTypography(.mono)
                            .padding(16)
                            .background(Color.brutalSurface)
                            .overlay(
                                Rectangle()
                                    .stroke(Color.brutalBorder, lineWidth: 1)
                            )
                            .lineLimit(3...6)
                    }
                    .padding(.horizontal, 24)

                    // Variables reference
                    VStack(alignment: .leading, spacing: 12) {
                        Text("settings.custom_format.label.variables")
                            .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                            .tracking(2)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("settings.custom_format.var.url")
                                    .brutalTypography(.mono, color: .brutalSuccess)
                                Text("settings.custom_format.var.url.desc")
                                    .brutalTypography(.bodySmall, color: .brutalTextTertiary)
                            }
                            HStack {
                                Text("settings.custom_format.var.filename")
                                    .brutalTypography(.mono, color: .brutalSuccess)
                                Text("settings.custom_format.var.filename.desc")
                                    .brutalTypography(.bodySmall, color: .brutalTextTertiary)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.brutalSurface)
                    }
                    .padding(.horizontal, 24)

                    // Preview
                    VStack(alignment: .leading, spacing: 12) {
                        Text("settings.custom_format.label.preview")
                            .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                            .tracking(2)

                        Text(LinkFormatService.shared.preview(format: .custom, customTemplate: editingTemplate))
                            .brutalTypography(.monoSmall, color: .brutalTextPrimary)
                            .lineLimit(3)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.brutalSurfaceElevated)
                    }
                    .padding(.horizontal, 24)

                    Spacer()

                    // Save button
                    BrutalPrimaryButton(title: String(localized: "settings.custom_format.button.save")) {
                        template = editingTemplate
                        onSave()
                        dismiss()
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.brutalBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Text("settings.custom_format.button.cancel")
                            .brutalTypography(.mono)
                    }
                }
            }
            .onAppear {
                editingTemplate = template
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Brutal Export Sheet View

struct BrutalExportSheetView: View {
    @Binding var exportState: SettingsView.ExportState
    @Binding var exportProgress: Double
    @Binding var exportError: String?
    let exportedFileURL: URL?
    let onStartExport: () -> Void
    let onCancelExport: () -> Void
    let onSaveToFiles: () -> Void
    let onSaveToPhotos: () -> Void
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.brutalBackground.ignoresSafeArea()

            VStack(spacing: 24) {
                switch exportState {
                case .idle:
                    VStack(spacing: 24) {
                        Text("settings.export.title")
                            .font(.system(size: 40, weight: .black))
                            .foregroundStyle(.white)

                        Text("settings.export.description")
                            .brutalTypography(.bodyMedium, color: .brutalTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        BrutalPrimaryButton(
                            title: String(localized: "settings.export.button.start"),
                            action: onStartExport
                        )
                        .padding(.horizontal, 24)
                    }

                case .starting:
                    BrutalLoading(text: String(localized: "settings.export.state.starting"))

                case .exporting(let progress):
                    VStack(spacing: 24) {
                        Text(verbatim: String(format: String(localized: "settings.export.progress_format"), Int(progress * 100)))
                            .font(.system(size: 56, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)

                        BrutalProgressBar(progress: progress)
                            .padding(.horizontal, 48)

                        Text("settings.export.state.exporting")
                            .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                            .tracking(2)

                        BrutalSecondaryButton(title: String(localized: "settings.export.button.cancel")) {
                            onCancelExport()
                            dismiss()
                        }
                        .frame(width: 140)
                    }

                case .downloading(let progress):
                    VStack(spacing: 24) {
                        Text(verbatim: String(format: String(localized: "settings.export.progress_format"), Int(progress * 100)))
                            .font(.system(size: 56, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)

                        BrutalProgressBar(progress: progress)
                            .padding(.horizontal, 48)

                        Text("settings.export.state.downloading")
                            .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                            .tracking(2)
                    }

                case .complete:
                    VStack(spacing: 24) {
                        Text("settings.export.state.complete.icon")
                            .font(.system(size: 64, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.brutalSuccess)

                        Text("settings.export.state.complete.title")
                            .brutalTypography(.titleMedium)

                        VStack(spacing: 12) {
                            BrutalPrimaryButton(
                                title: String(localized: "settings.export.state.complete.button.save_photos"),
                                action: onSaveToPhotos
                            )
                            .padding(.horizontal, 24)

                            if exportedFileURL != nil {
                                BrutalSecondaryButton(title: String(localized: "settings.export.state.complete.button.save_files")) {
                                    onSaveToFiles()
                                }
                                .padding(.horizontal, 24)
                            }
                        }

                        BrutalTextButton(title: String(localized: "settings.export.state.complete.button.done")) {
                            onDismiss()
                            dismiss()
                        }
                    }

                case .savingToPhotos(let progress):
                    VStack(spacing: 24) {
                        Text(verbatim: String(format: String(localized: "settings.export.progress_format"), Int(progress * 100)))
                            .font(.system(size: 56, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)

                        BrutalProgressBar(progress: progress)
                            .padding(.horizontal, 48)

                        Text("settings.export.state.saving_photos")
                            .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                            .tracking(2)
                    }

                case .savedToPhotos(let count):
                    VStack(spacing: 24) {
                        Text("settings.export.state.saved_photos.icon")
                            .font(.system(size: 64, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.brutalSuccess)

                        Text("settings.export.state.saved_photos.title")
                            .brutalTypography(.titleMedium)

                        Text(verbatim: String(format: String(localized: "settings.export.state.saved_photos.message"), count))
                            .brutalTypography(.bodySmall, color: .brutalTextSecondary)

                        BrutalPrimaryButton(title: String(localized: "settings.export.state.saved_photos.button.done")) {
                            onDismiss()
                            dismiss()
                        }
                        .frame(width: 160)
                    }

                case .error(let message):
                    VStack(spacing: 24) {
                        Text("settings.export.state.failed.icon")
                            .font(.system(size: 64, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.brutalError)

                        Text("settings.export.state.failed.title")
                            .brutalTypography(.titleMedium)

                        Text(verbatim: message)
                            .brutalTypography(.bodySmall, color: .brutalTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        BrutalPrimaryButton(title: String(localized: "settings.export.state.failed.button.retry"), action: onStartExport)
                            .frame(width: 160)

                        BrutalTextButton(title: String(localized: "settings.export.state.failed.button.cancel")) {
                            onDismiss()
                            dismiss()
                        }
                    }
                }

                Spacer()
            }
            .padding(.top, 48)
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AuthState.shared)
            .environmentObject(SubscriptionState.shared)
    }
}
