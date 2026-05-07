import Foundation

struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let tokenType: String
    let userId: String
    let email: String
    let subscriptionTier: String
    let emailVerified: Bool
    let isAnonymous: Bool?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case userId = "user_id"
        case email
        case subscriptionTier = "subscription_tier"
        case emailVerified = "email_verified"
        case isAnonymous = "is_anonymous"
        case message
    }
}

struct RefreshResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let tokenType: String
    let userId: String
    let email: String
    let subscriptionTier: String
    let isAnonymous: Bool?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case userId = "user_id"
        case email
        case subscriptionTier = "subscription_tier"
        case isAnonymous = "is_anonymous"
    }
}

struct MessageResponse: Codable {
    let message: String
    let emailVerified: Bool?

    enum CodingKeys: String, CodingKey {
        case message
        case emailVerified = "email_verified"
    }
}

struct ErrorResponse: Codable {
    let error: String
    let emailVerified: Bool?
    let retryAfter: Int?

    enum CodingKeys: String, CodingKey {
        case error
        case emailVerified = "email_verified"
        case retryAfter = "retry_after"
    }
}
