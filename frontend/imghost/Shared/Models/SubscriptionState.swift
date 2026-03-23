import Foundation

/// Manages subscription state across the app
@MainActor
final class SubscriptionState: ObservableObject {
    static let shared = SubscriptionState()

    @Published private(set) var status: Status = .loading
    @Published private(set) var tier: String = "free"
    @Published private(set) var trialDaysRemaining: Int?
    @Published private(set) var currentPeriodEnd: Date?
    @Published private(set) var trialEndsAt: Date?
    @Published private(set) var willRenew: Bool = false
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?

    enum Status: Equatable {
        case loading
        case free                // Free tier — has access with limits (50MB, 7-day TTL)
        case noSubscription      // Never subscribed, no trial - show paywall
        case trialing            // In free trial - allow access
        case trialExpired        // Trial ended, needs subscription - show paywall
        case subscribed          // Active paid subscription - allow access
        case expired             // Subscription lapsed - show paywall
        case cancelled           // Cancelled but still active until period end
        case error               // Transient error checking status - don't show paywall

        var displayName: String {
            switch self {
            case .loading:
                return "Loading..."
            case .free:
                return "Free"
            case .noSubscription:
                return "No Subscription"
            case .trialing:
                return "Free Trial"
            case .trialExpired:
                return "Trial Expired"
            case .subscribed:
                return "Pro"
            case .expired:
                return "Expired"
            case .cancelled:
                return "Cancelled"
            case .error:
                return "Error"
            }
        }
    }

    /// Whether user has access to app features (upload/view)
    var hasAccess: Bool {
        switch status {
        case .free, .trialing, .subscribed, .cancelled:
            return true
        default:
            return false
        }
    }

    /// Whether this is a free-tier user (limited storage, 7-day TTL on uploads)
    var isFree: Bool { status == .free }

    /// Whether to show the hard paywall gate
    var shouldShowPaywall: Bool {
        switch status {
        case .noSubscription, .trialExpired, .expired:
            return true
        default:
            return false // .free shows soft upgrade prompts, not a hard gate
        }
    }

    /// Whether to show an upgrade nudge (softer than full paywall)
    var shouldNudgeUpgrade: Bool {
        status == .free
    }

    /// Check subscription status from backend (with retry for transient errors)
    func checkStatus() async {
        isLoading = true
        error = nil

        // Retry up to 2 times for transient failures
        for attempt in 1...3 {
            do {
                let response = try await SubscriptionService.shared.getSubscriptionStatus()
                updateFromResponse(response)
                isLoading = false
                return
            } catch let err as SubscriptionError where err == .notAuthenticated {
                // Auth failure after token refresh was already attempted — don't retry
                self.error = err
                isLoading = false
                print("[SubscriptionState] Auth failed after refresh, showing error state: \(err)")
                status = .error
                return
            } catch {
                print("[SubscriptionState] Attempt \(attempt)/3 failed: \(error)")
                if attempt < 3 {
                    // Brief delay before retry (500ms, then 1s)
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                } else {
                    self.error = error
                    isLoading = false
                    print("[SubscriptionState] All attempts failed, showing error state")
                    // Show error state instead of paywall — transient errors shouldn't block the user
                    status = .error
                }
            }
        }
    }

    /// Update state from backend response
    func updateFromResponse(_ response: SubscriptionStatusResponse) {
        tier = response.tier

        switch response.status {
        case "active":
            // Distinguish free-tier active from paid-tier active
            if response.tier == "free" {
                status = .free
            } else {
                status = .subscribed
            }
        case "trialing":
            status = .trialing
        case "expired":
            if response.tier == "trial" || response.tier == "free" {
                status = .trialExpired
            } else {
                status = .expired
            }
        case "cancelled":
            status = .cancelled
        case "none":
            status = .noSubscription
        default:
            status = .noSubscription
        }

        trialDaysRemaining = response.trialDaysRemaining
        willRenew = response.willRenew

        if let expiresAtString = response.expiresAt {
            currentPeriodEnd = ISO8601DateFormatter().date(from: expiresAtString)
        }

        if let trialEndsAtString = response.trialEndsAt {
            trialEndsAt = ISO8601DateFormatter().date(from: trialEndsAtString)
        }
    }

    /// Reset state on logout
    func reset() {
        status = .loading
        tier = "free"
        trialDaysRemaining = nil
        currentPeriodEnd = nil
        trialEndsAt = nil
        willRenew = false
        error = nil
    }
}

// MARK: - Response Types

struct SubscriptionStatusResponse: Codable {
    let status: String
    let tier: String
    let hasAccess: Bool
    let productId: String?
    let expiresAt: String?
    let trialEndsAt: String?
    let trialDaysRemaining: Int?
    let willRenew: Bool
    let user: SubscriptionUserInfo?

    enum CodingKeys: String, CodingKey {
        case status
        case tier
        case hasAccess = "has_access"
        case productId = "product_id"
        case expiresAt = "expires_at"
        case trialEndsAt = "trial_ends_at"
        case trialDaysRemaining = "trial_days_remaining"
        case willRenew = "will_renew"
        case user
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        tier = try container.decode(String.self, forKey: .tier)
        hasAccess = try container.decodeIfPresent(Bool.self, forKey: .hasAccess) ?? false
        productId = try container.decodeIfPresent(String.self, forKey: .productId)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        trialEndsAt = try container.decodeIfPresent(String.self, forKey: .trialEndsAt)
        trialDaysRemaining = try container.decodeIfPresent(Int.self, forKey: .trialDaysRemaining)
        willRenew = try container.decodeIfPresent(Bool.self, forKey: .willRenew) ?? false
        user = try container.decodeIfPresent(SubscriptionUserInfo.self, forKey: .user)
    }
}

struct SubscriptionUserInfo: Codable {
    let subscriptionTier: String
    let storageLimitBytes: Int
    let storageUsedBytes: Int
    let imageCount: Int

    enum CodingKeys: String, CodingKey {
        case subscriptionTier = "subscription_tier"
        case storageLimitBytes = "storage_limit_bytes"
        case storageUsedBytes = "storage_used_bytes"
        case imageCount = "image_count"
    }
}

struct VerifyPurchaseResponse: Codable {
    let success: Bool
    let subscription: SubscriptionInfo?
    let user: SubscriptionUserInfo?
    let error: String?

    struct SubscriptionInfo: Codable {
        let status: String
        let tier: String
        let productId: String
        let expiresAt: String
        let isTrialPeriod: Bool
        let trialEndsAt: String?

        enum CodingKeys: String, CodingKey {
            case status
            case tier
            case productId = "product_id"
            case expiresAt = "expires_at"
            case isTrialPeriod = "is_trial_period"
            case trialEndsAt = "trial_ends_at"
        }
    }
}

struct RestorePurchasesResponse: Codable {
    let success: Bool
    let message: String?
    let subscription: VerifyPurchaseResponse.SubscriptionInfo?
    let user: SubscriptionUserInfo?
    let error: String?
    let expiredAt: String?

    enum CodingKeys: String, CodingKey {
        case success
        case message
        case subscription
        case user
        case error
        case expiredAt = "expired_at"
    }
}
