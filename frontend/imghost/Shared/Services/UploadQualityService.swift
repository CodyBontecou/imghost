import Foundation
import UIKit
import AVFoundation

/// Quality presets for media uploads
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
        case .original: return nil // No resize
        case .high: return 4096
        case .medium: return 2048
        case .low: return 1024
        }
    }

    /// Estimated size reduction compared to original
    var estimatedReduction: String {
        switch self {
        case .original: return "100%"
        case .high: return "~70%"
        case .medium: return "~40%"
        case .low: return "~20%"
        }
    }
}

/// Service for managing upload quality preferences
final class UploadQualityService {
    static let shared = UploadQualityService()

    private init() {}

    /// The currently selected upload quality
    var currentQuality: UploadQuality {
        get {
            guard let rawValue = Config.sharedDefaults?.string(forKey: Config.uploadQualityKey),
                  let quality = UploadQuality(rawValue: rawValue) else {
                return .original // Default to full quality (no compression)
            }
            return quality
        }
        set {
            Config.sharedDefaults?.set(newValue.rawValue, forKey: Config.uploadQualityKey)
        }
    }

    /// Whether to show a confirmation prompt before each upload starts
    var confirmBeforeUpload: Bool {
        get {
            Config.sharedDefaults?.bool(forKey: Config.confirmBeforeUploadKey) ?? false
        }
        set {
            Config.sharedDefaults?.set(newValue, forKey: Config.confirmBeforeUploadKey)
        }
    }

    /// Process image data according to quality settings
    /// - Parameters:
    ///   - data: Original image data
    ///   - filename: Original filename
    ///   - quality: Optional quality override. If nil, uses the current saved preference.
    /// - Returns: Processed data and possibly updated filename, or original if not an image
    func processForUpload(data: Data, filename: String, quality: UploadQuality? = nil) -> (Data, String) {
        let effectiveQuality = quality ?? currentQuality

        // If original quality, return data as-is
        if effectiveQuality == .original {
            return (data, filename)
        }

        // Check if this is an image we can process
        guard let image = UIImage(data: data) else {
            return (data, filename)
        }

        // Check if it's a format we should compress (skip GIFs to preserve animation)
        let lowercased = filename.lowercased()
        if lowercased.hasSuffix(".gif") {
            return (data, filename)
        }

        // Resize if needed
        var processedImage = image
        if let maxDim = effectiveQuality.maxDimension {
            processedImage = ImageProcessor.shared.resize(image: image, maxDimension: maxDim)
        }

        // Compress to JPEG
        if let compressedData = processedImage.jpegData(compressionQuality: effectiveQuality.jpegQuality) {
            // Update filename to .jpg since we're converting
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

        // Fallback to original if compression fails
        return (data, filename)
    }

    /// Process a UIImage according to current quality settings
    /// - Parameter image: The image to process
    /// - Returns: Processed image data
    func processForUpload(image: UIImage) -> Data? {
        let quality = currentQuality

        if quality == .original {
            // Return highest quality JPEG for original
            return image.jpegData(compressionQuality: 1.0)
        }

        var processedImage = image
        if let maxDim = quality.maxDimension {
            processedImage = ImageProcessor.shared.resize(image: image, maxDimension: maxDim)
        }

        return processedImage.jpegData(compressionQuality: quality.jpegQuality)
    }
    
    /// Compress an image to fit under a maximum file size
    /// Uses progressive quality reduction and dimension scaling
    /// - Parameters:
    ///   - fileURL: URL of the image file
    ///   - maxSizeBytes: Maximum allowed size in bytes
    ///   - progressHandler: Optional callback for compression progress updates
    /// - Returns: Tuple of (compressed data, new filename) or nil if compression fails/not an image
    func compressToFitSize(
        fileURL: URL,
        maxSizeBytes: Int64,
        progressHandler: ((String) -> Void)? = nil
    ) -> (Data, String)? {
        // Load image from URL using CGImageSource for memory efficiency
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }
        
        let image = UIImage(cgImage: cgImage)
        let filename = fileURL.lastPathComponent
        let lowercased = filename.lowercased()
        
        // Skip non-compressible formats
        if lowercased.hasSuffix(".gif") {
            return nil
        }
        
        // Check if it's an image format we can compress
        let isImage = lowercased.hasSuffix(".jpg") || lowercased.hasSuffix(".jpeg") ||
                      lowercased.hasSuffix(".png") || lowercased.hasSuffix(".heic") ||
                      lowercased.hasSuffix(".heif") || lowercased.hasSuffix(".webp") ||
                      lowercased.hasSuffix(".bmp") || lowercased.hasSuffix(".tiff") ||
                      lowercased.hasSuffix(".tif")
        
        guard isImage else {
            return nil
        }
        
        // Progressive compression settings (quality, max dimension)
        let compressionSteps: [(quality: CGFloat, maxDimension: CGFloat?)] = [
            (0.9, nil),           // High quality, original size
            (0.8, 8192),          // Slightly lower, cap at 8K
            (0.7, 6144),          // Medium-high quality
            (0.6, 4096),          // Medium quality, 4K
            (0.5, 3072),          // Lower quality
            (0.4, 2048),          // Lower quality, 2K
            (0.3, 1536),          // Low quality
            (0.2, 1024),          // Very low quality, 1K
        ]
        
        for (index, step) in compressionSteps.enumerated() {
            progressHandler?("Compressing... (attempt \(index + 1)/\(compressionSteps.count))")
            
            var processedImage = image
            
            // Resize if max dimension specified
            if let maxDim = step.maxDimension {
                processedImage = ImageProcessor.shared.resize(image: processedImage, maxDimension: maxDim)
            }
            
            // Compress to JPEG
            if let compressedData = processedImage.jpegData(compressionQuality: step.quality) {
                if compressedData.count < maxSizeBytes {
                    // Success! Update filename to .jpg
                    let newFilename = filename.replacingOccurrences(
                        of: "\\.[^.]+$",
                        with: ".jpg",
                        options: .regularExpression
                    )
                    
                    let sizeMB = Double(compressedData.count) / (1024 * 1024)
                    progressHandler?(String(format: "Compressed to %.1f MB", sizeMB))
                    
                    return (compressedData, newFilename)
                }
            }
        }
        
        // Could not compress to target size
        progressHandler?("Could not compress below limit")
        return nil
    }
    
