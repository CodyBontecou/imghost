import XCTest
import Security
import Darwin
@testable import AccountConversion

@MainActor
final class SessionCorrectionTests: XCTestCase {
    /// Synthetic Security data, but the actual KeychainService migration/reader, production
    /// file lock, refresh HTTP/CAS/retry actor, AuthState and Settings coordinator all execute.
    private final class Fixture {
        var items: [String: Data] = [:]
        var readStatus = errSecSuccess
        var writeStatus = errSecSuccess
        var reads: [String] = []
        var paths: [String] = []
        var authorizations: [String: String] = [:]
        var posts = 0
        var writes = 0
        var deletes = 0
        var delays = 0
        var syncs = 0
        var resets = 0
        var logins = 0
        var clock = Date()
        var heldLock: Int32 = -1
        var loseCompletion = false
        var refreshUserID = "source"
        var expectedRefreshToken = "old-refresh"
        var conversionHook: ((String) async throws -> Void)?
        var responseHook: (() async throws -> Void)?
        var delayHook: (() async throws -> Void)?
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("session-correction-\(UUID()).lock")
        let user = User(id: "source", email: "relay@example.test", emailVerified: true,
                        storageUsedBytes: 723, storageLimitBytes: 99999, imageCount: 7, isAnonymous: false)
        func key(_ group: String?, _ account: String) -> String { "\(group ?? "<nil>")/\(account)" }
        func queryKey(_ query: [String: Any]) -> String {
            XCTAssertEqual(query[kSecAttrService as String] as? String, "synthetic")
            return key(query[kSecAttrAccessGroup as String] as? String, query[kSecAttrAccount as String] as! String)
        }
        lazy var calls = AtomicSessionStore.SecurityCalls(read: { query in
            let key = self.queryKey(query)
            self.reads.append(key)
            if self.readStatus != errSecSuccess { return (self.readStatus, nil) }
            return self.items[key].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }, add: { query in
            self.writes += 1
            if self.writeStatus != errSecSuccess { return self.writeStatus }
            let key = self.queryKey(query)
            guard self.items[key] == nil else { return errSecDuplicateItem }
            self.items[key] = query[kSecValueData as String] as? Data
            return errSecSuccess
        }, update: { query, changes in
            self.writes += 1
            if self.writeStatus != errSecSuccess { return self.writeStatus }
            let key = self.queryKey(query)
            guard self.items[key] != nil else { return errSecItemNotFound }
            self.items[key] = changes[kSecValueData as String] as? Data
            return errSecSuccess
        })
        lazy var keychain = KeychainService(service: "synthetic", accessGroup: "current", lockURL: lockURL,
            calls: calls, deleteCall: { _ in self.deletes += 1; XCTFail("Never delete credentials for these operations"); return errSecSuccess })
        lazy var store = keychain.sessions
        lazy var refresher = SessionRefreshCoordinator(sessions: store, baseURL: URL(string: "https://nonproduction.invalid")!,
            now: { self.clock }, retryDelay: {
                self.delays += 1
                try await self.delayHook?()
            }, transport: { request in
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url!.path, "/auth/refresh")
                self.posts += 1
                self.paths.append(request.url!.path)
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
                XCTAssertEqual(body["refresh_token"], self.expectedRefreshToken)
                try await self.responseHook?()
                let data = Data("""
                    {"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":3600,
                    "token_type":"Bearer","user_id":"\(self.refreshUserID)","email":"relay@example.test","subscription_tier":"pro"}
                    """.utf8)
                return (data, self.http(request, 200))
            })
        @MainActor lazy var auth = AuthState(dependencies: .init(sessions: store,
            user: { _ = try await self.refresher.ensureValidSession(); return self.user },
            refresh: { try await self.refresher.refresh() }, sync: { self.syncs += 1 },
            resetSubscription: { self.resets += 1 }))

