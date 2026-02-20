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
                            BrutalSectionHeader(title: "Account")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)

                            BrutalCard {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(user.email)
                                        .brutalTypography(.bodyLarge)
                                        .lineLimit(1)

                                    if user.emailVerified {
                                        Text("✓ VERIFIED")
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
                            BrutalSectionHeader(title: "Storage")
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

                    // Upgrade to Pro Button (visible during trial or when no subscription)
                    if !subscriptionState.hasAccess || subscriptionState.status == .trialing {
                        BrutalPrimaryButton(title: subscriptionState.status == .trialing ? "Upgrade to Pro" : "Subscribe to Pro") {
                            showPaywall = true
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    } else {
                        Spacer().frame(height: 12)
                    }

                    // Upload Quality Section
                    VStack(spacing: 0) {
                        BrutalSectionHeader(title: "Upload Quality")
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
                                                Text(quality.displayName)
                                                    .brutalTypography(.bodyMedium)

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

                        // Quality info hint
                        Text("Lower quality = smaller files, faster uploads")
                            .brutalTypography(.monoSmall, color: .brutalTextTertiary)
                            .padding(.top, 12)
                    }
                    .padding(.bottom, 24)

                    // Link Format Section
                    VStack(spacing: 0) {
                        BrutalSectionHeader(title: "Link Format")
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
                                    Text("EDIT CUSTOM FORMAT")
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
                            Text("Variables:")
                                .brutalTypography(.monoSmall, color: .brutalTextTertiary)
                            Text("{url}")
                                .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                            Text("{filename}")
                                .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                        }
                        .padding(.top, 12)
                    }
                    .padding(.bottom, 24)

                    // Actions Section
                    VStack(spacing: 0) {
                        BrutalSectionHeader(title: "Actions")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)

                        BrutalCard(showBorder: true) {
                            VStack(spacing: 0) {
                                BrutalRow(
                                    title: "Clear Upload History",
                                    subtitle: "Remove local history only",
                                    destructive: true
                                ) {
                                    showClearConfirmation = true
                                }

                                Rectangle()
                                    .fill(Color.brutalBorder)
                                    .frame(height: 1)

                                BrutalRow(
                                    title: "Export All Images",
                                    subtitle: "Download as ZIP archive",
                                    showChevron: true
                                ) {
                                    showingExportSheet = true
                                }

                                Rectangle()
                                    .fill(Color.brutalBorder)
                                    .frame(height: 1)

                                BrutalRow(
                                    title: "Delete Account",
                                    subtitle: "Permanently delete all data",
                                    destructive: true
                                ) {
                                    showDeleteAccountConfirmation = true
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 24)

                    // Legal Section
                    VStack(spacing: 0) {
                        BrutalSectionHeader(title: "Legal")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)

                        BrutalCard(showBorder: true) {
                            VStack(spacing: 0) {
                                Link(destination: URL(string: "https://imghost.isolated.tech/terms")!) {
                                    HStack {
                                        Text("Terms of Use (EULA)")
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
                                        Text("Privacy Policy")
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
                    BrutalSecondaryButton(title: "Sign Out") {
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
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .confirmationDialog(
            "Clear History",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All History", role: .destructive) {
                clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all upload history from this device. Images on the server will not be affected.")
        }
        .confirmationDialog(
            "Delete Account",
            isPresented: $showDeleteAccountConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                deleteAccount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete your account and all your uploaded images. This action cannot be undone.")
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
                    showError(title: "Error", message: "Failed to load account info: \(error.localizedDescription)")
                    isLoadingUser = false
                }
            }
        }
    }

    private func clearHistory() {
        do {
            try HistoryService.shared.clear()
            showError(title: "History Cleared", message: "All upload history has been removed.")
        } catch {
            showError(title: "Error", message: "Failed to clear history: \(error.localizedDescription)")
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
                    showError(title: "Error", message: "Failed to delete account: \(error.localizedDescription)")
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
            Text("SETTINGS")
                .font(.system(size: 56, weight: .black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            HStack {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 24, height: 1)

                Text("ACCOUNT & PREFERENCES")
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
                        Text("CUSTOM\nFORMAT")
                            .font(.system(size: 40, weight: .black))
                            .foregroundStyle(.white)
                            .lineSpacing(-4)

                        Text("Define your own link template")
                            .brutalTypography(.bodyMedium, color: .brutalTextSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)

                    // Template input
                    VStack(alignment: .leading, spacing: 12) {
                        Text("TEMPLATE")
                            .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                            .tracking(2)

                        TextField("Enter template...", text: $editingTemplate, axis: .vertical)
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
                        Text("AVAILABLE VARIABLES")
                            .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                            .tracking(2)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("{url}")
                                    .brutalTypography(.mono, color: .brutalSuccess)
                                Text("- The image URL")
                                    .brutalTypography(.bodySmall, color: .brutalTextTertiary)
                            }
                            HStack {
                                Text("{filename}")
                                    .brutalTypography(.mono, color: .brutalSuccess)
                                Text("- Original filename")
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
                        Text("PREVIEW")
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
                    BrutalPrimaryButton(title: "Save Format") {
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
                        Text("CANCEL")
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
                        Text("EXPORT")
                            .font(.system(size: 40, weight: .black))
                            .foregroundStyle(.white)

                        Text("Create a ZIP archive of all your uploaded images.")
                            .brutalTypography(.bodyMedium, color: .brutalTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        BrutalPrimaryButton(
                            title: "Start Export",
                            action: onStartExport
                        )
                        .padding(.horizontal, 24)
                    }

                case .starting:
                    BrutalLoading(text: "Starting")

                case .exporting(let progress):
                    VStack(spacing: 24) {
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 56, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)

                        BrutalProgressBar(progress: progress)
                            .padding(.horizontal, 48)

                        Text("EXPORTING IMAGES")
                            .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                            .tracking(2)

                        BrutalSecondaryButton(title: "Cancel") {
                            onCancelExport()
                            dismiss()
                        }
                        .frame(width: 140)
                    }

                case .downloading(let progress):
                    VStack(spacing: 24) {
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 56, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)

                        BrutalProgressBar(progress: progress)
                            .padding(.horizontal, 48)

                        Text("DOWNLOADING ARCHIVE")
                            .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                            .tracking(2)
                    }

                case .complete:
                    VStack(spacing: 24) {
                        Text("✓")
                            .font(.system(size: 64, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.brutalSuccess)

                        Text("EXPORT COMPLETE")
                            .brutalTypography(.titleMedium)

                        VStack(spacing: 12) {
                            BrutalPrimaryButton(
                                title: "Save to Photos",
                                action: onSaveToPhotos
                            )
                            .padding(.horizontal, 24)

                            if exportedFileURL != nil {
                                BrutalSecondaryButton(title: "Save to Files") {
                                    onSaveToFiles()
                                }
                                .padding(.horizontal, 24)
                            }
                        }

                        BrutalTextButton(title: "Done") {
                            onDismiss()
                            dismiss()
                        }
                    }

                case .savingToPhotos(let progress):
                    VStack(spacing: 24) {
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 56, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)

                        BrutalProgressBar(progress: progress)
                            .padding(.horizontal, 48)

                        Text("SAVING TO PHOTOS")
                            .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                            .tracking(2)
                    }

                case .savedToPhotos(let count):
                    VStack(spacing: 24) {
                        Text("✓")
                            .font(.system(size: 64, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.brutalSuccess)

                        Text("SAVED TO PHOTOS")
                            .brutalTypography(.titleMedium)

                        Text("\(count) images saved to your photo library")
                            .brutalTypography(.bodySmall, color: .brutalTextSecondary)

                        BrutalPrimaryButton(title: "Done") {
                            onDismiss()
                            dismiss()
                        }
                        .frame(width: 160)
                    }

                case .error(let message):
                    VStack(spacing: 24) {
                        Text("✕")
                            .font(.system(size: 64, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.brutalError)

                        Text("EXPORT FAILED")
                            .brutalTypography(.titleMedium)

                        Text(message)
                            .brutalTypography(.bodySmall, color: .brutalTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        BrutalPrimaryButton(title: "Try Again", action: onStartExport)
                            .frame(width: 160)

                        BrutalTextButton(title: "Cancel") {
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
