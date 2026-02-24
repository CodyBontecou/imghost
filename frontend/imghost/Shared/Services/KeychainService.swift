import Foundation
import Security

final class KeychainService {
    static let shared = KeychainService()

    private let service: String
    private let accessGroup: String?

    init(service: String = Config.keychainService, accessGroup: String? = Config.keychainAccessGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    // MARK: - Public Methods

    /// Apply platform-specific keychain attributes to a query dictionary
    private func applyPlatformAttributes(to query: inout [String: Any]) {
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
        // Use data protection keychain on macOS to avoid
        // "would like to access data from other apps" privacy prompt.
        // The data protection keychain handles shared access groups
        // natively without triggering TCC prompts.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
    }

    func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw ImghostError.keychainError(status: errSecParam)
        }

        // First, try to delete any existing item
        try? delete(key: key)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        applyPlatformAttributes(to: &query)

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw ImghostError.keychainError(status: status)
        }
    }

    func load(key: String) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        applyPlatformAttributes(to: &query)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw ImghostError.keychainError(status: status)
        }
    }

    func delete(key: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        applyPlatformAttributes(to: &query)

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ImghostError.keychainError(status: status)
        }
    }

    // MARK: - Convenience Methods for Upload Token (Legacy)

    func saveUploadToken(_ token: String) throws {
        try save(key: Config.uploadTokenKey, value: token)
    }

    func loadUploadToken() throws -> String? {
        try load(key: Config.uploadTokenKey)
    }

    func deleteUploadToken() throws {
        try delete(key: Config.uploadTokenKey)
    }

    // MARK: - JWT Token Methods

    private let accessTokenKey = "accessToken"
    private let refreshTokenKey = "refreshToken"
    private let tokenExpiryKey = "tokenExpiry"

    func saveAccessToken(_ token: String) throws {
        try save(key: accessTokenKey, value: token)
    }

    func loadAccessToken() -> String? {
        try? load(key: accessTokenKey)
    }

    func deleteAccessToken() throws {
        try delete(key: accessTokenKey)
    }

    func saveRefreshToken(_ token: String) throws {
        try save(key: refreshTokenKey, value: token)
    }

    func loadRefreshToken() -> String? {
        try? load(key: refreshTokenKey)
    }

    func deleteRefreshToken() throws {
        try delete(key: refreshTokenKey)
    }

    func saveTokenExpiry(_ date: Date) throws {
        let timestamp = String(date.timeIntervalSince1970)
        try save(key: tokenExpiryKey, value: timestamp)
    }

    func loadTokenExpiry() -> Date? {
        guard let timestampString = try? load(key: tokenExpiryKey),
              let timestamp = Double(timestampString) else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    func deleteTokenExpiry() throws {
        try delete(key: tokenExpiryKey)
    }

    /// Clears all authentication tokens
    func clearAllTokens() {
        try? deleteAccessToken()
        try? deleteRefreshToken()
        try? deleteTokenExpiry()
        try? deleteUploadToken()
    }

    /// Check if user has valid tokens stored
    var hasValidTokens: Bool {
        loadAccessToken() != nil
    }

    // MARK: - Legacy Migration

    /// Migrate keychain items from previous access group configurations to the
    /// current explicit shared access group ("67KC823C9A.group.com.imghost.shared").
    ///
    /// Earlier builds stored tokens under:
    ///   1. The bare (unprefixed) app group "group.com.imghost.shared"
    ///   2. No explicit access group (nil), which defaulted to the app's own
    ///      application-identifier ("67KC823C9A.com.codybontecou.imghost")
    ///
    /// Both cases result in the share extension being unable to read the tokens.
    /// This method migrates from either legacy location to the shared group.
    ///
    /// Call once on main-app launch.  It is a no-op when there is nothing to
    /// migrate, or when running inside an extension (which can't read the
    /// legacy group anyway).
    func migrateFromLegacyAccessGroupIfNeeded() {
        #if SHARE_EXTENSION
        // Extensions can't read the legacy group – skip.
        return
        #else
        // If we already have tokens under the new shared group, nothing to do.
        if loadAccessToken() != nil { return }

        // --- Attempt 1: migrate from nil access group (app-identifier default) ---
        // Previous builds used keychainAccessGroup = nil, which saved tokens under
        // the app's own identifier. Create a service with nil group to read those.
        let nilGroupService = KeychainService(service: service, accessGroup: nil)
        if let accessToken = nilGroupService.loadAccessToken() {
            let refreshToken = nilGroupService.loadRefreshToken()
            let tokenExpiry = nilGroupService.loadTokenExpiry()

            do {
                try saveAccessToken(accessToken)
                if let rt = refreshToken { try saveRefreshToken(rt) }
                if let exp = tokenExpiry { try saveTokenExpiry(exp) }

                // Clean up old items
                try? nilGroupService.deleteAccessToken()
                try? nilGroupService.deleteRefreshToken()
                try? nilGroupService.deleteTokenExpiry()

                print("[KeychainService] ✅ Migrated tokens from nil (app-identifier) access group")
                return
            } catch {
                print("[KeychainService] ⚠️ Migration from nil access group failed: \(error)")
            }
        }

        // --- Attempt 2: migrate from bare (unprefixed) app group ---
        if let legacyGroup = Config.legacyKeychainAccessGroup {
            let legacyService = KeychainService(service: service, accessGroup: legacyGroup)

            if let accessToken = legacyService.loadAccessToken() {
                let refreshToken = legacyService.loadRefreshToken()
                let tokenExpiry = legacyService.loadTokenExpiry()

                do {
                    try saveAccessToken(accessToken)
                    if let rt = refreshToken { try saveRefreshToken(rt) }
                    if let exp = tokenExpiry { try saveTokenExpiry(exp) }

                    // Clean up legacy items
                    try? legacyService.deleteAccessToken()
                    try? legacyService.deleteRefreshToken()
                    try? legacyService.deleteTokenExpiry()

                    print("[KeychainService] ✅ Migrated tokens from legacy access group")
                } catch {
                    print("[KeychainService] ⚠️ Migration from legacy access group failed: \(error)")
                }
            }
        }
        #endif
    }
}
