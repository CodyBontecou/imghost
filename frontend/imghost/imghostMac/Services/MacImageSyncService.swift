import Foundation
import AppKit

/// macOS-specific image sync service using NSImage instead of UIImage
final class ImageSyncService {
    static let shared = ImageSyncService()

    private let historyService = HistoryService.shared
    private let keychainService = KeychainService.shared

    private init() {}

    func syncImages() async throws {
        guard let accessToken = keychainService.loadAccessToken() else {
            throw SyncError.notAuthenticated
        }

        let backendUrl = Config.backendURL
        guard let url = URL(string: "\(backendUrl)/images") else {
            throw SyncError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw SyncError.serverError(statusCode: httpResponse.statusCode)
        }

        let imagesResponse = try JSONDecoder().decode(MacImagesResponse.self, from: data)

        let existingRecords = (try? historyService.loadAll()) ?? []
        let existingById = Dictionary(uniqueKeysWithValues: existingRecords.map { ($0.id, $0) })

        var syncedRecords: [UploadRecord] = []
        for image in imagesResponse.images {
            let createdAt = Date(timeIntervalSince1970: TimeInterval(image.createdAt) / 1000)
            let existingRecord = existingById[image.id]

            var thumbnailData = existingRecord?.thumbnailData
            if thumbnailData == nil {
                thumbnailData = await fetchAndGenerateThumbnail(from: image.url)
            }

            let record = UploadRecord(
                id: image.id,
                url: image.url,
                deleteUrl: image.deleteUrl,
                thumbnailData: thumbnailData,
                createdAt: createdAt,
                originalFilename: image.filename
            )
            syncedRecords.append(record)
        }

        syncedRecords.sort { $0.createdAt > $1.createdAt }

        try historyService.clear()
        for record in syncedRecords.reversed() {
            try historyService.save(record)
        }
    }

    private func fetchAndGenerateThumbnail(from urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }
            return MacImageHelper.generateThumbnail(from: data)
        } catch {
            return nil
        }
    }
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case notAuthenticated
    case invalidURL
    case invalidResponse
    case serverError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated"
        case .invalidURL: return "Invalid backend URL"
        case .invalidResponse: return "Invalid server response"
        case .serverError(let statusCode): return "Server error: \(statusCode)"
        }
    }
}

// MARK: - Response Models

private struct MacImagesResponse: Codable {
    let images: [MacImageItem]
    let count: Int
}

private struct MacImageItem: Codable {
    let id: String
    let filename: String
    let url: String
    let deleteUrl: String
    let sizeBytes: Int
    let contentType: String
    let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case id, filename, url
        case deleteUrl = "delete_url"
        case sizeBytes = "size_bytes"
        case contentType = "content_type"
        case createdAt = "created_at"
    }
}
