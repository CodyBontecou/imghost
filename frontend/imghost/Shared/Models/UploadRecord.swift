import Foundation

struct UploadRecord: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let url: String
    let deleteUrl: String
    let thumbnailData: Data?
    let createdAt: Date
    let originalFilename: String?
    /// Non-nil for free-tier uploads; these are automatically deleted server-side after 7 days.
    let expiresAt: Date?

    init(
        id: String,
        url: String,
        deleteUrl: String,
        thumbnailData: Data? = nil,
        createdAt: Date = Date(),
        originalFilename: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.deleteUrl = deleteUrl
        self.thumbnailData = thumbnailData
        self.createdAt = createdAt
        self.originalFilename = originalFilename
        self.expiresAt = expiresAt
    }

    /// Whether this upload is on the free tier (has a server-side expiration).
    var isTemporary: Bool { expiresAt != nil }

    /// Human-readable days until expiration, or nil if permanent.
    var daysUntilExpiry: Int? {
        guard let expiresAt else { return nil }
        let diff = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt)
        return max(0, diff.day ?? 0)
    }

    static func == (lhs: UploadRecord, rhs: UploadRecord) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Preview/Test Data
extension UploadRecord {
    static let preview = UploadRecord(
        id: "abc123",
        url: "https://img.example.com/abc123.png",
        deleteUrl: "https://img.example.com/delete/abc123",
        thumbnailData: nil,
        createdAt: Date(),
        originalFilename: "photo.jpg",
        expiresAt: Date().addingTimeInterval(7 * 86400)
    )

    static let previewList: [UploadRecord] = [
        UploadRecord(
            id: "abc123",
            url: "https://img.example.com/abc123.png",
            deleteUrl: "https://img.example.com/delete/abc123",
            createdAt: Date(),
            originalFilename: "photo1.jpg"
        ),
        UploadRecord(
            id: "def456",
            url: "https://img.example.com/def456.png",
            deleteUrl: "https://img.example.com/delete/def456",
            createdAt: Date().addingTimeInterval(-3600),
            originalFilename: "photo2.jpg"
        ),
        UploadRecord(
            id: "ghi789",
            url: "https://img.example.com/ghi789.png",
            deleteUrl: "https://img.example.com/delete/ghi789",
            createdAt: Date().addingTimeInterval(-86400),
            originalFilename: "screenshot.png"
        )
    ]
}
