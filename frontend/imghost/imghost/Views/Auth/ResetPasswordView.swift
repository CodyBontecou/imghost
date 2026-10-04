import SwiftUI

struct ResetPasswordView: View {
    @Environment(\.dismiss) var dismiss

    let passwordResetService: AuthService
    let onReturnToSignIn: (() -> Void)?

    init(passwordResetService: AuthService = .shared, onReturnToSignIn: (() -> Void)? = nil) {
        self.passwordResetService = passwordResetService
        self.onReturnToSignIn = onReturnToSignIn
    }

    @State private var resetCode = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isResetSuccessful = false
    @State private var isActive = false
    @State private var resetOperation: UUID?

    var body: some View {
        ZStack {
            Color.brutalBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // Hero text
                    VStack(alignment: .leading, spacing: 8) {
                        Text(isResetSuccessful
                             ? "auth.reset_password.title.done"
                             : "auth.reset_password.title")
                            .font(.system(size: 56, weight: .black))
                            .foregroundStyle(.white)
                            .lineSpacing(-8)

                        HStack {
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: 24, height: 1)

                            Text(isResetSuccessful
                                 ? "auth.reset_password.subtitle.updated"
                                 : "auth.reset_password.subtitle.enter_code")
                                .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                                .tracking(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 40)

                    if isResetSuccessful {
                        // Success state
                        VStack(spacing: 24) {
                            BrutalCard(backgroundColor: .brutalSurface) {
                                VStack(spacing: 16) {
                                    Text("auth.reset_password.success.icon")
                                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.brutalSuccess)

                                    Text("auth.reset_password.success.message")
                                        .brutalTypography(.bodyMedium, color: .brutalTextSecondary)
                                        .multilineTextAlignment(.center)
                                        .accessibilityIdentifier("auth.reset.success")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .padding(.horizontal, 24)

                            BrutalPrimaryButton(
                                title: String(localized: "auth.reset_password.button.back_to_sign_in"),
                                action: {
                                    isActive = false
                                    resetOperation = nil
                                    if let onReturnToSignIn { onReturnToSignIn() } else { dismiss() }
                                }
                            )
                            .accessibilityIdentifier("auth.reset.backToSignIn")
                            .padding(.horizontal, 24)
                        }
                    } else {
                        // Form
                        VStack(spacing: 16) {
                            BrutalTextField(
                                label: String(localized: "auth.reset_password.field.reset_code"),
                                text: $resetCode,
                                autocapitalization: .never,
                                fieldAccessibilityIdentifier: "auth.reset.code",
                                fieldAccessibilityLabel: String(localized: "auth.reset_password.field.reset_code")
                            )

                            BrutalTextField(
                                label: String(localized: "auth.reset_password.field.new_password"),
                                text: $newPassword,
                                isSecure: true,
                                textContentType: .newPassword,
                                fieldAccessibilityIdentifier: "auth.reset.newPassword",
                                fieldAccessibilityLabel: String(localized: "auth.reset_password.field.new_password")
                            )

                            BrutalTextField(
                                label: String(localized: "auth.reset_password.field.confirm_password"),
                                text: $confirmPassword,
                                isSecure: true,
                                textContentType: .newPassword,
                                fieldAccessibilityIdentifier: "auth.reset.confirmPassword",
                                fieldAccessibilityLabel: String(localized: "auth.reset_password.field.confirm_password")
                            )

                            // Password requirements
                            BrutalCard(backgroundColor: .brutalSurface) {
                                VStack(alignment: .leading, spacing: 8) {
                                    BrutalRequirement(
                                        text: String(localized: "auth.reset_password.requirement.min_chars"),
                                        isMet: newPassword.count >= 8
                                    )
                                    BrutalRequirement(
                                        text: String(localized: "auth.reset_password.requirement.passwords_match"),
                                        isMet: !newPassword.isEmpty && newPassword == confirmPassword
                                    )
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 24)

                        // Error message
                        if let errorMessage = errorMessage {
                            Text(errorMessage.uppercased())
                                .brutalTypography(.monoSmall, color: .brutalError)
                                .tracking(1)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                                .padding(.top, 16)
                                .accessibilityIdentifier("auth.reset.error")
                        }

                        // Reset button
                        BrutalPrimaryButton(
                            title: String(localized: "auth.reset_password.button.reset"),
                            action: resetPassword,
                            isLoading: isLoading,
                            isDisabled: !isFormValid
                        )
                        .accessibilityIdentifier("auth.reset.submit")
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                    }

                    Spacer()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.brutalBackground, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { isActive = true }
        .onDisappear {
            isActive = false
            resetOperation = nil
            isLoading = false
        }
        .preferredColorScheme(.dark)
    }

    private var isFormValid: Bool {
        !resetCode.isEmpty &&
        newPassword.count >= 8 &&
        newPassword == confirmPassword
    }

    @MainActor
    private func resetPassword() {
        guard isActive, isFormValid, !isLoading else { return }
        let submittedCode = resetCode.trimmingCharacters(in: .whitespaces)
        let submittedPassword = newPassword
        let operation = UUID()
        resetOperation = operation
        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            do {
                try await passwordResetService.resetPassword(token: submittedCode, newPassword: submittedPassword)
                guard isActive, resetOperation == operation else { return }
                isResetSuccessful = true
            } catch let error as AuthError {
                guard isActive, resetOperation == operation else { return }
                errorMessage = error.errorDescription
            } catch {
                guard isActive, resetOperation == operation else { return }
                errorMessage = String(localized: "auth.reset_password.error.unexpected")
            }
            guard isActive, resetOperation == operation else { return }
            resetOperation = nil
            isLoading = false
        }
    }
}

#Preview {
    NavigationStack {
        ResetPasswordView()
    }
}
