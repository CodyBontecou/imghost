import SwiftUI
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.codybontecou.imghost.ShareExtension", category: "ShareView")

struct MacShareView: View {
    let extensionContext: NSExtensionContext?

    @State private var files: [ShareFile] = []
    @State private var isLoading = true
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var uploadStatusMessage: String = "Preparing..."
    @State private var results: [ShareUploadResult] = []
    @State private var errorMessage: String?
    @State private var debugInfo: String = ""
    @State private var selectedQuality: UploadQuality
    @State private var showDebug = false
    @State private var copiedIndex: Int? = nil

    private let uploadService = MacUploadService.shared

    struct ShareFile: Identifiable {
        let id = UUID()
        let url: URL
        let filename: String
        let thumbnailData: Data?
        let fileSize: Int64
    }

    struct ShareUploadResult: Identifiable {
        let id = UUID()
        let filename: String
        let url: String?
        let error: String?
    }

    init(extensionContext: NSExtensionContext?) {
        self.extensionContext = extensionContext
        _selectedQuality = State(initialValue: UploadQualityService.shared.currentQuality)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider().background(Color.brutalBorder)

            // Content
            if let error = errorMessage {
                errorView(message: error)
            } else if !KeychainService.shared.hasValidTokens && !isLoading {
                notLoggedInView
            } else if isLoading {
                loadingView
            } else if !results.isEmpty {
                resultsView
            } else if isUploading {
                uploadingView
            } else if files.isEmpty {
                noFilesView
            } else {
                fileListView
            }

            // Debug footer (tap header 3x to show)
            if showDebug && !debugInfo.isEmpty {
                debugView
            }
        }
        .background(Color.brutalBackground)
        .frame(width: 420, height: 480)
        .task {
            await gatherDebugInfo()
            await loadFiles()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.square")
                    .font(.system(size: 12))
                Text("IMGHOST")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(2)
            }
            .foregroundStyle(.white)
            .onTapGesture(count: 3) {
                showDebug.toggle()
            }

            Spacer()

