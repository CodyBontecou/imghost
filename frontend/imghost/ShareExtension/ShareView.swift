import SwiftUI
import UIKit
import AVFoundation

/// Upload status for individual items
enum ItemUploadStatus: Equatable {
    case pending
    case uploading(progress: Double)
    case compressing(progress: Double)
    case success(url: String)
    case failed(error: String)
}

/// Wrapper for SharedItem with upload state
class UploadableItem: Identifiable, ObservableObject {
    let id: UUID
    let sharedItem: SharedItem
    @Published var thumbnail: UIImage?
    @Published var status: ItemUploadStatus = .pending
    @Published var uploadedURL: String?
    
    init(sharedItem: SharedItem) {
        self.id = sharedItem.id
        self.sharedItem = sharedItem
        self.thumbnail = sharedItem.thumbnail
    }
    
    var filename: String { sharedItem.filename }
    var fileURL: URL { sharedItem.fileURL }
    var fileSize: Int64 { sharedItem.fileSize }
    var fileSizeMB: Double { sharedItem.fileSizeMB }
    var isVideo: Bool { sharedItem.isVideo }
}

struct ShareView: View {
    let extensionContext: NSExtensionContext?
    let loadAllItems: () async throws -> [SharedItem]

    @State private var state: ShareState = .loading
    @State private var items: [UploadableItem] = []
    @State private var errorMessage: String = ""
    @State private var currentUser: User?
    @State private var storageWarning: String?
    @State private var wouldExceedStorage: Bool = false
    @State private var uploadedURLs: [String] = []
    @State private var currentUploadIndex: Int = 0
    @State private var overallProgress: Double = 0
    @State private var selectedQuality: UploadQuality = UploadQualityService.shared.currentQuality
    
    private var maxUploadSize: Int64 { Config.maxUploadSizeBytes }
    private let largeFileThreshold: Int64 = 50 * 1024 * 1024
    
    private var totalSizeMB: Double {
        items.reduce(0) { $0 + $1.fileSizeMB }
    }
    
    private var totalSizeBytes: Int {
        items.reduce(0) { $0 + Int($1.fileSize) }
    }
    
    private var successCount: Int {
        items.filter { if case .success = $0.status { return true } else { return false } }.count
    }
    
    private var failedCount: Int {
        items.filter { if case .failed = $0.status { return true } else { return false } }.count
    }
    
    private var isAnyItemTooLarge: Bool {
        items.contains { $0.fileSize > maxUploadSize }
    }

