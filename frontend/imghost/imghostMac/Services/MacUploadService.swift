import Foundation
import AppKit
import AVFoundation

/// macOS-specific upload service using NSImage instead of UIImage
final class MacUploadService: NSObject {
    static let shared = MacUploadService()

    private let keychainService = KeychainService.shared

    private var progressHandler: ((Double) -> Void)?
    private var uploadTask: URLSessionUploadTask?
    private var uploadContinuation: CheckedContinuation<(Data, URLResponse), Error>?

    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    var testMode = false

    private override init() {
        super.init()
    }

    var isConfigured: Bool {
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
        if testMode {
            return try await mockUpload(imageData: imageData, filename: filename, progressHandler: progressHandler)
        }

        self.progressHandler = progressHandler

        let backendUrl = Config.backendURL
        guard !backendUrl.isEmpty else { throw ImghostError.notConfigured }

        try await AuthService.shared.ensureValidToken()
        guard let token = keychainService.loadAccessToken() else { throw ImghostError.notConfigured }
        guard let url = URL(string: "\(backendUrl)/upload") else { throw ImghostError.invalidURL }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body = createMultipartBody(imageData: imageData, filename: filename, boundary: boundary)

        let (data, response) = try await uploadWithProgress(request: request, bodyData: body)

        guard let httpResponse = response as? HTTPURLResponse else { throw ImghostError.invalidResponse }

        if httpResponse.statusCode == 401 {
            try await AuthService.shared.refreshTokens()
            guard let newToken = keychainService.loadAccessToken() else { throw ImghostError.notConfigured }

            var retryRequest = request
            retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await uploadWithProgress(request: retryRequest, bodyData: body)

            guard let retryHttpResponse = retryResponse as? HTTPURLResponse else { throw ImghostError.invalidResponse }
            guard retryHttpResponse.statusCode == 200 else {
                let message = String(data: retryData, encoding: .utf8)
                throw ImghostError.uploadFailed(statusCode: retryHttpResponse.statusCode, message: message)
            }
            return try parseUploadResponse(data: retryData, imageData: imageData, filename: filename)
        }

        if httpResponse.statusCode == 403 {
            throw Self.parse403Error(data: data)
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)
            throw ImghostError.uploadFailed(statusCode: httpResponse.statusCode, message: message)
        }

