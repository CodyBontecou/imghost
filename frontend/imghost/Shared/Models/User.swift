import Foundation

/// User identity and storage information.
/// Note: Subscription status should be accessed via SubscriptionState, not this model.
struct User: Codable, Equatable {
    let id: String
    let email: String
    let emailVerified: Bool
    let storageUsedBytes: Int
    let storageLimitBytes: Int
    let imageCount: Int?
    let isAnonymous: Bool?

    var displayEmail: String {
        isAnonymous == true ? "Anonymous device account" : email
    }

    var storageUsedFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(storageUsedBytes), countStyle: .file)
    }

    var storageLimitFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(storageLimitBytes), countStyle: .file)
    }

    var storagePercentUsed: Double {
        guard storageLimitBytes > 0 else { return 0 }
        return Double(storageUsedBytes) / Double(storageLimitBytes) * 100
    }

    var storageRemainingBytes: Int {
        max(0, storageLimitBytes - storageUsedBytes)
    }

    var storageRemainingFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(storageRemainingBytes), countStyle: .file)
    }

    func canUpload(bytes: Int) -> Bool {
        return bytes <= storageRemainingBytes
    }

    enum CodingKeys: String, CodingKey {
        case id = "user_id"
        case email
        case emailVerified = "email_verified"
        case storageUsedBytes = "storage_used_bytes"
        case storageLimitBytes = "storage_limit_bytes"
        case imageCount = "image_count"
        case isAnonymous = "is_anonymous"
    }
}
