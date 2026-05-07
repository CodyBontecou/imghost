import Foundation

/// Preset link format options
enum LinkFormat: String, CaseIterable, Identifiable {
    case rawURL = "raw"
    case markdownAlt = "markdown_alt"
    case markdownObsidian = "markdown_obsidian"
    case html = "html"
    case bbcode = "bbcode"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rawURL: return "Raw URL"
        case .markdownAlt: return "Markdown"
        case .markdownObsidian: return "Markdown (Obsidian)"
        case .html: return "HTML"
        case .bbcode: return "BBCode"
        case .custom: return "Custom"
        }
    }

    var previewExample: String {
        switch self {
        case .rawURL: return "https://example.com/img.jpg"
        case .markdownAlt: return "![photo.jpg](https://...)"
        case .markdownObsidian: return "![photo.jpg](url) + <video> for mp4"
        case .html: return "<img src=\"https://...\">"
        case .bbcode: return "[img]https://...[/img]"
        case .custom: return "Custom format"
        }
    }
}

/// Service for formatting upload URLs based on user preferences
final class LinkFormatService {
    static let shared = LinkFormatService()

    private init() {}

    /// Current link format preference
    var currentFormat: LinkFormat {
        get {
            guard let rawValue = Config.sharedDefaults?.string(forKey: Config.linkFormatKey),
                  let format = LinkFormat(rawValue: rawValue) else {
                return .rawURL
            }
            return format
        }
        set {
            Config.sharedDefaults?.set(newValue.rawValue, forKey: Config.linkFormatKey)
        }
    }

    /// Custom format template (used when format is .custom)
    var customTemplate: String {
        get {
            Config.sharedDefaults?.string(forKey: Config.customLinkFormatKey) ?? "{url}"
        }
        set {
            Config.sharedDefaults?.set(newValue, forKey: Config.customLinkFormatKey)
        }
    }

    /// Default media width applied to image and video templates when supported.
    /// 0 (or absence) means no width is injected.
    var preferredWidth: Int {
        get {
            Config.sharedDefaults?.integer(forKey: Config.linkWidthKey) ?? 0
        }
        set {
            Config.sharedDefaults?.set(max(0, newValue), forKey: Config.linkWidthKey)
        }
    }

    /// Format a URL using the current format preference
    /// - Parameters:
    ///   - url: The image or video URL
    ///   - filename: Optional original filename for templates that support it
    /// - Returns: Formatted string ready for clipboard
    func format(url: String, filename: String? = nil) -> String {
        format(url: url, using: currentFormat, filename: filename)
    }

    /// Format a URL using a specific format
    func format(url: String, using format: LinkFormat, filename: String? = nil) -> String {
        let isVideo = LinkFormatService.isVideoURL(url)
        let width = preferredWidth > 0 ? preferredWidth : nil
        let template = format == .custom
            ? customTemplate
            : LinkFormatService.template(for: format, isVideo: isVideo, width: width)
        return applyTemplate(template, url: url, filename: filename, width: width)
    }

    /// Preview what a format will look like with an example URL
    func preview(format: LinkFormat, customTemplate: String? = nil) -> String {
        let width = preferredWidth > 0 ? preferredWidth : nil
        let template: String
        if format == .custom {
            template = customTemplate ?? self.customTemplate
        } else {
            template = LinkFormatService.template(for: format, isVideo: false, width: width)
        }
        return applyTemplate(template, url: "https://img.example.com/abc123.jpg", filename: "photo.jpg", width: width)
    }

    // MARK: - Private

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "mkv", "avi"
    ]

    static func isVideoURL(_ url: String) -> Bool {
        guard let parsed = URL(string: url) else { return false }
        return videoExtensions.contains(parsed.pathExtension.lowercased())
    }

    private static func template(for format: LinkFormat, isVideo: Bool, width: Int?) -> String {
        switch format {
        case .rawURL:
            return "{url}"
        case .markdownAlt:
            return "![{filename}]({url})"
        case .markdownObsidian:
            if isVideo {
                return width != nil
                    ? "<video controls src=\"{url}\" width=\"{width}\"></video>"
                    : "<video controls src=\"{url}\"></video>"
            }
            return width != nil
                ? "![{filename}|{width}]({url})"
                : "![{filename}]({url})"
        case .html:
            if isVideo {
                return width != nil
                    ? "<video controls src=\"{url}\" width=\"{width}\"></video>"
                    : "<video controls src=\"{url}\"></video>"
            }
            return width != nil
                ? "<img src=\"{url}\" alt=\"{filename}\" width=\"{width}\">"
                : "<img src=\"{url}\" alt=\"{filename}\">"
        case .bbcode:
            return isVideo ? "[video]{url}[/video]" : "[img]{url}[/img]"
        case .custom:
            return "{url}"
        }
    }

    private func applyTemplate(_ template: String, url: String, filename: String?, width: Int?) -> String {
        var result = template
        result = result.replacingOccurrences(of: "{url}", with: url)

        let name = filename ?? URL(string: url)?.lastPathComponent ?? "image"
        result = result.replacingOccurrences(of: "{filename}", with: name)

        let widthString = width.map(String.init) ?? ""
        result = result.replacingOccurrences(of: "{width}", with: widthString)

        return result
    }
}
