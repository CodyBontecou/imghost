import Cocoa
import SwiftUI
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.codybontecou.imghost.ShareExtension", category: "ViewController")

class MacShareViewController: NSViewController {

    override func loadView() {
        logger.info("MacShareViewController loadView called")
        logger.info("Extension context: \(String(describing: self.extensionContext))")
        logger.info("Backend URL: \(Config.backendURL)")
        logger.info("Has valid tokens: \(KeychainService.shared.hasValidTokens)")

        if UploadQualityService.shared.confirmBeforeUpload {
            // Full UI — user wants to confirm quality/files before every upload
            let hostingView = NSHostingView(rootView: MacShareView(extensionContext: self.extensionContext))
            hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
            self.view = hostingView
            self.preferredContentSize = NSSize(width: 420, height: 480)
        } else {
            // Skip UI — upload immediately at the saved quality and auto-dismiss
            let hostingView = NSHostingView(rootView: MacAutoUploadView(extensionContext: self.extensionContext))
            hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
            self.view = hostingView
            self.preferredContentSize = NSSize(width: 320, height: 220)
        }

        logger.info("MacShareViewController loadView completed (confirmBeforeUpload=\(UploadQualityService.shared.confirmBeforeUpload))")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        logger.info("MacShareViewController viewDidLoad")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        logger.info("MacShareViewController viewDidAppear")
    }
}

// MARK: - MacAutoUploadView

/// Shown when confirmBeforeUpload is OFF. Uploads immediately at saved quality and auto-dismisses.
struct MacAutoUploadView: View {
    let extensionContext: NSExtensionContext?

    @State private var phase: Phase = .uploading

    private let uploadService = MacUploadService.shared

    enum Phase {
        case uploading
        case success(urls: [String])
        case failed(error: String)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Minimal header
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.brutalSurface)

            Divider().background(Color.brutalBorder)

            // Status area
            Spacer()

            switch phase {
            case .uploading:
                VStack(spacing: 14) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.2)

                    Text("UPLOADING")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                        .tracking(3)
                }

            case .success(let urls):
                VStack(spacing: 10) {
                    Text("✓")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(Color.brutalSuccess)

                    Text(urls.count == 1 ? "LINK COPIED" : "\(urls.count) LINKS COPIED")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .tracking(2)

                    if let first = urls.first {
                        Text(first)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 32)
                    }
                }

            case .failed(let error):
                VStack(spacing: 10) {
                    Text("!")
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.brutalError)

                    Text("UPLOAD FAILED")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .tracking(2)

                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .lineLimit(3)

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
                    .padding(.top, 4)
                }
            }

            Spacer()
        }
        .background(Color.brutalBackground)
        .frame(width: 320, height: 220)
        .onAppear { startUpload() }
    }

    // MARK: - Upload Logic

    private func startUpload() {
        Task {
            do {
                let files = try await loadFiles()

                guard !files.isEmpty else {
                    await MainActor.run {
                        phase = .failed(error: "No compatible files found in share.")
                    }
                    return
                }

                var uploadedURLs: [String] = []
                let quality = UploadQualityService.shared.currentQuality

                for file in files {
                    let filename = file.filename
                    let lowercased = filename.lowercased()
                    let isCompressibleImage = !lowercased.hasSuffix(".gif") && (
                        lowercased.hasSuffix(".jpg") || lowercased.hasSuffix(".jpeg") ||
                        lowercased.hasSuffix(".png") || lowercased.hasSuffix(".heic") ||
                        lowercased.hasSuffix(".webp") || lowercased.hasSuffix(".bmp") ||
                        lowercased.hasSuffix(".tiff")
                    )

                    let record: UploadRecord
                    if isCompressibleImage && quality != .original && file.fileSize < 50 * 1024 * 1024 {
                        let data = try Data(contentsOf: file.url)
                        let (processedData, processedFilename) = UploadQualityService.shared.processForUpload(
                            data: data, filename: filename, quality: quality
                        )
                        record = try await uploadService.upload(imageData: processedData, filename: processedFilename)
                    } else {
                        record = try await uploadService.uploadFromFile(fileURL: file.url, filename: filename)
                    }

                    try? HistoryService.shared.save(record)
                    let formatted = LinkFormatService.shared.format(url: record.url, filename: record.originalFilename)
                    uploadedURLs.append(formatted)

                    // Clean up temp files we created
                    if file.isTempFile {
                        try? FileManager.default.removeItem(at: file.url)
                    }
                }

                await MainActor.run {
                    MacClipboard.copy(uploadedURLs.joined(separator: "\n"))
                    phase = .success(urls: uploadedURLs)
                }

                // Auto-dismiss after brief success flash
                try await Task.sleep(nanoseconds: 1_400_000_000)
                done()

            } catch {
                await MainActor.run {
                    phase = .failed(error: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - File Loading

    private struct AutoShareFile {
        let url: URL
        let filename: String
        let fileSize: Int64
        let isTempFile: Bool
    }

    private func loadFiles() async throws -> [AutoShareFile] {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return []
        }

        var loadedFiles: [AutoShareFile] = []

        for item in items {
            guard let attachments = item.attachments else { continue }

            for attachment in attachments {
                // 1. Try file URL first (preserves original filename)
                if attachment.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    if let url = try? await attachment.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                        let filename = url.lastPathComponent
                        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                        loadedFiles.append(AutoShareFile(url: url, filename: filename, fileSize: fileSize, isTempFile: false))
                        continue
                    }
                }

                // 2. Try image type
                if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let loaded = try? await attachment.loadItem(forTypeIdentifier: UTType.image.identifier) {
                        if let url = loaded as? URL {
                            let filename = url.lastPathComponent
                            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                            loadedFiles.append(AutoShareFile(url: url, filename: filename, fileSize: fileSize, isTempFile: false))
                        } else if let data = loaded as? Data {
                            let tempURL = FileManager.default.temporaryDirectory
                                .appendingPathComponent("share_\(UUID().uuidString).jpg")
                            try? data.write(to: tempURL)
                            loadedFiles.append(AutoShareFile(url: tempURL, filename: tempURL.lastPathComponent, fileSize: Int64(data.count), isTempFile: true))
                        } else if let image = loaded as? NSImage {
                            if let data = MacImageHelper.jpegData(from: image) {
                                let tempURL = FileManager.default.temporaryDirectory
                                    .appendingPathComponent("share_\(UUID().uuidString).jpg")
                                try? data.write(to: tempURL)
                                loadedFiles.append(AutoShareFile(url: tempURL, filename: tempURL.lastPathComponent, fileSize: Int64(data.count), isTempFile: true))
                            }
                        }
                    }
                }
            }
        }

        return loadedFiles
    }

    // MARK: - Extension Actions

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "com.imghost", code: 0))
    }

    private func done() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
