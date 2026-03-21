import Foundation
import AppKit

/// Quality presets for media uploads (macOS version)
enum UploadQuality: String, CaseIterable, Identifiable {
    case original = "original"
    case high = "high"
    case medium = "medium"
    case low = "low"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: return "Original"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    var description: String {
        switch self {
        case .original: return "No compression"
        case .high: return "Slight compression"
        case .medium: return "Balanced quality/size"
        case .low: return "Smallest file size"
        }
    }

    var jpegQuality: CGFloat {
        switch self {
        case .original: return 1.0
        case .high: return 0.9
        case .medium: return 0.7
        case .low: return 0.5
        }
    }

    var maxDimension: CGFloat? {
        switch self {
        case .original: return nil
        case .high: return 4096
        case .medium: return 2048
        case .low: return 1024
        }
    }

    var estimatedReduction: String {
        switch self {
        case .original: return "100%"
        case .high: return "~70%"
        case .medium: return "~40%"
        case .low: return "~20%"
        }
    }
}

/// Service for managing upload quality preferences (macOS)
final class UploadQualityService {
    static let shared = UploadQualityService()

    private init() {}

    var currentQuality: UploadQuality {
        get {
            guard let rawValue = Config.sharedDefaults?.string(forKey: Config.uploadQualityKey),
                  let quality = UploadQuality(rawValue: rawValue) else {
                return .original
            }
            return quality
        }
        set {
            Config.sharedDefaults?.set(newValue.rawValue, forKey: Config.uploadQualityKey)
        }
    }

    var confirmBeforeUpload: Bool {
        get {
            Config.sharedDefaults?.bool(forKey: Config.confirmBeforeUploadKey) ?? false
        }
        set {
            Config.sharedDefaults?.set(newValue, forKey: Config.confirmBeforeUploadKey)
        }
    }

    /// Process image data according to quality settings (macOS)
    func processForUpload(data: Data, filename: String, quality: UploadQuality? = nil) -> (Data, String) {
        let effectiveQuality = quality ?? currentQuality

        if effectiveQuality == .original {
            return (data, filename)
        }

        guard let image = NSImage(data: data) else {
            return (data, filename)
        }

        let lowercased = filename.lowercased()
        if lowercased.hasSuffix(".gif") {
            return (data, filename)
        }

        var processedImage = image
        if let maxDim = effectiveQuality.maxDimension {
            processedImage = MacImageHelper.resize(image: image, maxDimension: maxDim)
        }

        if let compressedData = MacImageHelper.jpegData(from: processedImage, quality: effectiveQuality.jpegQuality) {
            let newFilename: String
            if lowercased.hasSuffix(".png") || lowercased.hasSuffix(".heic") ||
               lowercased.hasSuffix(".heif") || lowercased.hasSuffix(".webp") ||
               lowercased.hasSuffix(".bmp") || lowercased.hasSuffix(".tiff") {
                newFilename = filename.replacingOccurrences(
                    of: "\\.[^.]+$",
                    with: ".jpg",
                    options: .regularExpression
                )
            } else {
                newFilename = filename
            }
            return (compressedData, newFilename)
        }

        return (data, filename)
    }

    /// Process NSImage according to current quality settings
    func processForUpload(image: NSImage) -> Data? {
        let quality = currentQuality

        if quality == .original {
            return MacImageHelper.jpegData(from: image, quality: 1.0)
        }

        var processedImage = image
        if let maxDim = quality.maxDimension {
            processedImage = MacImageHelper.resize(image: image, maxDimension: maxDim)
        }

        return MacImageHelper.jpegData(from: processedImage, quality: quality.jpegQuality)
    }
}
