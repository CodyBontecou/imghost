import SwiftUI

struct MacUploadDetailView: View {
    let record: UploadRecord
    let onDelete: () -> Void

    @State private var isCopied = false
    @State private var showDeleteConfirm = false
    @State private var selectedFormat: LinkFormat

    private let linkFormatService = LinkFormatService.shared

    init(record: UploadRecord, onDelete: @escaping () -> Void) {
        self.record = record
        self.onDelete = onDelete
        _selectedFormat = State(initialValue: LinkFormatService.shared.currentFormat)
    }

    private var formattedLink: String {
        linkFormatService.format(url: record.url, using: selectedFormat, filename: record.originalFilename)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Image preview
                imagePreview

                // Info section
                VStack(alignment: .leading, spacing: 16) {
                    // Filename
                    if let filename = record.originalFilename {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("FILENAME")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.brutalTextTertiary)
                                .tracking(1.5)
                            Text(filename)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white)
                        }
                    }

                    // Date
                    VStack(alignment: .leading, spacing: 4) {
                        Text("UPLOADED")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.brutalTextTertiary)
                            .tracking(1.5)
                        Text(record.createdAt, style: .date)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.brutalTextSecondary)
                    }

                    Divider().background(Color.brutalBorder)

                    // Link format picker
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LINK FORMAT")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.brutalTextTertiary)
                            .tracking(1.5)

                        Picker("", selection: $selectedFormat) {
                            ForEach(LinkFormat.allCases) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    // Link display
                    VStack(alignment: .leading, spacing: 8) {
                        Text(formattedLink)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.brutalTextSecondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.brutalSurface)
                            .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                    }

                    // Actions
                    VStack(spacing: 8) {
                        // Copy button
                        Button(action: copyLink) {
                            HStack(spacing: 6) {
                                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 12))
                                Text(isCopied ? "COPIED" : "COPY LINK")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .tracking(1)
                            }
                            .foregroundStyle(Color.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(Color.white)
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 8) {
                            // Open in browser
                            Button(action: openInBrowser) {
                                HStack(spacing: 6) {
                                    Image(systemName: "safari")
                                        .font(.system(size: 12))
                                    Text("OPEN")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .tracking(1)
                                }
                                .foregroundStyle(Color.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                            }
                            .buttonStyle(.plain)

                            // Share
                            Button(action: shareLink) {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 12))
                                    Text("SHARE")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .tracking(1)
                                }
                                .foregroundStyle(Color.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }

                        // Delete
                        Button(action: { showDeleteConfirm = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                Text("DELETE")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .tracking(1)
                            }
                            .foregroundStyle(Color.brutalError)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .overlay(Rectangle().stroke(Color.brutalError.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
        .background(Color.brutalSurface.opacity(0.5))
        .alert("Delete Image", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This will permanently delete the image from the server.")
        }
    }

    // MARK: - Image Preview

    @ViewBuilder
    private var imagePreview: some View {
        if let data = record.thumbnailData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 300)
                .background(Color.black)
        } else {
            AsyncImage(url: URL(string: record.url)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 300)
                case .failure:
                    placeholderImage
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                @unknown default:
                    placeholderImage
                }
            }
            .background(Color.black)
        }
    }

    private var placeholderImage: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 32))
                .foregroundStyle(Color.brutalTextTertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .background(Color.brutalSurface)
    }

    // MARK: - Actions

    private func copyLink() {
        MacClipboard.copy(formattedLink)
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }
    }

    private func openInBrowser() {
        MacURLOpener.open(record.url)
    }

    private func shareLink() {
        // Use NSSharingServicePicker via the window
        guard let window = NSApplication.shared.keyWindow,
              let contentView = window.contentView else { return }

        let picker = NSSharingServicePicker(items: [record.url as NSString])
        picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
    }
}
