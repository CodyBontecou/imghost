import XCTest
import Security
import Darwin
@testable import AccountConversion

@MainActor
final class RefreshEdgeTests: XCTestCase {
    private enum ReadWindow: Equatable { case helper, coordinator }
    private enum Replacement: Equatable { case logout, sameID, otherID, foreignRevision }

    /// Real production store/file lock, refresh actor, coordinator and AuthState. Security/HTTP
    /// are synthetic. One clock drives response expiry, store fresh validation AND AuthState.
    private final class Fixture {
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        var items: [String: Data] = [:]
        var writeStatus = errSecSuccess
        var writes = 0
        var commits = 0
        var posts: [String] = []
        var paths: [String] = []
        var authorizations: [String: String] = [:]
        var resets = 0
        var syncs = 0
        var logins = 0
        var serverRefresh = "source-refresh"
        var serverAccess = "source-access"
        var responseData: Data?
        var beforeResponse: (() async throws -> Void)?
        var readWindow: ReadWindow?
        var windowHits: [ReadWindow] = []
        var heldLock: Int32 = -1
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-edge-\(UUID()).lock")
        let user = User(id: "source", email: "relay@example.test", emailVerified: true,
                        storageUsedBytes: 723, storageLimitBytes: 99999, imageCount: 7, isAnonymous: false)
        func account(_ query: [String: Any]) -> String {
            XCTAssertEqual(query[kSecAttrService as String] as? String, "refresh-edge-synthetic")
            XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "synthetic-group")
            return query[kSecAttrAccount as String] as! String
        }
        lazy var calls = AtomicSessionStore.SecurityCalls(read: { query in
            self.items[self.account(query)].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }, add: { query in
            self.writes += 1
            guard self.writeStatus == errSecSuccess else { return self.writeStatus }
            let key = self.account(query)
            guard self.items[key] == nil else { return errSecDuplicateItem }
            self.items[key] = query[kSecValueData as String] as? Data
            self.commits += 1
            return errSecSuccess
        }, update: { query, changes in
            self.writes += 1
            guard self.writeStatus == errSecSuccess else { return self.writeStatus }
            let key = self.account(query)
            guard self.items[key] != nil else { return errSecItemNotFound }
            self.items[key] = changes[kSecValueData as String] as? Data
            self.commits += 1
            return errSecSuccess
        })
        lazy var keychain = KeychainService(service: "refresh-edge-synthetic", accessGroup: "synthetic-group",
            lockURL: lockURL, calls: calls, now: { self.clock }, deleteCall: { _ in
                XCTFail("No destructive recovery or legacy deletion"); return errSecSuccess
            })
        lazy var store = keychain.sessions
        lazy var refresher = SessionRefreshCoordinator(sessions: store, baseURL: URL(string: "https://nonproduction.invalid")!,
            now: { self.clock }, retryDelay: {}, beforeAcknowledgementRead: { try self.contend(.helper) },
            transport: { request in
                XCTAssertEqual(request.url!.path, "/auth/refresh")
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
                let token = body["refresh_token"]!
                self.posts.append(token); self.paths.append(request.url!.path)
                // Model single-use rotation, not an always-green refresh endpoint.
                guard token == self.serverRefresh else {
                    XCTFail("Must never resend a consumed source refresh token")
                    return (Data("{}".utf8), self.http(request, 401))
                }
                self.serverAccess = "access-\(self.posts.count)"
                self.serverRefresh = "refresh-\(self.posts.count)"
                try await self.beforeResponse?()
                let data = self.responseData ?? Data("""
                    {"access_token":"\(self.serverAccess)","refresh_token":"\(self.serverRefresh)","expires_in":3600,
                    "token_type":"Bearer","user_id":"source","email":"relay@example.test","subscription_tier":"pro"}
                    """.utf8)
                return (data, self.http(request, 200))
            })
        @MainActor lazy var auth = AuthState(dependencies: .init(sessions: store,
            user: { _ = try await self.refresher.ensureValidSession(); return self.user },
            refresh: { try await self.refresher.refresh() }, sync: { self.syncs += 1 },
            resetSubscription: { self.resets += 1 }, now: { self.clock }))