        func legacy(group: String? = "current", expired: Bool = false) {
            items[key(group, "accessToken")] = Data("old-access".utf8)
            items[key(group, "refreshToken")] = Data("old-refresh".utf8)
            let expiry = clock.addingTimeInterval(expired ? -1 : 3600)
            items[key(group, "tokenExpiry")] = Data(String(expiry.timeIntervalSince1970).utf8)
        }
        func http(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        func loginResponse(id: String = "source", expiresIn: Int = 3600) -> AuthResponse {
            AuthResponse(accessToken: "login-access", refreshToken: "login-refresh", expiresIn: expiresIn,
                tokenType: "Bearer", userId: id, email: "new@example.test", subscriptionTier: "pro",
                emailVerified: true, isAnonymous: false, message: nil)
        }
        @MainActor func flow() -> EmailConversionCoordinator {
            auth.updateUser(user)
            let service = EmailConversionService(baseURL: URL(string: "https://nonproduction.invalid")!) { request in
                let path = request.url!.path
                self.paths.append(path)
                self.authorizations[path] = request.value(forHTTPHeaderField: "Authorization")
                try await self.conversionHook?(path)
                var data = Data("{}".utf8)
                if path.hasSuffix("challenge") {
                    data = Data("{\"challenge_id\":\"challenge\",\"nonce\":\"new-native-nonce\",\"expires_at\":\(Date().addingTimeInterval(300).timeIntervalSince1970 * 1000)}".utf8)
                } else if path.hasSuffix("complete") {
                    if self.loseCompletion {
                        self.clock = self.clock.addingTimeInterval(3601)
                        throw URLError(.timedOut) // Completion may have revoked old refresh; recovery must not use it.
                    }
                    data = Data("{\"user_id\":\"source\",\"email\":\"new@example.test\",\"email_verified\":true,\"apple_access_retained\":true,\"notification_pending\":false}".utf8)
                } else { XCTAssertTrue(path.hasSuffix("start")) }
                return (data, self.http(request, 200))
            }
            let flow = EmailConversionCoordinator(service: service, authState: auth,
                prepareSession: { try await self.refresher.ensureValidSession(replacing: $0) },
                login: { email, password in
                    XCTAssertEqual(email, "new@example.test"); XCTAssertEqual(password, "chosen password")
                    self.logins += 1
                    return self.loginResponse()
                })
            flow.destination = "new@example.test"
            return flow
        }
        @MainActor func prime(_ flow: EmailConversionCoordinator) async {
            await flow.begin(); XCTAssertEqual(flow.stage, .apple)
            await flow.authorize(identityToken: "new-interactive-proof"); XCTAssertEqual(flow.stage, .email)
            flow.code = "independent-code"; flow.password = "chosen password"; flow.confirmation = flow.password
        }
        func holdFileLock() throws {
            heldLock = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard heldLock >= 0, flock(heldLock, LOCK_EX | LOCK_NB) == 0 else {
                throw AtomicSessionStore.Failure.lockUnavailable
            }
        }
        func releaseFileLock() {
            if heldLock >= 0 { flock(heldLock, LOCK_UN); close(heldLock); heldLock = -1 }
        }
        deinit { releaseFileLock(); try? FileManager.default.removeItem(at: lockURL) }
    }

    func testLogoutAfterChallengePreventsStartDispatchAndReleasesSourceLease() async throws {
        let f = Fixture(); f.legacy(); let flow = f.flow()
        await flow.begin(); XCTAssertTrue(f.auth.logout())
        let tombstone = try f.store.snapshot()
        await flow.authorize(identityToken: "new-interactive-proof")
        XCTAssertEqual(flow.stage, .invalidated)
        XCTAssertEqual(f.paths, ["/auth/email-conversion/challenge"])
        XCTAssertEqual(try f.store.snapshot(), tombstone); XCTAssertNil(f.auth.currentUser)
        XCTAssertEqual(f.logins, 0); XCTAssertEqual(f.resets, 1)
        await f.auth.checkAuthStatus(); XCTAssertFalse(f.auth.isLoading)
    }

    func testAccountSwitchAfterChallengePreventsOldAccountStartDispatch() async throws {
        let f = Fixture(); f.legacy(); let flow = f.flow()
        await flow.begin(); try await f.auth.setAuthenticated(response: f.loginResponse(id: "other-account"))
        let replacement = try f.store.snapshot()
        await flow.authorize(identityToken: "new-interactive-proof")
        XCTAssertEqual(flow.stage, .invalidated)
        XCTAssertEqual(f.paths, ["/auth/email-conversion/challenge"])
        XCTAssertEqual(try f.store.snapshot(), replacement); XCTAssertEqual(f.auth.currentUser?.id, "other-account")
        XCTAssertEqual(f.logins, 0); XCTAssertEqual(f.resets, 0)
    }

