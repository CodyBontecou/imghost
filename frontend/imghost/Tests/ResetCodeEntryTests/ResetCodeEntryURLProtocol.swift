#if RESET_CODE_ENTRY_TEST_HOST
import Foundation

// Test-host-only transport. The injected reset session intercepts every request,
// including unexpected hosts/routes. This protocol never forwards to networking.
final class ResetCodeEntryURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { ResetCodeEntryFixture.shared.start(self) }
    override func stopLoading() { ResetCodeEntryFixture.shared.stop(self) }
}

final class ResetCodeEntryFixture {
    struct Receipt: Codable {
        let sequence: Int
        let owner: String
        let method: String
        let host: String
        let path: String
        let contentType: String?
        let authorization: String?
        let body: [String: String]?
        var status: Int?
        var settled = false
        var stopped = false
    }

    struct Snapshot: Codable {
        let owner: String
        let scenario: String
        let receipts: [Receipt]
        let held: Int
        let violations: [String]
    }

    static let shared = ResetCodeEntryFixture()
    private let queue = DispatchQueue(label: "ResetCodeEntryFixture.owner")
    private let owner: String
    private let scenario: String
    private var receipts: [Receipt] = []
    private var held: [ObjectIdentifier: (ResetCodeEntryURLProtocol, Int)] = [:]
    private var violations: [String] = []

    private init() {
        let environment = ProcessInfo.processInfo.environment
        guard let owner = environment["RESET_CASE_ID"], UUID(uuidString: owner) != nil,
              let scenario = environment["RESET_SCENARIO"],
              ["normal", "invalid", "expired", "storage", "transport", "holdForgot", "holdReset"].contains(scenario),
              Config.backendURL == "https://reset-code-entry.invalid" else {
            fatalError("Isolated reset host requires a synthetic URL and a unique case owner")
        }
        self.owner = owner
        self.scenario = scenario
    }

    var snapshotJSON: String {
        queue.sync {
            let snapshot = Snapshot(owner: owner, scenario: scenario, receipts: receipts,
                                    held: held.count, violations: violations)
            guard let data = try? JSONEncoder().encode(snapshot), data.count <= 16_384,
                  let json = String(data: data, encoding: .utf8) else {
                fatalError("Synthetic receipt budget exceeded")
            }
            return json
        }
    }

    func start(_ transport: ResetCodeEntryURLProtocol) {
        queue.async {
            let request = transport.request
            let sequence = self.receipts.count
            let body = self.readBody(request)
            let decoded = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            let path = request.url?.path ?? ""
            let host = request.url?.host ?? ""
            guard sequence < 16 else {
                self.reject(transport, reason: "More than 16 synthetic requests")
                return
            }
            self.receipts.append(Receipt(sequence: sequence, owner: self.owner,
                                         method: request.httpMethod ?? "", host: host, path: path,
                                         contentType: request.value(forHTTPHeaderField: "Content-Type"),
                                         authorization: request.value(forHTTPHeaderField: "Authorization"), body: decoded))
            let expectedKeys: Set<String> = path == "/auth/forgot-password" ? ["email"] : ["token", "new_password"]
            guard request.url?.scheme == "https", host == "reset-code-entry.invalid",
                  request.httpMethod == "POST", ["/auth/forgot-password", "/auth/reset-password"].contains(path),
                  request.value(forHTTPHeaderField: "Content-Type") == "application/json",
                  request.value(forHTTPHeaderField: "Authorization") == nil,
                  let decoded, Set(decoded.keys) == expectedKeys else {
                self.receipts[sequence].settled = true
                self.reject(transport, reason: "Unexpected synthetic request \(sequence): \(host)\(path)")
                return
            }
            if (self.scenario == "holdForgot" && path == "/auth/forgot-password") ||
               (self.scenario == "holdReset" && path == "/auth/reset-password") {
                self.held[ObjectIdentifier(transport)] = (transport, sequence)
                return
            }
            self.complete(transport, sequence: sequence)
        }
    }

    func stop(_ transport: ResetCodeEntryURLProtocol) {
        queue.async {
            let key = ObjectIdentifier(transport)
            if let (_, sequence) = self.held.removeValue(forKey: key) {
                self.receipts[sequence].stopped = true
                self.receipts[sequence].settled = true
            }
        }
    }

    // Diagnostic control releases only transport barriers, never view state/actions.
    func releaseHeld() {
        queue.async {
            let pending = self.held.values.sorted { $0.1 < $1.1 }
            self.held.removeAll()
            for (transport, sequence) in pending { self.complete(transport, sequence: sequence) }
        }
    }

    private func readBody(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data.count <= 4096 ? data : nil }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > 4096 { return nil }
        }
        return data
    }

    private func reject(_ transport: ResetCodeEntryURLProtocol, reason: String) {
        if violations.count < 8 { violations.append(reason) }
        transport.client?.urlProtocol(transport, didFailWithError: URLError(.unsupportedURL))
    }

    private func complete(_ transport: ResetCodeEntryURLProtocol, sequence: Int) {
        let path = receipts[sequence].path
        if path == "/auth/reset-password", scenario == "transport", sequence == 0 {
            receipts[sequence].settled = true
            transport.client?.urlProtocol(transport, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let status: Int
        let payload: [String: String]
        if path == "/auth/forgot-password" {
            status = 200
            payload = ["message": "If an account exists with this email, you will receive password reset instructions."]
        } else if scenario == "invalid" {
            status = 400
            payload = ["error": "Invalid reset token"]
        } else if scenario == "expired" {
            status = 400
            payload = ["error": "Reset token expired"]
        } else if scenario == "storage", sequence == 0 {
            status = 500
            payload = ["error": "Failed to reset password. Please try again."]
        } else {
            status = 200
            payload = ["message": "Password successfully reset. Please log in with your new password."]
        }
        guard let url = transport.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            fatalError("Synthetic response construction failed")
        }
        receipts[sequence].status = status
        transport.client?.urlProtocol(transport, didReceive: response, cacheStoragePolicy: .notAllowed)
        transport.client?.urlProtocol(transport, didLoad: data)
        transport.client?.urlProtocolDidFinishLoading(transport)
        receipts[sequence].settled = true
    }
}
#endif
