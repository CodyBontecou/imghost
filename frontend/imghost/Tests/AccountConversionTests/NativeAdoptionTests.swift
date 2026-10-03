import XCTest
import Security
import AuthenticationServices
@testable import AccountConversion

@MainActor
final class NativeAdoptionTests: XCTestCase {
    @MainActor private final class Fixture {
        var data: Data?
        var readStatus = errSecSuccess
        var writeStatus = errSecSuccess
        var adds = 0
        var updates = 0
        var paths: [String] = []
        var challengeStatus = 200
        var completeStatus = 200
        var loseCompletion = false
        var pending = false
        var completionID = "same-user"
        var loginID = "same-user"
        var loginFails = false
        var loginCalls = 0
        var syncCalls = 0
        var resetCalls = 0
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("conversion-tests-\(UUID()).lock")
        let oldUser = User(id: "same-user", email: "relay@example.test", emailVerified: true,
                           storageUsedBytes: 723, storageLimitBytes: 99999, imageCount: 7, isAnonymous: false)
        let oldSession = AccountSession(accessToken: "old-access", refreshToken: "old-refresh",
                                       expiresAt: Date().addingTimeInterval(3600), userID: "same-user")
        lazy var store = makeStore()
        lazy var auth = AuthState(dependencies: .init(sessions: store,
            user: { self.oldUser }, refresh: {}, sync: { self.syncCalls += 1 },
            resetSubscription: { self.resetCalls += 1 }))

        func makeStore() -> AtomicSessionStore {
            AtomicSessionStore.keychain(service: "synthetic-service", accessGroup: "synthetic-group", lockURL: lockURL,
                calls: .init(read: { query in
                    XCTAssertEqual(query[kSecAttrAccount as String] as? String, "atomicSession.v1")
                    XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "synthetic-group")
                    if self.readStatus != errSecSuccess { return (self.readStatus, nil) }
                    return self.data.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
                }, add: { query in
                    self.adds += 1
                    guard self.writeStatus == errSecSuccess else { return self.writeStatus }
                    self.data = query[kSecValueData as String] as? Data
                    return errSecSuccess
                }, update: { query, changes in
                    self.updates += 1
                    XCTAssertNil(query[kSecValueData as String])
                    XCTAssertEqual(changes.count, 1)
                    guard self.writeStatus == errSecSuccess else { return self.writeStatus }
                    self.data = changes[kSecValueData as String] as? Data
                    return errSecSuccess
                }), legacy: { self.oldSession })
        }

        func response() -> AuthResponse {
            AuthResponse(accessToken: "new-access", refreshToken: "new-refresh", expiresIn: 3600,
                tokenType: "Bearer", userId: loginID, email: "new@example.test", subscriptionTier: "pro",
                emailVerified: true, isAnonymous: false, message: nil)
        }
        func flow(login: ((String, String) async throws -> AuthResponse)? = nil) -> EmailConversionCoordinator {
            auth.updateUser(oldUser)
            let service = EmailConversionService(baseURL: URL(string: "https://nonproduction.invalid")!) { request in
                let path = request.url!.path
                self.paths.append(path)
                var status = 200
                var data = Data("{}".utf8)
                if path.hasSuffix("challenge") {
                    status = self.challengeStatus
                    data = Data("{\"challenge_id\":\"challenge\",\"nonce\":\"verbatim-nonce\",\"expires_at\":\(Date().addingTimeInterval(300).timeIntervalSince1970 * 1000)}".utf8)
                } else if path.hasSuffix("start") {
                    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
                    XCTAssertEqual(body["identity_token"], "interactive-proof")
                    XCTAssertEqual(body["destination_email"], "new@example.test")
                } else if path.hasSuffix("complete") {
                    if self.loseCompletion { throw URLError(.timedOut) }
                    status = self.completeStatus
                    data = Data("{\"user_id\":\"\(self.completionID)\",\"email\":\"new@example.test\",\"email_verified\":true,\"apple_access_retained\":true,\"notification_pending\":\(self.pending)}".utf8)
                } else { XCTFail("Unexpected account endpoint") }
                return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            let flow = EmailConversionCoordinator(service: service, authState: auth, login: login ?? { email, password in
                self.loginCalls += 1
                XCTAssertEqual(email, "new@example.test")
                XCTAssertEqual(password, "chosen password")
                if self.loginFails { throw URLError(.notConnectedToInternet) }
                return self.response()
            })
            flow.destination = " New@example.test \n"
            return flow
        }
        func prime(_ flow: EmailConversionCoordinator) async {
            await flow.begin()
            XCTAssertEqual(flow.stage, .apple)
            await flow.authorize(identityToken: "interactive-proof")
            XCTAssertEqual(flow.stage, .email)
            flow.code = "code"
            flow.password = "chosen password"
            flow.confirmation = "chosen password"
        }
        func unchanged(_ snapshot: AtomicSessionStore.Snapshot) throws {
            XCTAssertEqual(try store.snapshot(), snapshot)
            XCTAssertEqual(auth.currentUser, oldUser)
            XCTAssertTrue(auth.isAuthenticated)
            XCTAssertEqual(syncCalls, 0)
            XCTAssertEqual(resetCalls, 0)
        }
        deinit { try? FileManager.default.removeItem(at: lockURL) }
    }

