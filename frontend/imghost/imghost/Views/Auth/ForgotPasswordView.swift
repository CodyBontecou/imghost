import SwiftUI

struct ForgotPasswordView: View {
    @Environment(\.dismiss) var dismiss

    @State private var email = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isEmailSent = false
    @State private var showResetPassword = false

    var body: some View {
        ZStack {
            Color.brutalBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // Hero text
                    VStack(alignment: .leading, spacing: 8) {
                        Text("auth.forgot_password.title")
                            .font(.system(size: 56, weight: .black))
                            .foregroundStyle(.white)
                            .lineSpacing(-8)

                        HStack {
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: 24, height: 1)

                            Text(isEmailSent
                                 ? "auth.forgot_password.subtitle.check_email"
                                 : "auth.forgot_password.subtitle.enter_email")
                                .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                                .tracking(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 40)

                    if isEmailSent {
                        // Success state
                        VStack(spacing: 24) {
                            BrutalCard(backgroundColor: .brutalSurface) {
                                VStack(spacing: 16) {
                                    Text(verbatim: "✓")
                                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.brutalSuccess)

                                    Text("auth.forgot_password.code_sent_to")
                                        .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                                        .tracking(2)

                                    Text(verbatim: email)
                                        .brutalTypography(.bodyLarge)

                                    Text("auth.forgot_password.spam_hint")
                                        .brutalTypography(.bodySmall, color: .brutalTextTertiary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .padding(.horizontal, 24)

                            BrutalPrimaryButton(
                                title: String(localized: "auth.forgot_password.button.enter_code"),
                                action: { showResetPassword = true }
                            )
                            .padding(.horizontal, 24)

                            BrutalTextButton(title: String(localized: "auth.forgot_password.button.send_again")) {
                                isEmailSent = false
                            }
                        }
                    } else {
                        // Form
                        VStack(spacing: 24) {
                            BrutalTextField(
                                label: String(localized: "auth.forgot_password.field.email"),
                                text: $email,
                                keyboardType: .emailAddress,
                                textContentType: .emailAddress,
                                autocapitalization: .never
                            )
                            .padding(.horizontal, 24)

                            // Error message
                            if let errorMessage = errorMessage {
                                Text(errorMessage.uppercased())
                                    .brutalTypography(.monoSmall, color: .brutalError)
                                    .tracking(1)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                            }

                            BrutalPrimaryButton(
                                title: String(localized: "auth.forgot_password.button.send_code"),
                                action: sendResetEmail,
                                isLoading: isLoading,
                                isDisabled: !isFormValid
                            )
                            .padding(.horizontal, 24)
                        }
                    }

                    Spacer()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.brutalBackground, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(isPresented: $showResetPassword) {
            ResetPasswordView()
        }
        .preferredColorScheme(.dark)
    }

    private var isFormValid: Bool {
        !email.isEmpty && email.contains("@")
    }

    private func sendResetEmail() {
        guard isFormValid else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await AuthService.shared.forgotPassword(
                    email: email.trimmingCharacters(in: .whitespaces)
                )
                await MainActor.run {
                    isEmailSent = true
                }
            } catch let error as AuthError {
                await MainActor.run {
                    errorMessage = error.errorDescription
                }
            } catch {
                await MainActor.run {
                    errorMessage = String(localized: "auth.forgot_password.error.unexpected")
                }
            }

            await MainActor.run {
                isLoading = false
            }
        }
    }
}

#Preview {
    NavigationStack {
        ForgotPasswordView()
    }
}
