import SwiftUI
import UniformTypeIdentifiers

struct MacShareView: View {
    let extensionContext: NSExtensionContext?

    @State private var files: [ShareFile] = []
    @State private var isLoading = true
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var results: [ShareUploadResult] = []
    @State private var errorMessage: String?
    @State private var selectedQuality: UploadQuality

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
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.square")
                        .font(.system(size: 12))
                    Text("IMGHOST")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(2)
                }
                .foregroundStyle(.white)

                Spacer()

                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.brutalTextSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.brutalSurface)

            Divider().background(Color.brutalBorder)

            // Content
            if isLoading {
                Spacer()
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                Text("Loading files...")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.brutalTextSecondary)
                Spacer()
            } else if !results.isEmpty {
                resultsView
            } else if isUploading {
                uploadingView
            } else {
                fileListView
            }
        }
        .background(Color.brutalBackground)
        .frame(width: 420, height: 480)
        .task {
            await loadFiles()
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

            Spacer()
        }
    }

    // MARK: - Results

    private var resultsView: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(results) { result in
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
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            if let url = result.url {
                                Button(action: {
                                    MacClipboard.copy(url)
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.brutalTextSecondary)
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
                Text("\(successCount)/\(results.count) uploaded")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.brutalTextSecondary)

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

    // MARK: - Actions

    private func loadFiles() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            isLoading = false
            return
        }

        var loadedFiles: [ShareFile] = []

        for item in items {
            guard let attachments = item.attachments else { continue }

            for attachment in attachments {
                if attachment.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    if let url = try? await attachment.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                        let filename = url.lastPathComponent
                        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                        let thumbnail = MacImageHelper.generateThumbnail(from: (try? Data(contentsOf: url)) ?? Data(), maxSize: 80)

                        loadedFiles.append(ShareFile(url: url, filename: filename, thumbnailData: thumbnail, fileSize: fileSize))
                    }
                } else if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let url = try? await attachment.loadItem(forTypeIdentifier: UTType.image.identifier) as? URL {
                        let filename = url.lastPathComponent
                        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                        let thumbnail = MacImageHelper.generateThumbnail(from: (try? Data(contentsOf: url)) ?? Data(), maxSize: 80)

                        loadedFiles.append(ShareFile(url: url, filename: filename, thumbnailData: thumbnail, fileSize: fileSize))
                    }
                }
            }
        }

        await MainActor.run {
            files = loadedFiles
            isLoading = false
        }
    }

    private func uploadFiles() {
        isUploading = true
        uploadProgress = 0

        Task {
            var uploadResults: [ShareUploadResult] = []
            let total = files.count

            for (index, file) in files.enumerated() {
                let baseProgress = Double(index) / Double(total)

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

                    try? HistoryService.shared.save(record)
                    uploadResults.append(ShareUploadResult(filename: file.filename, url: record.url, error: nil))
                } catch {
                    uploadResults.append(ShareUploadResult(filename: file.filename, url: nil, error: error.localizedDescription))
                }
            }

            await MainActor.run {
                results = uploadResults
                isUploading = false

                // Auto-copy first link
                if let firstUrl = uploadResults.first?.url {
                    MacClipboard.copy(firstUrl)
                }
            }
        }
    }

    private func copyAllLinks() {
        let links = results.compactMap { $0.url }
        MacClipboard.copy(links.joined(separator: "\n"))
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "com.imghost", code: 0))
    }

    private func done() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