    private enum ShareState {
        case loading
        case ready
        case uploading
        case success
        case error
        case notConfigured
        case sessionExpired
        case storageFull
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            switch state {
            case .loading:
                loadingView
            case .ready:
                readyView
            case .uploading:
                uploadingView
            case .success:
                successView
            case .error:
                errorView
            case .notConfigured:
                notConfiguredView
            case .sessionExpired:
                sessionExpiredView
            case .storageFull:
                storageFullView
            }
        }
        .onAppear {
            prepareUpload()
        }
    }

    // MARK: - State Views

    private var loadingView: some View {
        VStack {
            Spacer()
            Text("share.state.loading")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(3)
            Spacer()
        }
    }

    private var readyView: some View {
        VStack(spacing: 0) {
            // Header
            header(title: items.count == 1
                ? (items.first?.filename ?? "FILE")
                : String(format: String(localized: "share.preview.item_count_plural"), items.count))
            
            // Preview area
            previewSection
            
            // Info & Controls
            VStack(spacing: 0) {
                // File info bar
                HStack {
                    Text(verbatim: items.count == 1
                        ? String(format: String(localized: "share.preview.item_count_singular"), items.count)
                        : String(format: String(localized: "share.preview.item_count_plural"), items.count))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                    
                    Spacer()
                    
                    Text(verbatim: String(format: String(localized: "share.preview.total_size"), totalSizeMB))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(.white.opacity(0.1)), alignment: .top)
                
                // Quality is set in the app's Settings — no per-upload picker shown here
                
                // Large file warning
                if isAnyItemTooLarge {
                    HStack(spacing: 12) {
                        Text("!")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                        Text("share.preview.warning.exceeds_limit")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .tracking(1)
                        Spacer()
                    }
                    .foregroundStyle(Color(hex: "FF453A"))
                    .padding(16)
                    .background(Color(hex: "FF453A").opacity(0.1))
                    .overlay(Rectangle().stroke(Color(hex: "FF453A").opacity(0.3), lineWidth: 1))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }

                // Storage warning
                if let warning = storageWarning {
                    HStack(spacing: 12) {
                        Text("!")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                        Text(warning.uppercased())
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .tracking(1)
                        Spacer()
                    }
                    .foregroundStyle(Color(hex: "FF453A"))
                    .padding(16)
                    .background(Color(hex: "FF453A").opacity(0.1))
                    .overlay(Rectangle().stroke(Color(hex: "FF453A").opacity(0.3), lineWidth: 1))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
            
            // Action buttons
            actionButtons
        }
    }
    
    private var hasImageItems: Bool {
        items.contains { item in
            let lowercased = item.filename.lowercased()
            return lowercased.hasSuffix(".jpg") || lowercased.hasSuffix(".jpeg") ||
                   lowercased.hasSuffix(".png") || lowercased.hasSuffix(".gif") ||
                   lowercased.hasSuffix(".heic") || lowercased.hasSuffix(".webp")
        }
    }
    
    private func header(title: String) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Text("button.cancel")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .tracking(1)
            }
            
            Spacer()
            
            Text(verbatim: title.uppercased())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .tracking(1)
                .lineLimit(1)
            
            Spacer()
            
            // Invisible spacer to balance
            Text("button.cancel")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.clear)
                .tracking(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.white.opacity(0.1)), alignment: .bottom)
    }
    
    private var previewSection: some View {
        GeometryReader { geo in
            if items.count == 1, let item = items.first {
                // Single item - large preview
                singleItemPreview(item: item, size: geo.size)
            } else {
                // Multiple items - grid
                multiItemGrid(size: geo.size)
            }
        }
    }
    
    private func singleItemPreview(item: UploadableItem, size: CGSize) -> some View {
        ZStack {
            if let thumbnail = item.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: size.width, maxHeight: size.height)
                
                if item.isVideo {
                    // Play button overlay
                    Circle()
                        .fill(.black.opacity(0.5))
                        .frame(width: 72, height: 72)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white)
                                .offset(x: 2)
                        )
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: fileIcon(for: item.filename))
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.2))
                    
                    Text(item.filename.uppercased())
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                        .tracking(1)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func multiItemGrid(size: CGSize) -> some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 4),
                GridItem(.flexible(), spacing: 4),
                GridItem(.flexible(), spacing: 4)
            ], spacing: 4) {
                ForEach(items) { item in
                    itemThumbnail(item: item)
                        .aspectRatio(1, contentMode: .fill)
                }
            }
            .padding(4)
        }
    }
    
    private func itemThumbnail(item: UploadableItem) -> some View {
        ZStack {
            if let thumbnail = item.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
                
                if item.isVideo {
                    // Play icon overlay
                    Circle()
                        .fill(.black.opacity(0.5))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.white)
                                .offset(x: 1)
                        )
                }
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: fileIcon(for: item.filename))
                                .font(.system(size: 24))
                                .foregroundStyle(.white.opacity(0.3))
                            
                            Text(fileExtension(for: item.filename).uppercased())
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    )
            }
            
            // Size badge
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(String(format: "%.1fMB", item.fileSizeMB))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.6))
                }
            }
            
            // Too large warning
            if item.fileSize > maxUploadSize {
                Rectangle()
                    .fill(Color(hex: "FF453A").opacity(0.3))
                    .overlay(
                        Text("share.preview.item.too_large")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(hex: "FF453A"))
                    )
            }
        }
    }
    
    private var qualitySection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("share.preview.quality_label")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .tracking(2)
                
                Spacer()
            }

            qualityPicker
        }
    }
    
    private var qualityPicker: some View {
        HStack(spacing: 0) {
            ForEach(UploadQuality.allCases) { quality in
                qualityButton(for: quality)
            }
        }
        .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
    }
    
    private func qualityButton(for quality: UploadQuality) -> some View {
        let isSelected = selectedQuality == quality
        
        return Button {
            selectedQuality = quality
        } label: {
            Text(quality.displayLabel.uppercased())
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .tracking(1)
                .foregroundStyle(isSelected ? .black : .white.opacity(0.5))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(isSelected ? Color.white : Color.clear)
        }
    }
    
    private var actionButtons: some View {
        VStack(spacing: 0) {
            Button {
                startUpload()
            } label: {
                Text(verbatim: validItemCount == 1
                    ? String(format: String(localized: "share.preview.button.upload_singular"), validItemCount)
                    : String(format: String(localized: "share.preview.button.upload_plural"), validItemCount))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(wouldExceedStorage || validItemCount == 0 ? Color.white.opacity(0.3) : Color.white)
            }
            .disabled(wouldExceedStorage || validItemCount == 0)
        }
    }
    
    private var validItemCount: Int {
        items.filter { $0.fileSize <= maxUploadSize }.count
    }

    private var uploadingView: some View {
        VStack(spacing: 0) {
            header(title: String(localized: "share.state.uploading"))
            
            // Items with status
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        uploadingItemRow(item: item)
                    }
                }
            }
            
            // Overall progress section
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.white.opacity(0.1))
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: geo.size.width * overallProgress)
                        }
                    }
                    .frame(height: 4)
                    
                    HStack {
                        Text("\(successCount)/\(validItemCount)")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                        
                        Spacer()
                        
                        Text("\(Int(overallProgress * 100))%")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 20)
                
                Button {
                    UploadService.shared.cancelUpload()
                    dismiss()
                } label: {
                    Text("share.upload.button.cancel")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(hex: "FF453A"))
                        .tracking(2)
                        .frame(height: 44)
                }
            }
            .padding(.bottom, 40)
        }
    }
    
    private func uploadingItemRow(item: UploadableItem) -> some View {
        HStack(spacing: 12) {
            // Thumbnail
            if let thumbnail = item.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: fileIcon(for: item.filename))
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.3))
                    )
            }
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                
                Text(String(format: "%.1f MB", item.fileSizeMB))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
            
            Spacer()
            
            // Status
            statusIndicator(for: item.status)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.white.opacity(0.1)), alignment: .bottom)
    }
    
    @ViewBuilder
    private func statusIndicator(for status: ItemUploadStatus) -> some View {
        switch status {
        case .pending:
            Text("—")
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.2))
        case .uploading(let progress):
            Text("\(Int(progress * 100))%")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
        case .compressing:
            Text("...")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(hex: "FFD60A"))
        case .success:
            Text("✓")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color(hex: "30D158"))
        case .failed:
            Text("!")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color(hex: "FF453A"))
        }
    }

    private var successView: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 32) {
                Text("✓")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(Color(hex: "30D158"))
                
                VStack(spacing: 12) {
                    if failedCount > 0 {
                        Text(verbatim: String(format: String(localized: "share.result.partial"), successCount, failedCount))
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .tracking(2)
                    } else {
                        Text(successCount == 1
                            ? "share.result.copied_single"
                            : String(format: String(localized: "share.result.copied_plural"), successCount) as LocalizedStringKey)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .tracking(2)
                    }
                    
                    if uploadedURLs.count == 1, let url = uploadedURLs.first {
                        Text(verbatim: url)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    } else if uploadedURLs.count > 1 {
                        Text(verbatim: String(format: String(localized: "share.result.links_count"), uploadedURLs.count))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            
            Spacer()
            
            Button {
                dismiss()
            } label: {
                Text("share.result.button.done")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color.white)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                dismiss()
            }
        }
    }

    private var errorView: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 32) {
                Text("!")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(Color(hex: "FF453A"))
                
                VStack(spacing: 16) {
                    Text("share.failed.title")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .tracking(2)
                    
                    // Error message box
                    ScrollView {
                        Text(errorMessage)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 120)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background(Color.white.opacity(0.05))
                    .overlay(Rectangle().stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .padding(.horizontal, 20)
                }
            }
            
            Spacer()
            
            VStack(spacing: 0) {
                Button {
                    // Reset item statuses before retry
                    for item in items {
                        item.status = .pending
                    }
                    state = .ready
                } label: {
                    Text("share.failed.button.retry")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.white)
                }
                
                Button {
                    dismiss()
                } label: {
                    Text("share.failed.button.cancel")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .tracking(2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                }
            }
        }
    }

    private var notConfiguredView: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 32) {
                Text("?")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(Color(hex: "FFD60A"))
                
                VStack(spacing: 12) {
                    Text("share.not_logged_in.title")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .tracking(2)
                    
                    Text("share.not_logged_in.message")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
            
            Spacer()
            
            VStack(spacing: 0) {
                Button {
                    openMainApp()
                } label: {
                    Text("share.not_logged_in.button.open_app")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.white)
                }
                
                Button {
                    dismiss()
                } label: {
                    Text("share.not_logged_in.button.cancel")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .tracking(2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                }
            }
        }
    }

    private var sessionExpiredView: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 32) {
                Text("!")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(Color(hex: "FF9500"))
                
                VStack(spacing: 12) {
                    Text("share.session_expired.title")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .tracking(2)
                    
                    Text("share.session_expired.message")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
            
            Spacer()
            
            VStack(spacing: 0) {
                Button {
                    openMainApp()
                } label: {
                    Text("share.session_expired.button.open_app")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.white)
                }
                
                Button {
                    dismiss()
                } label: {
                    Text("share.session_expired.button.cancel")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .tracking(2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                }
            }
        }
    }

    private var storageFullView: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 32) {
                Text("X")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(Color(hex: "FF453A"))
                
                VStack(spacing: 16) {
                    Text("share.storage_full.title")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .tracking(2)
                    
                    if let user = currentUser {
                        VStack(spacing: 8) {
                            Text(verbatim: String(format: String(localized: "share.storage_full.usage_format"), user.storageUsedFormatted, user.storageLimitFormatted))
                                .font(.system(size: 16, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                            
                            Text(verbatim: String(format: String(localized: "share.storage_full.need_more"), totalSizeMB))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    
                    Text("share.storage_full.cta")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
            
            Spacer()
            
            Button {
                dismiss()
            } label: {
                Text("share.storage_full.button.done")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color.white)
            }
        }
    }

    // MARK: - Actions

    private func prepareUpload() {
        guard UploadService.shared.isConfigured else {
            state = .notConfigured
            return
        }

        state = .loading

        Task {
            do {
                let user = try await AuthService.shared.getCurrentUser()
                let sharedItems = try await loadAllItems()
                
                // Create uploadable items
                let uploadableItems = sharedItems.map { UploadableItem(sharedItem: $0) }
                
                await MainActor.run {
                    currentUser = user
                    items = uploadableItems
                }
                
                // Generate thumbnails in background
                await generateThumbnails()
                
                // Check storage
                await MainActor.run {
                    if !user.canUpload(bytes: totalSizeBytes) {
                        state = .storageFull
                    } else {
                        updateStorageWarning()
                        state = .ready
                    }
                }
            } catch let error as AuthError {
                await MainActor.run {
                    // Check for session-related errors
                    switch error {
                    case .sessionExpired, .refreshFailed, .noRefreshToken, .notAuthenticated:
                        state = .sessionExpired
                    default:
                        errorMessage = error.localizedDescription
                        state = .error
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    state = .error
                }
            }
        }
    }
    
    private func generateThumbnails() async {
        await withTaskGroup(of: (UUID, UIImage?).self) { group in
            for item in items {
                group.addTask {
                    if item.isVideo {
                        let thumbnail = await self.generateVideoThumbnail(fileURL: item.fileURL)
                        return (item.id, thumbnail)
                    } else {
                        let thumbnail = self.generateImageThumbnail(fileURL: item.fileURL)
                        return (item.id, thumbnail)
                    }
                }
            }
            
            for await (id, thumbnail) in group {
                await MainActor.run {
                    if let index = items.firstIndex(where: { $0.id == id }) {
                        items[index].thumbnail = thumbnail
                    }
                }
            }
        }
    }
    
    private func generateImageThumbnail(fileURL: URL) -> UIImage? {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }
    
    private func generateVideoThumbnail(fileURL: URL) async -> UIImage? {
        let asset = AVURLAsset(url: fileURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 400, height: 400)
        
        do {
            let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }
    
    private func updateStorageWarning() {
        guard let user = currentUser else { return }
        
        wouldExceedStorage = !user.canUpload(bytes: totalSizeBytes)
        storageWarning = wouldExceedStorage ? String(format: String(localized: "share.preview.storage_warning"), user.storageRemainingFormatted) : nil
    }

    private func startUpload() {
        state = .uploading
        overallProgress = 0
        uploadedURLs = []
        
        // Filter out items that are too large
        let validItems = items.filter { $0.fileSize <= maxUploadSize }
        let totalItems = validItems.count
        
        Task {
            var successfulUploads: [String] = []
            
            for (index, item) in validItems.enumerated() {
                await MainActor.run {
                    currentUploadIndex = index
                    item.status = .uploading(progress: 0)
                }
                
                do {
                    let record = try await uploadItem(item: item) { progress in
                        Task { @MainActor in
                            item.status = .uploading(progress: progress)
                            // Overall progress: completed items + current item progress
                            let completedProgress = Double(index) / Double(totalItems)
                            let currentItemProgress = progress / Double(totalItems)
                            overallProgress = completedProgress + currentItemProgress
                        }
                    }
                    
                    await MainActor.run {
                        item.status = .success(url: record.url)
                        item.uploadedURL = record.url
                        successfulUploads.append(record.url)
                    }
                    
                    // Save to history
                    try? HistoryService.shared.save(record)
                    
                } catch {
                    await MainActor.run {
                        item.status = .failed(error: error.localizedDescription)
                    }
                }
            }
            
            // Mark items that were too large as failed
            for item in items where item.fileSize > maxUploadSize {
                await MainActor.run {
                    item.status = .failed(error: String(localized: "share.preview.file_too_large"))
                }
            }
            
            await MainActor.run {
                uploadedURLs = successfulUploads
                overallProgress = 1.0
                
                // Check if all uploads failed
                if successfulUploads.isEmpty {
                    // Get the first failure message for display
                    let firstFailure = items.compactMap { item -> String? in
                        if case .failed(let error) = item.status {
                            return error
                        }
                        return nil
                    }.first ?? "Unknown error"
                    
                    errorMessage = firstFailure
                    
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.error)
                    
                    state = .error
                    return
                }
                
                // Copy to clipboard
                if successfulUploads.count == 1, let record = items.first(where: { $0.uploadedURL != nil }) {
                    let formattedLink = LinkFormatService.shared.format(url: record.uploadedURL!, filename: record.filename)
                    UIPasteboard.general.string = formattedLink
                } else {
                    // Multiple URLs - join with newlines
                    let formattedLinks = items.compactMap { item -> String? in
                        guard let url = item.uploadedURL else { return nil }
                        return LinkFormatService.shared.format(url: url, filename: item.filename)
                    }
                    UIPasteboard.general.string = formattedLinks.joined(separator: "\n")
                }
                
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                
                state = .success
            }
        }
    }
    
    private func uploadItem(item: UploadableItem, progressHandler: @escaping (Double) -> Void) async throws -> UploadRecord {
        let fileURL = item.fileURL
        let filename = item.filename
        
        // Check if we need to process the image for quality
        let lowercased = filename.lowercased()
        let isImage = lowercased.hasSuffix(".jpg") || lowercased.hasSuffix(".jpeg") ||
                      lowercased.hasSuffix(".png") || lowercased.hasSuffix(".gif") ||
                      lowercased.hasSuffix(".heic") || lowercased.hasSuffix(".webp")
        
        if isImage && selectedQuality != .original && item.fileSize < 50 * 1024 * 1024 {
            // Load data and process
            let data = try Data(contentsOf: fileURL)
            let (processedData, processedFilename) = UploadQualityService.shared.processForUpload(
                data: data,
                filename: filename,
                quality: selectedQuality
            )
            return try await UploadService.shared.upload(
                imageData: processedData,
                filename: processedFilename,
                progressHandler: progressHandler
            )
        } else {
            // Upload file directly
            return try await UploadService.shared.uploadFromFile(
                fileURL: fileURL,
                filename: filename,
                progressHandler: progressHandler
            )
        }
    }

    private func fileIcon(for filename: String) -> String {
        let lowercased = filename.lowercased()
        
        if lowercased.hasSuffix(".jpg") || lowercased.hasSuffix(".jpeg") || lowercased.hasSuffix(".png") || lowercased.hasSuffix(".gif") || lowercased.hasSuffix(".heic") || lowercased.hasSuffix(".webp") { return "photo" }
        if lowercased.hasSuffix(".mp4") || lowercased.hasSuffix(".mov") || lowercased.hasSuffix(".avi") || lowercased.hasSuffix(".mkv") || lowercased.hasSuffix(".webm") { return "film" }
        if lowercased.hasSuffix(".mp3") || lowercased.hasSuffix(".wav") || lowercased.hasSuffix(".m4a") || lowercased.hasSuffix(".aac") || lowercased.hasSuffix(".flac") { return "waveform" }
        if lowercased.hasSuffix(".pdf") { return "doc.richtext" }
        if lowercased.hasSuffix(".doc") || lowercased.hasSuffix(".docx") { return "doc.text" }
        if lowercased.hasSuffix(".xls") || lowercased.hasSuffix(".xlsx") { return "tablecells" }
        if lowercased.hasSuffix(".zip") || lowercased.hasSuffix(".gz") || lowercased.hasSuffix(".tar") || lowercased.hasSuffix(".rar") { return "doc.zipper" }
        if lowercased.hasSuffix(".json") || lowercased.hasSuffix(".xml") || lowercased.hasSuffix(".html") || lowercased.hasSuffix(".css") || lowercased.hasSuffix(".js") { return "curlybraces" }
        
        return "doc"
    }
    
    private func fileExtension(for filename: String) -> String {
        let parts = filename.split(separator: ".")
        return parts.count > 1 ? String(parts.last!) : ""
    }

    private func openMainApp() {
        // Open the main app via URL scheme for login
        guard let url = URL(string: "imghost://login") else {
            dismiss()
            return
        }

        // Share extensions use extensionContext to open URLs
        extensionContext?.open(url) { success in
            // Dismiss the share sheet after opening the app
            self.dismiss()
        }
    }

    private func dismiss() {
        // Clean up temp files
        for item in items {
            try? FileManager.default.removeItem(at: item.fileURL)
        }
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}

// MARK: - Extensions

extension UploadQuality {
    var displayLabel: String {
        switch self {
        case .original: return "Full"
        case .high: return "High"
        case .medium: return "Med"
        case .low: return "Low"
        }
    }
}

extension UploadQualityService.VideoQualityPreset {
    var displayLabel: String {
        switch self {
        case .high: return "High"
        case .medium: return "Med"
        case .low: return "Low"
        case .veryLow: return "Min"
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

#Preview {
    ShareView(
        extensionContext: nil,
        loadAllItems: {
            [
                SharedItem(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("test1.png"),
                          filename: "test1.png", fileSize: 1024 * 1024, thumbnail: nil, isVideo: false, videoDuration: nil, dimensions: nil),
                SharedItem(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("test2.jpg"),
                          filename: "test2.jpg", fileSize: 2048 * 1024, thumbnail: nil, isVideo: false, videoDuration: nil, dimensions: nil),
                SharedItem(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("video.mp4"),
                          filename: "video.mp4", fileSize: 5 * 1024 * 1024, thumbnail: nil, isVideo: true, videoDuration: 30, dimensions: nil)
            ]
        }
    )
}
