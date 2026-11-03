import SwiftUI

struct ForgotPasswordView: View {
    @Environment(\.dismiss) var dismiss

    let passwordResetService: AuthService
    let onReturnToSignIn: (() -> Void)?

    init(passwordResetService: AuthService = .shared, onReturnToSignIn: (() -> Void)? = nil) {
        self.passwordResetService = passwordResetService
        self.onReturnToSignIn = onReturnToSignIn
    }

    @State private var email = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isRequestAccepted = false
    @State private var acceptedEmail = ""
    @State private var showResetPassword = false
    @State private var isActive = false
    @State private var requestOperation: UUID?

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

                            Text(isRequestAccepted
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

                    if isRequestAccepted {
                        // Success state
                        VStack(spacing: 24) {
                            BrutalCard(backgroundColor: .brutalSurface) {
                                VStack(spacing: 16) {
                                    Text(verbatim: "✓")
                                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.brutalSuccess)

                                    Text("auth.forgot_password.request_accepted")
                                        .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                                        .tracking(2)
                                        .accessibilityIdentifier("auth.forgot.requestAccepted")

                                    Text(verbatim: acceptedEmail)
                                        .brutalTypography(.bodyLarge)

                                    Text("auth.forgot_password.spam_hint")
                                        .brutalTypography(.bodySmall, color: .brutalTextTertiary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .padding(.horizontal, 24)

                            BrutalPrimaryButton(
                                title: String(localized: "auth.forgot_password.button.enter_code"),
                                action: enterExistingCode
                            )
                            .accessibilityIdentifier("auth.forgot.enterCode")
                            .padding(.horizontal, 24)

                            BrutalTextButton(title: String(localized: "auth.forgot_password.button.send_again")) {
                                requestOperation = nil
                                isRequestAccepted = false
                            }
                            .accessibilityIdentifier("auth.forgot.sendAgain")
                        }
                    } else {
                        // Form
                        VStack(spacing: 24) {
                            BrutalTextField(
                                label: String(localized: "auth.forgot_password.field.email"),
                                text: $email,
                                keyboardType: .emailAddress,
                                textContentType: .emailAddress,
                                autocapitalization: .never,
                                fieldAccessibilityIdentifier: "auth.forgot.email",
                                fieldAccessibilityLabel: String(localized: "auth.forgot_password.field.email")
                            )
                            .padding(.horizontal, 24)

                            // Error message
                            if let errorMessage = errorMessage {
                                Text(errorMessage.uppercased())
                                    .brutalTypography(.monoSmall, color: .brutalError)
                                    .tracking(1)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                                    .accessibilityIdentifier("auth.forgot.error")
                            }

                            BrutalPrimaryButton(
                                title: String(localized: "auth.forgot_password.button.send_code"),
                                action: sendResetEmail,
                                isLoading: isLoading,
                                isDisabled: !isFormValid
                            )
                            .accessibilityIdentifier("auth.forgot.sendCode")
                            .padding(.horizontal, 24)

                            BrutalTextButton(
                                title: String(localized: "auth.forgot_password.button.existing_code"),
                                action: enterExistingCode
                            )
                            .disabled(isLoading)
                            .accessibilityIdentifier("auth.forgot.existingCode")
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
            ResetPasswordView(passwordResetService: passwordResetService, onReturnToSignIn: onReturnToSignIn)
        }
        .onAppear { isActive = true }
        .onDisappear {
            isActive = false
            requestOperation = nil
            isLoading = false
        }
        .preferredColorScheme(.dark)
    }

    private var isFormValid: Bool {
        !email.isEmpty && email.contains("@")
    }

    @MainActor
    private func enterExistingCode() {
        guard isActive, !isLoading else { return }
        requestOperation = nil
        showResetPassword = true
    }

    @MainActor
    private func sendResetEmail() {
        guard isActive, isFormValid, !isLoading else { return }
        let submittedEmail = email.trimmingCharacters(in: .whitespaces)
        let operation = UUID()
        requestOperation = operation
        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            do {
                try await passwordResetService.forgotPassword(email: submittedEmail)
                guard isActive, requestOperation == operation else { return }
                acceptedEmail = submittedEmail
                isRequestAccepted = true
            } catch let error as AuthError {
                guard isActive, requestOperation == operation else { return }
                errorMessage = error.errorDescription
            } catch {
                guard isActive, requestOperation == operation else { return }
                errorMessage = String(localized: "auth.forgot_password.error.unexpected")
            }
            guard isActive, requestOperation == operation else { return }
            requestOperation = nil
            isLoading = false
        }
    }
}

#Preview {
    NavigationStack {
        ForgotPasswordView()
    }
}