    func testLogoutAfterEmailVerificationPreventsCompletionDispatch() async throws {
        let f = Fixture(); f.legacy(); let flow = f.flow()
        await f.prime(flow); XCTAssertTrue(f.auth.logout())
        let tombstone = try f.store.snapshot()
        await flow.complete()
        XCTAssertEqual(flow.stage, .invalidated); XCTAssertEqual(f.paths.count, 2)
        XCTAssertEqual(try f.store.snapshot(), tombstone); XCTAssertEqual(f.logins, 0)
        XCTAssertEqual(f.resets, 1)
    }

    func testSameAccountReloginAlsoInvalidatesOldCompletionAuthority() async throws {
        let f = Fixture(); f.legacy(); let flow = f.flow()
        await f.prime(flow); try await f.auth.setAuthenticated(response: f.loginResponse())
        let replacement = try f.store.snapshot()
        await flow.complete()
        XCTAssertEqual(flow.stage, .invalidated); XCTAssertEqual(f.paths.count, 2)
        XCTAssertEqual(try f.store.snapshot(), replacement); XCTAssertEqual(f.logins, 0)
        XCTAssertEqual(f.resets, 0)
    }

    func testAccountSwitchAfterEmailVerificationPreventsOldAccountCompletionDispatch() async throws {
        let f = Fixture(); f.legacy(); let flow = f.flow()
        await f.prime(flow); try await f.auth.setAuthenticated(response: f.loginResponse(id: "other-account"))
        let replacement = try f.store.snapshot()
        await flow.complete()
        XCTAssertEqual(flow.stage, .invalidated); XCTAssertEqual(f.paths.count, 2)
        XCTAssertEqual(try f.store.snapshot(), replacement); XCTAssertEqual(f.auth.currentUser?.id, "other-account")
        XCTAssertEqual(f.logins, 0); XCTAssertEqual(f.resets, 0)
    }

    func testLogoutDuringRefreshPrerequisitePreventsChallengeAndReturnedTokenResurrection() async throws {
        let f = Fixture(); f.legacy(expired: true); let flow = f.flow()
        var resume: CheckedContinuation<Void, Error>?
        f.responseHook = { try await withCheckedThrowingContinuation { resume = $0 } }
        let task = Task { await flow.begin() }
        while resume == nil { await Task.yield() }
        XCTAssertTrue(f.auth.logout())
        let tombstone = try f.store.snapshot()
        resume!.resume(returning: ()); await task.value
        XCTAssertEqual(flow.stage, .invalidated); XCTAssertEqual(f.paths, ["/auth/refresh"])
        XCTAssertEqual(try f.store.snapshot(), tombstone); XCTAssertNil(f.auth.currentUser)
        XCTAssertEqual(f.posts, 1); XCTAssertEqual(f.resets, 1)
    }

    func testAccountSwitchWhileChallengeResponseAwaitsCannotAdvanceOldFlow() async throws {
        let f = Fixture(); f.legacy(); let flow = f.flow()
        var resume: CheckedContinuation<Void, Error>?
        f.conversionHook = { _ in try await withCheckedThrowingContinuation { resume = $0 } }
        let task = Task { await flow.begin() }
        while resume == nil { await Task.yield() }
        try await f.auth.setAuthenticated(response: f.loginResponse(id: "other-account"))
        resume!.resume(returning: ()); await task.value
        XCTAssertEqual(flow.stage, .invalidated); XCTAssertNil(flow.challenge)
        XCTAssertEqual(f.paths, ["/auth/email-conversion/challenge"])
        XCTAssertEqual(f.auth.currentUser?.id, "other-account"); XCTAssertEqual(f.logins, 0)
    }

    func testLogoutDuringCompletionRefreshPrerequisitePreventsCredentialWrite() async throws {
        let f = Fixture(); f.legacy(); let flow = f.flow(); await f.prime(flow)
        f.clock = f.clock.addingTimeInterval(3601)
        var resume: CheckedContinuation<Void, Error>?
        f.responseHook = { try await withCheckedThrowingContinuation { resume = $0 } }
        let task = Task { await flow.complete() }
        while resume == nil { await Task.yield() }
        XCTAssertTrue(f.auth.logout())
        let tombstone = try f.store.snapshot()
        resume!.resume(returning: ()); await task.value
        XCTAssertEqual(flow.stage, .invalidated)
        XCTAssertEqual(f.paths, ["/auth/email-conversion/challenge", "/auth/email-conversion/start", "/auth/refresh"])
        XCTAssertEqual(try f.store.snapshot(), tombstone); XCTAssertEqual(f.logins, 0)
    }

