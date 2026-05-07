import Foundation
import UIKit
import AVFoundation

final class UploadService: NSObject {
    static let shared = UploadService()

    private let keychainService = KeychainService.shared
    private let imageProcessor = ImageProcessor.shared

    // For tracking upload progress
    private var progressHandler: ((Double) -> Void)?
    private var uploadTask: URLSessionUploadTask?
    private var uploadContinuation: CheckedContinuation<(Data, URLResponse), Error>?
    
    // Background session for large file uploads (share extension)
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // 5 minutes
        config.timeoutIntervalForResource = 600 // 10 minutes
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // Test mode for UI development
    var testMode = false

    private override init() {
        super.init()
    }

    // MARK: - Configuration

    var isConfigured: Bool {
        // Check if we have access token (user is authenticated)
        keychainService.hasValidTokens
    }

    func getBackendURL() -> String? {
        let url = Config.backendURL
        return url.isEmpty ? nil : url
    }

    // MARK: - Upload

    func upload(
        imageData: Data,
        filename: String,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> UploadRecord {
        // Test mode for UI development
        if testMode {
            return try await mockUpload(imageData: imageData, filename: filename, progressHandler: progressHandler)
        }

        self.progressHandler = progressHandler

        // Get configuration
        let backendUrl = Config.backendURL
        guard !backendUrl.isEmpty else {
            throw ImghostError.notConfigured
        }

        // Ensure we have a valid token, refresh if needed
        try await AuthService.shared.ensureValidToken()

        guard let token = keychainService.loadAccessToken() else {
            throw ImghostError.notConfigured
        }

        guard let url = URL(string: "\(backendUrl)/upload") else {
            throw ImghostError.invalidURL
        }

        // Upload original data without resizing
        let processedData = imageData

        // Build multipart request
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body = createMultipartBody(imageData: processedData, filename: filename, boundary: boundary)

        // Perform upload with progress tracking
        let (data, response) = try await uploadWithProgress(request: request, bodyData: body)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImghostError.invalidResponse
        }

        // Handle 401 - try to refresh token and retry once
        if httpResponse.statusCode == 401 {
            try await AuthService.shared.refreshTokens()
            guard let newToken = keychainService.loadAccessToken() else {
                throw ImghostError.notConfigured
            }

            // Retry with new token
            var retryRequest = request
            retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await uploadWithProgress(request: retryRequest, bodyData: body)

            guard let retryHttpResponse = retryResponse as? HTTPURLResponse else {
                throw ImghostError.invalidResponse
            }

            guard retryHttpResponse.statusCode == 200 else {
                let message = String(data: retryData, encoding: .utf8)
                throw ImghostError.uploadFailed(statusCode: retryHttpResponse.statusCode, message: message)
            }

            return try parseUploadResponse(data: retryData, imageData: imageData, filename: filename)
        }

        // Handle 403 - email verification, subscription, or free-tier limits
        if httpResponse.statusCode == 403 {
            throw Self.parse403Error(data: data)
        }

        // Handle 413 - free tier file size limit
        if httpResponse.statusCode == 413 {
            throw Self.parse413Error(data: data)
        }

        // Handle 429 - free tier daily upload limit
        if httpResponse.statusCode == 429 {
            throw ImghostError.freeTierDailyLimitReached
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)
            throw ImghostError.uploadFailed(statusCode: httpResponse.statusCode, message: message)
        }

