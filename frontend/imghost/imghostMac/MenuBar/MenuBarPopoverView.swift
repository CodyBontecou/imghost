import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Menu Bar Popover View

struct MenuBarPopoverView: View {
    @EnvironmentObject var authState: AuthState

    let onDismiss: () -> Void
    let onShowMainWindow: () -> Void

    @State private var recentUploads: [UploadRecord] = []
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var uploadFileName: String?
    @State private var lastCopiedId: String?
    @State private var isSyncing = false
    @State private var statusMessage: String?

    private let historyService = HistoryService.shared
    private let linkFormatService = LinkFormatService.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider().background(Color(white: 0.2))

            if authState.isAuthenticated {
                // Quick actions
                quickActions

                Divider().background(Color(white: 0.15))

                // Upload progress (if active)
                if isUploading {
                    uploadProgressBar
                    Divider().background(Color(white: 0.15))
                }

                // Status message
                if let message = statusMessage {
                    statusBanner(message)
                    Divider().background(Color(white: 0.15))
                }

                // Recent uploads
                recentUploadsList

                Divider().background(Color(white: 0.15))

                // Footer actions
                footerActions
            } else {
                // Not authenticated
                notAuthenticatedView
            }
        }
        .background(Color(white: 0.06))
        .onAppear {
            loadRecentUploads()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("IMGHOST")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .tracking(3)

            Spacer()

            if authState.isAuthenticated {
                Circle()
                    .fill(Color(hex: "30D158"))
                    .frame(width: 6, height: 6)
                Text("ONLINE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.5))
                    .tracking(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(white: 0.04))
    }

    // MARK: - Quick Actions

    private var quickActions: some View {
        HStack(spacing: 6) {
            // Upload file
            MenuBarActionButton(
                icon: "arrow.up.doc",
                label: "UPLOAD",
                action: uploadFile
            )

            // Paste from clipboard
            MenuBarActionButton(
                icon: "doc.on.clipboard",
                label: "PASTE",
                action: pasteFromClipboard
            )

            // Sync
            MenuBarActionButton(
                icon: "arrow.clockwise",
                label: "SYNC",
                isSpinning: isSyncing,
                action: syncImages
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Upload Progress

    private var uploadProgressBar: some View {
        VStack(spacing: 4) {
            HStack {
                Text(uploadFileName ?? "Uploading...")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(white: 0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(Int(uploadProgress * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color(white: 0.15))
                    Rectangle()
                        .fill(.white)
                        .frame(width: geo.size.width * uploadProgress)
                }
            }
            .frame(height: 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Status Message

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(hex: "30D158"))
            Text(message.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.5))
                .tracking(0.5)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(hex: "30D158").opacity(0.06))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeOut(duration: 0.3)) {
                    statusMessage = nil
                }
            }
        }
    }

    // MARK: - Recent Uploads List

    private var recentUploadsList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("RECENT")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.35))
                    .tracking(2)
                Spacer()
                Text("\(recentUploads.count)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.25))
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if recentUploads.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(white: 0.2))
                    Text("NO UPLOADS YET")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(white: 0.25))
                        .tracking(1.5)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(recentUploads) { record in
                            MenuBarUploadRow(
                                record: record,
                                isCopied: lastCopiedId == record.id,
                                onCopy: { copyLink(for: record) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    // MARK: - Footer

    private var footerActions: some View {
        HStack(spacing: 0) {
            MenuBarFooterButton(icon: "macwindow", label: "Open App") {
                onShowMainWindow()
            }

            Divider()
                .frame(height: 16)
                .background(Color(white: 0.2))

            MenuBarFooterButton(icon: "gearshape", label: "Settings") {
                onDismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }

            Divider()
                .frame(height: 16)
                .background(Color(white: 0.2))

            MenuBarFooterButton(icon: "power", label: "Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    // MARK: - Not Authenticated

    private var notAuthenticatedView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 28))
                .foregroundStyle(Color(white: 0.25))
            Text("NOT SIGNED IN")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.4))
                .tracking(2)
            Text("Open the app to sign in")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.3))

            Button(action: onShowMainWindow) {
                Text("OPEN IMGHOST")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .tracking(1)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(.white)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Actions

    private func loadRecentUploads() {
        do {
            let all = try historyService.loadAll()
            recentUploads = Array(all.prefix(8))
        } catch {
            print("[MenuBar] Failed to load history: \(error)")
        }
    }

    private func uploadFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .png, .jpeg, .gif, .webP, .heic, .heif, .tiff, .bmp, .svg]
        panel.title = "Upload Image"

        // Need to bring the panel to front since we're coming from a popover
        panel.level = .floating

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            if UploadQualityService.shared.confirmBeforeUpload {
                let alert = NSAlert()
                alert.messageText = "Upload \"\(url.lastPathComponent)\"?"
                alert.informativeText = "Resolution: \(UploadQualityService.shared.currentQuality.displayName)"
                alert.addButton(withTitle: "Upload")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }

            Task { @MainActor in
                await self.performUpload(fileURL: url)
            }
        }
    }

    private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general

        // Check for image data on pasteboard
        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            if UploadQualityService.shared.confirmBeforeUpload {
                let alert = NSAlert()
                alert.messageText = "Upload clipboard image?"
                alert.informativeText = "Resolution: \(UploadQualityService.shared.currentQuality.displayName)"
                alert.addButton(withTitle: "Upload")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            Task { @MainActor in
                await performUploadFromData(imageData, filename: "clipboard-\(Int(Date().timeIntervalSince1970)).png")
            }
        } else if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  let fileURL = fileURLs.first {
            if UploadQualityService.shared.confirmBeforeUpload {
                let alert = NSAlert()
                alert.messageText = "Upload \"\(fileURL.lastPathComponent)\"?"
                alert.informativeText = "Resolution: \(UploadQualityService.shared.currentQuality.displayName)"
                alert.addButton(withTitle: "Upload")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            Task { @MainActor in
                await performUpload(fileURL: fileURL)
            }
        } else {
            showStatus("No image in clipboard")
        }
    }

    private func performUpload(fileURL: URL) async {
        isUploading = true
        uploadProgress = 0
        uploadFileName = fileURL.lastPathComponent

        do {
            let record = try await MacUploadService.shared.uploadFromFile(
                fileURL: fileURL,
                filename: fileURL.lastPathComponent,
                progressHandler: { progress in
                    Task { @MainActor in
                        self.uploadProgress = progress
                    }
                }
            )

            // Copy link immediately
            let formatted = linkFormatService.format(url: record.url, filename: record.originalFilename)
            MacClipboard.copy(formatted)

            isUploading = false
            uploadProgress = 0
            uploadFileName = nil
            lastCopiedId = record.id
            showStatus("Uploaded — link copied")
            loadRecentUploads()

            // Clear copied indicator after a moment
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if lastCopiedId == record.id {
                    lastCopiedId = nil
                }
            }
        } catch {
            isUploading = false
            uploadProgress = 0
            uploadFileName = nil
            showStatus("Upload failed")
            print("[MenuBar] Upload error: \(error)")
        }
    }

    private func performUploadFromData(_ data: Data, filename: String) async {
        isUploading = true
        uploadProgress = 0
        uploadFileName = filename

        do {
            let record = try await MacUploadService.shared.upload(
                imageData: data,
                filename: filename,
                progressHandler: { progress in
                    Task { @MainActor in
                        self.uploadProgress = progress
                    }
                }
            )

            let formatted = linkFormatService.format(url: record.url, filename: record.originalFilename)
            MacClipboard.copy(formatted)

            isUploading = false
            uploadProgress = 0
            uploadFileName = nil
            lastCopiedId = record.id
            showStatus("Uploaded — link copied")
            loadRecentUploads()

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if lastCopiedId == record.id {
                    lastCopiedId = nil
                }
            }
        } catch {
            isUploading = false
            uploadProgress = 0
            uploadFileName = nil
            showStatus("Upload failed")
            print("[MenuBar] Upload error: \(error)")
        }
    }

    private func syncImages() {
        guard !isSyncing else { return }
        isSyncing = true
        Task {
            do {
                try await ImageSyncService.shared.syncImages()
                await MainActor.run {
                    loadRecentUploads()
                    showStatus("Synced")
                }
            } catch {
                print("[MenuBar] Sync error: \(error)")
            }
            await MainActor.run {
                isSyncing = false
            }
        }
    }

    private func copyLink(for record: UploadRecord) {
        let formatted = linkFormatService.format(url: record.url, filename: record.originalFilename)
        MacClipboard.copy(formatted)
        lastCopiedId = record.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if lastCopiedId == record.id {
                lastCopiedId = nil
            }
        }
    }

    private func showStatus(_ message: String) {
        withAnimation(.easeIn(duration: 0.15)) {
            statusMessage = message
        }
    }
}

