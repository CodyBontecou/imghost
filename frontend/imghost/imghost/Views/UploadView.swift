import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import StoreKit

struct UploadView: View {
    @Environment(\.requestReview) private var requestReview

    @State private var selectedItem: PhotosPickerItem?
    @State private var showFilePicker = false
    @State private var selectedFileURL: URL?
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var uploadState: UploadState = .idle
    @State private var errorMessage: String?
    @State private var uploadedRecord: UploadRecord?
    @State private var showCopiedFeedback = false

    // Confirm before upload
    @State private var showUploadConfirm = false
    @State private var confirmMessage = ""
    @State private var pendingPhotoItem: PhotosPickerItem? = nil
    @State private var pendingFileURL: URL? = nil

    // Supported file types
    private static let supportedTypes: [UTType] = [
        // Images
        .image, .jpeg, .png, .gif, .webP, .heic, .heif, .bmp, .tiff, .svg, .ico,
        // Videos
        .movie, .video, .mpeg4Movie, .quickTimeMovie, .avi,
        // Audio
        .audio, .mp3, .wav, .aiff, .mpeg4Audio,
        // Documents
        .pdf, .plainText, .rtf, .html,
        // Archives
        .zip, .gzip,
        // Data
        .json, .xml,
        // Other common types
        .data
    ]

    private enum UploadState {
        case idle
        case loading
        case uploading
        case success
        case error
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.brutalBackground.ignoresSafeArea()

