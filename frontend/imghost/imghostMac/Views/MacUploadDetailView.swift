import SwiftUI
import AppKit

// MARK: - NSView Anchor (for positioning NSSharingServicePicker)

private struct NSViewAnchor: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView) }
    }
}

// MARK: - Selectable Link Text (NSViewRepresentable)
// SwiftUI's .textSelection(.enabled) on Text can ignore foregroundStyle on macOS,
// rendering black text that's invisible on dark backgrounds. This uses NSTextField
// directly so we control the text color reliably.

private struct SelectableLinkText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.isEditable = false
        field.isSelectable = true
        field.drawsBackground = false
        field.textColor = NSColor(white: 0.6, alpha: 1.0)
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.maximumNumberOfLines = 3
        field.lineBreakMode = .byTruncatingTail
        field.isBordered = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let cell = field.cell as? NSTextFieldCell {
            cell.wraps = true
            cell.isScrollable = false
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text
        nsView.textColor = NSColor(white: 0.6, alpha: 1.0)
    }
}

struct MacUploadDetailView: View {
    let record: UploadRecord
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var isCopied = false
    @State private var showDeleteConfirm = false
    @State private var selectedFormat: LinkFormat
    @State private var shareButtonView: NSView?

    private let linkFormatService = LinkFormatService.shared

    init(record: UploadRecord, onDelete: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.record = record
        self.onDelete = onDelete
        self.onClose = onClose
        _selectedFormat = State(initialValue: LinkFormatService.shared.currentFormat)
    }

    private var macExpirationLabel: String {
        guard let days = record.daysUntilExpiry else {
            return String(localized: "detail.permanent")
        }
        if days == 0 { return String(localized: "detail.expires_today") }
        return String(format: String(localized: "detail.expires_in_days"), days)
    }

    private var formattedLink: String {
        linkFormatService.format(url: record.url, using: selectedFormat, filename: record.originalFilename)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Fixed close header — always visible, never scrolls away
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.brutalTextSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close sidebar")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.brutalSurface)

            ScrollView {
                VStack(spacing: 0) {
                // Image preview
                imagePreview

                // Info section
                VStack(alignment: .leading, spacing: 16) {
                    // Filename
                    if let filename = record.originalFilename {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("detail.label.filename")
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
                        Text("detail.label.uploaded")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.brutalTextTertiary)
                            .tracking(1.5)
                        Text(record.createdAt, style: .date)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.brutalTextSecondary)
                    }

                    // Expiry (free-tier uploads only)
                    if record.isTemporary {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LINK")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.brutalTextTertiary)
                                .tracking(1.5)
                            HStack(spacing: 4) {
                                Image(systemName: "clock.fill")
                                    .font(.system(size: 11))
                                Text(macExpirationLabel)
                                    .font(.system(size: 13))
                            }
                            .foregroundStyle(Color.brutalWarning)
                        }
                    }

                    Divider().background(Color.brutalBorder)

                    // Link format picker
                    VStack(alignment: .leading, spacing: 8) {
                        Text("detail.label.link_format")
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
                        SelectableLinkText(text: formattedLink)
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
                                Text(isCopied ? "detail.button.copied" : "detail.button.copy_link")
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
                                    Text("detail.button.open")
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
                                    Text("detail.button.share")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .tracking(1)
                                }
                                .foregroundStyle(Color.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .background(NSViewAnchor { self.shareButtonView = $0 })
                        }

                        // Delete
                        Button(action: { showDeleteConfirm = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                Text("detail.button.delete")
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
            } // VStack inside ScrollView
            } // ScrollView
        } // outer VStack
        .background(Color.brutalSurface.opacity(0.5))
        .alert(String(localized: "detail.alert.delete.title"), isPresented: $showDeleteConfirm) {
            Button(String(localized: "detail.alert.delete.button.cancel"), role: .cancel) {}
            Button(String(localized: "detail.alert.delete.button.confirm"), role: .destructive) { onDelete() }
        } message: {
            Text("detail.alert.delete.message")
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
        guard let anchor = shareButtonView else { return }

        let picker = NSSharingServicePicker(items: [record.url as NSString])
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
}