    func testActualRefreshRetriesContendedFileLockWithoutSecondPOST() async throws {
        let f = Fixture(); f.legacy(expired: true); f.auth.updateUser(f.user)
        f.responseHook = { try f.holdFileLock() }
        f.delayHook = { f.releaseFileLock() }
        try await f.refresher.refresh()
        XCTAssertEqual(f.posts, 1); XCTAssertEqual(f.delays, 1)
        XCTAssertEqual(try f.store.snapshot().session?.accessToken, "rotated-access")
        XCTAssertEqual(try f.store.snapshot().session?.refreshToken, "rotated-refresh")
        XCTAssertEqual(f.auth.currentUser, f.user); XCTAssertEqual(f.resets, 0)
    }

    func testPersistentRefreshLockFailureIsBoundedAndExplicitRetryPersistsReturnedTokens() async throws {
        let f = Fixture(); f.legacy(expired: true); f.auth.updateUser(f.user)
        f.responseHook = { try f.holdFileLock() }
        await f.auth.checkAuthStatus()
        XCTAssertEqual(f.posts, 1); XCTAssertEqual(f.delays, 3)
        XCTAssertNotNil(f.auth.sessionStorageMessage); XCTAssertEqual(f.auth.currentUser, f.user)
        XCTAssertEqual(f.resets, 0); XCTAssertEqual(f.writes, 0)
        f.releaseFileLock()
        try await f.refresher.refresh() // Persistence retry, not a second HTTP rotation.
        XCTAssertEqual(f.posts, 1)
        XCTAssertEqual(try f.store.snapshot().session?.refreshToken, "rotated-refresh")
    }

    func testRefreshSecurityFailurePreservesAuthAndReturnedReplacementUntilExplicitRetry() async throws {
        let f = Fixture(); f.legacy(expired: true); f.auth.updateUser(f.user)
        let before = try f.store.snapshot(); f.writeStatus = errSecInteractionNotAllowed
        await f.auth.checkAuthStatus()
        XCTAssertEqual(f.posts, 1); XCTAssertEqual(f.delays, 0)
        XCTAssertNotNil(f.auth.sessionStorageMessage); XCTAssertEqual(f.auth.currentUser, f.user)
        XCTAssertEqual(try f.store.snapshot(), before); XCTAssertEqual(f.resets, 0); XCTAssertEqual(f.syncs, 0)
        f.writeStatus = errSecSuccess
        _ = try await f.refresher.ensureValidSession()
        XCTAssertEqual(f.posts, 1)
        XCTAssertEqual(try f.store.snapshot().session?.refreshToken, "rotated-refresh")
    }

    func testCancelledRefreshPersistenceWaitRetainsReturnedTokensForExplicitRetry() async throws {
        let f = Fixture(); f.legacy(expired: true)
        f.responseHook = { try f.holdFileLock() }
        f.delayHook = { throw CancellationError() }
        do { try await f.refresher.refresh(); XCTFail("Must report unsaved returned session") }
        catch { XCTAssertTrue(SessionRefreshCoordinator.isLocalFailure(error)) }
        f.releaseFileLock()
        try await f.refresher.refresh()
        XCTAssertEqual(f.posts, 1)
        XCTAssertEqual(try f.store.snapshot().session?.refreshToken, "rotated-refresh")
    }

    func testSupersededPendingRefreshDoesNotBlockNewAccountsOwnRefresh() async throws {
        let f = Fixture(); f.legacy(expired: true); f.auth.updateUser(f.user)
        f.writeStatus = errSecInteractionNotAllowed
        do { try await f.refresher.refresh(); XCTFail("Expected retained unsaved response") }
        catch { XCTAssertTrue(SessionRefreshCoordinator.isLocalFailure(error)) }
        f.writeStatus = errSecSuccess
        try await f.auth.setAuthenticated(response: f.loginResponse(id: "other-account", expiresIn: 60))
        f.expectedRefreshToken = "login-refresh"; f.refreshUserID = "other-account"
        do { _ = try await f.refresher.ensureValidSession(); XCTFail("Must discard superseded response, not apply it") }
        catch AtomicSessionStore.Failure.changedSession { }
        XCTAssertEqual(f.posts, 1)
        let current = try await f.refresher.ensureValidSession()
        XCTAssertEqual(f.posts, 2); XCTAssertEqual(current.session?.userID, "other-account")
        XCTAssertEqual(f.auth.currentUser?.id, "other-account"); XCTAssertEqual(f.resets, 0)
    }

