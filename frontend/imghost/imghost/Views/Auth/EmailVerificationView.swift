import SwiftUI

struct EmailVerificationView: View {
    @EnvironmentObject var authState: AuthState

    @State private var verificationCode = ""
    @State private var isLoading = false
    @State private var isResending = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        ZStack {
            Color.brutalBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // Hero text
                    VStack(alignment: .leading, spacing: 8) {
                        Text("auth.verify_email.title")
                            .font(.system(size: 56, weight: .black))
                            .foregroundStyle(.white)
                            .lineSpacing(-8)

                        HStack {
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: 24, height: 1)

                            Text("auth.verify_email.subtitle")
                                .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                                .tracking(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 48)
                    .padding(.bottom, 32)

                    // Email info
                    if let email = authState.currentUser?.email {
                        BrutalCard(backgroundColor: .brutalSurface) {
                            VStack(spacing: 12) {
                                Text("auth.verify_email.code_sent_to")
                                    .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                                    .tracking(2)

                                Text(verbatim: email)
                                    .brutalTypography(.bodyLarge)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }

                    // Info box
                    HStack(spacing: 12) {
                        Text("auth.verify_email.warning_icon")
                            .brutalTypography(.mono, color: .brutalWarning)

                        Text("auth.verify_email.warning_message")
                            .brutalTypography(.bodySmall, color: .brutalTextSecondary)
                    }
                    .padding(16)
                    .background(Color.brutalSurface)
                    .overlay(
                        Rectangle()
                            .stroke(Color.brutalBorder, lineWidth: 1)
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)

                    // Form
                    BrutalTextField(
                        label: String(localized: "auth.verify_email.field.code"),
                        text: $verificationCode,
                        autocapitalization: .never
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)

                    // Messages
                    if let errorMessage = errorMessage {
                        Text(errorMessage.uppercased())
                            .brutalTypography(.monoSmall, color: .brutalError)
                            .tracking(1)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 16)
                    }

                    if let successMessage = successMessage {
                        Text(successMessage.uppercased())
                            .brutalTypography(.monoSmall, color: .brutalSuccess)
                            .tracking(1)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 16)
                    }

                    // Verify button
                    BrutalPrimaryButton(
                        title: String(localized: "auth.verify_email.button.verify"),
                        action: verifyEmail,
                        isLoading: isLoading,
                        isDisabled: verificationCode.isEmpty
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)

                    // Resend code
                    HStack(spacing: 8) {
                        if isResending {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                        }
                        BrutalTextButton(title: String(localized: "auth.verify_email.button.resend"), action: resendCode)
                    }
                    .disabled(isResending)

                    Spacer(minLength: 48)

                    // Logout option
                    BrutalTextButton(title: String(localized: "auth.verify_email.button.sign_out"), color: .brutalError) {
                        logout()
                    }
                    .padding(.bottom, 32)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func verifyEmail() {
        guard !verificationCode.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        successMessage = nil

        Task {
            do {
                try await AuthService.shared.verifyEmail(
                    token: verificationCode.trimmingCharacters(in: .whitespaces)
                )
                await MainActor.run {
                    authState.setEmailVerified(true)
                }
            } catch let error as AuthError {
                await MainActor.run {
                    errorMessage = error.errorDescription
                }
            } catch {
                await MainActor.run {
                    errorMessage = String(localized: "auth.verify_email.error.unexpected")
                }
            }

            await MainActor.run {
                isLoading = false
            }
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
                await MainActor.run {
                    successMessage = String(localized: "auth.verify_email.success.code_sent")
                }
            } catch let error as AuthError {
                await MainActor.run {
                    errorMessage = error.errorDescription
                }
            } catch {
                await MainActor.run {
                    errorMessage = String(localized: "auth.verify_email.error.unexpected")
                }
            }

            await MainActor.run {
                isResending = false
            }
        }
    }

    private func logout() {
        authState.logout()
    }
}

#Preview {
    EmailVerificationView()
        .environmentObject(AuthState.shared)
}
