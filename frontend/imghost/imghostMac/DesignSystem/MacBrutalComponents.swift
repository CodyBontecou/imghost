import SwiftUI
import AppKit

// MARK: - macOS Brutal Text Field (no UIKeyboardType / UITextContentType)

struct MacBrutalTextField: View {
    let label: String
    @Binding var text: String
    var isSecure: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .brutalTypography(.monoSmall, color: isFocused ? Color.white : Color.brutalTextSecondary)
                .tracking(2)

            Group {
                if isSecure {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                }
            }
            .focused($isFocused)
            .textFieldStyle(.plain)
            .disableAutocorrection(true)
            .brutalTypography(.bodyLarge)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.brutalSurface)
            .overlay(
                Rectangle()
                    .stroke(isFocused ? Color.white : Color.brutalBorder, lineWidth: isFocused ? 2 : 1)
            )
        }
    }
}

// MARK: - macOS Clipboard Helper

struct MacClipboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - macOS Share Helper

struct MacShareHelper {
    static func share(_ items: [Any], from view: NSView? = nil) {
        let picker = NSSharingServicePicker(items: items)
        if let view = view {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }
}

// MARK: - macOS URL Opener

struct MacURLOpener {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - macOS Drag & Drop View

struct MacDropZone<Content: View>: View {
    let isTargeted: Bool
    let content: Content

    init(isTargeted: Bool, @ViewBuilder content: () -> Content) {
        self.isTargeted = isTargeted
        self.content = content()
    }

    var body: some View {
        content
            .overlay(
                Rectangle()
                    .stroke(
                        isTargeted ? Color.white : Color.brutalBorder,
                        style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [8, 4])
                    )
            )
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }
}

// MARK: - macOS Image Thumbnail Helper

import CoreGraphics

struct MacImageHelper {
    /// Generate thumbnail from image data
    static func generateThumbnail(from data: Data, maxSize: CGFloat = Config.thumbnailSize) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(maxSize / size.width, maxSize / size.height, 1.0)
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()

        guard let tiffData = newImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: Config.thumbnailQuality]) else {
            return nil
        }
        return jpegData
    }

    /// Create NSImage from data
    static func createImage(from data: Data) -> NSImage? {
        NSImage(data: data)
    }

    /// Resize NSImage
    static func resize(image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension else { return image }

        let scale: CGFloat
        if size.width > size.height {
            scale = maxDimension / size.width
        } else {
            scale = maxDimension / size.height
        }

        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

    /// Compress to JPEG data
    static func jpegData(from image: NSImage, quality: CGFloat = Config.jpegQuality) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