        return try parseUploadResponse(data: data, imageData: imageData, filename: filename)
    }

    /// Parse a 403 response into the appropriate ImghostError
    static func parse403Error(data: Data) -> ImghostError {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .emailVerificationRequired
        }

        let error = json["error"] as? String ?? ""
        let accountRequired = json["account_required"] as? Bool ?? false
        let upgradeRequired = json["upgrade_required"] as? Bool ?? false

        if accountRequired && upgradeRequired {
            return .uploadFailed(
                statusCode: 403,
                message: error.isEmpty ? "Subscribe to upload now. No email account required." : error
            )
        }

        if upgradeRequired {
            if error.contains("storage") {
                return .freeTierStorageFull
            }
            if error.contains("daily") || error.contains("Daily") {
                return .freeTierDailyLimitReached
            }
        }
        if let subscriptionRequired = json["subscription_required"] as? Bool, subscriptionRequired {
            return .subscriptionRequired
        }
        return .emailVerificationRequired
    }

    /// Parse a 413 (file too large for free tier) response
    static func parse413Error(data: Data) -> ImghostError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let upgradeRequired = json["upgrade_required"] as? Bool,
           upgradeRequired {
            return .freeTierFileSizeExceeded
        }
        return .uploadFailed(statusCode: 413, message: nil)
    }

    private func parseUploadResponse(data: Data, imageData: Data, filename: String) throws -> UploadRecord {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              let urlString = json["url"] as? String,
              let deleteUrl = json["deleteUrl"] as? String else {
            throw ImghostError.invalidResponse
        }

        let expiresAt = (json["expires_at"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }

        // Generate thumbnail
        let thumbnailData = imageProcessor.generateThumbnail(from: imageData)

        return UploadRecord(
            id: id,
            url: urlString,
            deleteUrl: deleteUrl,
            thumbnailData: thumbnailData,
            createdAt: Date(),
            originalFilename: filename,
            expiresAt: expiresAt
        )
    }

    // MARK: - File-based Upload (for large files / share extension)
    
    /// Upload a file from URL - uses streaming to avoid memory issues with large files
    func uploadFromFile(
        fileURL: URL,
        filename: String,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> UploadRecord {
        // Test mode for UI development
        if testMode {
            let data = try Data(contentsOf: fileURL)
            return try await mockUpload(imageData: data, filename: filename, progressHandler: progressHandler)
        }

        self.progressHandler = progressHandler

        // Get configuration
        let backendUrl = Config.backendURL
        guard !backendUrl.isEmpty else {
            throw ImghostError.notConfigured
        }

        // Ensure we have a valid token, refresh if needed
        try await AuthService.shared.ensureValidToken()

        guard let token = keychainService.loadAccessToken() else {
            throw ImghostError.notConfigured
        }

        guard let url = URL(string: "\(backendUrl)/upload") else {
            throw ImghostError.invalidURL
        }

        // Create multipart body as temp file to avoid memory issues
        let boundary = UUID().uuidString
        let tempFileURL = try createMultipartBodyFile(fileURL: fileURL, filename: filename, boundary: boundary)
        
        defer {
            // Clean up temp file
            try? FileManager.default.removeItem(at: tempFileURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 600 // 10 minutes for large files

        // Perform upload with progress tracking using file-based upload
        let (data, response) = try await uploadFileWithProgress(request: request, fileURL: tempFileURL)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImghostError.invalidResponse
        }

        // Handle 401 - try to refresh token and retry once
        if httpResponse.statusCode == 401 {
            try await AuthService.shared.refreshTokens()
            guard let newToken = keychainService.loadAccessToken() else {
                throw ImghostError.notConfigured
            }

            // Retry with new token
            var retryRequest = request
            retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await uploadFileWithProgress(request: retryRequest, fileURL: tempFileURL)

            guard let retryHttpResponse = retryResponse as? HTTPURLResponse else {
                throw ImghostError.invalidResponse
            }

            guard retryHttpResponse.statusCode == 200 else {
                let message = String(data: retryData, encoding: .utf8)
                throw ImghostError.uploadFailed(statusCode: retryHttpResponse.statusCode, message: message)
            }

            // Read a small chunk for thumbnail only
            let thumbnailData = generateThumbnailFromFile(fileURL: fileURL)
            return try parseUploadResponseWithThumbnail(data: retryData, thumbnailData: thumbnailData, filename: filename)
        }

        // Handle 403 - email verification, subscription, or free-tier limits
        if httpResponse.statusCode == 403 {
            throw Self.parse403Error(data: data)
        }

        // Handle 413 - free tier file size limit
        if httpResponse.statusCode == 413 {
            throw Self.parse413Error(data: data)
        }

        // Handle 429 - free tier daily upload limit
        if httpResponse.statusCode == 429 {
            throw ImghostError.freeTierDailyLimitReached
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)
            throw ImghostError.uploadFailed(statusCode: httpResponse.statusCode, message: message)
        }

        // Read a small chunk for thumbnail only
        let thumbnailData = generateThumbnailFromFile(fileURL: fileURL)
        return try parseUploadResponseWithThumbnail(data: data, thumbnailData: thumbnailData, filename: filename)
    }
    
    /// Create multipart body as a temp file (streaming, no memory pressure)
    private func createMultipartBodyFile(fileURL: URL, filename: String, boundary: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileURL = tempDir.appendingPathComponent(UUID().uuidString + ".multipart")
        
        FileManager.default.createFile(atPath: tempFileURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempFileURL)
        
        defer {
            try? fileHandle.close()
        }
        
        // Read first 12 bytes to detect actual content type
        let inputHandle = try FileHandle(forReadingFrom: fileURL)
        let headerBytes = inputHandle.readData(ofLength: 12)
        try inputHandle.seek(toOffset: 0) // Reset to beginning
        
        let contentType = mimeType(for: filename, data: headerBytes)
        
        // Write header
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n"
        fileHandle.write(header.data(using: .utf8)!)
        
        // Stream file content in chunks
        defer {
            try? inputHandle.close()
        }
        
        let chunkSize = 1024 * 1024 // 1MB chunks
        while autoreleasepool(invoking: {
            let chunk = inputHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                return false
            }
            fileHandle.write(chunk)
            return true
        }) {}
        
        // Write footer
        let footer = "\r\n--\(boundary)--\r\n"
        fileHandle.write(footer.data(using: .utf8)!)
        
        return tempFileURL
    }
    
    /// Upload from file URL with progress tracking
    private func uploadFileWithProgress(request: URLRequest, fileURL: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.uploadContinuation = continuation
            let task = backgroundSession.uploadTask(with: request, fromFile: fileURL)
            self.uploadTask = task
            task.resume()
        }
    }
    
    /// Generate thumbnail from file without loading entire file into memory
    private func generateThumbnailFromFile(fileURL: URL) -> Data? {
        // First, try to generate thumbnail as an image
        if let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Config.thumbnailSize,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                let uiImage = UIImage(cgImage: thumbnail)
                return uiImage.jpegData(compressionQuality: Config.thumbnailQuality)
            }
        }
        
        // If image thumbnail generation failed, try video thumbnail
        return generateVideoThumbnail(fileURL: fileURL)
    }
    
    /// Generate thumbnail from video file using AVFoundation
    private func generateVideoThumbnail(fileURL: URL) -> Data? {
        let asset = AVURLAsset(url: fileURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        // Set maximum size for the thumbnail
        imageGenerator.maximumSize = CGSize(width: Config.thumbnailSize, height: Config.thumbnailSize)
        
        // Try to get a frame from 1 second into the video (or beginning if shorter)
        let time = CMTime(seconds: 1.0, preferredTimescale: 600)
        
        do {
            let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
            let uiImage = UIImage(cgImage: cgImage)
            return uiImage.jpegData(compressionQuality: Config.thumbnailQuality)
        } catch {
            // If 1 second fails, try the very beginning
            do {
                let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
                let uiImage = UIImage(cgImage: cgImage)
                return uiImage.jpegData(compressionQuality: Config.thumbnailQuality)
            } catch {
                return nil
            }
        }
    }
    
    private func parseUploadResponseWithThumbnail(data: Data, thumbnailData: Data?, filename: String) throws -> UploadRecord {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              let urlString = json["url"] as? String,
              let deleteUrl = json["deleteUrl"] as? String else {
            throw ImghostError.invalidResponse
        }

        let expiresAt = (json["expires_at"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }

        return UploadRecord(
            id: id,
            url: urlString,
            deleteUrl: deleteUrl,
            thumbnailData: thumbnailData,
            createdAt: Date(),
            originalFilename: filename,
            expiresAt: expiresAt
        )
    }

    // MARK: - Delete

    func delete(record: UploadRecord) async throws {
        // Ensure we have a valid token
        try await AuthService.shared.ensureValidToken()

        guard let token = keychainService.loadAccessToken() else {
            throw ImghostError.notConfigured
        }

        guard let url = URL(string: record.deleteUrl) else {
            throw ImghostError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImghostError.invalidResponse
        }

        // Handle 401 - try to refresh and retry
        if httpResponse.statusCode == 401 {
            try await AuthService.shared.refreshTokens()
            guard let newToken = keychainService.loadAccessToken() else {
                throw ImghostError.notConfigured
            }

            var retryRequest = URLRequest(url: url)
            retryRequest.httpMethod = "DELETE"
            retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")

            let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
            guard let retryHttpResponse = retryResponse as? HTTPURLResponse else {
                throw ImghostError.invalidResponse
            }

            guard retryHttpResponse.statusCode == 200 || retryHttpResponse.statusCode == 204 else {
                let message = String(data: retryData, encoding: .utf8)
                throw ImghostError.deleteFailed(statusCode: retryHttpResponse.statusCode, message: message)
            }
            return
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 204 else {
            let message = String(data: data, encoding: .utf8)
            throw ImghostError.deleteFailed(statusCode: httpResponse.statusCode, message: message)
        }
    }

    // MARK: - Test Connection

    func testConnection() async throws {
        guard let testImageData = imageProcessor.createTestImage() else {
            throw ImghostError.imageProcessingFailed
        }

        let record = try await upload(imageData: testImageData, filename: "test.png")

        // Try to delete the test image
        try? await delete(record: record)
    }

    // MARK: - Cancel

    func cancelUpload() {
        uploadTask?.cancel()
        uploadTask = nil
    }

    // MARK: - Private Methods

    private func createMultipartBody(imageData: Data, filename: String, boundary: String) -> Data {
        var body = Data()

        // Determine content type from actual data (preferred) or filename
        let contentType = mimeType(for: filename, data: imageData)

        // Add file part - backend expects "image" field name
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)

        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return body
    }

    /// Detect MIME type from actual file data using magic bytes
    private func detectMimeType(from data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        
        let bytes = [UInt8](data.prefix(12))
        
        // JPEG: FF D8 FF
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return "image/jpeg"
        }
        
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 &&
           bytes[4] == 0x0D && bytes[5] == 0x0A && bytes[6] == 0x1A && bytes[7] == 0x0A {
            return "image/png"
        }
        
        // GIF: 47 49 46 38 (GIF8)
        if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38 {
            return "image/gif"
        }
        
        // WebP: RIFF....WEBP
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
           bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 {
            return "image/webp"
        }
        
        // HEIC/HEIF: ftyp box
        if bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
            let brand = String(bytes: bytes[8...11], encoding: .ascii) ?? ""
            if ["heic", "heix", "mif1", "msf1", "miaf"].contains(brand) {
                return "image/heic"
            }
            if ["heif", "heim", "heis"].contains(brand) {
                return "image/heif"
            }
            // MP4/MOV video
            if ["isom", "iso2", "mp41", "mp42", "M4V ", "qt  "].contains(brand) {
                return "video/mp4"
            }
        }
        
        return nil
    }
    
    private func mimeType(for filename: String, data: Data? = nil) -> String {
        // First try to detect from actual data (most accurate)
        if let data = data, let detected = detectMimeType(from: data) {
            return detected
        }
        
        // Fall back to filename-based detection
        let lowercased = filename.lowercased()
        
        // Images
        if lowercased.hasSuffix(".jpg") || lowercased.hasSuffix(".jpeg") { return "image/jpeg" }
        if lowercased.hasSuffix(".png") { return "image/png" }
        if lowercased.hasSuffix(".gif") { return "image/gif" }
        if lowercased.hasSuffix(".webp") { return "image/webp" }
        if lowercased.hasSuffix(".heic") { return "image/heic" }
        if lowercased.hasSuffix(".heif") { return "image/heif" }
        if lowercased.hasSuffix(".bmp") { return "image/bmp" }
        if lowercased.hasSuffix(".tiff") || lowercased.hasSuffix(".tif") { return "image/tiff" }
        if lowercased.hasSuffix(".svg") { return "image/svg+xml" }
        if lowercased.hasSuffix(".ico") { return "image/x-icon" }
        
        // Videos
        if lowercased.hasSuffix(".mp4") { return "video/mp4" }
        if lowercased.hasSuffix(".mov") { return "video/quicktime" }
        if lowercased.hasSuffix(".m4v") { return "video/x-m4v" }
        if lowercased.hasSuffix(".avi") { return "video/x-msvideo" }
        if lowercased.hasSuffix(".webm") { return "video/webm" }
        if lowercased.hasSuffix(".mkv") { return "video/x-matroska" }
        if lowercased.hasSuffix(".flv") { return "video/x-flv" }
        if lowercased.hasSuffix(".wmv") { return "video/x-ms-wmv" }
        if lowercased.hasSuffix(".mpeg") || lowercased.hasSuffix(".mpg") { return "video/mpeg" }
        
        // Audio
        if lowercased.hasSuffix(".mp3") { return "audio/mpeg" }
        if lowercased.hasSuffix(".wav") { return "audio/wav" }
        if lowercased.hasSuffix(".m4a") { return "audio/mp4" }
        if lowercased.hasSuffix(".aac") { return "audio/aac" }
        if lowercased.hasSuffix(".ogg") { return "audio/ogg" }
        if lowercased.hasSuffix(".flac") { return "audio/flac" }
        if lowercased.hasSuffix(".aiff") || lowercased.hasSuffix(".aif") { return "audio/aiff" }
        if lowercased.hasSuffix(".wma") { return "audio/x-ms-wma" }
        
        // Documents
        if lowercased.hasSuffix(".pdf") { return "application/pdf" }
        if lowercased.hasSuffix(".doc") { return "application/msword" }
        if lowercased.hasSuffix(".docx") { return "application/vnd.openxmlformats-officedocument.wordprocessingml.document" }
        if lowercased.hasSuffix(".xls") { return "application/vnd.ms-excel" }
        if lowercased.hasSuffix(".xlsx") { return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }
        if lowercased.hasSuffix(".ppt") { return "application/vnd.ms-powerpoint" }
        if lowercased.hasSuffix(".pptx") { return "application/vnd.openxmlformats-officedocument.presentationml.presentation" }
        if lowercased.hasSuffix(".txt") { return "text/plain" }
        if lowercased.hasSuffix(".rtf") { return "application/rtf" }
        if lowercased.hasSuffix(".csv") { return "text/csv" }
        if lowercased.hasSuffix(".md") { return "text/markdown" }
        
        // Web
        if lowercased.hasSuffix(".html") || lowercased.hasSuffix(".htm") { return "text/html" }
        if lowercased.hasSuffix(".css") { return "text/css" }
        if lowercased.hasSuffix(".js") { return "application/javascript" }
        if lowercased.hasSuffix(".json") { return "application/json" }
        if lowercased.hasSuffix(".xml") { return "application/xml" }
        
        // Archives
        if lowercased.hasSuffix(".zip") { return "application/zip" }
        if lowercased.hasSuffix(".gz") || lowercased.hasSuffix(".gzip") { return "application/gzip" }
        if lowercased.hasSuffix(".tar") { return "application/x-tar" }
        if lowercased.hasSuffix(".rar") { return "application/vnd.rar" }
        if lowercased.hasSuffix(".7z") { return "application/x-7z-compressed" }
        
        // Default
        return "application/octet-stream"
    }

    private func uploadWithProgress(request: URLRequest, bodyData: Data) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let task = session.uploadTask(with: request, from: bodyData) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: ImghostError.networkError(underlying: error))
                    return
                }

                guard let data = data, let response = response else {
                    continuation.resume(throwing: ImghostError.invalidResponse)
                    return
                }

                continuation.resume(returning: (data, response))
            }

            self.uploadTask = task
            task.resume()
        }
    }

    // MARK: - Mock Upload for Testing

    private func mockUpload(imageData: Data, filename: String, progressHandler: ((Double) -> Void)?) async throws -> UploadRecord {
        // Simulate upload progress
        for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
            await MainActor.run {
                progressHandler?(progress)
            }
        }

        let id = UUID().uuidString.prefix(8).lowercased()
        let thumbnailData = imageProcessor.generateThumbnail(from: imageData)

        return UploadRecord(
            id: String(id),
            url: "https://img.example.com/\(id).png",
            deleteUrl: "https://img.example.com/delete/\(id)",
            thumbnailData: thumbnailData,
            createdAt: Date(),
            originalFilename: filename
        )
    }
}

// MARK: - URLSessionTaskDelegate & URLSessionDataDelegate

extension UploadService: URLSessionTaskDelegate, URLSessionDataDelegate {
    // Track response data for file-based uploads
    private static var responseData = Data()
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        DispatchQueue.main.async {
            self.progressHandler?(progress)
        }
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        UploadService.responseData.append(data)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            UploadService.responseData = Data()
        }
        
        if let error = error {
            uploadContinuation?.resume(throwing: ImghostError.networkError(underlying: error))
            uploadContinuation = nil
            return
        }
        
        guard let response = task.response else {
            uploadContinuation?.resume(throwing: ImghostError.invalidResponse)
            uploadContinuation = nil
            return
        }
        
        uploadContinuation?.resume(returning: (UploadService.responseData, response))
        uploadContinuation = nil
    }
}
