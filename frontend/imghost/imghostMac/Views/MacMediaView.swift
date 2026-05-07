import SwiftUI
import UniformTypeIdentifiers

struct MacMediaView: View {
    // MARK: - History State
    @State private var records: [UploadRecord] = []
    @State private var isLoading = true
    @State private var selectedRecord: UploadRecord?
    @State private var searchText = ""
    @State private var isSyncing = false

    // MARK: - Upload State
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var uploadResults: [UploadResult] = []
    @State private var isDragOver = false
    @State private var showFileImporter = false
    @State private var selectedQuality: UploadQuality
    @State private var showUploadBanner = false
    @State private var uploadBannerMessage = ""
    @State private var uploadBannerIsError = false
    @State private var showPaywall = false

    @EnvironmentObject var subscriptionState: SubscriptionState

    private let historyService = HistoryService.shared
    private let uploadService = MacUploadService.shared
    private let qualityService = UploadQualityService.shared

    struct UploadResult: Identifiable {
        let id = UUID()
        let record: UploadRecord?
        let filename: String
        let error: String?
    }

    init() {
        _selectedQuality = State(initialValue: UploadQualityService.shared.currentQuality)
    }

    // MARK: - Filtered & Grouped

    private var filteredRecords: [UploadRecord] {
        if searchText.isEmpty {
            return records
        }
        return records.filter { record in
            (record.originalFilename ?? "").localizedCaseInsensitiveContains(searchText) ||
            record.url.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var groupedRecords: [(String, [UploadRecord])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        let grouped = Dictionary(grouping: filteredRecords) { record in
            formatter.string(from: record.createdAt)
        }

        return grouped.sorted { lhs, rhs in
            guard let lhsDate = lhs.value.first?.createdAt,
                  let rhsDate = rhs.value.first?.createdAt else { return false }
            return lhsDate > rhsDate
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider().background(Color.brutalBorder)

            // Upload progress banner
            if isUploading {
                uploadProgressBanner
            }

            // Success/error banner
            if showUploadBanner {
                resultBanner
            }

            // Main content area
            ZStack {
                if isLoading {
                    VStack {
                        Spacer()
                        BrutalLoading(text: String(localized: "media.loading"))
                        Spacer()
                    }
                } else if filteredRecords.isEmpty && !isUploading {
                    emptyState
                } else {
                    gridContent
                }

                // Drag overlay
                if isDragOver {
                    dragOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                handleDrop(providers: providers)
                return true
            }
            .onPasteCommand(of: [.fileURL, .image, .png, .jpeg]) { providers in
                handlePaste(providers: providers)
            }
        }
        .frame(minWidth: 400, maxWidth: .infinity)
        .background(Color.brutalBackground)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image, .movie, .data],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .inspector(isPresented: inspectorBinding) {
            if let record = selectedRecord {
                MacUploadDetailView(record: record, onDelete: {
                    deleteRecord(record)
                }, onClose: {
                    selectedRecord = nil
                })
                .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
            }
        }
        .sheet(isPresented: $showPaywall) {
            MacPaywallView(allowDismiss: true)
                .environmentObject(subscriptionState)
                .frame(width: 540, height: 620)
        }
        .task {
            loadRecords()
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { selectedRecord != nil },
            set: { if !$0 { selectedRecord = nil } }
        )
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("media.title")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white)
                .tracking(2)
                .fixedSize()
                .layoutPriority(1)

            Spacer(minLength: 4)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.brutalTextSecondary)

                TextField(String(localized: "media.search.placeholder"), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 60, idealWidth: 120)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.brutalSurface)
            .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))

            // Quality picker
            HStack(spacing: 4) {
                Text("media.label.quality")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.brutalTextTertiary)
                    .tracking(1)
                    .lineLimit(1)

                Picker("", selection: $selectedQuality) {
                    ForEach(UploadQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 90)
                .onChange(of: selectedQuality) { _, newValue in
                    qualityService.currentQuality = newValue
                }
            }
            .fixedSize()

            // Sync button
            Button(action: syncImages) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.brutalTextSecondary)
                    .rotationEffect(.degrees(isSyncing ? 360 : 0))
                    .animation(isSyncing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isSyncing)
            }
            .buttonStyle(.plain)
            .help(String(localized: "media.button.sync.help"))

            // Upload button
            Button(action: { showFileImporter = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                    Text("media.button.upload.label")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1)
                        .lineLimit(1)
                }
                .foregroundStyle(Color.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .layoutPriority(1)
            .help(String(localized: "media.button.upload.help"))

            Text("\(filteredRecords.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.brutalTextSecondary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.brutalSurface)
    }

    // MARK: - Upload Progress Banner

    private var uploadProgressBanner: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)

                Text("media.upload.progress.title")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .tracking(1)

                Spacer()

                Text("\(Int(uploadProgress * 100))%")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)

                Button(action: cancelUpload) {
                    Text("media.upload.progress.cancel")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.brutalError)
                        .tracking(1)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            BrutalProgressBar(progress: uploadProgress)
                .frame(height: 2)
        }
        .background(Color.brutalSurface)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Result Banner

    private var resultBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: uploadBannerIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(uploadBannerIsError ? Color.brutalError : Color.brutalSuccess)

            Text(uploadBannerMessage.uppercased())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(uploadBannerIsError ? Color.brutalError : Color.brutalSuccess)
                .tracking(1)

            Spacer()

            Button(action: { withAnimation { showUploadBanner = false } }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.brutalTextTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(uploadBannerIsError ? Color.brutalError.opacity(0.1) : Color.brutalSuccess.opacity(0.1))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                ZStack {
                    Rectangle()
                        .stroke(Color.brutalBorder, style: StrokeStyle(lineWidth: 1, dash: [10, 6]))

                    VStack(spacing: 16) {
                        Image(systemName: "arrow.up.doc")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.brutalTextSecondary)

                        VStack(spacing: 4) {
                            Text("media.drop_zone.title")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.white)
                                .tracking(2)

                            Text("media.drop_zone.subtitle")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.brutalTextSecondary)
                        }

                        Text("media.drop_zone.hint")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.brutalTextTertiary)
                    }
                    .padding(40)
                }
                .frame(maxWidth: 480, maxHeight: 280)
            }

            HStack(spacing: 4) {
                Text(verbatim: "⌘V")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.brutalTextSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))

                Text("media.clipboard.hint")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.brutalTextTertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Grid Content

    private var gridContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedRecords, id: \.0) { date, items in
                    Text(date.uppercased())
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.brutalTextTertiary)
                        .tracking(1.5)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 2)
                    ], spacing: 2) {
                        ForEach(items) { record in
                            MacThumbnailCell(
                                record: record,
                                isSelected: selectedRecord?.id == record.id
                            )
                            .onTapGesture {
                                withAnimation {
                                    if selectedRecord?.id == record.id {
                                        selectedRecord = nil
                                    } else {
                                        selectedRecord = record
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: - Drag Overlay

    private var dragOverlay: some View {
        ZStack {
            Color.brutalBackground.opacity(0.85)

            VStack(spacing: 16) {
                Image(systemName: "arrow.up.doc.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.white)

                Text("media.drag_overlay.title")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .tracking(3)
            }
        }
        .overlay(
            Rectangle()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: [12, 8]))
                .padding(16)
        )
    }

    // MARK: - History Actions

    private func loadRecords() {
        isLoading = true
        do {
            records = try historyService.loadAll()
        } catch {
            print("Failed to load history: \(error)")
        }
        isLoading = false
    }

    private func syncImages() {
        isSyncing = true
        Task {
            do {
                try await ImageSyncService.shared.syncImages()
                await MainActor.run {
                    loadRecords()
                }
            } catch {
                print("Sync failed: \(error)")
            }
            await MainActor.run {
                isSyncing = false
            }
        }
    }

    private func deleteRecord(_ record: UploadRecord) {
        Task {
            do {
                try await MacUploadService.shared.delete(record: record)
                try historyService.delete(id: record.id)
                await MainActor.run {
                    records.removeAll { $0.id == record.id }
                    if selectedRecord?.id == record.id {
                        selectedRecord = nil
                    }
                }
            } catch {
                print("Delete failed: \(error)")
            }
        }
    }

    // MARK: - Upload Actions

    private func handleDrop(providers: [NSItemProvider]) {
        var fileURLs: [URL] = []

        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url") { data, error in
                defer { group.leave() }
                if let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    fileURLs.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            if !fileURLs.isEmpty {
                uploadFiles(fileURLs)
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            uploadFiles(urls)
        case .failure(let error):
            showBanner(message: error.localizedDescription, isError: true)
        }
    }

    private func handlePaste(providers: [NSItemProvider]) {
        if let pasteboardItems = NSPasteboard.general.pasteboardItems {
            var imageDataList: [(Data, String)] = []

            for item in pasteboardItems {
                if let fileURL = item.string(forType: .fileURL),
                   let url = URL(string: fileURL) {
                    uploadFiles([url])
                    return
                }

                if let pngData = item.data(forType: .png) {
                    imageDataList.append((pngData, "clipboard_\(Date().timeIntervalSince1970).png"))
                } else if let jpegData = item.data(forType: .init("public.jpeg")) {
                    imageDataList.append((jpegData, "clipboard_\(Date().timeIntervalSince1970).jpg"))
                }
            }

            if !imageDataList.isEmpty {
                uploadImageData(imageDataList)
            }
        }
    }

    private func uploadFiles(_ urls: [URL]) {
        withAnimation { isUploading = true }
        uploadProgress = 0
        uploadResults.removeAll()
        showUploadBanner = false

        Task {
            var results: [UploadResult] = []
            let totalFiles = urls.count

            for (index, url) in urls.enumerated() {
                let filename = url.lastPathComponent
                let baseProgress = Double(index) / Double(totalFiles)

                do {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }

                    let record = try await uploadService.uploadFromFile(
                        fileURL: url,
                        filename: filename
                    ) { fileProgress in
                        let totalProgress = baseProgress + (fileProgress / Double(totalFiles))
                        Task { @MainActor in
                            uploadProgress = totalProgress
                        }
                    }

                    try? HistoryService.shared.save(record)
                    results.append(UploadResult(record: record, filename: filename, error: nil))
                } catch {
                    results.append(UploadResult(record: nil, filename: filename, error: error.localizedDescription))
                }
            }

            await MainActor.run {
                uploadResults = results
                withAnimation { isUploading = false }
                uploadProgress = 1.0

                // Refresh the grid
                loadRecords()

                // Copy links & show banner
                let successful = results.filter { $0.record != nil }
                let failed = results.filter { $0.error != nil }

                if !successful.isEmpty {
                    // Copy all links to clipboard
                    let links = successful.compactMap { result -> String? in
                        guard let record = result.record else { return nil }
                        return LinkFormatService.shared.format(url: record.url, filename: result.filename)
                    }
                    MacClipboard.copy(links.joined(separator: "\n"))

                    // Select the first uploaded record
                    if let firstRecord = successful.first?.record {
                        selectedRecord = firstRecord
                    }
                }

                // Show upgrade immediately for anonymous/free-tier upload attempts.
                let accountOrUpgradeMessage = failed.compactMap(\.error).first {
                    $0.localizedCaseInsensitiveContains("subscribe to upload")
                }

                // Check if any failure was subscription-related
                let hasSubscriptionError = results.contains { result in
                    result.error?.contains("subscription is required") == true ||
                    result.error?.contains("active subscription") == true
                }

                if accountOrUpgradeMessage != nil {
                    showBanner(message: "Choose a plan to upload now. No email account required.", isError: true)
                    showPaywall = true
                } else if hasSubscriptionError {
                    Task { await subscriptionState.checkStatus() }
                    showBanner(message: String(localized: "media.banner.subscription_required"), isError: true)
                    showPaywall = true
                } else if failed.isEmpty {
                    let hasTTL = successful.compactMap(\.record).contains { $0.isTemporary }
                    let msg: String
                    if successful.count == 1 {
                        msg = hasTTL
                            ? String(format: String(localized: "media.banner.upload_success_singular_ttl"), successful.count)
                            : String(format: String(localized: "media.banner.upload_success_singular"), successful.count)
                    } else {
                        msg = hasTTL
                            ? String(format: String(localized: "media.banner.upload_success_plural_ttl"), successful.count)
                            : String(format: String(localized: "media.banner.upload_success_plural"), successful.count)
                    }
                    showBanner(message: msg, isError: false)
                } else if successful.isEmpty {
                    let msg = failed.count == 1
                        ? (failed.first?.error ?? String(format: String(localized: "media.banner.upload_failed_singular"), failed.count))
                        : String(format: String(localized: "media.banner.upload_failed_plural"), failed.count)
                    showBanner(message: msg, isError: true)
                } else {
                    showBanner(message: String(format: String(localized: "media.banner.upload_partial"), successful.count, failed.count), isError: true)
                }
            }
        }
    }

    private func uploadImageData(_ images: [(Data, String)]) {
        withAnimation { isUploading = true }
        uploadProgress = 0
        uploadResults.removeAll()
        showUploadBanner = false

        Task {
            var results: [UploadResult] = []
            let totalFiles = images.count

            for (index, (data, filename)) in images.enumerated() {
                let baseProgress = Double(index) / Double(totalFiles)

                do {
                    let record = try await uploadService.upload(
                        imageData: data,
                        filename: filename
                    ) { fileProgress in
                        let totalProgress = baseProgress + (fileProgress / Double(totalFiles))
                        Task { @MainActor in
                            uploadProgress = totalProgress
                        }
                    }
                    try? HistoryService.shared.save(record)
                    results.append(UploadResult(record: record, filename: filename, error: nil))
                } catch {
                    results.append(UploadResult(record: nil, filename: filename, error: error.localizedDescription))
                }
            }

            await MainActor.run {
                uploadResults = results
                withAnimation { isUploading = false }

                loadRecords()

                let successful = results.filter { $0.record != nil }
                let failed = results.filter { $0.error != nil }

                if !successful.isEmpty {
                    let links = successful.compactMap { result -> String? in
                        guard let record = result.record else { return nil }
                        return LinkFormatService.shared.format(url: record.url, filename: result.filename)
                    }
                    MacClipboard.copy(links.joined(separator: "\n"))

                    if let firstRecord = successful.first?.record {
                        selectedRecord = firstRecord
                    }
                }

                // Show upgrade immediately for anonymous/free-tier upload attempts.
                let accountOrUpgradeMessage = failed.compactMap(\.error).first {
                    $0.localizedCaseInsensitiveContains("subscribe to upload")
                }

                // Check if any failure was subscription-related
                let hasSubscriptionError = results.contains { result in
                    result.error?.contains("subscription is required") == true ||
                    result.error?.contains("active subscription") == true
                }

                if accountOrUpgradeMessage != nil {
                    showBanner(message: "Choose a plan to upload now. No email account required.", isError: true)
                    showPaywall = true
                } else if hasSubscriptionError {
                    Task { await subscriptionState.checkStatus() }
                    showBanner(message: String(localized: "media.banner.subscription_required"), isError: true)
                    showPaywall = true
                } else if failed.isEmpty {
                    let hasTTL = successful.compactMap(\.record).contains { $0.isTemporary }
                    let msg: String
                    if successful.count == 1 {
                        msg = hasTTL
                            ? String(format: String(localized: "media.banner.upload_success_singular_ttl"), successful.count)
                            : String(format: String(localized: "media.banner.upload_success_singular"), successful.count)
                    } else {
                        msg = hasTTL
                            ? String(format: String(localized: "media.banner.upload_success_plural_ttl"), successful.count)
                            : String(format: String(localized: "media.banner.upload_success_plural"), successful.count)
                    }
                    showBanner(message: msg, isError: false)
                } else if successful.isEmpty {
                    let msg = failed.count == 1
                        ? (failed.first?.error ?? String(format: String(localized: "media.banner.upload_failed_singular"), failed.count))
                        : String(format: String(localized: "media.banner.upload_failed_plural"), failed.count)
                    showBanner(message: msg, isError: true)
                } else {
                    showBanner(message: String(format: String(localized: "media.banner.upload_partial"), successful.count, failed.count), isError: true)
                }
            }
        }
    }

    private func cancelUpload() {
        uploadService.cancelUpload()
        withAnimation { isUploading = false }
    }

    private func showBanner(message: String, isError: Bool) {
        uploadBannerMessage = message
        uploadBannerIsError = isError
        withAnimation { showUploadBanner = true }

        // Auto-dismiss success banners
        if !isError {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if showUploadBanner && !uploadBannerIsError {
                    withAnimation { showUploadBanner = false }
                }
            }
        }
    }
}