// MARK: - Action Button

private struct MenuBarActionButton: View {
    let icon: String
    let label: String
    var isSpinning: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isHovered ? .white : Color(white: 0.55))
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
                    .animation(isSpinning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isSpinning)

                Text(label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(isHovered ? Color(white: 0.8) : Color(white: 0.35))
                    .tracking(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isHovered ? Color(white: 0.12) : Color.clear)
            .overlay(
                Rectangle()
                    .stroke(isHovered ? Color(white: 0.25) : Color(white: 0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Upload Row

private struct MenuBarUploadRow: View {
    let record: UploadRecord
    let isCopied: Bool
    let onCopy: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 10) {
                // Thumbnail
                ZStack {
                    Color(white: 0.1)
                    if let data = record.thumbnailData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(white: 0.2))
                    }
                }
                .frame(width: 32, height: 32)
                .clipped()

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.originalFilename ?? "image")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isHovered ? .white : Color(white: 0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(record.createdAt.menuBarFormatted)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color(white: 0.3))
                }

                Spacer()

                // Copy indicator
                if isCopied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "30D158"))
                } else if isHovered {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.4))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isHovered ? Color(white: 0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Footer Button

private struct MenuBarFooterButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label.uppercased())
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(0.5)
            }
            .foregroundStyle(isHovered ? .white : Color(white: 0.4))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isHovered ? Color(white: 0.1) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Date Formatting

private extension Date {
    var menuBarFormatted: String {
        let now = Date()
        let interval = now.timeIntervalSince(self)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: self)
        }
    }
}
