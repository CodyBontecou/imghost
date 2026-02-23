import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct MediaView: View {
    // MARK: - History State
    @State private var records: [UploadRecord] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var deletingIds: Set<String> = []
    @State private var selectedRecord: UploadRecord?

    // MARK: - Upload State
    @State private var selectedItem: PhotosPickerItem?
    @State private var showFilePicker = false
    @State private var selectedFileURL: URL?
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var uploadState: UploadState = .idle
    @State private var uploadErrorMessage: String?
    @State private var uploadedRecord: UploadRecord?
    @State private var showCopiedFeedback = false
    @State private var showUploadOptions = false
    @State private var showPhotoPicker = false

    // Supported file types
    private static let supportedTypes: [UTType] = [
        .image, .jpeg, .png, .gif, .webP, .heic, .heif, .bmp, .tiff, .svg, .ico,
        .movie, .video, .mpeg4Movie, .quickTimeMovie, .avi,
        .audio, .mp3, .wav, .aiff, .mpeg4Audio,
        .pdf, .plainText, .rtf, .html,
        .zip, .gzip,
        .json, .xml,
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

                VStack(spacing: 0) {
                    // Upload progress banner
                    uploadBanner

                    // Main content
                    Group {
                        if isLoading {
                            BrutalLoading(text: "Loading")
                        } else if let error = errorMessage {
                            BrutalEmptyState(
                                title: "Something went wrong",
                                subtitle: error,
                                action: loadHistory,
                                actionTitle: "Retry"
                            )
                        } else if records.isEmpty {
                            emptyStateView
                        } else {
                            PhotoGridView(
                                records: records,
                                onSelect: { record in
                                    selectedRecord = record
                                },
                                onDelete: { record in
                                    deleteRecord(record)
                                }
                            )
                            .refreshable {
                                loadHistory()
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }

                // Floating upload button
                if uploadState == .idle || uploadState == .success || uploadState == .error {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            uploadFAB
                                .padding(.trailing, 20)
                                .padding(.bottom, 20)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("MEDIA")
                        .brutalTypography(.mono)
                        .tracking(2)
                }
            }
            .toolbarBackground(Color.brutalBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selectedRecord) { record in
                UploadDetailView(record: record, onDelete: {
                    deleteRecord(record)
                })
            }
            .onAppear {
                loadHistory()
            }
            .preferredColorScheme(.dark)
            .confirmationDialog("Upload", isPresented: $showUploadOptions, titleVisibility: .hidden) {
                Button("Photo Library") {
                    showPhotoPicker = true
                }
                Button("Browse Files") {
                    showFilePicker = true
                }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $selectedItem,
                matching: .any(of: [.images, .videos]),
                photoLibrary: .shared()
            )
            .onChange(of: selectedItem) { _, newItem in
                if let item = newItem {
                    processSelectedPhotoItem(item)
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: Self.supportedTypes,
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Color.brutalTextTertiary)

                Text("NO\nMEDIA\nYET")
                    .font(.system(size: 48, weight: .black))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                VStack(spacing: 8) {
                    Text("Tap + to upload your first file.")
                        .brutalTypography(.bodyMedium, color: .brutalTextSecondary)
                        .multilineTextAlignment(.center)

                    Text("Images, videos, documents, and more.")
                        .brutalTypography(.bodyMedium, color: .brutalTextTertiary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()
            Spacer()
        }
        .padding(32)
    }

    // MARK: - Upload FAB

    private var uploadFAB: some View {
        Button {
            showUploadOptions = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 56, height: 56)
                .background(Color.white)
                .clipShape(Circle())
                .shadow(color: .white.opacity(0.15), radius: 8, y: 4)
        }
    }

    // MARK: - Upload Banner

    @ViewBuilder
    private var uploadBanner: some View {
        switch uploadState {
        case .idle:
            EmptyView()

        case .loading:
            uploadBannerContainer {
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                    Text("PREPARING...")
                        .brutalTypography(.monoSmall)
                        .tracking(1)
                    Spacer()
                }
            }

        case .uploading:
            uploadBannerContainer {
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Text("UPLOADING")
                            .brutalTypography(.monoSmall)
                            .tracking(1)
                        Spacer()
                        Text("\(Int(uploadProgress * 100))%")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                        Button {
                            cancelUpload()
                        } label: {
                            Text("✕")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.brutalTextSecondary)
                        }
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.brutalBorder)
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: geo.size.width * uploadProgress)
                                .animation(.easeInOut(duration: 0.2), value: uploadProgress)
                        }
                    }
                    .frame(height: 3)
                }
            }

        case .success:
            uploadBannerContainer {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.green)

                    Text(showCopiedFeedback ? "LINK COPIED" : "UPLOADED")
                        .brutalTypography(.monoSmall, color: .brutalSuccess)
                        .tracking(1)

                    Spacer()

                    Button {
                        dismissUploadBanner()
                    } label: {
                        Text("✕")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.brutalTextSecondary)
                    }
                }
            }
            .onAppear {
                // Auto-dismiss success banner after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if uploadState == .success {
                        dismissUploadBanner()
                    }
                }
            }

        case .error:
            uploadBannerContainer {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.orange)

                    Text("FAILED")
                        .brutalTypography(.monoSmall, color: .brutalError)
                        .tracking(1)

                    if let err = uploadErrorMessage {
                        Text(err)
                            .brutalTypography(.bodySmall, color: .brutalTextTertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        retryUpload()
                    } label: {
                        Text("RETRY")
                            .brutalTypography(.monoSmall)
                            .tracking(1)
                    }

                    Button {
                        dismissUploadBanner()
                    } label: {
                        Text("✕")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.brutalTextSecondary)
                    }
                }
            }
        }
    }

    private func uploadBannerContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.brutalSurface)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(Color.brutalBorder),
                alignment: .bottom
            )
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: uploadState)
    }

    // MARK: - History Actions

    private func loadHistory() {
        isLoading = true
        errorMessage = nil

        do {
            records = try HistoryService.shared.loadAll()
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func deleteRecord(_ record: UploadRecord) {
        deletingIds.insert(record.id)

        Task {
            do {
                try await UploadService.shared.delete(record: record)
            } catch {
                print("Server delete failed: \(error)")
            }

            do {
                try HistoryService.shared.delete(id: record.id)
                await MainActor.run {
                    records.removeAll { $0.id == record.id }
                    deletingIds.remove(record.id)
                }
            } catch {
                await MainActor.run {
                    deletingIds.remove(record.id)
                }
            }
        }
    }

    // MARK: - Upload Actions

    private func processSelectedPhotoItem(_ item: PhotosPickerItem) {
        uploadState = .loading

        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ImghostError.imageProcessingFailed
                }

                let filename = generateFilenameFromData(data)

                let (processedData, processedFilename) = UploadQualityService.shared.processForUpload(
                    data: data,
                    filename: filename
                )

                await performUpload(data: processedData, filename: processedFilename)

            } catch {
                await MainActor.run {
                    uploadErrorMessage = error.localizedDescription
                    uploadState = .error
                }
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            processSelectedFile(url)
        case .failure(let error):
            uploadErrorMessage = error.localizedDescription
            uploadState = .error
        }
    }

    private func processSelectedFile(_ url: URL) {
        selectedFileURL = url
        uploadState = .loading

        Task {
            do {
                guard url.startAccessingSecurityScopedResource() else {
                    throw ImghostError.imageProcessingFailed
                }
                defer { url.stopAccessingSecurityScopedResource() }

                let data = try Data(contentsOf: url)
                let filename = url.lastPathComponent

                let (processedData, processedFilename) = UploadQualityService.shared.processForUpload(
                    data: data,
                    filename: filename
                )

                await performUpload(data: processedData, filename: processedFilename)

            } catch {
                await MainActor.run {
                    uploadErrorMessage = error.localizedDescription
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

            await MainActor.run {
                uploadedRecord = record
                showCopiedFeedback = true
                uploadState = .success

                // Reload history to show new upload at top
                loadHistory()
            }

        } catch {
            await MainActor.run {
                uploadErrorMessage = error.localizedDescription
                uploadState = .error
            }
        }
    }

    private func cancelUpload() {
        UploadService.shared.cancelUpload()
        dismissUploadBanner()
    }

    private func retryUpload() {
        if let item = selectedItem {
            processSelectedPhotoItem(item)
        } else if let url = selectedFileURL {
            processSelectedFile(url)
        }
    }

    private func dismissUploadBanner() {
        withAnimation {
            selectedItem = nil
            selectedFileURL = nil
            uploadState = .idle
            uploadProgress = 0
            uploadErrorMessage = nil
            uploadedRecord = nil
            showCopiedFeedback = false
        }
    }

    private func generateFilenameFromData(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        let timestamp = Int(Date().timeIntervalSince1970)

        // Video detection
        if data.count >= 8 {
            let ftypBytes = [UInt8](data[4..<8])
            if ftypBytes == [0x66, 0x74, 0x79, 0x70] {
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

        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            return "video_\(timestamp).webm"
        }

        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) && data.count > 12 {
            let typeBytes = [UInt8](data[8..<12])
            if typeBytes == [0x41, 0x56, 0x49, 0x20] {
                return "video_\(timestamp).avi"
            }
            if typeBytes == [0x57, 0x45, 0x42, 0x50] {
                return "upload_\(timestamp).webp"
            }
        }

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

        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            return "document_\(timestamp).pdf"
        }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            return "archive_\(timestamp).zip"
        }
        if bytes.starts(with: [0x1F, 0x8B]) {
            return "archive_\(timestamp).gz"
        }
        if bytes.starts(with: [0x49, 0x44, 0x33]) || bytes.starts(with: [0xFF, 0xFB]) {
            return "audio_\(timestamp).mp3"
        }
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) && data.count > 12 {
            let typeBytes = [UInt8](data[8..<12])
            if typeBytes == [0x57, 0x41, 0x56, 0x45] {
                return "audio_\(timestamp).wav"
            }
        }

        return "file_\(timestamp).bin"
    }
}

#Preview {
    MediaView()
}