    func testActualRefreshRejectsChangedSessionInsteadOfOverwritingAccountReplacement() async throws {
        let f = Fixture(); f.legacy(); f.auth.updateUser(f.user)
        f.responseHook = { try await f.auth.setAuthenticated(response: f.loginResponse(id: "other-account")) }
        do { try await f.refresher.refresh(); XCTFail("Must reject stale refresh") }
        catch AtomicSessionStore.Failure.changedSession { }
        XCTAssertEqual(try f.store.snapshot().session?.userID, "other-account")
        XCTAssertEqual(try f.store.snapshot().session?.refreshToken, "login-refresh")
        XCTAssertEqual(f.posts, 1); XCTAssertEqual(f.resets, 0)
    }

    func testActualRefreshRejectsDurableLogoutTombstoneBeforeResponseCommit() async throws {
        let f = Fixture(); f.legacy(); f.auth.updateUser(f.user)
        f.responseHook = { await MainActor.run { XCTAssertTrue(f.auth.logout()) } }
        do { try await f.refresher.refresh(); XCTFail("Must reject stale refresh") }
        catch AtomicSessionStore.Failure.changedSession { }
        XCTAssertNil(try f.store.snapshot().session); XCTAssertEqual(f.posts, 1); XCTAssertEqual(f.resets, 1)
        do { try await f.refresher.refresh(); XCTFail("No refresh after logout") }
        catch SessionRefreshCoordinator.Failure.noRefreshToken { }
        XCTAssertEqual(f.posts, 1)
    }

    func testNilAccessGroupMigrationImportsExpiredAccessThenProductionRefreshSucceeds() async throws {
        try await migration(group: nil)
    }

    func testBareAccessGroupMigrationImportsExpiredAccessThenProductionRefreshSucceeds() async throws {
        try await migration(group: Config.legacyKeychainAccessGroup)
    }

    private func migration(group: String?) async throws {
        let f = Fixture(); f.legacy(group: group, expired: true)
        let original = f.items
        try f.keychain.migrateFromLegacyAccessGroupIfNeeded()
        XCTAssertNotNil(try f.store.snapshot().data)
        XCTAssertLessThan(try XCTUnwrap(f.store.snapshot().session).expiresAt, Date())
        let refreshed = try await f.refresher.ensureValidSession()
        XCTAssertEqual(refreshed.session?.refreshToken, "rotated-refresh")
        XCTAssertEqual(refreshed.session?.userID, "source"); XCTAssertEqual(f.posts, 1)
        for (key, value) in original { XCTAssertEqual(f.items[key], value) }
        XCTAssertEqual(f.deletes, 0); XCTAssertEqual(f.resets, 0)
    }

    func testMigrationNeverFallsBackOverCorruptAuthoritativeDestination() async throws {
        let f = Fixture(); f.legacy(group: nil, expired: true)
        f.items[f.key("current", "atomicSession.v1")] = Data("corrupt".utf8)
        let original = f.items
        XCTAssertThrowsError(try f.keychain.migrateFromLegacyAccessGroupIfNeeded())
        XCTAssertEqual(f.items, original); XCTAssertEqual(f.reads, ["current/atomicSession.v1"])
        XCTAssertEqual(f.writes, 0); XCTAssertEqual(f.deletes, 0)
    }

    func testPartialLegacyDestinationIsNotAbsenceOrPermissionToImportAnotherGroup() async throws {
        let f = Fixture(); f.legacy(group: nil, expired: true)
        f.items[f.key("current", "accessToken")] = Data("partial-access".utf8)
        let original = f.items
        XCTAssertThrowsError(try f.keychain.migrateFromLegacyAccessGroupIfNeeded())
        XCTAssertEqual(f.items, original); XCTAssertEqual(f.writes, 0); XCTAssertEqual(f.deletes, 0)
        XCTAssertFalse(f.reads.contains { $0.hasPrefix("<nil>/") })
    }

