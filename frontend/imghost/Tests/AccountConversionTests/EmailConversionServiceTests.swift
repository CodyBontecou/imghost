import XCTest
@testable import AccountConversion

final class EmailConversionServiceTests: XCTestCase {
    private let baseURL = URL(string: "https://nonproduction.invalid")!
    private let challenge = EmailConversionService.Challenge(challengeID: "account-bound-id", nonce: "fresh-nonce", expiresAt: 10000)
    private let success = Data("""
        {"user_id":"existing-user","email":"new@example.test","email_verified":true,
         "apple_access_retained":true,"notification_pending":false}
        """.utf8)

    private func http(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testChallengeAndFreshAppleProofUseOnlyStagedAccountRoutes() async throws {
        var requests: [URLRequest] = []
        let service = EmailConversionService(baseURL: baseURL) { request in
            requests.append(request)
            let data = request.url!.path.hasSuffix("challenge") ? Data("""
                {"challenge_id":"account-bound-id","nonce":"fresh-nonce","expires_at":10000}
                """.utf8) : Data("{}".utf8)
            return (data, self.http(request, 200))
        }
        let result = try await service.challenge(accessToken: "access-jwt")
        XCTAssertEqual(result, challenge)
        try await service.start(challenge: result, identityToken: "new-apple-authorization", destinationEmail: " new@example.test \n", accessToken: "access-jwt")
        XCTAssertEqual(requests.map { $0.url!.path }, ["/auth/email-conversion/challenge", "/auth/email-conversion/start"])
        for request in requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-jwt")
            XCTAssertNil(request.url!.query)
        }
        let body = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: String]
        XCTAssertEqual(body["identity_token"], "new-apple-authorization")
        XCTAssertEqual(body["challenge_id"], challenge.challengeID)
        XCTAssertEqual(body["destination_email"], "new@example.test")
    }

    func testCompletionAcceptsCopyPasteWhitespaceAndReturnsSameAccountWithoutRegisterOrUnlink() async throws {
        var paths: [String] = []
        let service = EmailConversionService(baseURL: baseURL) { request in
            paths.append(request.url!.path)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            XCTAssertEqual(body["code"], "emailed+code=")
            XCTAssertEqual(body["new_password"], "my chosen password")
            return (self.success, self.http(request, 200))
        }
        let result = try await service.complete(challenge: challenge, code: " \nemailed+code= \n", password: "my chosen password",
            passwordConfirmation: "my chosen password", sourceUserID: "existing-user", accessToken: "access-jwt")
        XCTAssertEqual(result.userID, "existing-user")
        XCTAssertTrue(result.appleAccessRetained)
        XCTAssertEqual(paths, ["/auth/email-conversion/complete"])
    }

    func testPasswordMismatchShortPasswordAndMissingCodeNeverSendCredentials() async throws {
        var calls = 0
        let service = EmailConversionService(baseURL: baseURL) { request in
            calls += 1
            return (self.success, self.http(request, 200))
        }
        for (password, confirmation, code) in [("long password", "different password", "code"), ("short", "short", "code"), ("long password", "long password", " \n ")] {
            do {
                _ = try await service.complete(challenge: challenge, code: code, password: password,
                    passwordConfirmation: confirmation, sourceUserID: "existing-user", accessToken: "access-jwt")
                XCTFail("Invalid input should not send")
            } catch { XCTAssertEqual(error as? EmailConversionService.Failure, .invalidInput) }
        }
        XCTAssertEqual(calls, 0)
    }

    func testBackendErrorsDoNotAutomaticallyRetryRegisterOrDelete() async throws {
        for (status, expected) in [(401, EmailConversionService.Failure.reauthenticate),
                                  (409, .destinationUnavailable), (429, .tooManyRequests), (400, .invalidInput)] {
            var calls = 0
            let service = EmailConversionService(baseURL: baseURL) { request in
                calls += 1
                return (Data("{}".utf8), self.http(request, status))
            }
            do {
                _ = try await service.complete(challenge: challenge, code: "code", password: "long password",
                    passwordConfirmation: "long password", sourceUserID: "existing-user", accessToken: "access-jwt")
                XCTFail("Expected mapped error")
            } catch { XCTAssertEqual(error as? EmailConversionService.Failure, expected) }
            XCTAssertEqual(calls, 1)
        }
    }

    func testLostCompletionResponseIsUncertainNotAccountLoss() async throws {
        let service = EmailConversionService(baseURL: baseURL) { _ in throw URLError(.timedOut) }
        do {
            _ = try await service.complete(challenge: challenge, code: "code", password: "long password",
                passwordConfirmation: "long password", sourceUserID: "existing-user", accessToken: "access-jwt")
            XCTFail("Expected uncertainty")
        } catch { XCTAssertEqual(error as? EmailConversionService.Failure, .uncertainCompletion) }
    }

    func testMalformedSuccessAndAccountMismatchCannotReplaceLocalAccountIdentity() async throws {
        for (data, expected) in [(Data("{}".utf8), EmailConversionService.Failure.uncertainCompletion), (success, .wrongAccount)] {
            let service = EmailConversionService(baseURL: baseURL) { request in (data, self.http(request, 200)) }
            do {
                _ = try await service.complete(challenge: challenge, code: "code", password: "long password",
                    passwordConfirmation: "long password", sourceUserID: "different-user", accessToken: "access-jwt")
                XCTFail("Should not trust response")
            } catch { XCTAssertEqual(error as? EmailConversionService.Failure, expected) }
        }
    }

    func testPendingConfirmationNotificationDoesNotUndoCommittedConversion() async throws {
        let pending = Data(String(data: success, encoding: .utf8)!.replacingOccurrences(of: "\"notification_pending\":false", with: "\"notification_pending\":true").utf8)
        let service = EmailConversionService(baseURL: baseURL) { request in (pending, self.http(request, 200)) }
        let result = try await service.complete(challenge: challenge, code: "code", password: "long password",
            passwordConfirmation: "long password", sourceUserID: "existing-user", accessToken: "access-jwt")
        XCTAssertTrue(result.notificationPending)
        XCTAssertEqual(result.userID, "existing-user")
    }
}