    /// Check if a file can potentially be compressed (is a supported image or video format)
    func canCompress(filename: String) -> Bool {
        return isImage(filename: filename) || isVideo(filename: filename)
    }
    
    /// Check if file is an image that can be compressed
    func isImage(filename: String) -> Bool {
        let lowercased = filename.lowercased()
        
        // GIFs can't be compressed without losing animation
        if lowercased.hasSuffix(".gif") {
            return false
        }
        
        // Supported image formats
        return lowercased.hasSuffix(".jpg") || lowercased.hasSuffix(".jpeg") ||
               lowercased.hasSuffix(".png") || lowercased.hasSuffix(".heic") ||
               lowercased.hasSuffix(".heif") || lowercased.hasSuffix(".webp") ||
               lowercased.hasSuffix(".bmp") || lowercased.hasSuffix(".tiff") ||
               lowercased.hasSuffix(".tif")
    }
    
    /// Check if file is a video that can be compressed
    func isVideo(filename: String) -> Bool {
        let lowercased = filename.lowercased()
        return lowercased.hasSuffix(".mp4") || lowercased.hasSuffix(".mov") ||
               lowercased.hasSuffix(".m4v") || lowercased.hasSuffix(".avi") ||
               lowercased.hasSuffix(".mkv") || lowercased.hasSuffix(".webm")
    }
    
    // MARK: - Video Compression
    
    /// Video quality presets
    enum VideoQualityPreset: String, CaseIterable {
        case high = "high"           // 1080p, high bitrate
        case medium = "medium"       // 720p, medium bitrate
        case low = "low"             // 480p, lower bitrate
        case veryLow = "veryLow"     // 360p, lowest bitrate
        
        var displayName: String {
            switch self {
            case .high: return "High (1080p)"
            case .medium: return "Medium (720p)"
            case .low: return "Low (480p)"
            case .veryLow: return "Very Low (360p)"
            }
        }
        
