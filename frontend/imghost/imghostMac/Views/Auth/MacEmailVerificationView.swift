import SwiftUI

struct MacEmailVerificationView: View {
    @EnvironmentObject var authState: AuthState

    @State private var verificationCode = ""
    @State private var isLoading = false
    @State private var isResending = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        ZStack {
            Color.brutalBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 24) {
                    // Hero
                    VStack(spacing: 8) {
                        Text("VERIFY\nEMAIL")
                            .font(.system(size: 48, weight: .black))
                            .foregroundStyle(Color.white)
                            .multilineTextAlignment(.center)

                        HStack {
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: 24, height: 1)
                            Text("CHECK YOUR INBOX")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.brutalTextSecondary)
                                .tracking(2)
                        }
                    }

                    // Email info
                    if let email = authState.currentUser?.email {
                        VStack(spacing: 8) {
                            Text("CODE SENT TO:")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.brutalTextSecondary)
                                .tracking(2)
                            Text(email)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.white)
                        }
                        .padding(16)
                        .background(Color.brutalSurface)
                        .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                    }

                    // Info
                    HStack(spacing: 12) {
                        Text("!")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.brutalWarning)
                        Text("Verify your email before uploading images.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.brutalTextSecondary)
                    }
                    .padding(12)
                    .background(Color.brutalSurface)
                    .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))

                    // Code field
                    MacBrutalTextField(label: "Verification Code", text: $verificationCode)
                        .frame(maxWidth: 300)

                    // Messages
                    if let errorMessage = errorMessage {
                        Text(errorMessage.uppercased())
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.brutalError)
                            .tracking(1)
                    }

                    if let successMessage = successMessage {
                        Text(successMessage.uppercased())
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.brutalSuccess)
                            .tracking(1)
                    }

                    // Verify button
                    Button(action: verifyEmail) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                    .scaleEffect(0.7)
                            } else {
                                Text("VERIFY EMAIL")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .tracking(1)
                            }
                        }
                        .foregroundStyle(Color.black)
                        .frame(width: 200, height: 44)
                        .background(verificationCode.isEmpty ? Color.brutalTextTertiary : Color.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(verificationCode.isEmpty || isLoading)

                    // Resend / Sign out
                    HStack(spacing: 16) {
                        Button(action: resendCode) {
                            HStack(spacing: 4) {
                                if isResending {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                }
                                Text("RESEND CODE")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.brutalTextSecondary)
                                    .tracking(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isResending)

                        Button(action: { authState.logout() }) {
                            Text("SIGN OUT")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.brutalError)
                                .tracking(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 400)

                Spacer()
            }
        }
    }

    private func verifyEmail() {
        guard !verificationCode.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        successMessage = nil

        Task {
            do {
                try await AuthService.shared.verifyEmail(token: verificationCode.trimmingCharacters(in: .whitespaces))
                await MainActor.run { authState.setEmailVerified(true) }
            } catch let error as AuthError {
                await MainActor.run { errorMessage = error.errorDescription }
            } catch {
                await MainActor.run { errorMessage = "An unexpected error occurred." }
            }
            await MainActor.run { isLoading = false }
        }
    }

    private func resendCode() {
        guard let email = authState.currentUser?.email else { return }
        isResending = true
        errorMessage = nil
        successMessage = nil

        Task {
            do {
                try await AuthService.shared.resendVerification(email: email)
                await MainActor.run { successMessage = "Verification code sent!" }
            } catch let error as AuthError {
                await MainActor.run { errorMessage = error.errorDescription }
            } catch {
                await MainActor.run { errorMessage = "An unexpected error occurred." }
            }
            await MainActor.run { isResending = false }
        }
    }
}
