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

    private var diagnosticCase = ""
    private var diagnosticScenario = ""
    private var diagnosticEpoch = 0.0
    private var diagnosticSlots: Set<Int> = []
    private var lastSnapshotObservation: [String: Any] = ["status": "UNVERIFIED_not_read"]
    private var snapshotObservedAt = 0.0

    private let diagnosticCases: Set<String> = [
        "testColdExistingCodeWithEmptyEmailMakesZeroRequests()",
        "testExplicitSendIsPositiveRequestControl()",
        "testExistingCodeSubmitsExactTokenAndNewPassword()",
        "testMailWhitespaceAndBase64CharactersArePreserved()",
        "testOriginalRequestThenEnterCodeUsesExistingForm()",
        "testSendAgainRequiresExplicitSecondSend()",
        "testGenericAcceptedResponseDoesNotClaimDelivery()",
        "testInvalidCodePreservesFieldsWithoutReplacement()",
        "testExpiredCodePreservesFieldsWithoutReplacement()",
        "testUncertainFailureRequiresExplicitRetry()",
        "testShortPasswordBlocksSubmission()",
        "testMismatchedPasswordsBlockSubmission()",
        "testBackCancelAndReentryMakeNoRequests()",
        "testSuccessReturnsToActualSignInRoute()",
        "testPendingForgotBlocksColdEntryAndLateCompletionCannotReopen()",
        "testLateResetCompletionCannotAffectReenteredFlow()"
    ]
    private let diagnosticScenarios: Set<String> = [
        "normal", "invalid", "expired", "storage", "transport", "holdForgot", "holdReset"
    ]
    private let diagnosticQueryTypes = [
        "auth.login.forgotPassword": "Button",
        "auth.forgot.sendCode": "Button",
        "auth.forgot.email": "TextField",
        "auth.reset.code": "TextField",
        "auth.reset.newPassword": "SecureTextField",
        "auth.reset.confirmPassword": "SecureTextField",
        "auth.reset.submit": "Button",
        "auth.reset.error": "StaticText"
    ]

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
        diagnosticEpoch = ProcessInfo.processInfo.systemUptime
        diagnosticSlots.removeAll()
    }

    override func tearDownWithError() throws {
        app?.terminate() // New process and UUID per launch; no cross-case fixture reuse.
        app = nil
    }

    private func launch(_ scenario: String = "normal", caseFunction: StaticString = #function) throws {
        app?.terminate()
        owner = UUID().uuidString
        diagnosticCase = String(describing: caseFunction)
        diagnosticScenario = scenario
        lastSnapshotObservation = ["status": "UNVERIFIED_not_read"]
        snapshotObservedAt = 0
        app = XCUIApplication()
        app.launchEnvironment = ["RESET_CASE_ID": owner, "RESET_SCENARIO": scenario,
                                 "APP_ANALYTICS_ENABLED": "0"]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        try require(app.buttons["auth.login.forgotPassword"])
        try wait { (try? self.snapshot().owner) == self.owner }
        XCTAssertEqual(try snapshot().receipts.count, 0)
    }

    private func require(_ element: XCUIElement, knownID: String? = nil) throws {
        guard element.waitForExistence(timeout: 5) else {
            observe(2, "required_control_unavailable") { _, fields in
                if let knownID, let kind = self.diagnosticQueryTypes[knownID] {
                    fields["query"] = knownID
                    fields["query_type"] = kind
                } else {
                    fields["query"] = "UNVERIFIED_query"
                    fields["query_type"] = "UNVERIFIED_query"
                }
                fields["original_wait_succeeded"] = false
            }
            XCTFail("Missing actual native element: \(element)")
            throw Failure.missingElement
        }
    }

    private func activate(_ element: XCUIElement, knownID: String? = nil) throws {
        try require(element, knownID: knownID)
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
        let hittable = element.isHittable
        XCTAssertTrue(hittable, "Actual control must be hittable")
        if let knownID {
            observeBeforeAction(element, knownID: knownID, hittable: hittable)
        }
        #if os(iOS)
        element.tap()
        #else
        element.click()
        #endif
    }

    private func field(_ identifier: String) -> XCUIElement {
        switch identifier {
        case "auth.forgot.email", "auth.reset.code":
            return app.textFields[identifier]
        case "auth.reset.newPassword", "auth.reset.confirmPassword":
            return app.secureTextFields[identifier]
        default:
            preconditionFailure("Unexpected reset-test field identifier")
        }
    }

    private func type(_ identifier: String, _ text: String) throws {
        let element = field(identifier)
        try activate(element, knownID: identifier)
        element.typeText(text)
    }

    private func openForgot() throws {
        try activate(app.buttons["auth.login.forgotPassword"], knownID: "auth.login.forgotPassword")
    }
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
        snapshotObservedAt = ProcessInfo.processInfo.systemUptime
        lastSnapshotObservation = ["status": "UNVERIFIED_snapshot_query_started"]
        guard diagnostic.exists else {
            lastSnapshotObservation = ["status": "UNVERIFIED_missing_snapshot_node"]
            throw Failure.invalidReceipts
        }
        lastSnapshotObservation = ["status": "UNVERIFIED_snapshot_value_query_started"]
        guard let json = diagnostic.value as? String else {
            lastSnapshotObservation = ["status": "UNVERIFIED_nonstring_snapshot_value"]
            throw Failure.invalidReceipts
        }
        guard let data = json.data(using: .utf8), data.count <= 16_384 else {
            lastSnapshotObservation = ["status": "UNVERIFIED_snapshot_encoding_or_size"]
            throw Failure.invalidReceipts
        }
        do {
            let value = try JSONDecoder().decode(Snapshot.self, from: data)
            snapshotObservedAt = ProcessInfo.processInfo.systemUptime
            if value.receipts.count <= 16, (0...16).contains(value.held),
               value.violations.count <= 8 {
                lastSnapshotObservation = [
                    "status": "observed_NOT_acceptance",
                    "snapshot_owner_matches": value.owner == owner,
                    "snapshot_scenario_matches": value.scenario == diagnosticScenario,
                    "receipt_count": value.receipts.count,
                    "held_count": value.held,
                    "settled_count": value.receipts.filter(\.settled).count,
                    "stopped_count": value.receipts.filter(\.stopped).count,
                    "foreign_receipt_owner_count": value.receipts.filter { $0.owner != owner }.count,
                    "violation_count": value.violations.count
                ]
            } else {
                lastSnapshotObservation = ["status": "UNVERIFIED_snapshot_count_bounds"]
            }
            return value
        } catch {
            lastSnapshotObservation = ["status": "UNVERIFIED_undecodable_snapshot"]
            throw error
        }
    }

    private func wait(onFailure: (() -> Void)? = nil, _ condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: 5) == .completed else {
            onFailure?()
            XCTFail("Bounded native observation timed out")
            throw Failure.timeout
        }
    }

    private func receipts(_ count: Int, settled: Bool = true) throws -> [Receipt] {
        try wait(onFailure: {
            self.observe(2, "receipt_predicate_failed") { _, fields in
                fields.merge(self.lastSnapshotObservation) { _, latest in latest }
                fields["sample"] = "last_predicate_snapshot_NOT_current"
                fields["expected_receipt_count"] = count
                fields["settlement_required"] = settled
                fields["sample_age_ms"] = self.snapshotObservedAt == 0 ? -1 :
                    min(Int((ProcessInfo.processInfo.systemUptime - self.snapshotObservedAt) * 1000),
                        2_147_483_647)
            }
        }) {
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

    // Observations never supply an acceptance result or change an action.
    // Public AX reads may block/abort in XCTest: limits below are cooperative.
    private func observe(_ slot: Int, _ phase: String,
                         _ collect: (Double, inout [String: Any]) -> Void) {
        guard diagnosticSlots.insert(slot).inserted else { return }
        var fields: [String: Any] = [
            "slot": slot, "phase": phase, "status": "observed_NOT_acceptance"
        ]
        let begun = ProcessInfo.processInfo.systemUptime
        let deadline = min(begun + 2, diagnosticEpoch + 120)
        if diagnosticCases.contains(diagnosticCase),
           diagnosticScenarios.contains(diagnosticScenario),
           let uuid = UUID(uuidString: owner) {
            fields["case"] = diagnosticCase
            fields["owner"] = uuid.uuidString
            fields["scenario"] = diagnosticScenario
            if begun < deadline {
                collect(deadline, &fields)
            } else {
                fields["status"] = "UNVERIFIED_cooperative_budget"
            }
        } else {
            fields["status"] = "UNVERIFIED_observation_scope"
        }
        let ended = ProcessInfo.processInfo.systemUptime
        fields["elapsed_ms_pre_output"] =
            min(Int((ended - begun) * 1000), 2_147_483_647)
        if ended >= deadline {
            fields["status"] = "UNVERIFIED_cooperative_budget"
        }
        let prefix = "RESET_NATIVE_OBSERVATION "
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
           data.count + prefix.utf8.count + 1 <= 1024,
           let json = String(data: data, encoding: .utf8) {
            print(prefix + json)
        } else {
            print(prefix + #"{"status":"UNVERIFIED_observation_output_budget"}"#)
        }
    }

    private func observeBeforeAction(_ element: XCUIElement, knownID: String, hittable: Bool) {
        let earlyNavigationCases: Set<String> = [
            "testColdExistingCodeWithEmptyEmailMakesZeroRequests()",
            "testGenericAcceptedResponseDoesNotClaimDelivery()",
            "testBackCancelAndReentryMakeNoRequests()"
        ]
        let selected = knownID == "auth.reset.submit" ||
            (knownID == "auth.forgot.sendCode" &&
             diagnosticCase == "testPendingForgotBlocksColdEntryAndLateCompletionCannotReopen()") ||
            (knownID == "auth.login.forgotPassword" && earlyNavigationCases.contains(diagnosticCase))
        guard selected else { return }
        observe(1, "before_original_action") { deadline, fields in
            fields["query"] = knownID
            fields["query_type"] = "Button"
            fields["original_hittable_result"] = hittable
            guard ProcessInfo.processInfo.systemUptime < deadline else { return }
            let present = element.exists
            fields["button_query_match"] = present
            guard present, ProcessInfo.processInfo.systemUptime < deadline else {
                fields["status"] = "UNVERIFIED_control_or_budget"
                return
            }
            fields["enabled"] = element.isEnabled
            guard knownID == "auth.reset.submit" else { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return }
            let codeField = self.app.textFields["auth.reset.code"]
            let codePresent = codeField.exists
            fields["code_query_match"] = codePresent
            guard codePresent, ProcessInfo.processInfo.systemUptime < deadline else {
                fields["status"] = "UNVERIFIED_code_or_budget"
                return
            }
            let observed = codeField.value as? String
            let expected = self.diagnosticCase == "testMailWhitespaceAndBase64CharactersArePreserved()" ?
                "  \(self.code)  " : self.code
            fields["code_is_string"] = observed != nil
            fields["code_matches_existing_input"] = observed == expected
            if observed == nil { fields["status"] = "UNVERIFIED_code_value_type" }
        }
    }

    private func observeError(_ element: XCUIElement, label: String, expected: String) {
        guard label != expected else { return }
        observe(2, "exact_error_label_mismatch") { deadline, fields in
            fields["query"] = "auth.reset.error"
            fields["query_type"] = "StaticText"
            fields["label_matches_expected"] = label == expected
            guard ProcessInfo.processInfo.systemUptime < deadline else { return }
            let value = element.value as? String
            fields["value_is_string"] = value != nil
            fields["value_matches_expected"] = value == expected
            if value == nil { fields["status"] = "UNVERIFIED_error_value_type" }
        }
    }

    private func observePending(_ element: XCUIElement, knownID: String) {
        observe(2, "before_original_pending_assertion") { deadline, fields in
            fields["query"] = knownID
            fields["query_type"] = "Button"
            guard ProcessInfo.processInfo.systemUptime < deadline else { return }
            fields["button_query_match"] = element.exists
            fields["limitation"] = "Presence observation is NOT disabled or late-response proof"
        }
    }

    private func observeCodeMismatch(_ observed: String?, expected: String) {
        guard observed != expected else { return }
        observe(2, "exact_typed_code_mismatch") { _, fields in
            fields["query"] = "auth.reset.code"
            fields["query_type"] = "TextField"
            fields["code_is_string"] = observed != nil
            fields["matches_existing_input"] = observed == expected
            fields["observed_utf8_count_capped"] = min(observed?.utf8.count ?? 0, 97)
            fields["matches_previously_observed_period_variant"] = observed == "  \(self.code). "
            fields["limitation"] = "Input transformation mechanism NOT established"
        }
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
        try require(field("auth.forgot.email"), knownID: "auth.forgot.email")
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
        try activate(app.buttons["auth.reset.submit"], knownID: "auth.reset.submit")
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
        observeCodeMismatch(observed, expected: typed)
        XCTAssertEqual(observed, typed, "Record genuine field normalization; do not waive this assertion")
        print("NATIVE_FIELD_OBSERVATION horizontal-spaces/base64=\(observed ?? "<missing>"); CRLF/tab/clipboard NOT QUALIFIED")
        try type("auth.reset.newPassword", " \(password) ")
        try type("auth.reset.confirmPassword", " \(password) ")
        try activate(app.buttons["auth.reset.submit"], knownID: "auth.reset.submit")
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
        try activate(app.buttons["auth.reset.submit"], knownID: "auth.reset.submit")
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
        try activate(app.buttons["auth.reset.submit"], knownID: "auth.reset.submit")
        XCTAssertEqual(try receipts(1)[0].status, 400)
        try require(app.staticTexts["auth.reset.error"])
        let errorElement = app.staticTexts["auth.reset.error"]
        let actualLabel = errorElement.label
        observeError(errorElement, label: actualLabel, expected: "INVALID OR EXPIRED CODE.")
        XCTAssertEqual(actualLabel, "INVALID OR EXPIRED CODE.")
        XCTAssertEqual(field("auth.reset.code").value as? String, code)
        XCTAssertFalse((field("auth.reset.newPassword").value as? String ?? "").isEmpty)
        XCTAssertFalse(app.staticTexts["auth.reset.success"].exists)
        try quiet(1)
    }

    func testExpiredCodePreservesFieldsWithoutReplacement() throws {
        try launch("expired")
        try openCode()
        try fillReset()
        try activate(app.buttons["auth.reset.submit"], knownID: "auth.reset.submit")
        XCTAssertEqual(try receipts(1)[0].status, 400)
        try require(app.staticTexts["auth.reset.error"])
        let errorElement = app.staticTexts["auth.reset.error"]
        let actualLabel = errorElement.label
        observeError(errorElement, label: actualLabel, expected: "THIS CODE HAS EXPIRED. PLEASE REQUEST A NEW ONE.")
        XCTAssertEqual(actualLabel, "THIS CODE HAS EXPIRED. PLEASE REQUEST A NEW ONE.")
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
            try activate(app.buttons["auth.reset.submit"], knownID: "auth.reset.submit")
            let failed = try receipts(1)
            if scenario == "storage" { XCTAssertEqual(failed[0].status, 500) }
            else { XCTAssertNil(failed[0].status) }
            try require(app.staticTexts["auth.reset.error"])
            XCTAssertEqual(field("auth.reset.code").value as? String, code)
            XCTAssertFalse(app.staticTexts["auth.reset.success"].exists)
            try quiet(1)
            try activate(app.buttons["auth.reset.submit"], knownID: "auth.reset.submit")
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
        try activate(app.buttons["auth.reset.submit"], knownID: "auth.reset.submit")
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
        try activate(app.buttons["auth.forgot.sendCode"], knownID: "auth.forgot.sendCode")
        let sent = try receipts(1, settled: false)
        XCTAssertEqual(sent[0].body, ["email": "ordinary@example.com"])
        XCTAssertEqual(try snapshot().held, 1)
        XCTAssertFalse(app.buttons["auth.forgot.existingCode"].isEnabled)
        observePending(app.buttons["auth.forgot.sendCode"], knownID: "auth.forgot.sendCode")
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
        try activate(app.buttons["auth.reset.submit"], knownID: "auth.reset.submit")
        let sent = try receipts(1, settled: false)
        XCTAssertEqual(sent[0].body, ["token": code, "new_password": password])
        XCTAssertEqual(try snapshot().held, 1)
        observePending(app.buttons["auth.reset.submit"], knownID: "auth.reset.submit")
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
