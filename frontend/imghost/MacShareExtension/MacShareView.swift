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
    @State private var uploadStatusMessage: String = String(localized: "share.upload.status.preparing")
    @State private var results: [ShareUploadResult] = []
    @State private var errorMessage: String?
    @State private var debugInfo: String = ""
    @State private var selectedQuality: UploadQuality
    @State private var showDebug = false
    @State private var copiedIndex: Int? = nil
    @State private var showPermissionExplainer = false

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
            if showPermissionExplainer {
                permissionExplainerView
            } else if let error = errorMessage {
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
            // Check if this is the first time using the share extension
            let defaults = Config.sharedDefaults ?? UserDefaults.standard
            let hasGrantedAccess = defaults.bool(forKey: "hasGrantedShareExtensionAccess")
            if !hasGrantedAccess {
                await MainActor.run {
                    showPermissionExplainer = true
                    isLoading = false
                }
            } else {
                await loadFiles()
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.square")
                    .font(.system(size: 12))
                Text("share.app_name")
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
            Text("share.state.loading")
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

            Text("share.error.title")
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
                    Text("share.error.button.retry")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)
                        .tracking(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button(action: cancel) {
                    Text("share.error.button.close")
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

    // MARK: - Permission Explainer

    private var permissionExplainerView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(Color.white)

            Text("share.permission.title")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white)
                .tracking(2)

            VStack(spacing: 12) {
                Text("share.permission.prompt")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .multilineTextAlignment(.center)

                Text("share.permission.explanation")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.brutalTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                Text("share.permission.privacy_note")
                    .font(.system(size: 10))
            }
            .foregroundStyle(Color.brutalTextTertiary)
            .padding(.horizontal, 24)

            Spacer()

            HStack {
                Spacer()

                Button(action: cancel) {
                    Text("share.permission.button.cancel")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)
                        .tracking(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button(action: {
                    let defaults = Config.sharedDefaults ?? UserDefaults.standard
                    defaults.set(true, forKey: "hasGrantedShareExtensionAccess")
                    showPermissionExplainer = false
                    isLoading = true
                    Task { await loadFiles() }
                }) {
                    Text("share.permission.button.continue")
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

            Text("share.not_signed_in.title")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.brutalWarning)
                .tracking(2)

            Text("share.not_signed_in.message")
                .font(.system(size: 12))
                .foregroundStyle(Color.brutalTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer()

            HStack {
                Spacer()
                Button(action: cancel) {
                    Text("share.error.button.close")
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

            Text("share.no_files.title")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.brutalTextSecondary)
                .tracking(2)

            Text("share.no_files.message")
                .font(.system(size: 12))
                .foregroundStyle(Color.brutalTextTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer()

            HStack {
                Spacer()
                Button(action: cancel) {
                    Text("share.error.button.close")
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
                Text("share.preview.quality_label")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.brutalTextTertiary)
                    .tracking(1)

                Spacer()

                HStack(spacing: 0) {
                    ForEach(UploadQuality.allCases) { quality in
                        let isSelected = selectedQuality == quality
                        Button(action: { selectedQuality = quality }) {
                            Text(quality.displayName)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .tracking(0.5)
                                .foregroundStyle(isSelected ? .black : Color.brutalTextSecondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background(isSelected ? Color.white : Color.clear)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
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
                Text(verbatim: files.count == 1
                    ? String(format: String(localized: "share.preview.file_count_singular"), files.count)
                    : String(format: String(localized: "share.preview.file_count_plural"), files.count))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.brutalTextSecondary)

                Spacer()

                Button(action: cancel) {
                    Text("share.preview.button.cancel")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)
                        .tracking(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button(action: uploadFiles) {
                    Text("share.preview.button.upload")
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

            Text("share.state.uploading")
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
                    Text(verbatim: String(format: String(localized: "share.results.uploaded_count"), successCount, results.count))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)

                    if errorCount > 0 {
                        Text(verbatim: String(format: String(localized: "share.results.failed_count"), errorCount))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.brutalError)
                    }
                }

                Spacer()

                if successCount > 0 {
                    Button(action: copyAllLinks) {
                        Text("share.results.button.copy_all")
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
                    Text("share.results.button.done")
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
                errorMessage = String(localized: "share.error.no_content")
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
                errorMessage = String(format: String(localized: "share.error.failed_to_load"), loadErrors.joined(separator: "\n"))
            }

            logger.info("Loaded \(loadedFiles.count) files, \(loadErrors.count) errors")
        }
    }

    private func uploadFiles() {
        logger.info("uploadFiles() starting with \(files.count) files")

        guard KeychainService.shared.hasValidTokens else {
            logger.error("No valid tokens - cannot upload")
            errorMessage = String(localized: "share.error.not_signed_in_upload")
            return
        }

        isUploading = true
        uploadProgress = 0
        uploadStatusMessage = String(localized: "share.upload.status.starting")

        Task {
            var uploadResults: [ShareUploadResult] = []
            let total = files.count

            for (index, file) in files.enumerated() {
                let baseProgress = Double(index) / Double(total)

                await MainActor.run {
                    uploadStatusMessage = String(format: String(localized: "share.upload.status.in_progress"), file.filename, index + 1, total)
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
                return String(localized: "share.error.description.not_signed_in")
            case .invalidURL:
                return String(localized: "share.error.description.invalid_url")
            case .invalidResponse:
                return String(localized: "share.error.description.invalid_response")
            case .uploadFailed(let statusCode, let message):
                return String(format: String(localized: "share.error.description.upload_failed"), statusCode, message ?? String(localized: "share.error.description.no_details"))
            case .networkError(let underlying):
                return String(format: String(localized: "share.error.description.network"), underlying.localizedDescription)
            case .subscriptionRequired:
                return String(localized: "share.error.description.subscription_required")
            case .emailVerificationRequired:
                return String(localized: "share.error.description.email_not_verified")
            case .keychainError(let status):
                return String(format: String(localized: "share.error.description.keychain"), status)
            case .fileSystemError(let underlying):
                return String(format: String(localized: "share.error.description.file_system"), underlying.localizedDescription)
            case .imageProcessingFailed:
                return String(localized: "share.error.description.image_processing")
            case .deleteFailed(let statusCode, let message):
                return String(format: String(localized: "share.error.description.delete_failed"), statusCode, message ?? String(localized: "share.error.description.no_details"))
            case .freeTierFileSizeExceeded:
                return String(localized: "share.error.description.free_tier_file_size")
            case .freeTierStorageFull:
                return String(localized: "share.error.description.free_tier_storage_full")
            case .freeTierDailyLimitReached:
                return String(localized: "share.error.description.free_tier_daily_limit")
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