                VStack(spacing: 32) {
                    switch uploadState {
                    case .idle:
                        idleView

                    case .loading:
                        loadingView

                    case .uploading:
                        uploadingView

                    case .success:
                        successView

                    case .error:
                        errorView
                    }
                }
                .padding(24)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("upload.title")
                        .brutalTypography(.mono)
                        .tracking(2)
                }
            }
            .toolbarBackground(Color.brutalBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .confirmationDialog(confirmMessage, isPresented: $showUploadConfirm, titleVisibility: .visible) {
                Button(String(localized: "upload.confirm.button.upload")) {
                    if let item = pendingPhotoItem {
                        pendingPhotoItem = nil
                        processSelectedPhotoItem(item)
                    } else if let url = pendingFileURL {
                        pendingFileURL = nil
                        processSelectedFile(url)
                    }
                }
                Button(String(localized: "upload.confirm.button.cancel"), role: .cancel) {
                    pendingPhotoItem = nil
                    pendingFileURL = nil
                }
            } message: {
                Text(verbatim: String(format: String(localized: "upload.confirm.resolution"), UploadQualityService.shared.currentQuality.displayName))
            }
        }
    }

    // MARK: - State Views

    private var idleView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white)

                Text("upload.drop_zone.title")
                    .font(.system(size: 36, weight: .black))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("upload.drop_zone.subtitle")
                    .brutalTypography(.bodyMedium, color: .brutalTextSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 12) {
                // Photos picker for camera roll
                PhotosPicker(
                    selection: $selectedItem,
                    matching: .any(of: [.images, .videos]),
                    photoLibrary: .shared()
                ) {
                    HStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 20, weight: .semibold))
                        Text("upload.source.photo_library")
                            .font(.system(size: 18, weight: .bold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .onChange(of: selectedItem) { _, newItem in
                    if let item = newItem {
                        requestUploadConfirmation(photoItem: item)
                    }
                }

                // File picker for documents
                Button {
                    showFilePicker = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc")
                            .font(.system(size: 20, weight: .semibold))
                        Text("upload.source.browse_files")
                            .font(.system(size: 18, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: Self.supportedTypes,
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }

            Spacer()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 24) {
            Spacer()
            BrutalLoading(text: String(localized: "state.preparing"))
            Spacer()
        }
    }

    private var uploadingView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                // Circular progress
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 8)
                        .frame(width: 100, height: 100)

                    Circle()
                        .trim(from: 0, to: uploadProgress)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 100, height: 100)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.2), value: uploadProgress)

                    Text("\(Int(uploadProgress * 100))%")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }

                Text("upload.progress.title")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(.white)
                    .tracking(2)
            }

            Spacer()

            Button {
                cancelUpload()
            } label: {
                Text("upload.progress.cancel")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.brutalTextSecondary)
            }

            Spacer()
        }
    }

    private var successView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)

                Text("upload.success.title")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(.white)
                    .tracking(2)

                Text("upload.success.link_copied")
                    .brutalTypography(.bodyMedium, color: .brutalTextSecondary)

                // TTL notice for free-tier uploads
                if let record = uploadedRecord, record.isTemporary {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 11))
                        Text("upload.free_tier.ttl_notice")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(Color.brutalWarning)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.brutalWarning.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.brutalWarning.opacity(0.4), lineWidth: 1)
                    )
                }
            }

            if let record = uploadedRecord {
                VStack(spacing: 8) {
                    Text(record.url)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(showCopiedFeedback ? .green : Color.brutalTextTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .animation(.easeInOut(duration: 0.2), value: showCopiedFeedback)

                    Text(showCopiedFeedback ? "upload.success.copied_feedback" : "upload.success.hold_to_copy")
                        .font(.system(.caption2, design: .default))
                        .foregroundStyle(showCopiedFeedback ? .green : Color.brutalTextTertiary.opacity(0.6))
                        .animation(.easeInOut(duration: 0.2), value: showCopiedFeedback)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onLongPressGesture(minimumDuration: 0.5) {
                    copyURLToClipboard(record.url)
                }
            }

            Spacer()

            Button {
                reset()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                    Text("upload.success.button.upload_another")
                        .font(.system(size: 18, weight: .bold))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Spacer()
        }
    }

    private var errorView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)

                Text("upload.failure.title")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(.white)
                    .tracking(2)

                if let error = errorMessage {
                    Text(error)
                        .brutalTypography(.bodyMedium, color: .brutalTextSecondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    if let item = selectedItem {
                        processSelectedPhotoItem(item)
                    } else if let url = selectedFileURL {
                        processSelectedFile(url)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 20, weight: .semibold))
                        Text("upload.failure.button.retry")
                            .font(.system(size: 18, weight: .bold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    reset()
                } label: {
                    Text("upload.failure.button.cancel")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.brutalTextSecondary)
                }
            }

            Spacer()
        }
    }

    // MARK: - Actions

    private func processSelectedPhotoItem(_ item: PhotosPickerItem) {
        uploadState = .loading

        Task {
            do {
                // Load the data
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ImghostError.imageProcessingFailed
                }

                // Determine filename based on content type
                let filename = generateFilenameFromData(data)

                // Apply quality settings
                let (processedData, processedFilename) = UploadQualityService.shared.processForUpload(
                    data: data,
                    filename: filename
                )

                await performUpload(data: processedData, filename: processedFilename)

            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    uploadState = .error
                }
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            requestUploadConfirmation(fileURL: url)
        case .failure(let error):
            errorMessage = error.localizedDescription
            uploadState = .error
        }
    }

    private func requestUploadConfirmation(photoItem: PhotosPickerItem? = nil, fileURL: URL? = nil) {
        guard UploadQualityService.shared.confirmBeforeUpload else {
            if let item = photoItem { processSelectedPhotoItem(item) }
            else if let url = fileURL { processSelectedFile(url) }
            return
        }

        if let url = fileURL {
            confirmMessage = String(format: String(localized: "upload.confirm.file"), url.lastPathComponent)
            pendingFileURL = url
            pendingPhotoItem = nil
        } else {
            confirmMessage = String(localized: "upload.confirm.photo")
            pendingPhotoItem = photoItem
            pendingFileURL = nil
        }
        showUploadConfirm = true
    }

    private func processSelectedFile(_ url: URL) {
        selectedFileURL = url
        uploadState = .loading

        Task {
            do {
                // Start accessing security-scoped resource
                guard url.startAccessingSecurityScopedResource() else {
                    throw ImghostError.imageProcessingFailed
                }
                defer { url.stopAccessingSecurityScopedResource() }

                // Read file data
                let data = try Data(contentsOf: url)
                let filename = url.lastPathComponent

                // Apply quality settings
                let (processedData, processedFilename) = UploadQualityService.shared.processForUpload(
                    data: data,
                    filename: filename
                )

                await performUpload(data: processedData, filename: processedFilename)

            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    uploadState = .error
                }
            }
        }
    }

    private func performUpload(data: Data, filename: String) async {
        await MainActor.run {
            uploadState = .uploading
            uploadProgress = 0
        }

        do {
            let record = try await UploadService.shared.upload(
                imageData: data,
                filename: filename
            ) { progress in
                Task { @MainActor in
                    uploadProgress = progress
                }
            }

            // Copy formatted URL to clipboard
            let formattedLink = LinkFormatService.shared.format(
                url: record.url,
                filename: record.originalFilename
            )
            await MainActor.run {
                UIPasteboard.general.string = formattedLink
            }

            // Play haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)

            // Save to history
            try? HistoryService.shared.save(record)

            let shouldReview = ReviewRequestService.shared.recordSuccessfulUpload()

            await MainActor.run {
                uploadedRecord = record
                uploadState = .success

                if shouldReview {
                    requestReview()
                }
            }

        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                uploadState = .error
            }
        }
    }

    private func generateFilenameFromData(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        let timestamp = Int(Date().timeIntervalSince1970)

        // Video detection
        if data.count >= 8 {
            let ftypBytes = [UInt8](data[4..<8])
            if ftypBytes == [0x66, 0x74, 0x79, 0x70] { // "ftyp"
                if data.count >= 12 {
                    let brandBytes = [UInt8](data[8..<12])
                    let brand = String(bytes: brandBytes, encoding: .ascii) ?? ""
                    if brand.hasPrefix("qt") {
                        return "video_\(timestamp).mov"
                    } else if brand.hasPrefix("M4V") {
                        return "video_\(timestamp).m4v"
                    }
                }
                return "video_\(timestamp).mp4"
            }
        }
        
        // WebM
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            return "video_\(timestamp).webm"
        }
        
        // AVI
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) && data.count > 12 {
            let typeBytes = [UInt8](data[8..<12])
            if typeBytes == [0x41, 0x56, 0x49, 0x20] {
                return "video_\(timestamp).avi"
            }
            if typeBytes == [0x57, 0x45, 0x42, 0x50] {
                return "upload_\(timestamp).webp"
            }
        }

        // Image detection
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "upload_\(timestamp).png"
        }
        if bytes.starts(with: [0x47, 0x49, 0x46]) {
            return "upload_\(timestamp).gif"
        }
        if bytes.count >= 12 && bytes[4...11] == [0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63] {
            return "upload_\(timestamp).heic"
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "upload_\(timestamp).jpg"
        }
        
        // PDF
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            return "document_\(timestamp).pdf"
        }
        
        // ZIP
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            return "archive_\(timestamp).zip"
        }
        
        // GZIP
        if bytes.starts(with: [0x1F, 0x8B]) {
            return "archive_\(timestamp).gz"
        }
        
        // MP3
        if bytes.starts(with: [0x49, 0x44, 0x33]) || bytes.starts(with: [0xFF, 0xFB]) {
            return "audio_\(timestamp).mp3"
        }
        
        // WAV
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) && data.count > 12 {
            let typeBytes = [UInt8](data[8..<12])
            if typeBytes == [0x57, 0x41, 0x56, 0x45] {
                return "audio_\(timestamp).wav"
            }
        }

        // Default to binary
        return "file_\(timestamp).bin"
    }

    private func cancelUpload() {
        UploadService.shared.cancelUpload()
        reset()
    }

    private func reset() {
        selectedItem = nil
        selectedFileURL = nil
        uploadState = .idle
        uploadProgress = 0
        errorMessage = nil
        uploadedRecord = nil
        showCopiedFeedback = false
    }

    private func copyURLToClipboard(_ url: String) {
        UIPasteboard.general.string = url
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        showCopiedFeedback = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedFeedback = false
        }
    }
}

#Preview {
    UploadView()
}