    func testSettingsCoordinatorVerifiesOrdinaryLoginThenCommitsSameAccountWithoutClearingData() async throws {
        let f = Fixture(); let flow = f.flow()
        await f.prime(flow)
        await flow.complete()
        XCTAssertEqual(flow.stage, .done)
        XCTAssertEqual(f.loginCalls, 1)
        XCTAssertEqual(f.auth.currentUser?.id, f.oldUser.id)
        XCTAssertEqual(f.auth.currentUser?.email, "new@example.test")
        XCTAssertEqual(f.auth.currentUser?.storageUsedBytes, 723)
        XCTAssertEqual(f.auth.currentUser?.storageLimitBytes, 99999)
        XCTAssertEqual(f.auth.currentUser?.imageCount, 7)
        XCTAssertEqual(try f.store.snapshot().session?.accessToken, "new-access")
        XCTAssertEqual(try f.store.snapshot().session?.refreshToken, "new-refresh")
        XCTAssertEqual(f.adds, 1); XCTAssertEqual(f.updates, 0)
        XCTAssertEqual(f.syncCalls, 0); XCTAssertEqual(f.resetCalls, 0)
        XCTAssertEqual(flow.password, "")
        XCTAssertEqual(f.paths, ["/auth/email-conversion/challenge", "/auth/email-conversion/start", "/auth/email-conversion/complete"])
    }

    func testDisabledRolloutIsDiscoverableUnavailableAndRetryDoesNotChangeSession() async throws {
        let f = Fixture(); f.challengeStatus = 404; let flow = f.flow()
        let before = try f.store.snapshot()
        await flow.begin()
        XCTAssertEqual(flow.stage, .idle)
        XCTAssertTrue(flow.message!.contains("not available"))
        try f.unchanged(before)
        f.challengeStatus = 200
        await flow.begin()
        XCTAssertEqual(flow.stage, .apple)
        try f.unchanged(before)
    }

    func testFreshNativeAppleRequestUsesVerbatimChallengeNonceAndNoCachedProof() async throws {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        let challenge = EmailConversionService.Challenge(challengeID: "id", nonce: "verbatim-nonce", expiresAt: 1)
        EmailConversionAppleProof.configure(request, challenge: challenge)
        XCTAssertEqual(request.nonce, "verbatim-nonce")
        XCTAssertEqual(request.requestedScopes, [])
    }

    func testAppleCancellationKeepsOriginalCredentialsAndAllowsFreshRetry() async throws {
        let f = Fixture(); let flow = f.flow(); let before = try f.store.snapshot()
        await flow.begin()
        flow.appleAuthorizationFailed(cancelled: true)
        XCTAssertEqual(flow.stage, .apple)
        XCTAssertTrue(flow.message!.contains("cancelled"))
        try f.unchanged(before)
        await flow.authorize(identityToken: "interactive-proof")
        XCTAssertEqual(flow.stage, .email)
        try f.unchanged(before)
    }

    func testDestinationIsFrozenAfterChallengeEvenIfViewBindingChanges() async throws {
        let f = Fixture(); let flow = f.flow()
        await flow.begin()
        flow.destination = "other@example.test"
        await flow.authorize(identityToken: "interactive-proof")
        flow.code = "code"; flow.password = "chosen password"; flow.confirmation = flow.password
        await flow.complete()
        XCTAssertEqual(flow.stage, .done)
        XCTAssertEqual(f.auth.currentUser?.email, "new@example.test")
    }

    func testPasswordConfirmationFailureNeverSendsCompletionOrAdopts() async throws {
        let f = Fixture(); let flow = f.flow(); let before = try f.store.snapshot()
        await f.prime(flow); flow.confirmation = "different password"
        await flow.complete()
        XCTAssertEqual(flow.stage, .email)
        XCTAssertEqual(f.paths.count, 2); XCTAssertEqual(f.loginCalls, 0)
        try f.unchanged(before)
    }

    func testRejectedCodeDoesNotLoginOrPublishAndCanRestart() async throws {
        let f = Fixture(); f.completeStatus = 400; let flow = f.flow(); let before = try f.store.snapshot()
        await f.prime(flow); await flow.complete()
        XCTAssertEqual(flow.stage, .email); XCTAssertEqual(f.loginCalls, 0)
        try f.unchanged(before)
        flow.cancel(); XCTAssertEqual(flow.stage, .idle)
        await flow.begin(); XCTAssertEqual(flow.stage, .apple)
    }

