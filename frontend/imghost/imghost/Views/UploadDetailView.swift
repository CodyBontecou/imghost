import SwiftUI

struct UploadDetailView: View {
    let record: UploadRecord
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false
    @State private var copiedField: CopiedField?
    @State private var isDeleting = false

    private enum CopiedField {
        case url, formatted
    }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        ZStack {
            Color.brutalBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // Full-bleed image preview - load full resolution from URL
                    AsyncImage(url: URL(string: record.url)) { phase in
                        switch phase {
                        case .empty:
                            // Show thumbnail as placeholder while loading
                            if let thumbnailData = record.thumbnailData,
                               let uiImage = UIImage(data: thumbnailData) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .overlay {
                                        ProgressView()
                                            .tint(.white)
                                    }
                            } else {
                                Rectangle()
                                    .fill(Color.brutalSurface)
                                    .aspectRatio(4/3, contentMode: .fit)
                                    .overlay {
                                        ProgressView()
                                            .tint(.white)
                                    }
                            }
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                        case .failure:
                            // Fall back to thumbnail on error
                            if let thumbnailData = record.thumbnailData,
                               let uiImage = UIImage(data: thumbnailData) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Rectangle()
                                    .fill(Color.brutalSurface)
                                    .aspectRatio(4/3, contentMode: .fit)
                                    .overlay {
                                        Text("□")
                                            .font(.system(size: 48, weight: .bold))
                                            .foregroundStyle(Color.brutalTextTertiary)
                                    }
                            }
                        @unknown default:
                            EmptyView()
                        }
                    }

                    // Action bar
                    BrutalActionBar(
                        onShare: { shareImage() },
                        onCopy: {
                            let formattedLink = LinkFormatService.shared.format(
                                url: record.url,
                                filename: record.originalFilename
                            )
                            copyToClipboard(formattedLink)
                            copiedField = .formatted
                        },
                        onOpen: { openInBrowser() },
                        onDelete: { showDeleteConfirmation = true },
                        isCopied: copiedField == .formatted,
                        isDeleting: isDeleting
                    )

                    // Details section
                    VStack(spacing: 0) {
                        BrutalDetailSection(title: String(localized: "detail.section.image_url")) {
                            BrutalCopyableRow(
                                text: record.url,
                                isCopied: copiedField == .url,
                                onCopy: {
                                    copyToClipboard(record.url)
                                    copiedField = .url
                                }
                            )
                        }

                        Rectangle()
                            .fill(Color.brutalBorder)
                            .frame(height: 1)

                        BrutalDetailSection(title: String(localized: "detail.section.details")) {
                            VStack(spacing: 0) {
                                BrutalInfoRow(label: String(localized: "detail.label.uploaded"), value: dateFormatter.string(from: record.createdAt))

                                if let filename = record.originalFilename {
                                    Rectangle()
                                        .fill(Color.brutalBorder.opacity(0.5))
                                        .frame(height: 1)
                                    BrutalInfoRow(label: String(localized: "detail.label.original_file"), value: filename)
                                }

                                Rectangle()
                                    .fill(Color.brutalBorder.opacity(0.5))
                                    .frame(height: 1)
                                BrutalInfoRow(label: String(localized: "detail.label.id"), value: record.id)

                                // Expiration row — only for free-tier uploads
                                Rectangle()
                                    .fill(Color.brutalBorder.opacity(0.5))
                                    .frame(height: 1)
                                BrutalInfoRow(
                                    label: "Link",
                                    value: expirationLabel,
                                    valueColor: record.isTemporary ? .brutalWarning : .brutalTextSecondary
                                )
                            }
                        }
                    }
                    .background(Color.brutalSurface)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.brutalBackground, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .confirmationDialog(
            String(localized: "detail.alert.delete.title"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "detail.alert.delete.button.confirm"), role: .destructive) {
                deleteFromServer()
            }
            Button(String(localized: "detail.alert.delete.button.cancel"), role: .cancel) {}
        } message: {
            Text("detail.alert.delete.message")
        }
        .onChange(of: copiedField) { _, newValue in
            if newValue != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copiedField = nil
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var expirationLabel: String {
        guard let days = record.daysUntilExpiry else {
            return String(localized: "detail.permanent")
        }
        if days == 0 {
            return String(localized: "detail.expires_today")
        }
        return String(format: String(localized: "detail.expires_in_days"), days)
    }

    private func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    private func shareImage() {
        guard let url = URL(string: record.url) else { return }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootVC = window.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }

    private func openInBrowser() {
        guard let url = URL(string: record.url) else { return }
        UIApplication.shared.open(url)
    }

    private func deleteFromServer() {
        isDeleting = true

        Task {
            do {
                try await UploadService.shared.delete(record: record)
                try HistoryService.shared.delete(id: record.id)
                await MainActor.run {
                    onDelete()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isDeleting = false
                }
            }
        }
    }
}

// MARK: - Brutal Action Bar

struct BrutalActionBar: View {
    let onShare: () -> Void
    let onCopy: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void
    let isCopied: Bool
    let isDeleting: Bool

    var body: some View {
        HStack(spacing: 0) {
            BrutalActionButton(label: String(localized: "detail.button.share"), action: onShare)
            BrutalActionButton(
                label: isCopied ? String(localized: "detail.button.copied") : String(localized: "detail.button.copy"),
                color: isCopied ? .brutalSuccess : .white,
                action: onCopy
            )
            BrutalActionButton(label: String(localized: "detail.button.open"), action: onOpen)
            BrutalActionButton(
                label: isDeleting ? String(localized: "detail.button.delete_deleting") : String(localized: "detail.button.delete"),
                color: .brutalError,
                action: onDelete
            )
            .disabled(isDeleting)
        }
        .padding(.vertical, 16)
        .background(Color.brutalBackground)
        .overlay(
            Rectangle()
                .stroke(Color.brutalBorder, lineWidth: 1)
        )
    }
}

// MARK: - Brutal Action Button

struct BrutalActionButton: View {
    let label: String
    var color: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .brutalTypography(.monoSmall, color: color)
                .tracking(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }
}

// MARK: - Brutal Detail Section

struct BrutalDetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                .tracking(2)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            content
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
    }
}

// MARK: - Brutal Copyable Row

struct BrutalCopyableRow: View {
    let text: String
    let isCopied: Bool
    let onCopy: () -> Void

    var body: some View {
        HStack {
            Text(text)
                .brutalTypography(.monoSmall, color: .brutalTextPrimary)
                .lineLimit(2)

            Spacer()

            Button(action: onCopy) {
                Text(isCopied ? "detail.copy_button.copied" : "detail.copy_button.label")
                    .brutalTypography(.monoSmall, color: isCopied ? .brutalSuccess : .brutalTextSecondary)
                    .tracking(1)
            }
        }
        .padding(12)
        .background(Color.brutalSurfaceElevated)
    }
}

// MARK: - Brutal Info Row

struct BrutalInfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .brutalTextPrimary

    var body: some View {
        HStack {
            Text(label.uppercased())
                .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                .tracking(1)
            Spacer()
            Text(value)
                .brutalTypography(.bodySmall, color: valueColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#Preview {
    NavigationStack {
        UploadDetailView(record: .preview) {}
    }
}