    func testMigrationReadPermissionFailureIsNotEmptyDestination() async throws {
        let f = Fixture(); f.legacy(group: nil, expired: true); f.readStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try f.keychain.migrateFromLegacyAccessGroupIfNeeded())
        XCTAssertEqual(f.reads, ["current/atomicSession.v1"]); XCTAssertEqual(f.writes, 0)
    }

    func testLegacyImportCannotOverwriteLogoutOrRelaxFreshLoginValidation() async throws {
        let f = Fixture(); f.legacy(); f.auth.updateUser(f.user)
        let before = try f.store.snapshot()
        do { try await f.auth.setAuthenticated(response: f.loginResponse(expiresIn: 0)); XCTFail("Expired fresh response") }
        catch AtomicSessionStore.Failure.invalidSession { }
        XCTAssertEqual(try f.store.snapshot(), before)
        XCTAssertTrue(f.auth.logout())
        let tombstone = try f.store.snapshot()
        let expired = AccountSession(accessToken: "old", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(-1), userID: nil)
        XCTAssertThrowsError(try f.store.importLegacySession(expired, replacing: tombstone))
        XCTAssertEqual(try f.store.snapshot(), tombstone)
        try f.keychain.migrateFromLegacyAccessGroupIfNeeded()
        XCTAssertEqual(try f.store.snapshot(), tombstone)
    }

    func testConversionRefreshesExpiredSourceBeforeChallengeWithoutResetOrRegistration() async throws {
        let f = Fixture(); f.legacy(expired: true); let flow = f.flow()
        await f.prime(flow); await flow.complete()
        XCTAssertEqual(flow.stage, .done)
        XCTAssertEqual(f.paths, ["/auth/refresh", "/auth/email-conversion/challenge", "/auth/email-conversion/start", "/auth/email-conversion/complete"])
        XCTAssertEqual(f.authorizations["/auth/email-conversion/challenge"], "Bearer rotated-access")
        XCTAssertEqual(f.posts, 1); XCTAssertEqual(f.logins, 1); XCTAssertEqual(f.resets, 0); XCTAssertEqual(f.syncs, 0)
        XCTAssertEqual(f.auth.currentUser?.storageUsedBytes, 723); XCTAssertEqual(f.auth.currentUser?.imageCount, 7)
    }

    func testConversionRefreshesExpiryAfterStartBeforeSingleCompletionDispatch() async throws {
        let f = Fixture(); f.legacy(); let flow = f.flow()
        await f.prime(flow)
        f.clock = f.clock.addingTimeInterval(3601)
        await flow.complete()
        XCTAssertEqual(flow.stage, .done)
        XCTAssertEqual(f.paths, ["/auth/email-conversion/challenge", "/auth/email-conversion/start", "/auth/refresh", "/auth/email-conversion/complete"])
        XCTAssertEqual(f.authorizations["/auth/email-conversion/complete"], "Bearer rotated-access")
        XCTAssertEqual(f.posts, 1); XCTAssertEqual(f.logins, 1); XCTAssertEqual(f.resets, 0)
        XCTAssertEqual(f.auth.currentUser?.storageLimitBytes, 99999)
    }

    func testCompletionPreflightPersistenceFailureRetriesReturnedTokensBeforeOneCodePOST() async throws {
        let f = Fixture(); f.legacy(); let flow = f.flow(); await f.prime(flow)
        let before = try f.store.snapshot()
        f.clock = f.clock.addingTimeInterval(3601); f.writeStatus = errSecInteractionNotAllowed
        await flow.complete()
        XCTAssertEqual(flow.stage, .email); XCTAssertEqual(try f.store.snapshot(), before)
        XCTAssertEqual(f.paths, ["/auth/email-conversion/challenge", "/auth/email-conversion/start", "/auth/refresh"])
        XCTAssertEqual(f.auth.currentUser, f.user); XCTAssertEqual(f.resets, 0); XCTAssertEqual(f.logins, 0)
        f.writeStatus = errSecSuccess
        await flow.complete()
        XCTAssertEqual(flow.stage, .done); XCTAssertEqual(f.posts, 1); XCTAssertEqual(f.logins, 1)
        XCTAssertEqual(f.paths.filter { $0.hasSuffix("complete") }.count, 1)
    }

    func testUncertainCompletionRecoveryNeverRefreshesRevokedSourceOrResendsCode() async throws {
        let f = Fixture(); f.legacy(); f.loseCompletion = true; let flow = f.flow()
        await f.prime(flow); await flow.complete()
        XCTAssertEqual(flow.stage, .recovery); XCTAssertEqual(f.posts, 0); XCTAssertEqual(f.logins, 0)
        XCTAssertEqual(f.auth.currentUser, f.user)
        await flow.recover()
        XCTAssertEqual(flow.stage, .done); XCTAssertEqual(f.paths.count, 3)
        XCTAssertEqual(f.posts, 0); XCTAssertEqual(f.logins, 1); XCTAssertEqual(f.resets, 0)
    }

    func testRecoveryCannotRebindToNewSameAccountLoginLease() async throws {
        let f = Fixture(); f.legacy(); f.loseCompletion = true; let flow = f.flow()
        await f.prime(flow); await flow.complete()
        try await f.auth.setAuthenticated(response: f.loginResponse())
        let replacement = try f.store.snapshot()
        await flow.recover()
        XCTAssertEqual(flow.stage, .recovery); XCTAssertEqual(f.logins, 0)
        XCTAssertEqual(try f.store.snapshot(), replacement)
        XCTAssertTrue(flow.message!.contains("cannot continue"))
    }

    func testLogoutReadFailureIsObservableAndExplicitRetryCommitsTombstone() async throws {
        let f = Fixture(); f.legacy(); f.auth.updateUser(f.user)
        let before = try f.store.snapshot(); f.readStatus = errSecInteractionNotAllowed
        XCTAssertFalse(f.auth.logout()); XCTAssertNotNil(f.auth.logoutError)
        XCTAssertTrue(f.auth.logoutError!.contains("still signed in"))
        XCTAssertEqual(f.auth.currentUser, f.user); XCTAssertEqual(f.resets, 0)
        f.readStatus = errSecSuccess
        XCTAssertEqual(try f.store.snapshot(), before)
        XCTAssertTrue(f.auth.logout()); XCTAssertNil(f.auth.logoutError)
        XCTAssertNil(try f.store.snapshot().session); XCTAssertEqual(f.resets, 1)
    }

    func testLogoutWriteFailurePreservesCredentialsSubscriptionAndActiveSourceLease() async throws {
        let f = Fixture(); f.legacy(); let flow = f.flow(); await flow.begin()
        let before = try f.store.snapshot(); f.writeStatus = errSecMissingEntitlement
        XCTAssertFalse(f.auth.logout()); XCTAssertNotNil(f.auth.logoutError)
        XCTAssertEqual(try f.store.snapshot(), before); XCTAssertEqual(f.auth.currentUser, f.user)
        XCTAssertEqual(f.resets, 0)
        f.writeStatus = errSecSuccess
        await flow.authorize(identityToken: "new-interactive-proof") // Failed logout did not falsely invalidate durable source.
        XCTAssertEqual(flow.stage, .email)
        XCTAssertTrue(f.auth.logout()); XCTAssertNil(f.auth.logoutError)
        XCTAssertNil(try f.store.snapshot().session); XCTAssertEqual(f.resets, 1)
    }

    func testLogoutContendedFileLockIsObservableAndExplicitRetryDoesNotResetEarly() async throws {
        let f = Fixture(); f.legacy(); f.auth.updateUser(f.user)
        let before = try f.store.snapshot(); try f.holdFileLock()
        XCTAssertFalse(f.auth.logout()); XCTAssertNotNil(f.auth.logoutError)
        XCTAssertEqual(f.auth.currentUser, f.user); XCTAssertEqual(f.resets, 0)
        f.releaseFileLock()
        XCTAssertEqual(try f.store.snapshot(), before)
        XCTAssertTrue(f.auth.logout()); XCTAssertEqual(f.resets, 1)
        XCTAssertNil(try f.store.snapshot().session)
    }

    func testCorruptAuthoritativeSessionShowsGuidanceWithoutDeletingOrResurrectingLegacy() async throws {
        let f = Fixture(); f.legacy(); f.auth.updateUser(f.user)
        f.items[f.key("current", "atomicSession.v1")] = Data("corrupt".utf8)
        let original = f.items
        XCTAssertFalse(f.auth.logout())
        XCTAssertTrue(f.auth.logoutError!.contains("contact support privately"))
        await f.auth.checkAuthStatus()
        XCTAssertNotNil(f.auth.sessionStorageMessage)
        do { try await f.auth.setAuthenticated(response: f.loginResponse()); XCTFail("No silent corrupt-item replacement") }
        catch { }
        XCTAssertEqual(f.items, original); XCTAssertEqual(f.deletes, 0); XCTAssertEqual(f.posts, 0)
        XCTAssertEqual(f.auth.currentUser, f.user); XCTAssertEqual(f.resets, 0)
    }
}