    func testLostCompletionResponseRequiresExplicitSameIDLoginRecoveryNotRollbackOrResend() async throws {
        let f = Fixture(); f.loseCompletion = true; let flow = f.flow(); let before = try f.store.snapshot()
        await f.prime(flow); await flow.complete()
        XCTAssertEqual(flow.stage, .recovery); XCTAssertEqual(f.loginCalls, 0)
        XCTAssertTrue(flow.message!.contains("may have changed"))
        try f.unchanged(before)
        await flow.recover()
        XCTAssertEqual(flow.stage, .done); XCTAssertEqual(f.paths.count, 3); XCTAssertEqual(f.loginCalls, 1)
    }

    func testMismatchedCompletionAccountNeverAutomaticallyLogsInOrAdopts() async throws {
        let f = Fixture(); f.completionID = "another-user"; let flow = f.flow(); let before = try f.store.snapshot()
        await f.prime(flow); await flow.complete()
        XCTAssertEqual(flow.stage, .recovery); XCTAssertEqual(f.loginCalls, 0)
        try f.unchanged(before)
    }

    func testMismatchedOrdinaryLoginAccountLeavesOriginalStateAndDurableCredentials() async throws {
        let f = Fixture(); f.loginID = "another-user"; let flow = f.flow(); let before = try f.store.snapshot()
        await f.prime(flow); await flow.complete()
        XCTAssertEqual(flow.stage, .recovery); XCTAssertEqual(f.loginCalls, 1)
        try f.unchanged(before)
    }

    func testLoginNetworkFailureAfterCommitDoesNotClaimRollbackAndRetryOnlyLogsIn() async throws {
        let f = Fixture(); f.loginFails = true; let flow = f.flow(); let before = try f.store.snapshot()
        await f.prime(flow); await flow.complete()
        XCTAssertEqual(flow.stage, .recovery)
        try f.unchanged(before)
        f.loginFails = false; await flow.recover()
        XCTAssertEqual(flow.stage, .done); XCTAssertEqual(f.paths.count, 3)
    }

    func testKeychainAddFailureKeepsLegacySessionAndMemoryThenExplicitRecoverySucceeds() async throws {
        let f = Fixture(); f.writeStatus = errSecMissingEntitlement; let flow = f.flow(); let before = try f.store.snapshot()
        await f.prime(flow); await flow.complete()
        XCTAssertEqual(flow.stage, .recovery); XCTAssertNil(f.data)
        try f.unchanged(before)
        f.writeStatus = errSecSuccess; await flow.recover()
        XCTAssertEqual(flow.stage, .done)
    }

    func testKeychainUpdateFailureKeepsAuthoritativeSessionAndMemoryWithoutDeleteBeforeAdd() async throws {
        let f = Fixture(); let flow = f.flow()
        try f.store.commit(f.oldSession, replacing: f.store.snapshot())
        let before = try f.store.snapshot()
        f.writeStatus = errSecInteractionNotAllowed
        await f.prime(flow); await flow.complete()
        XCTAssertEqual(flow.stage, .recovery)
        try f.unchanged(before)
        XCTAssertEqual(f.adds, 1); XCTAssertEqual(f.updates, 1)
        f.writeStatus = errSecSuccess; await flow.recover()
        XCTAssertEqual(flow.stage, .done); XCTAssertEqual(f.adds, 1); XCTAssertEqual(f.updates, 2)
    }

    func testKeychainReadFailureIsNotAbsenceOrPermissionToFallBackToLegacy() async throws {
        let f = Fixture(); let flow = f.flow()
        try f.store.commit(f.oldSession, replacing: f.store.snapshot())
        let before = f.data
        f.readStatus = errSecInteractionNotAllowed
        await flow.begin()
        XCTAssertEqual(f.paths.count, 0); XCTAssertEqual(f.data, before)
        XCTAssertEqual(f.auth.currentUser, f.oldUser)
        XCTAssertThrowsError(try f.store.snapshot())
    }

    func testCorruptAuthoritativeItemDoesNotResurrectLegacyCredentials() async throws {
        let f = Fixture(); f.data = Data("corrupt".utf8)
        XCTAssertThrowsError(try f.store.snapshot())
        XCTAssertEqual(f.data, Data("corrupt".utf8))
        XCTAssertEqual(f.adds, 0); XCTAssertEqual(f.updates, 0)
    }

