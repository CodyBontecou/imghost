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
    private let operations: Operations

    init(operations: Operations) { self.operations = operations }

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
                  session.expiresAt > Date() else { throw Failure.invalidSession }
        }
        let data = try JSONEncoder().encode(Envelope(revision: UUID(), session: session))
        try operations.locked {
            let actual = try self.readUnlocked()
            guard actual == expected else { throw Failure.changedSession }
            try self.operations.replace(data, actual.data != nil)
        }
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
        }, locked: { action in
            try SessionFileLock.withLock(url: lockURL, action: action)
        }))
    }
}

private enum SessionFileLock {
    // flock alone does not serialize threads sharing one process on all platforms.
    static let processLock = NSRecursiveLock()
    static func withLock(url: URL?, action: () throws -> Void) throws {
        processLock.lock()
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
