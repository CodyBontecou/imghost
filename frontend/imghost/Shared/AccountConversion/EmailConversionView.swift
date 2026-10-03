import SwiftUI
import AuthenticationServices

enum EmailConversionAppleProof {
    static func configure(_ request: ASAuthorizationAppleIDRequest, challenge: EmailConversionService.Challenge) {
        request.nonce = challenge.nonce
        request.requestedScopes = []
    }
}

@available(macOS 14.0, *)
struct EmailConversionView: View {
    @StateObject private var flow: EmailConversionCoordinator
    @Environment(\.dismiss) private var dismiss

    init(flow: EmailConversionCoordinator) { _flow = StateObject(wrappedValue: flow) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add email/password login").font(.title2).bold()
            Text("For an Apple-linked account, verify a new email and choose a password without moving your library or subscription. Apple sign-in stays available. This rollout may not be available yet.")
                .font(.callout)
            if flow.stage != .done {
                TextField("New login email", text: $flow.destination)
                    .textContentType(.emailAddress)
                    .disabled(flow.stage != .idle || flow.busy)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                #endif
                if flow.stage == .idle {
                    Button("Check availability and continue") { Task { await flow.begin() } }
                        .disabled(flow.busy)
                }
                if flow.stage == .apple, let challenge = flow.challenge {
                    Text("Authorize with Apple again to prove ownership of this account.")
                    SignInWithAppleButton(.continue) { request in
                        // Native AuthenticationServices echoes this nonce in the identity token.
                        // The staged server compares it verbatim, NOT SHA256(nonce).
                        EmailConversionAppleProof.configure(request, challenge: challenge)
                    } onCompletion: { result in
                        switch result {
                        case .success(let authorization):
                            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                                  let data = credential.identityToken,
                                  let token = String(data: data, encoding: .utf8) else {
                                flow.appleAuthorizationFailed(cancelled: false)
                                return
                            }
                            Task { await flow.authorize(identityToken: token) }
                        case .failure(let error):
                            flow.appleAuthorizationFailed(cancelled: (error as? ASAuthorizationError)?.code == .canceled)
                        }
                    }
                    .frame(height: 44)
                    .disabled(flow.busy)
                }
                if flow.stage == .email || flow.stage == .recovery {
                    if flow.stage == .email {
                        Text("Enter the code from your new email. It expires in 10 minutes. To resend, restart with a new Apple authorization.")
                        TextField("Email verification code", text: $flow.code)
                            .textContentType(.oneTimeCode)
                            .autocorrectionDisabled()
                            .disabled(flow.busy)
                    }
                    SecureField("New password (8–1024 characters)", text: $flow.password)
                        .textContentType(.newPassword)
                        .disabled(flow.busy)
                    SecureField("Confirm new password", text: $flow.confirmation)
                        .textContentType(.newPassword)
                        .disabled(flow.busy)
                    if flow.stage == .email {
                        Button("Verify email and save login") { Task { await flow.complete() } }
                            .disabled(flow.busy)
                    } else {
                        Button("Check new email login and recover") { Task { await flow.recover() } }
                            .disabled(flow.busy)
                    }
                }
                if flow.stage == .apple || flow.stage == .email {
                    Button("Restart with a new code") { flow.cancel() }
                        .disabled(flow.busy)
                }
            }
            if flow.busy { ProgressView("Working…") }
            if let message = flow.message {
                Text(verbatim: message).font(.callout).accessibilityIdentifier("conversion.message")
            }
            if flow.stage != .done {
                Text("Closing keeps your local credentials. If completion was sent, the server may already have changed the email. Apple access remains; never create a replacement account.")
                    .font(.caption)
            }
            Button(flow.stage == .done ? "Done" : "Close") { flow.cancel(); dismiss() }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(maxWidth: 520)
        .onDisappear { flow.cancel() }
        .interactiveDismissDisabled(flow.busy)
    }
}
