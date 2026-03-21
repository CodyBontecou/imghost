import SwiftUI

struct ResetPasswordView: View {
    @Environment(\.dismiss) var dismiss

    @State private var resetCode = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isResetSuccessful = false

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
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .padding(.horizontal, 24)

                            BrutalPrimaryButton(
                                title: String(localized: "auth.reset_password.button.back_to_sign_in"),
                                action: { dismiss() }
                            )
                            .padding(.horizontal, 24)
                        }
                    } else {
                        // Form
                        VStack(spacing: 16) {
                            BrutalTextField(
                                label: String(localized: "auth.reset_password.field.reset_code"),
                                text: $resetCode,
                                autocapitalization: .never
                            )

                            BrutalTextField(
                                label: String(localized: "auth.reset_password.field.new_password"),
                                text: $newPassword,
                                isSecure: true,
                                textContentType: .newPassword
                            )

                            BrutalTextField(
                                label: String(localized: "auth.reset_password.field.confirm_password"),
                                text: $confirmPassword,
                                isSecure: true,
                                textContentType: .newPassword
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
                        }

                        // Reset button
                        BrutalPrimaryButton(
                            title: String(localized: "auth.reset_password.button.reset"),
                            action: resetPassword,
                            isLoading: isLoading,
                            isDisabled: !isFormValid
                        )
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
        .preferredColorScheme(.dark)
    }

    private var isFormValid: Bool {
        !resetCode.isEmpty &&
        newPassword.count >= 8 &&
        newPassword == confirmPassword
    }

    private func resetPassword() {
        guard isFormValid else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await AuthService.shared.resetPassword(
                    token: resetCode.trimmingCharacters(in: .whitespaces),
                    newPassword: newPassword
                )
                await MainActor.run {
                    isResetSuccessful = true
                }
            } catch let error as AuthError {
                await MainActor.run {
                    errorMessage = error.errorDescription
                }
            } catch {
                await MainActor.run {
                    errorMessage = String(localized: "auth.reset_password.error.unexpected")
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
        ResetPasswordView()
    }
}