        var exportPreset: String {
            switch self {
            case .high: return AVAssetExportPreset1920x1080
            case .medium: return AVAssetExportPreset1280x720
            case .low: return AVAssetExportPreset640x480
            case .veryLow: return AVAssetExportPresetLowQuality
            }
        }
        
        /// Estimated size reduction factor
        var estimatedReductionFactor: Double {
            switch self {
            case .high: return 0.5      // ~50% of original
            case .medium: return 0.25   // ~25% of original
            case .low: return 0.1       // ~10% of original
            case .veryLow: return 0.05  // ~5% of original
            }
        }
    }
    
    /// Compress a video file to fit under a maximum size
    /// - Parameters:
    ///   - fileURL: URL of the video file
    ///   - preset: Video quality preset to use
    ///   - progressHandler: Optional callback for compression progress updates
    /// - Returns: URL to the compressed video file, or nil if compression fails
    func compressVideo(
        fileURL: URL,
        preset: VideoQualityPreset,
        progressHandler: ((String, Double?) -> Void)? = nil
    ) async -> URL? {
        let asset = AVURLAsset(url: fileURL)
        
        // Check if the preset is compatible
        let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let presetToUse: String
        
        if compatiblePresets.contains(preset.exportPreset) {
            presetToUse = preset.exportPreset
        } else if compatiblePresets.contains(AVAssetExportPresetMediumQuality) {
            presetToUse = AVAssetExportPresetMediumQuality
            progressHandler?("Using fallback quality preset", nil)
        } else if let firstPreset = compatiblePresets.first {
            presetToUse = firstPreset
            progressHandler?("Using available preset: \(firstPreset)", nil)
        } else {
            progressHandler?("No compatible export presets found", nil)
            return nil
        }
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetToUse) else {
            progressHandler?("Failed to create export session", nil)
            return nil
        }
        
        // Create temp output URL
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent(UUID().uuidString + ".mp4")
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        
        progressHandler?("Starting video compression...", 0)
        
        // Start export with progress monitoring
        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                let progress = Double(exportSession.progress)
                await MainActor.run {
                    progressHandler?("Compressing video...", progress)
                }
                if exportSession.status == .completed || exportSession.status == .failed || exportSession.status == .cancelled {
                    break
                }
            }
        }
        
        await exportSession.export()
        progressTask.cancel()
        
        switch exportSession.status {
        case .completed:
            // Get final file size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
               let size = attrs[.size] as? Int64 {
                let sizeMB = Double(size) / (1024 * 1024)
                progressHandler?(String(format: "Compressed to %.1f MB", sizeMB), 1.0)
            }
            return outputURL
            
        case .failed:
            let errorMessage = exportSession.error?.localizedDescription ?? "Unknown error"
            progressHandler?("Compression failed: \(errorMessage)", nil)
            return nil
            
        case .cancelled:
            progressHandler?("Compression cancelled", nil)
            return nil
            
        default:
            progressHandler?("Unexpected export status", nil)
            return nil
        }
    }
    
    /// Get video information (duration, dimensions, estimated sizes at each preset)
    func getVideoInfo(fileURL: URL) async -> (duration: Double, dimensions: CGSize, fileSizeMB: Double)? {
        let asset = AVURLAsset(url: fileURL)
        
        // Get duration
        let duration: Double
        do {
            let durationCM = try await asset.load(.duration)
            duration = CMTimeGetSeconds(durationCM)
        } catch {
            return nil
        }
        
        // Get dimensions from video track
        var dimensions: CGSize = .zero
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            if let videoTrack = tracks.first {
                let size = try await videoTrack.load(.naturalSize)
                let transform = try await videoTrack.load(.preferredTransform)
                // Apply transform to get correct dimensions (handles rotation)
                let transformedSize = size.applying(transform)
                dimensions = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
            }
        } catch {
            // Continue without dimensions
        }
        
        // Get file size
        var fileSizeMB: Double = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int64 {
            fileSizeMB = Double(size) / (1024 * 1024)
        }
        
        return (duration, dimensions, fileSizeMB)
    }
    
    /// Estimate compressed video size for a given preset
    func estimateCompressedVideoSize(originalSizeMB: Double, preset: VideoQualityPreset) -> Double {
        return originalSizeMB * preset.estimatedReductionFactor
    }
}
