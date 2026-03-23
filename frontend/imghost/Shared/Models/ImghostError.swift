import Foundation

enum ImghostError: LocalizedError {
    case notConfigured
    case invalidURL
    case uploadFailed(statusCode: Int, message: String?)
    case networkError(underlying: Error)
    case invalidResponse
    case keychainError(status: OSStatus)
    case fileSystemError(underlying: Error)
    case imageProcessingFailed
    case deleteFailed(statusCode: Int, message: String?)
    case emailVerificationRequired
    case subscriptionRequired
    case freeTierFileSizeExceeded   // File > 5 MB on free tier
    case freeTierStorageFull        // 50 MB quota reached on free tier
    case freeTierDailyLimitReached  // 20 uploads/day on free tier

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "error.not_configured.description")
        case .invalidURL:
            return String(localized: "error.invalid_url.description")
        case .uploadFailed(let statusCode, let message):
            if let message = message {
                return String(format: String(localized: "error.upload_failed.with_message"), statusCode, message)
            }
            return String(format: String(localized: "error.upload_failed.status_only"), statusCode)
        case .networkError(let underlying):
            return String(format: String(localized: "error.network.description"), underlying.localizedDescription)
        case .invalidResponse:
            return String(localized: "error.invalid_response.description")
        case .keychainError(let status):
            return String(format: String(localized: "error.keychain.description"), status)
        case .fileSystemError(let underlying):
            return String(format: String(localized: "error.file_system.description"), underlying.localizedDescription)
        case .imageProcessingFailed:
            return String(localized: "error.image_processing.description")
        case .deleteFailed(let statusCode, let message):
            if let message = message {
                return String(format: String(localized: "error.delete_failed.with_message"), statusCode, message)
            }
            return String(format: String(localized: "error.delete_failed.status_only"), statusCode)
        case .emailVerificationRequired:
            return String(localized: "error.email_not_verified.description")
        case .subscriptionRequired:
            return String(localized: "error.subscription_required.description")
        case .freeTierFileSizeExceeded:
            return String(localized: "error.free_tier_file_size.description")
        case .freeTierStorageFull:
            return String(localized: "error.free_tier_storage_full.description")
        case .freeTierDailyLimitReached:
            return String(localized: "error.free_tier_daily_limit.description")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notConfigured:
            return String(localized: "error.not_configured.recovery")
        case .invalidURL:
            return String(localized: "error.invalid_url.recovery")
        case .uploadFailed:
            return String(localized: "error.upload_failed.recovery")
        case .networkError:
            return String(localized: "error.network.recovery")
        case .invalidResponse:
            return String(localized: "error.invalid_response.recovery")
        case .keychainError:
            return String(localized: "error.keychain.recovery")
        case .fileSystemError:
            return String(localized: "error.file_system.recovery")
        case .imageProcessingFailed:
            return String(localized: "error.image_processing.recovery")
        case .deleteFailed:
            return String(localized: "error.delete_failed.recovery")
        case .emailVerificationRequired:
            return String(localized: "error.email_not_verified.recovery")
        case .subscriptionRequired:
            return String(localized: "error.subscription_required.recovery")
        case .freeTierFileSizeExceeded, .freeTierStorageFull, .freeTierDailyLimitReached:
            return String(localized: "error.free_tier.upgrade_recovery")
        }
    }
}
