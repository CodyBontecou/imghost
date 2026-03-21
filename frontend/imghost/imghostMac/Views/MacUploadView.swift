import SwiftUI
import UniformTypeIdentifiers

struct MacUploadView: View {
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var uploadResults: [UploadResult] = []
    @State private var errorMessage: String?
    @State private var isDragOver = false
    @State private var showFileImporter = false

    // Pending upload state (used when confirmBeforeUpload is enabled)
    @State private var pendingFileURLs: [URL]? = nil
    @State private var pendingImageData: [(Data, String)]? = nil
    @State private var showUploadConfirm = false
    @State private var confirmMessage = ""

    private let uploadService = MacUploadService.shared
    private let qualityService = UploadQualityService.shared

    struct UploadResult: Identifiable {
        let id = UUID()
        let record: UploadRecord?
        let filename: String
        let error: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("upload.title")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .tracking(2)

                Spacer()

                // Quality indicator (read-only, set in Settings)
                HStack(spacing: 4) {
                    Text("upload.label.resolution")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.brutalTextTertiary)
                        .tracking(1)
                    Text(qualityService.currentQuality.displayName.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)
                        .tracking(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.brutalSurface)

            Divider().background(Color.brutalBorder)

            // Main content
            if isUploading {
                uploadingView
            } else if !uploadResults.isEmpty {
                resultsView
            } else {
                dropZoneView
            }
        }
        .background(Color.brutalBackground)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image, .movie, .data],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .alert(confirmMessage, isPresented: $showUploadConfirm) {
            Button(String(localized: "upload.confirm.button.upload"), role: .none) {
                if let urls = pendingFileURLs {
                    pendingFileURLs = nil
                    uploadFiles(urls)
                } else if let data = pendingImageData {
                    pendingImageData = nil
                    uploadImageData(data)
                }
            }
            Button(String(localized: "upload.confirm.button.cancel"), role: .cancel) {
                pendingFileURLs = nil
                pendingImageData = nil
            }
        }
    }

    // MARK: - Drop Zone

    private var dropZoneView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                ZStack {
                    Rectangle()
                        .stroke(
                            isDragOver ? Color.white : Color.brutalBorder,
                            style: StrokeStyle(lineWidth: isDragOver ? 2 : 1, dash: [10, 6])
                        )
                        .background(isDragOver ? Color.brutalSurfaceElevated : Color.clear)

                    VStack(spacing: 16) {
                        Image(systemName: "arrow.up.doc")
                            .font(.system(size: 36))
                            .foregroundStyle(isDragOver ? Color.white : Color.brutalTextSecondary)

                        VStack(spacing: 4) {
                            Text("upload.drop_zone.title")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.white)
                                .tracking(2)

                            Text("upload.drop_zone.subtitle")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.brutalTextSecondary)
                        }

                        Text("upload.drop_zone.hint")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.brutalTextTertiary)
                    }
                    .padding(40)
                }
                .frame(maxWidth: 480, maxHeight: 280)
                .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                    handleDrop(providers: providers)
                    return true
                }
                .onTapGesture {
                    showFileImporter = true
                }
            }

            // Keyboard shortcut hint
            HStack(spacing: 4) {
                Text(verbatim: "⌘V")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.brutalTextSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))

                Text("upload.clipboard.hint")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.brutalTextTertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onPasteCommand(of: [.fileURL, .image, .png, .jpeg]) { providers in
            handlePaste(providers: providers)
        }
    }

    // MARK: - Uploading View

    private var uploadingView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Text("upload.progress.title")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .tracking(2)

                BrutalProgressBar(progress: uploadProgress)
                    .frame(width: 240)

                Text("\(Int(uploadProgress * 100))%")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)

                Button(action: cancelUpload) {
                    Text("upload.progress.cancel")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.brutalError)
                        .tracking(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .overlay(Rectangle().stroke(Color.brutalError.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    // MARK: - Results View

    private var resultsView: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(uploadResults) { result in
                        MacUploadResultRow(result: result)
                    }
                }
                .padding(16)
            }

            Divider().background(Color.brutalBorder)

            // Upload more button
            HStack {
                Button(action: { uploadResults.removeAll() }) {
                    Text("upload.success.button.upload_more")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .tracking(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()

                if uploadResults.contains(where: { $0.record != nil }) {
                    Button(action: copyAllLinks) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                            Text("upload.success.button.copy_all")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .tracking(1)
                        }
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .background(Color.brutalSurface)
        }
    }

    // MARK: - Actions

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
            guard !fileURLs.isEmpty else { return }
            self.requestUploadConfirmation(fileURLs: fileURLs)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            requestUploadConfirmation(fileURLs: urls)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func handlePaste(providers: [NSItemProvider]) {
        // Handle paste from clipboard
        if let pasteboardItems = NSPasteboard.general.pasteboardItems {
            var imageDataList: [(Data, String)] = []

            for item in pasteboardItems {
                if let fileURL = item.string(forType: .fileURL),
                   let url = URL(string: fileURL) {
                    requestUploadConfirmation(fileURLs: [url])
                    return
                }

                // Try image data
                if let pngData = item.data(forType: .png) {
                    imageDataList.append((pngData, "clipboard_\(Date().timeIntervalSince1970).png"))
                } else if let jpegData = item.data(forType: .init("public.jpeg")) {
                    imageDataList.append((jpegData, "clipboard_\(Date().timeIntervalSince1970).jpg"))
                }
            }

            if !imageDataList.isEmpty {
                requestUploadConfirmation(imageData: imageDataList)
            }
        }
    }

    /// Gate uploads through the confirmation dialog when the setting is enabled.
    private func requestUploadConfirmation(fileURLs: [URL]? = nil, imageData: [(Data, String)]? = nil) {
        guard qualityService.confirmBeforeUpload else {
            if let urls = fileURLs { uploadFiles(urls) }
            else if let data = imageData { uploadImageData(data) }
            return
        }

        if let urls = fileURLs {
            let count = urls.count
            confirmMessage = count == 1
                ? String(format: String(localized: "upload.confirm.file"), urls[0].lastPathComponent)
                : String(format: String(localized: "upload.confirm.files_plural"), count)
            pendingFileURLs = urls
            pendingImageData = nil
        } else if let data = imageData {
            let count = data.count
            confirmMessage = count == 1
                ? String(localized: "upload.confirm.clipboard_single")
                : String(format: String(localized: "upload.confirm.clipboard_plural"), count)
            pendingImageData = data
            pendingFileURLs = nil
        }
        showUploadConfirm = true
    }

    private func uploadFiles(_ urls: [URL]) {
        isUploading = true
        uploadProgress = 0
        uploadResults.removeAll()
        errorMessage = nil

        Task {
            var results: [UploadResult] = []
            let totalFiles = urls.count
            let quality = qualityService.currentQuality

            for (index, url) in urls.enumerated() {
                let filename = url.lastPathComponent
                let baseProgress = Double(index) / Double(totalFiles)

                do {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }

                    let record: UploadRecord
                    if quality != .original {
                        // Apply quality processing for non-original settings
                        let data = try Data(contentsOf: url)
                        let (processedData, processedFilename) = qualityService.processForUpload(
                            data: data, filename: filename, quality: quality
                        )
                        record = try await uploadService.upload(
                            imageData: processedData,
                            filename: processedFilename
                        ) { fileProgress in
                            let totalProgress = baseProgress + (fileProgress / Double(totalFiles))
                            Task { @MainActor in self.uploadProgress = totalProgress }
                        }
                    } else {
                        record = try await uploadService.uploadFromFile(
                            fileURL: url,
                            filename: filename
                        ) { fileProgress in
                            let totalProgress = baseProgress + (fileProgress / Double(totalFiles))
                            Task { @MainActor in self.uploadProgress = totalProgress }
                        }
                    }

                    // Save to history
                    try? HistoryService.shared.save(record)
                    results.append(UploadResult(record: record, filename: filename, error: nil))
                } catch {
                    results.append(UploadResult(record: nil, filename: filename, error: error.localizedDescription))
                }
            }

            await MainActor.run {
                uploadResults = results
                isUploading = false
                uploadProgress = 1.0
            }
        }
    }

    private func uploadImageData(_ images: [(Data, String)]) {
        isUploading = true
        uploadProgress = 0
        uploadResults.removeAll()

        Task {
            var results: [UploadResult] = []
            let totalFiles = images.count

            for (index, (data, filename)) in images.enumerated() {
                let baseProgress = Double(index) / Double(totalFiles)

                do {
                    // Apply quality processing (processForUpload returns original data for .original quality)
                    let (processedData, processedFilename) = qualityService.processForUpload(
                        data: data, filename: filename
                    )
                    let record = try await uploadService.upload(
                        imageData: processedData,
                        filename: processedFilename
                    ) { fileProgress in
                        let totalProgress = baseProgress + (fileProgress / Double(totalFiles))
                        Task { @MainActor in self.uploadProgress = totalProgress }
                    }
                    try? HistoryService.shared.save(record)
                    results.append(UploadResult(record: record, filename: filename, error: nil))
                } catch {
                    results.append(UploadResult(record: nil, filename: filename, error: error.localizedDescription))
                }
            }

            await MainActor.run {
                uploadResults = results
                isUploading = false
            }
        }
    }

    private func cancelUpload() {
        uploadService.cancelUpload()
        isUploading = false
    }

    private func copyAllLinks() {
        let links = uploadResults.compactMap { $0.record?.url }
        MacClipboard.copy(links.joined(separator: "\n"))
    }
}

// MARK: - Upload Result Row

struct MacUploadResultRow: View {
    let result: MacUploadView.UploadResult
    @State private var isCopied = false

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            if let data = result.record?.thumbnailData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipped()
            } else {
                Rectangle()
                    .fill(result.error != nil ? Color.brutalError.opacity(0.1) : Color.brutalSurface)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: result.error != nil ? "xmark" : "photo")
                            .font(.system(size: 14))
                            .foregroundStyle(result.error != nil ? Color.brutalError : Color.brutalTextTertiary)
                    )
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(result.filename)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)

                if let error = result.error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.brutalError)
                        .lineLimit(1)
                } else if let url = result.record?.url {
                    Text(url)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            // Copy button
            if result.record != nil {
                Button(action: {
                    if let url = result.record?.url {
                        let formatted = LinkFormatService.shared.format(url: url, filename: result.filename)
                        MacClipboard.copy(formatted)
                        isCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCopied = false }
                    }
                }) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(isCopied ? Color.brutalSuccess : Color.brutalTextSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.brutalSurface)
        .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
    }
}
