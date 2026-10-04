#if RESET_CODE_ENTRY_UI_TESTS
import XCTest
import Foundation

// Both registered UI targets compile this exact file. No hidden production state
// writes, paste fabrication or substitute route/action implementation is used.
final class ResetCodeEntryUITests: XCTestCase {
    private var app: XCUIApplication!
    private var owner = ""
    private let code = "Ab+/CdEf0123456789012345678901234567890123456="
    private let password = "ReplacementPassword456"

    private struct Receipt: Decodable {
        let sequence: Int
        let owner: String
        let method: String
        let host: String
        let path: String
        let contentType: String?
        let authorization: String?
        let body: [String: String]?
        let status: Int?
        let settled: Bool
        let stopped: Bool
    }
    private struct Snapshot: Decodable {
        let owner: String
        let scenario: String
        let receipts: [Receipt]
        let held: Int
        let violations: [String]
    }
    private enum Failure: Error { case missingElement, invalidReceipts, timeout }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate() // New process and UUID per launch; no cross-case fixture reuse.
        app = nil
    }

    private func launch(_ scenario: String = "normal") throws {
        app?.terminate()
        owner = UUID().uuidString
        app = XCUIApplication()
        app.launchEnvironment = ["RESET_CASE_ID": owner, "RESET_SCENARIO": scenario,
                                 "APP_ANALYTICS_ENABLED": "0"]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        try require(app.buttons["auth.login.forgotPassword"])
        try wait { (try? self.snapshot().owner) == self.owner }
        XCTAssertEqual(try snapshot().receipts.count, 0)
    }

    private func require(_ element: XCUIElement) throws {
        guard element.waitForExistence(timeout: 5) else {
            XCTFail("Missing actual native element: \(element)")
            throw Failure.missingElement
        }
    }

    private func activate(_ element: XCUIElement) throws {
        try require(element)
        for _ in 0..<6 {
            if element.isHittable { break }
            let scroll = app.scrollViews.firstMatch
            guard scroll.exists else { break }
            let aboveViewport = element.frame.midY < scroll.frame.midY
            #if os(iOS)
            if aboveViewport { scroll.swipeDown() } else { scroll.swipeUp() }
            #else
            scroll.scroll(byDeltaX: 0, deltaY: aboveViewport ? 180 : -180)
            #endif
        }
        XCTAssertTrue(element.isHittable, "Actual control must be hittable")
        #if os(iOS)
        element.tap()
        #else
        element.click()
        #endif
    }

    private func field(_ identifier: String) -> XCUIElement {
        let plain = app.textFields[identifier]
        return plain.exists ? plain : app.secureTextFields[identifier]
    }

    private func type(_ identifier: String, _ text: String) throws {
        let element = field(identifier)
        try activate(element)
        element.typeText(text)
    }

    private func openForgot() throws { try activate(app.buttons["auth.login.forgotPassword"]) }
    private func openCode() throws {
        try openForgot()
        try activate(app.buttons["auth.forgot.existingCode"])
        try require(field("auth.reset.code"))
    }
    private func fillReset(code: String? = nil, password: String? = nil, confirmation: String? = nil) throws {
        let value = password ?? self.password
        try type("auth.reset.code", code ?? self.code)
        try type("auth.reset.newPassword", value)
        try type("auth.reset.confirmPassword", confirmation ?? value)
    }

    private func snapshot() throws -> Snapshot {
        let diagnostic = app.staticTexts["fixture.receipts"]
        guard diagnostic.exists, let json = diagnostic.value as? String,
              let data = json.data(using: .utf8), data.count <= 16_384 else {
            throw Failure.invalidReceipts
        }
        return try JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func wait(_ condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: 5) == .completed else {
            XCTFail("Bounded native observation timed out")
            throw Failure.timeout
        }
    }

    private func receipts(_ count: Int, settled: Bool = true) throws -> [Receipt] {
        try wait {
            guard let value = try? self.snapshot() else { return false }
            return value.receipts.count == count && (!settled || value.receipts.allSatisfy(\.settled))
        }
        let value = try snapshot()
        XCTAssertEqual(value.owner, owner)
        XCTAssertTrue(value.violations.isEmpty, "Fail-closed transport violations: \(value.violations)")
        XCTAssertEqual(value.receipts.count, count)
        for (index, receipt) in value.receipts.enumerated() {
            XCTAssertEqual(receipt.owner, owner)
            XCTAssertEqual(receipt.sequence, index)
            XCTAssertEqual(receipt.method, "POST")
            XCTAssertEqual(receipt.host, "reset-code-entry.invalid")
            XCTAssertEqual(receipt.contentType, "application/json")
            XCTAssertNil(receipt.authorization)
            XCTAssertFalse(receipt.stopped, "A stopped request is not a late-response proof")
        }
        print("SYNTHETIC_RECEIPT \(try snapshotJSON())")
        return value.receipts
    }

    private func snapshotJSON() throws -> String {
        guard let json = app.staticTexts["fixture.receipts"].value as? String else { throw Failure.invalidReceipts }
        return json
    }

    private func quiet(_ count: Int) throws {
        // Bounded observation, not an assertion about infinite future behavior.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        _ = try receipts(count)
    }

    private func backFromCode() throws {
        #if os(iOS)
        let back = app.navigationBars.buttons.firstMatch
        try activate(back) // Real NavigationStack back, not a test proxy.
        #else
        try activate(app.buttons["auth.reset.back"])
        #endif
    }

    private func leaveForgot() throws {
        #if os(iOS)
        try activate(app.navigationBars.buttons.firstMatch)
        #else
        try activate(app.buttons["auth.forgot.cancel"])
        #endif
        try require(app.buttons["auth.login.forgotPassword"])
    }

    private func releaseHeld() throws {
        #if os(macOS)
        // The diagnostic window is independent of the document-modal Forgot sheet.
        try activate(app.windows["Synthetic transport"].buttons["fixture.release"])
        #else
        try activate(app.buttons["fixture.release"])
        #endif
    }

    func testColdExistingCodeWithEmptyEmailMakesZeroRequests() throws {
        try launch()
        try openForgot()
        XCTAssertEqual(field("auth.forgot.email").value as? String, "")
        XCTAssertTrue(app.buttons["auth.forgot.existingCode"].isEnabled)
        try activate(app.buttons["auth.forgot.existingCode"])
        try require(field("auth.reset.code"))
        XCTAssertFalse(field("auth.forgot.email").exists)
        try quiet(0)
    }

    func testExplicitSendIsPositiveRequestControl() throws {
        try launch()
        try openForgot()
        try type("auth.forgot.email", "ordinary@example.com")
        try activate(app.buttons["auth.forgot.sendCode"])
        let sent = try receipts(1)
        XCTAssertEqual(sent[0].path, "/auth/forgot-password")
        XCTAssertEqual(sent[0].body, ["email": "ordinary@example.com"])
        XCTAssertEqual(sent[0].status, 200)
        try require(app.staticTexts["auth.forgot.requestAccepted"])
    }

    func testExistingCodeSubmitsExactTokenAndNewPassword() throws {
        try launch()
        try openCode()
        try fillReset()
        try activate(app.buttons["auth.reset.submit"])
        let sent = try receipts(1)
        XCTAssertEqual(sent[0].path, "/auth/reset-password")
        XCTAssertEqual(sent[0].body, ["token": code, "new_password": password])
        try require(app.staticTexts["auth.reset.success"])
    }

    func testMailWhitespaceAndBase64CharactersArePreserved() throws {
        try launch()
        try openCode()
        // Single-line native typing only. Tabs/CR/LF can change focus or submit;
        // this case does NOT fabricate paste or claim their insertion/survival.
        let typed = "  \(code)  "
        try type("auth.reset.code", typed)
        let observed = field("auth.reset.code").value as? String
        XCTAssertEqual(observed, typed, "Record genuine field normalization; do not waive this assertion")
        print("NATIVE_FIELD_OBSERVATION horizontal-spaces/base64=\(observed ?? "<missing>"); CRLF/tab/clipboard NOT QUALIFIED")
        try type("auth.reset.newPassword", " \(password) ")
        try type("auth.reset.confirmPassword", " \(password) ")
        try activate(app.buttons["auth.reset.submit"])
        let sent = try receipts(1)
        XCTAssertEqual(sent[0].body, ["token": code, "new_password": " \(password) "])
        XCTAssertEqual(sent[0].path, "/auth/reset-password")
    }

    func testOriginalRequestThenEnterCodeUsesExistingForm() throws {
        try launch()
        try openForgot()
        try type("auth.forgot.email", "ordinary@example.com")
        try activate(app.buttons["auth.forgot.sendCode"])
        _ = try receipts(1)
        try activate(app.buttons["auth.forgot.enterCode"])
        try fillReset()
        try activate(app.buttons["auth.reset.submit"])
        let sent = try receipts(2)
        XCTAssertEqual(sent.map(\.path), ["/auth/forgot-password", "/auth/reset-password"])
        XCTAssertEqual(sent[1].body, ["token": code, "new_password": password])
    }

    func testSendAgainRequiresExplicitSecondSend() throws {
        try launch()
        try openForgot()
        try type("auth.forgot.email", "ordinary@example.com")
        try activate(app.buttons["auth.forgot.sendCode"])
        _ = try receipts(1)
        try activate(app.buttons["auth.forgot.sendAgain"])
        try require(field("auth.forgot.email"))
        try quiet(1)
        try activate(app.buttons["auth.forgot.sendCode"])
        let sent = try receipts(2)
        XCTAssertEqual(sent.map(\.path), ["/auth/forgot-password", "/auth/forgot-password"])
        XCTAssertEqual(sent[0].body, sent[1].body)
    }

    func testGenericAcceptedResponseDoesNotClaimDelivery() throws {
        try launch()
        try openForgot()
        try type("auth.forgot.email", "unknown@example.com")
        try activate(app.buttons["auth.forgot.sendCode"])
        _ = try receipts(1)
        let text = app.staticTexts["auth.forgot.requestAccepted"]
        try require(text)
        XCTAssertEqual(text.label, "If an account exists for this email, reset instructions will be sent.")
        XCTAssertFalse(app.staticTexts["RESET CODE SENT TO:"].exists)
        try quiet(1)
    }

    func testInvalidCodePreservesFieldsWithoutReplacement() throws {
        try launch("invalid")
        try openCode()
        try fillReset()
        try activate(app.buttons["auth.reset.submit"])
        XCTAssertEqual(try receipts(1)[0].status, 400)
        try require(app.staticTexts["auth.reset.error"])
        XCTAssertEqual(app.staticTexts["auth.reset.error"].label, "INVALID OR EXPIRED CODE.")
        XCTAssertEqual(field("auth.reset.code").value as? String, code)
        XCTAssertFalse((field("auth.reset.newPassword").value as? String ?? "").isEmpty)
        XCTAssertFalse(app.staticTexts["auth.reset.success"].exists)
        try quiet(1)
    }

    func testExpiredCodePreservesFieldsWithoutReplacement() throws {
        try launch("expired")
        try openCode()
        try fillReset()
        try activate(app.buttons["auth.reset.submit"])
        XCTAssertEqual(try receipts(1)[0].status, 400)
        try require(app.staticTexts["auth.reset.error"])
        XCTAssertEqual(app.staticTexts["auth.reset.error"].label, "THIS CODE HAS EXPIRED. PLEASE REQUEST A NEW ONE.")
        XCTAssertEqual(field("auth.reset.code").value as? String, code)
        XCTAssertFalse((field("auth.reset.confirmPassword").value as? String ?? "").isEmpty)
        XCTAssertFalse(app.staticTexts["auth.reset.success"].exists)
        try quiet(1)
    }

    func testUncertainFailureRequiresExplicitRetry() throws {
        for scenario in ["storage", "transport"] {
            try launch(scenario)
            try openCode()
            try fillReset()
            try activate(app.buttons["auth.reset.submit"])
            let failed = try receipts(1)
            if scenario == "storage" { XCTAssertEqual(failed[0].status, 500) }
            else { XCTAssertNil(failed[0].status) }
            try require(app.staticTexts["auth.reset.error"])
            XCTAssertEqual(field("auth.reset.code").value as? String, code)
            XCTAssertFalse(app.staticTexts["auth.reset.success"].exists)
            try quiet(1)
            try activate(app.buttons["auth.reset.submit"])
            let retried = try receipts(2)
            XCTAssertEqual(retried.map(\.path), ["/auth/reset-password", "/auth/reset-password"])
            XCTAssertEqual(retried[1].body, failed[0].body)
            XCTAssertEqual(retried[1].body, ["token": code, "new_password": password])
            try require(app.staticTexts["auth.reset.success"])
        }
    }

    func testShortPasswordBlocksSubmission() throws {
        try launch()
        try openCode()
        try fillReset(password: "short")
        XCTAssertFalse(app.buttons["auth.reset.submit"].isEnabled)
        try quiet(0)
    }

    func testMismatchedPasswordsBlockSubmission() throws {
        try launch()
        try openCode()
        try fillReset(confirmation: "DifferentPassword789")
        XCTAssertFalse(app.buttons["auth.reset.submit"].isEnabled)
        try quiet(0)
    }

    func testBackCancelAndReentryMakeNoRequests() throws {
        try launch()
        try openCode()
        try type("auth.reset.code", code)
        try backFromCode()
        try require(field("auth.forgot.email"))
        try leaveForgot()
        try openForgot()
        try require(field("auth.forgot.email"))
        XCTAssertEqual(field("auth.forgot.email").value as? String, "")
        try activate(app.buttons["auth.forgot.existingCode"])
        XCTAssertEqual(field("auth.reset.code").value as? String, "")
        try quiet(0)
    }

    func testSuccessReturnsToActualSignInRoute() throws {
        try launch()
        try openCode()
        try fillReset()
        try activate(app.buttons["auth.reset.submit"])
        _ = try receipts(1)
        try require(app.staticTexts["auth.reset.success"])
        try activate(app.buttons["auth.reset.backToSignIn"])
        try require(app.buttons["auth.login.forgotPassword"])
        XCTAssertFalse(field("auth.forgot.email").exists)
        XCTAssertFalse(field("auth.reset.code").exists)
        try quiet(1)
    }

    func testPendingForgotBlocksColdEntryAndLateCompletionCannotReopen() throws {
        try launch("holdForgot")
        try openForgot()
        try type("auth.forgot.email", "ordinary@example.com")
        try activate(app.buttons["auth.forgot.sendCode"])
        let sent = try receipts(1, settled: false)
        XCTAssertEqual(sent[0].body, ["email": "ordinary@example.com"])
        XCTAssertEqual(try snapshot().held, 1)
        XCTAssertFalse(app.buttons["auth.forgot.existingCode"].isEnabled)
        XCTAssertFalse(app.buttons["auth.forgot.sendCode"].isEnabled)
        try type("auth.forgot.email", ".changed") // Pending submission retains its original snapshot.
        try leaveForgot()
        try openForgot()
        XCTAssertEqual(field("auth.forgot.email").value as? String, "")
        try releaseHeld()
        _ = try receipts(1)
        try quiet(1)
        XCTAssertFalse(app.staticTexts["auth.forgot.requestAccepted"].exists)
        XCTAssertFalse(app.staticTexts["auth.forgot.error"].exists)
        XCTAssertTrue(app.buttons["auth.forgot.existingCode"].isEnabled)
    }

    func testLateResetCompletionCannotAffectReenteredFlow() throws {
        try launch("holdReset")
        try openCode()
        try fillReset()
        try activate(app.buttons["auth.reset.submit"])
        let sent = try receipts(1, settled: false)
        XCTAssertEqual(sent[0].body, ["token": code, "new_password": password])
        XCTAssertEqual(try snapshot().held, 1)
        XCTAssertFalse(app.buttons["auth.reset.submit"].isEnabled)
        try backFromCode()
        try activate(app.buttons["auth.forgot.existingCode"])
        try require(field("auth.reset.code"))
        try releaseHeld()
        _ = try receipts(1)
        try quiet(1)
        XCTAssertTrue(field("auth.reset.code").exists)
        XCTAssertFalse(app.staticTexts["auth.reset.success"].exists)
        XCTAssertFalse(app.staticTexts["auth.reset.error"].exists)
    }
}
#endif
