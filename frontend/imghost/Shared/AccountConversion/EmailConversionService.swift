import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Staged transport contract shared by iOS/macOS. Not exposed in Settings until QA passes.
/// Never registers, merges accounts, deletes local history or unlinks Apple.
struct EmailConversionService {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)

    struct Challenge: Decodable, Equatable {
        let challengeID: String
        /// Pass verbatim to ASAuthorizationAppleIDRequest.nonce; request a NEW authorization.
        let nonce: String
        let expiresAt: Double
        enum CodingKeys: String, CodingKey {
            case challengeID = "challenge_id", nonce, expiresAt = "expires_at"
        }
    }

    struct Completion: Decodable, Equatable {
        let userID: String
        let email: String
        let emailVerified: Bool
        let appleAccessRetained: Bool
        let notificationPending: Bool
        enum CodingKeys: String, CodingKey {
            case userID = "user_id", email, emailVerified = "email_verified"
            case appleAccessRetained = "apple_access_retained", notificationPending = "notification_pending"
        }
    }

    enum Failure: Error, Equatable {
        case reauthenticate, destinationUnavailable, tooManyRequests, unavailable, invalidInput
        /// The server may already have committed. Try new email login or Apple; don't register.
        case uncertainCompletion
        case wrongAccount
    }

    private let baseURL: URL
    private let transport: Transport

    init(baseURL: URL, transport: @escaping Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unavailable }
        return (data, http)
    }) {
        self.baseURL = baseURL
        self.transport = transport
    }

    func challenge(accessToken: String) async throws -> Challenge {
        let data = try await send("challenge", token: accessToken, body: Data("{}".utf8))
        return try JSONDecoder().decode(Challenge.self, from: data)
    }

    func start(challenge: Challenge, identityToken: String, destinationEmail: String, accessToken: String) async throws {
        struct Body: Encodable {
            let challenge_id: String
            let identity_token: String
            let destination_email: String
        }
        _ = try await send("start", token: accessToken, body: JSONEncoder().encode(Body(
            challenge_id: challenge.challengeID, identity_token: identityToken,
            destination_email: destinationEmail.trimmingCharacters(in: .whitespacesAndNewlines))))
    }

    func complete(challenge: Challenge, code: String, password: String, passwordConfirmation: String,
                  sourceUserID: String, accessToken: String) async throws -> Completion {
        guard password == passwordConfirmation, (8...1024).contains(password.utf16.count),
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidInput }
        struct Body: Encodable {
            let challenge_id: String
            let code: String
            let new_password: String
        }
        let body = try JSONEncoder().encode(Body(challenge_id: challenge.challengeID,
            code: code.trimmingCharacters(in: .whitespacesAndNewlines), new_password: password))
        let data = try await send("complete", token: accessToken, body: body)
        guard let result = try? JSONDecoder().decode(Completion.self, from: data),
              result.emailVerified, result.appleAccessRetained else { throw Failure.uncertainCompletion }
        guard result.userID == sourceUserID else { throw Failure.wrongAccount }
        // Caller must prove ordinary login on both supported clients before considering any future unlink UI.
        // Current backend intentionally offers no Apple unlink endpoint. Keep local account/history intact.
        return result
    }

    private func send(_ step: String, token: String, body: Data) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/email-conversion/\(step)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = body
        let pair: (Data, HTTPURLResponse)
        do { pair = try await transport(request) }
        catch { throw step == "complete" ? Failure.uncertainCompletion : Failure.unavailable }
        switch pair.1.statusCode {
        case 200: return pair.0
        case 400: throw Failure.invalidInput
        case 401: throw Failure.reauthenticate
        case 409: throw Failure.destinationUnavailable
        case 429: throw Failure.tooManyRequests
        default: throw step == "complete" ? Failure.uncertainCompletion : Failure.unavailable
        }
    }
}
