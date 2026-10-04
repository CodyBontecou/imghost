import Foundation
import Security

final class KeychainService {
    static let shared = KeychainService()

    private let service: String
    private let accessGroup: String?
    private let lockURL: URL?
    private let calls: AtomicSessionStore.SecurityCalls
    private let now: () -> Date
    private let deleteCall: ([String: Any]) -> OSStatus

    var sessions: AtomicSessionStore { AtomicSessionStore.keychain(
        service: service, accessGroup: accessGroup, lockURL: lockURL, calls: calls, now: now,
        legacy: { [unowned self] in
            let access = try self.load(key: self.accessTokenKey)
            let refresh = try self.load(key: self.refreshTokenKey)
            let expiry = try self.load(key: self.tokenExpiryKey)
            if access == nil, refresh == nil, expiry == nil { return nil }
            guard let access, !access.isEmpty, let refresh, !refresh.isEmpty,
                  let expiry, let timestamp = Double(expiry), timestamp.isFinite else {
                throw AtomicSessionStore.Failure.invalidSession
            }
            return AccountSession(accessToken: access, refreshToken: refresh,
                                  expiresAt: Date(timeIntervalSince1970: timestamp), userID: nil)
        }) }

    init(service: String = Config.keychainService, accessGroup: String? = Config.keychainAccessGroup,
         lockURL: URL? = Config.sharedContainerURL?.appendingPathComponent("auth-session.lock"),
         calls: AtomicSessionStore.SecurityCalls = .system,
         now: @escaping () -> Date = Date.init,
         deleteCall: @escaping ([String: Any]) -> OSStatus = { SecItemDelete($0 as CFDictionary) }) {
        self.service = service
        self.accessGroup = accessGroup
        self.lockURL = lockURL
        self.calls = calls
        self.now = now
        self.deleteCall = deleteCall
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

        let status = calls.add(query)

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

        let (status, result) = calls.read(query)

        switch status {
        case errSecSuccess:
            guard let data = result,
                  let string = String(data: data, encoding: .utf8) else {
                throw ImghostError.keychainError(status: errSecDecode)
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

        let status = deleteCall(query)

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

    func loadAccessToken() -> String? {
        try? sessions.snapshot().session?.accessToken
    }

    func loadRefreshToken() -> String? {
        try? sessions.snapshot().session?.refreshToken
    }

    func loadTokenExpiry() -> Date? {
        try? sessions.snapshot().session?.expiresAt
    }

    /// Clears all authentication tokens
    func clearAllTokens() throws {
        let snapshot = try sessions.snapshot()
        try sessions.commit(nil, replacing: snapshot)
        // The tombstone is authoritative. Legacy JWT items are never read after logout.
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
    func migrateFromLegacyAccessGroupIfNeeded() throws {
        #if SHARE_EXTENSION
        return // Extensions cannot read the old app-only groups.
        #else
        // Read/permission/decode failure is never absence. Never overwrite a tombstone.
        let destination = try sessions.snapshot()
        guard destination.data == nil, destination.session == nil else { return }
        let oldGroups: [String?] = [nil, Config.legacyKeychainAccessGroup]
        for group in oldGroups {
            let old = KeychainService(service: service, accessGroup: group, lockURL: lockURL,
                                      calls: calls, now: now, deleteCall: deleteCall)
            // Snapshot the complete old item/triplet under the same production lock.
            // An inaccessible obsolete group is not authority to delete anything; the
            // other historical group can still contain a readable session.
            let source: AtomicSessionStore.Snapshot
            do { source = try old.sessions.snapshot() }
            catch ImghostError.keychainError(let status) where status == errSecMissingEntitlement { continue }
            catch AtomicSessionStore.Failure.keychain(let status) where status == errSecMissingEntitlement { continue }
            if let session = source.session {
                try sessions.importLegacySession(session, replacing: destination)
                return // Keep every old item intact; new authoritative item wins.
            }
        }
        #endif
    }
}
