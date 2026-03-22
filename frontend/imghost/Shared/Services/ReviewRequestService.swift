import Foundation

/// Decides when to ask the user for an App Store review.
///
/// Rules:
/// - Never ask before 3 successful uploads (user hasn't formed an opinion yet).
/// - Never ask again within 60 days of the last prompt.
/// - After the first ask, re-ask every 10 uploads — but still respect the 60-day
///   cooldown. Apple caps system prompts at 3 per year regardless, so being
///   conservative here is fine.
final class ReviewRequestService {
    static let shared = ReviewRequestService()

    // MARK: - Constants

    private let minimumUploadsBeforeFirstAsk = 3
    private let uploadsPerSubsequentAsk = 10
    private let cooldownDays = 60

    // MARK: - UserDefaults Keys

    private let keyUploadCount    = "reviewRequest.uploadCount"
    private let keyLastRequestDate = "reviewRequest.lastRequestDate"
    private let keyLastAskCount   = "reviewRequest.lastAskUploadCount"

    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Public Interface

    /// Call this after every successful upload.
    /// Returns `true` when the caller should trigger `requestReview()`.
    @discardableResult
    func recordSuccessfulUpload() -> Bool {
        let newCount = uploadCount + 1
        defaults.set(newCount, forKey: keyUploadCount)
        return shouldRequest(uploadCount: newCount)
    }

    // MARK: - Private

    private var uploadCount: Int {
        defaults.integer(forKey: keyUploadCount)
    }

    private var lastRequestDate: Date? {
        defaults.object(forKey: keyLastRequestDate) as? Date
    }

    private var lastAskUploadCount: Int {
        defaults.integer(forKey: keyLastAskCount)
    }

    private func shouldRequest(uploadCount: Int) -> Bool {
        // Must have hit the minimum threshold
        guard uploadCount >= minimumUploadsBeforeFirstAsk else { return false }

        // Respect the cooldown window
        if let last = lastRequestDate {
            let daysSinceLast = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0
            guard daysSinceLast >= cooldownDays else { return false }
        }

        // First ask: haven't asked before
        if lastRequestDate == nil {
            markAsAsked(at: uploadCount)
            return true
        }

        // Subsequent asks: every N uploads since the last ask
        let uploadsSinceLastAsk = uploadCount - lastAskUploadCount
        if uploadsSinceLastAsk >= uploadsPerSubsequentAsk {
            markAsAsked(at: uploadCount)
            return true
        }

        return false
    }

    private func markAsAsked(at count: Int) {
        defaults.set(Date(), forKey: keyLastRequestDate)
        defaults.set(count, forKey: keyLastAskCount)
    }
}