            // Status indicator
            if KeychainService.shared.hasValidTokens {
                Circle()
                    .fill(Color.brutalSuccess)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(Color.brutalError)
                    .frame(width: 8, height: 8)
            }

            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.brutalSurface)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
            Text("Loading files...")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.brutalTextSecondary)
            Spacer()
        }
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(Color.brutalError)

            Text("ERROR")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.brutalError)
                .tracking(2)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.brutalTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .textSelection(.enabled)

            Spacer()

            HStack {
                Spacer()

                Button(action: {
                    errorMessage = nil
                    isLoading = true
                    Task { await loadFiles() }
                }) {
                    Text("RETRY")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)
                        .tracking(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button(action: cancel) {
                    Text("CLOSE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .tracking(1)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.white)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.brutalSurface)
        }
    }

    // MARK: - Not Logged In

    private var notLoggedInView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 32))
                .foregroundStyle(Color.brutalWarning)

            Text("NOT SIGNED IN")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.brutalWarning)
                .tracking(2)

            Text("Open the imghost app and sign in to enable uploads from the share sheet.")
                .font(.system(size: 12))
                .foregroundStyle(Color.brutalTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer()

            HStack {
                Spacer()
                Button(action: cancel) {
                    Text("CLOSE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .tracking(1)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.white)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.brutalSurface)
        }
    }

    // MARK: - No Files

    private var noFilesView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "doc.questionmark")
                .font(.system(size: 32))
                .foregroundStyle(Color.brutalTextTertiary)

            Text("NO FILES FOUND")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.brutalTextSecondary)
                .tracking(2)

            Text("No compatible files were found in the shared content. Try sharing an image or file directly.")
                .font(.system(size: 12))
                .foregroundStyle(Color.brutalTextTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer()

            HStack {
                Spacer()
                Button(action: cancel) {
                    Text("CLOSE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .tracking(1)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.white)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.brutalSurface)
        }
    }

    // MARK: - File List

    private var fileListView: some View {
        VStack(spacing: 0) {
            // Quality picker
            HStack {
                Text("QUALITY")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.brutalTextTertiary)
                    .tracking(1)

                Spacer()

                Picker("", selection: $selectedQuality) {
                    ForEach(UploadQuality.allCases) { q in
                        Text(q.displayName).tag(q)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.brutalSurface.opacity(0.5))

            // Files
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(files) { file in
                        HStack(spacing: 10) {
                            // Thumbnail
                            if let data = file.thumbnailData, let image = NSImage(data: data) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 36, height: 36)
                                    .clipped()
                            } else {
                                Rectangle()
                                    .fill(Color.brutalSurface)
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Image(systemName: "doc")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color.brutalTextTertiary)
                                    )
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.filename)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)

                                Text(ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.brutalTextTertiary)
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider().background(Color.brutalBorder)

            // Upload button
            HStack {
                Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.brutalTextSecondary)

                Spacer()

                Button(action: cancel) {
                    Text("CANCEL")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)
                        .tracking(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button(action: uploadFiles) {
                    Text("UPLOAD")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .tracking(1)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.white)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.brutalSurface)
        }
    }

    // MARK: - Uploading

    private var uploadingView: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("UPLOADING")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .tracking(2)

            BrutalProgressBar(progress: uploadProgress)
                .frame(width: 200)

            Text("\(Int(uploadProgress * 100))%")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            Text(uploadStatusMessage)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.brutalTextSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer()
        }
    }

    // MARK: - Results

    private var resultsView: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        HStack(spacing: 10) {
                            Image(systemName: result.error != nil ? "xmark.circle" : "checkmark.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(result.error != nil ? Color.brutalError : Color.brutalSuccess)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.filename)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)

                                if let url = result.url {
                                    Text(url)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Color.brutalTextSecondary)
                                        .lineLimit(1)
                                        .textSelection(.enabled)
                                } else if let error = result.error {
                                    Text(error)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.brutalError)
                                        .lineLimit(2)
                                }
                            }

                            Spacer()

                            if let url = result.url {
                                Button(action: {
                                    MacClipboard.copy(url)
                                    copiedIndex = index
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        if copiedIndex == index { copiedIndex = nil }
                                    }
                                }) {
                                    Image(systemName: copiedIndex == index ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 11))
                                        .foregroundStyle(copiedIndex == index ? Color.brutalSuccess : Color.brutalTextSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider().background(Color.brutalBorder)

            // Done button
            HStack {
                let successCount = results.filter { $0.error == nil }.count
                let errorCount = results.filter { $0.error != nil }.count

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(successCount)/\(results.count) uploaded")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)

                    if errorCount > 0 {
                        Text("\(errorCount) failed")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.brutalError)
                    }
                }

                Spacer()

                if successCount > 0 {
                    Button(action: copyAllLinks) {
                        Text("COPY ALL")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .tracking(1)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: done) {
                    Text("DONE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .tracking(1)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.white)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.brutalSurface)
        }
    }

    // MARK: - Debug View

    private var debugView: some View {
        VStack(spacing: 0) {
            Divider().background(Color.brutalBorder)
            ScrollView {
                Text(debugInfo)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.brutalTextTertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 100)
            .background(Color.black)
        }
    }

    // MARK: - Actions

    private func gatherDebugInfo() async {
        var info: [String] = []
        info.append("Backend: \(Config.backendURL)")
        info.append("Has tokens: \(KeychainService.shared.hasValidTokens)")
        info.append("Bundle: \(Bundle.main.bundleIdentifier ?? "nil")")
        info.append("App group: \(Config.appGroup)")

        if let container = Config.sharedContainerURL {
            info.append("Container: \(container.path)")
            info.append("Container exists: \(FileManager.default.fileExists(atPath: container.path))")
        } else {
            info.append("Container: nil (PROBLEM)")
        }

        if let defaults = Config.sharedDefaults {
            info.append("UserDefaults: OK")
            info.append("Quality: \(defaults.string(forKey: Config.uploadQualityKey) ?? "default")")
        } else {
            info.append("UserDefaults: nil (PROBLEM)")
        }

        let inputItems = extensionContext?.inputItems as? [NSExtensionItem]
        info.append("Input items: \(inputItems?.count ?? 0)")
        if let items = inputItems {
            for (i, item) in items.enumerated() {
                let attachments = item.attachments ?? []
                info.append("  Item[\(i)]: \(attachments.count) attachments")
                for (j, att) in attachments.enumerated() {
                    info.append("    Att[\(j)]: \(att.registeredTypeIdentifiers)")
                }
            }
        }

        await MainActor.run {
            debugInfo = info.joined(separator: "\n")
        }

        logger.info("Debug info gathered:\n\(info.joined(separator: "\n"))")
    }

    private func loadFiles() async {
        logger.info("loadFiles() starting")

        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            logger.error("No input items from extension context")
            await MainActor.run {
                errorMessage = "No content received from share sheet. The extension context had no input items."
                isLoading = false
            }
            return
        }

        logger.info("Found \(items.count) input items")

        var loadedFiles: [ShareFile] = []
        var loadErrors: [String] = []

        for (itemIndex, item) in items.enumerated() {
            guard let attachments = item.attachments else {
                logger.warning("Item \(itemIndex) has no attachments")
                continue
            }

            logger.info("Item \(itemIndex) has \(attachments.count) attachments")

            for (attIndex, attachment) in attachments.enumerated() {
                let typeIds = attachment.registeredTypeIdentifiers
                logger.info("Attachment \(attIndex) types: \(typeIds)")

                // Try file URL first
                if attachment.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    do {
                        if let url = try await attachment.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                            logger.info("Loaded file URL: \(url.path)")
                            let filename = url.lastPathComponent
                            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                            let thumbnail = MacImageHelper.generateThumbnail(from: (try? Data(contentsOf: url)) ?? Data(), maxSize: 80)
                            loadedFiles.append(ShareFile(url: url, filename: filename, thumbnailData: thumbnail, fileSize: fileSize))
                            continue
                        } else {
                            logger.warning("Loaded item was not a URL for fileURL type")
                        }
                    } catch {
                        logger.error("Failed to load file URL attachment: \(error.localizedDescription)")
                        loadErrors.append("File \(attIndex): \(error.localizedDescription)")
                    }
                }

                // Try image type
                if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    do {
                        let loadedItem = try await attachment.loadItem(forTypeIdentifier: UTType.image.identifier)
                        if let url = loadedItem as? URL {
                            logger.info("Loaded image URL: \(url.path)")
                            let filename = url.lastPathComponent
                            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                            let thumbnail = MacImageHelper.generateThumbnail(from: (try? Data(contentsOf: url)) ?? Data(), maxSize: 80)
                            loadedFiles.append(ShareFile(url: url, filename: filename, thumbnailData: thumbnail, fileSize: fileSize))
                        } else if let data = loadedItem as? Data {
                            logger.info("Loaded image as Data (\(data.count) bytes)")
                            // Write to temp file for upload
                            let tempDir = FileManager.default.temporaryDirectory
                            let tempURL = tempDir.appendingPathComponent("share_\(UUID().uuidString).jpg")
                            try data.write(to: tempURL)
                            let thumbnail = MacImageHelper.generateThumbnail(from: data, maxSize: 80)
                            loadedFiles.append(ShareFile(url: tempURL, filename: tempURL.lastPathComponent, thumbnailData: thumbnail, fileSize: Int64(data.count)))
                        } else if let image = loadedItem as? NSImage {
                            logger.info("Loaded image as NSImage")
                            if let data = MacImageHelper.jpegData(from: image) {
                                let tempDir = FileManager.default.temporaryDirectory
                                let tempURL = tempDir.appendingPathComponent("share_\(UUID().uuidString).jpg")
                                try data.write(to: tempURL)
                                let thumbnail = MacImageHelper.generateThumbnail(from: data, maxSize: 80)
                                loadedFiles.append(ShareFile(url: tempURL, filename: tempURL.lastPathComponent, thumbnailData: thumbnail, fileSize: Int64(data.count)))
                            }
                        } else {
                            logger.warning("Loaded image item was unexpected type: \(type(of: loadedItem))")
                            loadErrors.append("Attachment \(attIndex): unexpected type \(type(of: loadedItem))")
                        }
                    } catch {
                        logger.error("Failed to load image attachment: \(error.localizedDescription)")
                        loadErrors.append("Image \(attIndex): \(error.localizedDescription)")
                    }
                }

                // Try URL type (e.g., URL to a remote image)
                if loadedFiles.isEmpty && attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    do {
                        if let url = try await attachment.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                            logger.info("Loaded URL: \(url.absoluteString)")
                            // Only handle file URLs
                            if url.isFileURL {
                                let filename = url.lastPathComponent
                                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                                let thumbnail = MacImageHelper.generateThumbnail(from: (try? Data(contentsOf: url)) ?? Data(), maxSize: 80)
                                loadedFiles.append(ShareFile(url: url, filename: filename, thumbnailData: thumbnail, fileSize: fileSize))
                            }
                        }
                    } catch {
                        logger.error("Failed to load URL attachment: \(error.localizedDescription)")
                    }
                }
            }
        }

        await MainActor.run {
            files = loadedFiles
            isLoading = false

            if loadedFiles.isEmpty && !loadErrors.isEmpty {
                errorMessage = "Failed to load shared files:\n\(loadErrors.joined(separator: "\n"))"
            }

            logger.info("Loaded \(loadedFiles.count) files, \(loadErrors.count) errors")
        }
    }

    private func uploadFiles() {
        logger.info("uploadFiles() starting with \(files.count) files")

        guard KeychainService.shared.hasValidTokens else {
            logger.error("No valid tokens - cannot upload")
            errorMessage = "Not signed in. Open the imghost app and sign in first."
            return
        }

        isUploading = true
        uploadProgress = 0
        uploadStatusMessage = "Starting upload..."

        Task {
            var uploadResults: [ShareUploadResult] = []
            let total = files.count

            for (index, file) in files.enumerated() {
                let baseProgress = Double(index) / Double(total)

                await MainActor.run {
                    uploadStatusMessage = "Uploading \(file.filename) (\(index + 1)/\(total))"
                }

                logger.info("Uploading file \(index + 1)/\(total): \(file.filename) (\(file.fileSize) bytes)")

                do {
                    let record = try await uploadService.uploadFromFile(
                        fileURL: file.url,
                        filename: file.filename
                    ) { fileProgress in
                        let totalProgress = baseProgress + (fileProgress / Double(total))
                        Task { @MainActor in
                            uploadProgress = totalProgress
                        }
                    }

                    logger.info("Upload succeeded for \(file.filename): \(record.url)")
                    try? HistoryService.shared.save(record)
                    uploadResults.append(ShareUploadResult(filename: file.filename, url: record.url, error: nil))
                } catch {
                    let errorDesc = describeError(error)
                    logger.error("Upload failed for \(file.filename): \(errorDesc)")
                    uploadResults.append(ShareUploadResult(filename: file.filename, url: nil, error: errorDesc))
                }
            }

            await MainActor.run {
                results = uploadResults
                isUploading = false
                uploadProgress = 1.0

                // Auto-copy first link
                if let firstUrl = uploadResults.first?.url {
                    MacClipboard.copy(firstUrl)
                    logger.info("Auto-copied first URL to clipboard")
                }

                let successCount = uploadResults.filter { $0.error == nil }.count
                logger.info("Upload complete: \(successCount)/\(total) succeeded")
            }
        }
    }

    private func describeError(_ error: Error) -> String {
        if let imghostError = error as? ImghostError {
            switch imghostError {
            case .notConfigured:
                return "Not signed in. Open imghost app to sign in."
            case .invalidURL:
                return "Invalid upload URL. Check backend configuration."
            case .invalidResponse:
                return "Invalid response from server."
            case .uploadFailed(let statusCode, let message):
                return "Upload failed (HTTP \(statusCode)): \(message ?? "No details")"
            case .networkError(let underlying):
                return "Network error: \(underlying.localizedDescription)"
            case .subscriptionRequired:
                return "Subscription required. Upgrade in the imghost app."
            case .emailVerificationRequired:
                return "Email verification required. Check your email."
            case .keychainError(let status):
                return "Keychain error (status \(status)). Try signing in again."
            case .fileSystemError(let underlying):
                return "File error: \(underlying.localizedDescription)"
            case .imageProcessingFailed:
                return "Failed to process image. File may be corrupted."
            case .deleteFailed(let statusCode, let message):
                return "Delete failed (HTTP \(statusCode)): \(message ?? "No details")"
            }
        }
        return error.localizedDescription
    }

    private func copyAllLinks() {
        let links = results.compactMap { $0.url }
        MacClipboard.copy(links.joined(separator: "\n"))
    }

    private func cancel() {
        logger.info("Share extension cancelled by user")
        extensionContext?.cancelRequest(withError: NSError(domain: "com.imghost", code: 0))
    }

    private func done() {
        logger.info("Share extension completed")
        extensionContext?.completeRequest(returningItems: nil)
    }
}