        func legacy(expiresIn: TimeInterval = 400) {
            items["accessToken"] = Data("source-access".utf8)
            items["refreshToken"] = Data("source-refresh".utf8)
            items["tokenExpiry"] = Data(String(clock.addingTimeInterval(expiresIn).timeIntervalSince1970).utf8)
        }
        func http(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        func response(id: String = "source", expiresIn: Int = 3600, access: String = "login-access",
                      refresh: String = "login-refresh") -> AuthResponse {
            AuthResponse(accessToken: access, refreshToken: refresh, expiresIn: expiresIn, tokenType: "Bearer",
                userId: id, email: "new@example.test", subscriptionTier: "pro", emailVerified: true,
                isAnonymous: false, message: nil)
        }
        @MainActor func flow() -> EmailConversionCoordinator {
            auth.updateUser(user)
            let service = EmailConversionService(baseURL: URL(string: "https://nonproduction.invalid")!) { request in
                let path = request.url!.path
                self.paths.append(path)
                self.authorizations[path] = request.value(forHTTPHeaderField: "Authorization")
                let data: Data
                if path.hasSuffix("challenge") {
                    data = Data("{\"challenge_id\":\"unchanged-challenge\",\"nonce\":\"fresh-proof-nonce\",\"expires_at\":\(self.clock.addingTimeInterval(600).timeIntervalSince1970 * 1000)}".utf8)
                } else if path.hasSuffix("start") {
                    data = Data("{}".utf8)
                } else {
                    XCTAssertTrue(path.hasSuffix("complete"))
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.serverAccess)")
                    XCTAssertGreaterThan(try XCTUnwrap(self.store.snapshot().session).expiresAt, self.clock)
                    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
                    XCTAssertEqual(body["code"], "unchanged-independent-code")
                    data = Data("{\"user_id\":\"source\",\"email\":\"new@example.test\",\"email_verified\":true,\"apple_access_retained\":true,\"notification_pending\":false}".utf8)
                }
                return (data, self.http(request, 200))
            }
            let flow = EmailConversionCoordinator(service: service, authState: auth,
                prepareSession: { try await self.refresher.ensureValidSession(replacing: $0) },
                beforeValidationRead: { try self.contend(.coordinator) }, login: { email, password in
                    XCTAssertEqual(email, "new@example.test"); XCTAssertEqual(password, "chosen password")
                    self.logins += 1
                    return self.response()
                })
            flow.destination = "new@example.test"
            return flow
        }
        @MainActor func prime(_ flow: EmailConversionCoordinator) async {
            await flow.begin(); XCTAssertEqual(flow.stage, .apple)
            await flow.authorize(identityToken: "fresh-interactive-proof"); XCTAssertEqual(flow.stage, .email)
            flow.code = "unchanged-independent-code"; flow.password = "chosen password"; flow.confirmation = flow.password
        }
        func contend(_ window: ReadWindow) throws {
            guard readWindow == window, commits == 1 else { return }
            readWindow = nil
            windowHits.append(window)
            // This is AFTER successful Security commit and BEFORE the specified production
            // snapshot. Independent open descriptor, actual flock; no injected lock failure.
            heldLock = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard heldLock >= 0, flock(heldLock, LOCK_EX | LOCK_NB) == 0 else {
                throw AtomicSessionStore.Failure.lockUnavailable
            }
        }
        func release() {
            if heldLock >= 0 { flock(heldLock, LOCK_UN); close(heldLock); heldLock = -1 }
        }
        deinit { release(); try? FileManager.default.removeItem(at: lockURL) }
    }

    func testAgedValidatedPendingResponseUsesReturnedRefreshWithSharedActorStoreAuthClock() async throws {
        let f = Fixture(); f.legacy(expiresIn: -1); f.auth.updateUser(f.user)
        let source = try f.store.snapshot(); f.writeStatus = errSecInteractionNotAllowed
        await f.auth.checkAuthStatus()
        XCTAssertEqual(f.posts, ["source-refresh"]); XCTAssertEqual(try f.store.snapshot(), source)
        XCTAssertNotNil(f.auth.sessionStorageMessage); XCTAssertEqual(f.auth.currentUser, f.user)
        f.clock = f.clock.addingTimeInterval(3601); f.writeStatus = errSecSuccess
        await f.auth.checkAuthStatus() // Explicit retry after aging, through actual AuthState.
        XCTAssertEqual(f.posts, ["source-refresh", "refresh-1"])
        let current = try XCTUnwrap(f.store.snapshot().session)
        XCTAssertEqual(current.refreshToken, "refresh-2"); XCTAssertEqual(current.userID, "source")
        XCTAssertGreaterThan(current.expiresAt, f.clock); XCTAssertNil(f.auth.sessionStorageMessage)
        XCTAssertEqual(f.auth.currentUser, f.user); XCTAssertEqual(f.resets, 0); XCTAssertEqual(f.syncs, 1)
        XCTAssertEqual(f.commits, 2) // Scoped aged B persistence, then fresh C; no expired access request.
    }

    func testAgedRenewalWriteFailureRetainsReturnedTokensAndDoesNotResetAuth() async throws {
        let f = Fixture(); f.legacy(expiresIn: -1); f.auth.updateUser(f.user)
        f.writeStatus = errSecInteractionNotAllowed
        await f.auth.checkAuthStatus()
        f.clock = f.clock.addingTimeInterval(3601); f.writeStatus = errSecSuccess
        f.beforeResponse = { if f.posts.count == 2 { f.writeStatus = errSecInteractionNotAllowed } }
        await f.auth.checkAuthStatus()
        XCTAssertEqual(f.posts, ["source-refresh", "refresh-1"]); XCTAssertEqual(f.commits, 1)
        XCTAssertLessThan(try XCTUnwrap(f.store.snapshot().session).expiresAt, f.clock)
        XCTAssertNotNil(f.auth.sessionStorageMessage); XCTAssertEqual(f.auth.currentUser, f.user)
        XCTAssertEqual(f.resets, 0); XCTAssertEqual(f.syncs, 0)
        f.writeStatus = errSecSuccess
        await f.auth.checkAuthStatus()
        XCTAssertEqual(f.posts, ["source-refresh", "refresh-1"]); XCTAssertEqual(f.commits, 2)
        XCTAssertGreaterThan(try XCTUnwrap(f.store.snapshot().session).expiresAt, f.clock)
        XCTAssertEqual(try f.store.snapshot().session?.refreshToken, "refresh-2")
        XCTAssertNil(f.auth.sessionStorageMessage); XCTAssertEqual(f.resets, 0); XCTAssertEqual(f.syncs, 1)
    }

    func testLogoutAfterAgedPersistenceBeforeRenewalRetryRejectsRetainedResponse() async throws {
        let f = Fixture(); f.legacy(expiresIn: -1); f.auth.updateUser(f.user)
        f.writeStatus = errSecInteractionNotAllowed
        await f.auth.checkAuthStatus()
        f.clock = f.clock.addingTimeInterval(3601); f.writeStatus = errSecSuccess
        f.beforeResponse = { if f.posts.count == 2 { f.writeStatus = errSecInteractionNotAllowed } }
        await f.auth.checkAuthStatus()
        f.writeStatus = errSecSuccess; XCTAssertTrue(f.auth.logout())
        let tombstone = try f.store.snapshot()
        do { try await f.refresher.refresh(); XCTFail("Retained renewal must not resurrect durable logout") }
        catch AtomicSessionStore.Failure.changedSession { }
        XCTAssertEqual(try f.store.snapshot(), tombstone); XCTAssertNil(f.auth.currentUser)
        XCTAssertEqual(f.posts, ["source-refresh", "refresh-1"]); XCTAssertEqual(f.resets, 1)
    }

    func testAgedPendingResponseRejectsDurableLogoutBeforeExpiredPersistence() async throws {
        try await agedSupersession(.logout)
    }
    func testAgedPendingResponseRejectsOtherAccountBeforeExpiredPersistence() async throws {
        try await agedSupersession(.otherID)
    }
    func testAgedPendingResponseRejectsSameIDReloginBeforeExpiredPersistence() async throws {
        try await agedSupersession(.sameID)
    }
    private func agedSupersession(_ replacement: Replacement) async throws {
        let f = Fixture(); f.legacy(expiresIn: -1); f.auth.updateUser(f.user)
        f.writeStatus = errSecInteractionNotAllowed
        await f.auth.checkAuthStatus(); XCTAssertEqual(f.posts, ["source-refresh"])
        f.clock = f.clock.addingTimeInterval(3601); f.writeStatus = errSecSuccess
        if replacement == .logout { XCTAssertTrue(f.auth.logout()) }
        else { try await f.auth.setAuthenticated(response: f.response(id: replacement == .otherID ? "other" : "source")) }
        let changed = try f.store.snapshot(); let user = f.auth.currentUser
        do { try await f.refresher.refresh(); XCTFail("Expired capability must still reject superseded source CAS") }
        catch AtomicSessionStore.Failure.changedSession { }
        XCTAssertEqual(try f.store.snapshot(), changed); XCTAssertEqual(f.auth.currentUser, user)
        XCTAssertEqual(f.posts, ["source-refresh"]); XCTAssertEqual(f.commits, 1)
        XCTAssertEqual(f.resets, replacement == .logout ? 1 : 0)
    }

    func testFinalHelperSnapshotRealContentionAfterOwnCommitAllowsExactRetry() async throws {
        try await readRecovery(.helper)
    }
    func testCoordinatorValidationSnapshotRealContentionAfterOwnCommitAllowsExactRetry() async throws {
        try await readRecovery(.coordinator)
    }
    private func committedButUnread(_ window: ReadWindow) async throws -> (Fixture, EmailConversionCoordinator) {
        let f = Fixture(); f.legacy(); let flow = f.flow(); await f.prime(flow)
        let source = try f.store.snapshot()
        f.clock = f.clock.addingTimeInterval(401); f.readWindow = window
        await flow.complete()
        XCTAssertEqual(f.windowHits, [window]); XCTAssertGreaterThanOrEqual(f.heldLock, 0)
        XCTAssertEqual(f.commits, 1); XCTAssertEqual(f.posts, ["source-refresh"])
        XCTAssertEqual(flow.stage, .email); XCTAssertTrue(flow.message!.contains("unavailable"))
        XCTAssertEqual(flow.code, "unchanged-independent-code"); XCTAssertEqual(flow.password, "chosen password")
        XCTAssertEqual(flow.confirmation, flow.password); XCTAssertEqual(f.auth.currentUser, f.user)
        XCTAssertEqual(f.paths, ["/auth/email-conversion/challenge", "/auth/email-conversion/start", "/auth/refresh"])
        XCTAssertEqual(f.logins, 0); XCTAssertEqual(f.resets, 0)
        f.release()
        let committed = try f.store.snapshot()
        XCTAssertNotEqual(committed, source); XCTAssertEqual(committed.session?.refreshToken, "refresh-1")
        return (f, flow)
    }
    private func readRecovery(_ window: ReadWindow) async throws {
        let (f, flow) = try await committedButUnread(window)
        await flow.complete()
        XCTAssertEqual(flow.stage, .done); XCTAssertEqual(f.posts, ["source-refresh"])
        XCTAssertEqual(f.paths.filter { $0.hasSuffix("challenge") }.count, 1)
        XCTAssertEqual(f.paths.filter { $0.hasSuffix("start") }.count, 1)
        XCTAssertEqual(f.paths.filter { $0.hasSuffix("complete") }.count, 1)
        XCTAssertEqual(f.authorizations["/auth/email-conversion/complete"], "Bearer access-1")
        XCTAssertEqual(f.logins, 1); XCTAssertEqual(f.resets, 0); XCTAssertEqual(f.syncs, 0)
        XCTAssertEqual(f.auth.currentUser?.storageUsedBytes, 723); XCTAssertEqual(f.auth.currentUser?.imageCount, 7)
    }

    func testLogoutBetweenHelperCommitAndRetryRejectsOwnReceipt() async throws { try await readSupersession(.helper, .logout) }
    func testSameIDReloginBetweenHelperCommitAndRetryRejectsOwnReceipt() async throws { try await readSupersession(.helper, .sameID) }
    func testAccountSwitchBetweenHelperCommitAndRetryRejectsOwnReceipt() async throws { try await readSupersession(.helper, .otherID) }
    func testForeignSameIDRevisionBetweenHelperCommitAndRetryRejectsOwnReceipt() async throws { try await readSupersession(.helper, .foreignRevision) }
    func testLogoutBetweenCoordinatorCommitAndRetryRejectsOwnReceipt() async throws { try await readSupersession(.coordinator, .logout) }
    func testSameIDReloginBetweenCoordinatorCommitAndRetryRejectsOwnReceipt() async throws { try await readSupersession(.coordinator, .sameID) }
    func testAccountSwitchBetweenCoordinatorCommitAndRetryRejectsOwnReceipt() async throws { try await readSupersession(.coordinator, .otherID) }
    func testForeignSameIDRevisionBetweenCoordinatorCommitAndRetryRejectsOwnReceipt() async throws { try await readSupersession(.coordinator, .foreignRevision) }
    private func readSupersession(_ window: ReadWindow, _ replacement: Replacement) async throws {
        let (f, flow) = try await committedButUnread(window)
        switch replacement {
        case .logout: XCTAssertTrue(f.auth.logout())
        case .sameID, .otherID:
            try await f.auth.setAuthenticated(response: f.response(id: replacement == .sameID ? "source" : "other"))
        case .foreignRevision:
            let current = try f.store.snapshot()
            // Identical same-ID credentials, DIFFERENT revision, without touching the app lease.
            try f.keychain.sessions.commit(current.session, replacing: current)
        }
        let changed = try f.store.snapshot(); let user = f.auth.currentUser
        await flow.complete()
        XCTAssertEqual(flow.stage, .invalidated); XCTAssertEqual(try f.store.snapshot(), changed)
        XCTAssertEqual(f.auth.currentUser, user); XCTAssertEqual(f.logins, 0)
        XCTAssertEqual(f.posts, ["source-refresh"]); XCTAssertFalse(f.paths.contains { $0.hasSuffix("complete") })
        XCTAssertEqual(f.resets, replacement == .logout ? 1 : 0)
    }

    func testMalformedFreshRefreshCannotMintAgingCapability() async throws {
        for (access, refresh, id, expires) in [("", "new-refresh", "source", 3600),
            ("new-access", "", "source", 3600), ("new-access", "new-refresh", "", 3600),
            ("new-access", "new-refresh", "source", 0), ("new-access", "new-refresh", "source", -1)] {
            let f = Fixture(); f.legacy(expiresIn: -1)
            f.responseData = Data("{\"access_token\":\"\(access)\",\"refresh_token\":\"\(refresh)\",\"user_id\":\"\(id)\",\"expires_in\":\(expires),\"token_type\":\"Bearer\",\"email\":\"relay@example.test\",\"subscription_tier\":\"pro\"}".utf8)
            let before = try f.store.snapshot()
            do { try await f.refresher.refresh(); XCTFail("Malformed fresh response must be rejected") }
            catch SessionRefreshCoordinator.Failure.invalidResponse { }
            XCTAssertEqual(try f.store.snapshot(), before); XCTAssertEqual(f.commits, 0)
            XCTAssertEqual(f.posts, ["source-refresh"])
        }
    }

    func testInvalidJSONAndWrongTokenTypeRefreshCannotMintAgingCapability() async throws {
        for data in [Data("{}".utf8), Data("{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"user_id\":\"source\",\"expires_in\":3600,\"token_type\":\"NotBearer\",\"email\":\"relay@example.test\",\"subscription_tier\":\"pro\"}".utf8)] {
            let f = Fixture(); f.legacy(expiresIn: -1); f.responseData = data
            let before = try f.store.snapshot()
            do { try await f.refresher.refresh(); XCTFail("Unverified fresh response must not mint a capability") }
            catch SessionRefreshCoordinator.Failure.invalidResponse { }
            XCTAssertEqual(try f.store.snapshot(), before); XCTAssertEqual(f.commits, 0)
        }
    }

    func testWrongAccountRefreshCannotMintAgingCapability() async throws {
        let f = Fixture(); f.legacy()
        let before = try f.store.snapshot()
        try f.store.commit(AccountSession(accessToken: "source-access", refreshToken: "source-refresh",
            expiresAt: f.clock.addingTimeInterval(400), userID: "source"), replacing: before)
        let bound = try f.store.snapshot()
        f.responseData = Data("{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"user_id\":\"other\",\"expires_in\":3600,\"token_type\":\"Bearer\",\"email\":\"other@example.test\",\"subscription_tier\":\"pro\"}".utf8)
        do { try await f.refresher.refresh(); XCTFail("Wrong ID is not validated refresh provenance") }
        catch AtomicSessionStore.Failure.changedSession { }
        XCTAssertEqual(try f.store.snapshot(), bound); XCTAssertEqual(f.commits, 1)
    }

    func testSharedClockFreshLoginAndAdoptionRemainStrictAfterAging() async throws {
        let f = Fixture(); f.legacy(); f.auth.updateUser(f.user)
        f.clock = f.clock.addingTimeInterval(3601)
        let before = try f.store.snapshot()
        for response in [f.response(expiresIn: 0), f.response(expiresIn: -1), f.response(access: ""), f.response(refresh: "")] {
            do { try await f.auth.setAuthenticated(response: response); XCTFail("No relaxed fresh-login expiry/token policy") }
            catch AtomicSessionStore.Failure.invalidSession { }
            XCTAssertEqual(try f.store.snapshot(), before); XCTAssertEqual(f.auth.currentUser, f.user)
            do { try f.auth.adoptConversion(response, sourceUserID: "source", replacing: before); XCTFail("No relaxed fresh-adoption policy") }
            catch AtomicSessionStore.Failure.invalidSession { }
            XCTAssertEqual(try f.store.snapshot(), before); XCTAssertEqual(f.auth.currentUser, f.user)
        }
        XCTAssertEqual(f.resets, 0); XCTAssertEqual(f.syncs, 0); XCTAssertEqual(f.commits, 0)
    }

    func testValidatedRefreshCapabilityIsStoreBoundAndCannotReplayAfterCASCommit() throws {
        let f = Fixture(); f.legacy()
        let source = try f.store.snapshot()
        let response = RefreshResponse(accessToken: "validated-access", refreshToken: "validated-refresh", expiresIn: 3600,
            tokenType: "Bearer", userId: "source", email: "relay@example.test", subscriptionTier: "pro", isAnonymous: false)
        let capability = try f.store.validateReturnedRefresh(response, replacing: source, receivedAt: f.clock)
        f.clock = f.clock.addingTimeInterval(3601)
        XCTAssertThrowsError(try f.keychain.sessions.commitReturnedRefresh(capability)) { error in
            guard let failure = error as? AtomicSessionStore.Failure, case .invalidSession = failure else {
                return XCTFail("A capability from another store is invalid, not authority to overwrite")
            }
        }
        XCTAssertEqual(try f.store.snapshot(), source)
        let committed = try f.store.commitReturnedRefresh(capability)
        XCTAssertLessThan(try XCTUnwrap(committed.session).expiresAt, f.clock)
        XCTAssertEqual(try f.store.snapshot(), committed)
        XCTAssertThrowsError(try f.store.commit(committed.session, replacing: committed)) // Generic fresh path remains strict.
        XCTAssertThrowsError(try f.store.commitReturnedRefresh(capability)) // Exact source revision has been consumed.
        XCTAssertEqual(try f.store.snapshot(), committed); XCTAssertEqual(f.commits, 1)
    }
}