    func testLateRefreshFromAnotherStoreCannotOverwriteCommittedConversion() async throws {
        let f = Fixture(); let flow = f.flow()
        let extensionStore = f.makeStore()
        let staleRefresh = try extensionStore.snapshot()
        await f.prime(flow); await flow.complete()
        let committed = try f.store.snapshot()
        XCTAssertThrowsError(try extensionStore.commit(f.oldSession, replacing: staleRefresh))
        XCTAssertEqual(try f.store.snapshot(), committed)
        XCTAssertEqual(f.auth.currentUser?.email, "new@example.test")
    }

    func testLogoutTombstonePreventsLegacyFallbackAndLateRefreshResurrection() async throws {
        let f = Fixture(); let flow = f.flow(); _ = flow
        let stale = try f.store.snapshot()
        f.auth.logout()
        XCTAssertNil(try f.makeStore().snapshot().session)
        XCTAssertNotNil(f.data)
        XCTAssertNil(f.auth.currentUser)
        XCTAssertThrowsError(try f.store.commit(f.oldSession, replacing: stale))
        XCTAssertEqual(f.resetCalls, 1)
    }

    func testLogoutDuringVerificationCannotBeOverwrittenByLateConversionLogin() async throws {
        let f = Fixture()
        var resume: CheckedContinuation<AuthResponse, Error>?
        let flow = f.flow(login: { _, _ in try await withCheckedThrowingContinuation { resume = $0 } })
        await f.prime(flow)
        let task = Task { await flow.complete() }
        while resume == nil { await Task.yield() }
        f.auth.logout()
        resume!.resume(returning: f.response())
        await task.value
        XCTAssertNil(f.auth.currentUser); XCTAssertNil(try f.store.snapshot().session)
        XCTAssertEqual(flow.stage, .recovery)
    }

    func testClosingDuringLoginInvalidatesCallbackWithoutLocalAdoption() async throws {
        let f = Fixture()
        var resume: CheckedContinuation<AuthResponse, Error>?
        let flow = f.flow(login: { _, _ in try await withCheckedThrowingContinuation { resume = $0 } })
        let before = try f.store.snapshot()
        await f.prime(flow)
        let task = Task { await flow.complete() }
        while resume == nil { await Task.yield() }
        flow.cancel()
        resume!.resume(returning: f.response())
        await task.value
        try f.unchanged(before)
        XCTAssertEqual(flow.stage, .idle)
    }

    func testTaskCancellationAfterServerCommitNeverAdoptsOrClaimsRollback() async throws {
        let f = Fixture()
        var resume: CheckedContinuation<AuthResponse, Error>?
        let flow = f.flow(login: { _, _ in try await withCheckedThrowingContinuation { resume = $0 } })
        let before = try f.store.snapshot()
        await f.prime(flow)
        let task = Task { await flow.complete() }
        while resume == nil { await Task.yield() }
        task.cancel(); resume!.resume(returning: f.response())
        await task.value
        try f.unchanged(before); XCTAssertEqual(flow.stage, .recovery)
    }

    func testNotificationPendingIsShownWithoutUndoingDurableAdoption() async throws {
        let f = Fixture(); f.pending = true; let flow = f.flow()
        await f.prime(flow); await flow.complete()
        XCTAssertEqual(flow.stage, .done)
        XCTAssertTrue(flow.message!.contains("pending"))
        XCTAssertEqual(try f.store.snapshot().session?.userID, f.oldUser.id)
    }

    func testOrdinaryAuthStateLoginPersistenceFailureDoesNotPublishPartialSuccess() async throws {
        let f = Fixture(); f.auth.updateUser(f.oldUser)
        let before = try f.store.snapshot(); f.writeStatus = errSecMissingEntitlement
        do { try await f.auth.setAuthenticated(response: f.response()); XCTFail("Expected Keychain fault") }
        catch { }
        try f.unchanged(before)
    }

    func testStaleAuthStatusFailureAfterAdoptionCannotLogOutNewSession() async throws {
        let f = Fixture()
        var resume: CheckedContinuation<User, Error>?
        let auth = AuthState(dependencies: .init(sessions: f.store,
            user: { try await withCheckedThrowingContinuation { resume = $0 } },
            refresh: { XCTFail("Stale refresh must not run") }, sync: {},
            resetSubscription: { XCTFail("Must not reset subscription") }))
        auth.updateUser(f.oldUser)
        let before = try f.store.snapshot()
        let task = Task { await auth.checkAuthStatus() }
        while resume == nil { await Task.yield() }
        try auth.adoptConversion(f.response(), sourceUserID: f.oldUser.id, replacing: before)
        resume!.resume(throwing: URLError(.timedOut))
        await task.value
        XCTAssertEqual(auth.currentUser?.email, "new@example.test")
        XCTAssertEqual(try f.store.snapshot().session?.accessToken, "new-access")
        XCTAssertTrue(auth.isAuthenticated)
    }
}