        return try parseUploadResponse(data: data, imageData: imageData, filename: filename)
    }

    // MARK: - File Upload

    func uploadFromFile(
        fileURL: URL,
        filename: String,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> UploadRecord {
        self.progressHandler = progressHandler

        let backendUrl = Config.backendURL
        guard !backendUrl.isEmpty else { throw ImghostError.notConfigured }

        try await AuthService.shared.ensureValidToken()
        guard let token = keychainService.loadAccessToken() else { throw ImghostError.notConfigured }
        guard let url = URL(string: "\(backendUrl)/upload") else { throw ImghostError.invalidURL }

        let boundary = UUID().uuidString
        let tempFileURL = try createMultipartBodyFile(fileURL: fileURL, filename: filename, boundary: boundary)

        defer { try? FileManager.default.removeItem(at: tempFileURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 600

        let (data, response) = try await uploadFileWithProgress(request: request, fileURL: tempFileURL)

        guard let httpResponse = response as? HTTPURLResponse else { throw ImghostError.invalidResponse }

        if httpResponse.statusCode == 401 {
            try await AuthService.shared.refreshTokens()
            guard let newToken = keychainService.loadAccessToken() else { throw ImghostError.notConfigured }
            var retryRequest = request
            retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await uploadFileWithProgress(request: retryRequest, fileURL: tempFileURL)
            guard let retryHttpResponse = retryResponse as? HTTPURLResponse else { throw ImghostError.invalidResponse }
            guard retryHttpResponse.statusCode == 200 else {
                let message = String(data: retryData, encoding: .utf8)
                throw ImghostError.uploadFailed(statusCode: retryHttpResponse.statusCode, message: message)
            }
            let thumbnailData = generateThumbnailFromFile(fileURL: fileURL)
            return try parseUploadResponseWithThumbnail(data: retryData, thumbnailData: thumbnailData, filename: filename)
        }

        if httpResponse.statusCode == 403 {
            throw Self.parse403Error(data: data)
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)
            throw ImghostError.uploadFailed(statusCode: httpResponse.statusCode, message: message)
        }

        let thumbnailData = generateThumbnailFromFile(fileURL: fileURL)
        return try parseUploadResponseWithThumbnail(data: data, thumbnailData: thumbnailData, filename: filename)
    }

    // MARK: - Delete

    func delete(record: UploadRecord) async throws {
        try await AuthService.shared.ensureValidToken()
        guard let token = keychainService.loadAccessToken() else { throw ImghostError.notConfigured }
        guard let url = URL(string: record.deleteUrl) else { throw ImghostError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw ImghostError.invalidResponse }

        if httpResponse.statusCode == 401 {
            try await AuthService.shared.refreshTokens()
            guard let newToken = keychainService.loadAccessToken() else { throw ImghostError.notConfigured }
            var retryRequest = URLRequest(url: url)
            retryRequest.httpMethod = "DELETE"
            retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
            guard let retryHttpResponse = retryResponse as? HTTPURLResponse else { throw ImghostError.invalidResponse }
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

    func cancelUpload() {
        uploadTask?.cancel()
        uploadTask = nil
    }

    // MARK: - 403 Parsing

    /// Parse a 403 response to distinguish anonymous upload gating, subscriptions, and email verification
    static func parse403Error(data: Data) -> ImghostError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let error = json["error"] as? String ?? ""
            let accountRequired = json["account_required"] as? Bool ?? false
            let upgradeRequired = json["upgrade_required"] as? Bool ?? false

            if accountRequired && upgradeRequired {
                return .uploadFailed(
                    statusCode: 403,
                    message: error.isEmpty ? "Subscribe to upload now. No email account required." : error
                )
            }

            if let subscriptionRequired = json["subscription_required"] as? Bool,
               subscriptionRequired {
                return .subscriptionRequired
            }
        }
        return .emailVerificationRequired
    }

    // MARK: - Private

    private func parseUploadResponse(data: Data, imageData: Data, filename: String) throws -> UploadRecord {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              let urlString = json["url"] as? String,
              let deleteUrl = json["deleteUrl"] as? String else {
            throw ImghostError.invalidResponse
        }

        let thumbnailData = MacImageHelper.generateThumbnail(from: imageData)
        return UploadRecord(id: id, url: urlString, deleteUrl: deleteUrl, thumbnailData: thumbnailData, createdAt: Date(), originalFilename: filename)
    }

    private func parseUploadResponseWithThumbnail(data: Data, thumbnailData: Data?, filename: String) throws -> UploadRecord {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              let urlString = json["url"] as? String,
              let deleteUrl = json["deleteUrl"] as? String else {
            throw ImghostError.invalidResponse
        }

        return UploadRecord(id: id, url: urlString, deleteUrl: deleteUrl, thumbnailData: thumbnailData, createdAt: Date(), originalFilename: filename)
    }

    private func generateThumbnailFromFile(fileURL: URL) -> Data? {
        if let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Config.thumbnailSize,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                let nsImage = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
                return MacImageHelper.jpegData(from: nsImage, quality: Config.thumbnailQuality)
            }
        }
        // Try video thumbnail
        return generateVideoThumbnail(fileURL: fileURL)
    }

    private func generateVideoThumbnail(fileURL: URL) -> Data? {
        let asset = AVURLAsset(url: fileURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: Config.thumbnailSize, height: Config.thumbnailSize)

        let time = CMTime(seconds: 1.0, preferredTimescale: 600)
        do {
            let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            return MacImageHelper.jpegData(from: nsImage, quality: Config.thumbnailQuality)
        } catch {
            do {
                let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                return MacImageHelper.jpegData(from: nsImage, quality: Config.thumbnailQuality)
            } catch {
                return nil
            }
        }
    }

    private func createMultipartBody(imageData: Data, filename: String, boundary: String) -> Data {
        var body = Data()
        let contentType = mimeType(for: filename, data: imageData)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private func createMultipartBodyFile(fileURL: URL, filename: String, boundary: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileURL = tempDir.appendingPathComponent(UUID().uuidString + ".multipart")

        FileManager.default.createFile(atPath: tempFileURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempFileURL)
        defer { try? fileHandle.close() }

        let inputHandle = try FileHandle(forReadingFrom: fileURL)
        let headerBytes = inputHandle.readData(ofLength: 12)
        try inputHandle.seek(toOffset: 0)

        let contentType = mimeType(for: filename, data: headerBytes)

        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n"
        fileHandle.write(header.data(using: .utf8)!)

        defer { try? inputHandle.close() }

        let chunkSize = 1024 * 1024
        while autoreleasepool(invoking: {
            let chunk = inputHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { return false }
            fileHandle.write(chunk)
            return true
        }) {}

        let footer = "\r\n--\(boundary)--\r\n"
        fileHandle.write(footer.data(using: .utf8)!)
        return tempFileURL
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

    private func uploadFileWithProgress(request: URLRequest, fileURL: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.uploadContinuation = continuation
            let task = backgroundSession.uploadTask(with: request, fromFile: fileURL)
            self.uploadTask = task
            task.resume()
        }
    }

    private func mimeType(for filename: String, data: Data? = nil) -> String {
        if let data = data, let detected = detectMimeType(from: data) { return detected }

        let lowercased = filename.lowercased()
        if lowercased.hasSuffix(".jpg") || lowercased.hasSuffix(".jpeg") { return "image/jpeg" }
        if lowercased.hasSuffix(".png") { return "image/png" }
        if lowercased.hasSuffix(".gif") { return "image/gif" }
        if lowercased.hasSuffix(".webp") { return "image/webp" }
        if lowercased.hasSuffix(".heic") { return "image/heic" }
        if lowercased.hasSuffix(".mp4") { return "video/mp4" }
        if lowercased.hasSuffix(".mov") { return "video/quicktime" }
        if lowercased.hasSuffix(".pdf") { return "application/pdf" }
        return "application/octet-stream"
    }

    private func detectMimeType(from data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF { return "image/jpeg" }
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 { return "image/png" }
        if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38 { return "image/gif" }
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
           bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 { return "image/webp" }
        return nil
    }

    private func mockUpload(imageData: Data, filename: String, progressHandler: ((Double) -> Void)?) async throws -> UploadRecord {
        for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
            try await Task.sleep(nanoseconds: 100_000_000)
            await MainActor.run { progressHandler?(progress) }
        }
        let id = UUID().uuidString.prefix(8).lowercased()
        let thumbnailData = MacImageHelper.generateThumbnail(from: imageData)
        return UploadRecord(id: String(id), url: "https://img.example.com/\(id).png", deleteUrl: "https://img.example.com/delete/\(id)", thumbnailData: thumbnailData, createdAt: Date(), originalFilename: filename)
    }
}

// MARK: - URLSessionTaskDelegate & URLSessionDataDelegate

extension MacUploadService: URLSessionTaskDelegate, URLSessionDataDelegate {
    private static var responseData = Data()

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        DispatchQueue.main.async { self.progressHandler?(progress) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MacUploadService.responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { MacUploadService.responseData = Data() }
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
        uploadContinuation?.resume(returning: (MacUploadService.responseData, response))
        uploadContinuation = nil
    }
}
