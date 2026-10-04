import Foundation
import Security
import Darwin

struct AccountSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userID: String?
}

/// One authoritative Keychain item. Never deletes the previous credentials to replace them.
/// All app/extension writers use the same app-group lock, including stale-response checks.
final class AtomicSessionStore {
    struct Snapshot: Equatable {
        let data: Data?
        let session: AccountSession?
    }
    private struct Envelope: Codable {
        let revision: UUID
        let session: AccountSession? // A durable logout tombstone prevents legacy resurrection.
    }
    enum Failure: Error { case changedSession, invalidSession, lockUnavailable, keychain(OSStatus) }
    struct Operations {
        let read: () throws -> Data?
        let legacy: () throws -> AccountSession?
        let replace: (Data, Bool) throws -> Void
        let locked: (@escaping () throws -> Void) throws -> Void
    }
    /// Only this store can mint a refresh-only capability after validating a fresh response.
    /// It is not a general permission to save expired login/adoption credentials.
    struct ValidatedRefresh {
        let source: Snapshot
        let session: AccountSession
        fileprivate let storeID: UUID
        fileprivate init(source: Snapshot, session: AccountSession, storeID: UUID) {
            self.source = source
            self.session = session
            self.storeID = storeID
        }
    }
    private let operations: Operations
    private let now: () -> Date
    private let storeID = UUID()

    init(operations: Operations, now: @escaping () -> Date = Date.init) {
        self.operations = operations
        self.now = now
    }

    func snapshot() throws -> Snapshot {
        var result: Snapshot?
        try operations.locked { result = try self.readUnlocked() }
        return result!
    }

    /// Compare the whole captured session under the cross-process lock. A late refresh/login
    /// response may not resurrect logout or overwrite a conversion committed while it awaited.
    func commit(_ session: AccountSession?, replacing expected: Snapshot) throws {
        if let session {
            guard !session.accessToken.isEmpty, !session.refreshToken.isEmpty,
                  session.expiresAt > now() else { throw Failure.invalidSession }
        }
        _ = try write(session, replacing: expected)
    }

    func validateReturnedRefresh(_ response: RefreshResponse, replacing source: Snapshot,
                                 receivedAt: Date) throws -> ValidatedRefresh {
        guard let previous = source.session, !response.userId.isEmpty,
              !response.accessToken.isEmpty, !response.refreshToken.isEmpty,
              response.tokenType.lowercased() == "bearer", response.expiresIn > 0 else { throw Failure.invalidSession }
        guard previous.userID == nil || previous.userID == response.userId else { throw Failure.changedSession }
        let expiry = receivedAt.addingTimeInterval(TimeInterval(response.expiresIn))
        guard receivedAt.timeIntervalSince1970.isFinite, expiry.timeIntervalSince1970.isFinite,
              expiry > receivedAt, expiry > now() else { throw Failure.invalidSession }
        return ValidatedRefresh(source: source, session: AccountSession(accessToken: response.accessToken,
            refreshToken: response.refreshToken, expiresAt: expiry, userID: response.userId), storeID: storeID)
    }

    /// An already-validated refresh response can age while Security is unavailable. Persist
    /// its usable refresh credential under the ORIGINAL exact CAS, even if access has aged.
    /// The actor must renew before returning expired access as authorization. No new format.
    func commitReturnedRefresh(_ returned: ValidatedRefresh) throws -> Snapshot {
        guard returned.storeID == storeID else { throw Failure.invalidSession }
        return try write(returned.session, replacing: returned.source)
    }

    /// Import only into a completely empty destination. Expired legacy access tokens are
    /// expected; preserving their refresh credential lets ordinary refresh recover on launch.
    /// This does NOT relax validation of new login, refresh or conversion responses.
    func importLegacySession(_ session: AccountSession, replacing expected: Snapshot) throws {
        guard expected.data == nil, expected.session == nil,
              !session.accessToken.isEmpty, !session.refreshToken.isEmpty,
              session.expiresAt.timeIntervalSince1970.isFinite else { throw Failure.invalidSession }
        _ = try write(session, replacing: expected)
    }

    private func write(_ session: AccountSession?, replacing expected: Snapshot) throws -> Snapshot {
        let data = try JSONEncoder().encode(Envelope(revision: UUID(), session: session))
        try operations.locked {
            let actual = try self.readUnlocked()
            guard actual == expected else { throw Failure.changedSession }
            try self.operations.replace(data, actual.data != nil)
        }
        // Exact successful write receipt, including its revision; no fallible second read.
        return Snapshot(data: data, session: session)
    }

    private func readUnlocked() throws -> Snapshot {
        if let data = try operations.read() {
            // Corruption/locked Keychain is NOT absence; never fall back to old credentials.
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            return Snapshot(data: data, session: envelope.session)
        }
        return Snapshot(data: nil, session: try operations.legacy())
    }

    struct SecurityCalls {
        let read: ([String: Any]) -> (OSStatus, Data?)
        let add: ([String: Any]) -> OSStatus
        let update: ([String: Any], [String: Any]) -> OSStatus
        static let system = SecurityCalls(read: { query in
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }, add: { SecItemAdd($0 as CFDictionary, nil) },
           update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) })
    }

    /// Production Security.framework adapter. Inject syscall faults into this exact path;
    /// no test-only adoption/state model and no real credential writes in hosted tests.
    static func keychain(service: String, accessGroup: String?, lockURL: URL?,
                         calls: SecurityCalls = .system,
                         now: @escaping () -> Date = Date.init,
                         locked: ((@escaping () throws -> Void) throws -> Void)? = nil,
                         legacy: @escaping () throws -> AccountSession?) -> AtomicSessionStore {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: "atomicSession.v1"]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return AtomicSessionStore(operations: Operations(read: {
            var read = query
            read[kSecReturnData as String] = true
            read[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, result) = calls.read(read)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result else {
                throw Failure.keychain(status == errSecSuccess ? errSecDecode : status)
            }
            return data
        }, legacy: legacy, replace: { data, exists in
            let status: OSStatus
            if exists {
                status = calls.update(query, [kSecValueData as String: data])
            } else {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                status = calls.add(add)
            }
            guard status == errSecSuccess else { throw Failure.keychain(status) }
        }, locked: locked ?? { action in
            try SessionFileLock.withLock(url: lockURL, action: action)
        }), now: now)
    }
}

private enum SessionFileLock {
    // flock alone does not serialize threads sharing one process on all platforms.
    static let processLock = NSRecursiveLock()
    static func withLock(url: URL?, action: () throws -> Void) throws {
        guard processLock.try() else { throw AtomicSessionStore.Failure.lockUnavailable }
        defer { processLock.unlock() }
        guard let url else { throw AtomicSessionStore.Failure.lockUnavailable }
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AtomicSessionStore.Failure.lockUnavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw AtomicSessionStore.Failure.lockUnavailable }
        defer { flock(descriptor, LOCK_UN) }
        try action()
    }
}
