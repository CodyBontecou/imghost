import SwiftUI

struct MacForgotPasswordView: View {
    @Environment(\.dismiss) var dismiss

    @State private var email = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isEmailSent = false
    @State private var showResetPassword = false

    // Reset password fields
    @State private var resetCode = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isResetting = false
    @State private var resetError: String?
    @State private var isResetSuccessful = false

    var body: some View {
        ZStack {
            Color.brutalBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("auth.forgot_password.sheet.title")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .tracking(2)
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.brutalTextSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                .background(Color.brutalSurface)

                Divider().background(Color.brutalBorder)

                ScrollView {
                    VStack(spacing: 24) {
                        if isResetSuccessful {
                            successView
                        } else if showResetPassword {
                            resetPasswordView
                        } else if isEmailSent {
                            emailSentView
                        } else {
                            requestCodeView
                        }
                    }
                    .padding(24)
                }
            }
        }
    }

    // MARK: - Request Code

    private var requestCodeView: some View {
        VStack(spacing: 20) {
            Text("auth.forgot_password.title")
                .font(.system(size: 40, weight: .black))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            MacBrutalTextField(label: String(localized: "auth.forgot_password.field.email"), text: $email)

            if let errorMessage = errorMessage {
                Text(errorMessage.uppercased())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.brutalError)
                    .tracking(1)
            }

            Button(action: sendResetEmail) {
                HStack {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                            .scaleEffect(0.7)
                    } else {
                        Text("auth.forgot_password.button.send_code")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .tracking(1)
                    }
                }
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(!email.isEmpty && email.contains("@") ? Color.white : Color.brutalTextTertiary)
            }
            .buttonStyle(.plain)
            .disabled(email.isEmpty || !email.contains("@") || isLoading)
        }
    }

    // MARK: - Email Sent

    private var emailSentView: some View {
        VStack(spacing: 20) {
            Text(verbatim: "✓")
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.brutalSuccess)

            Text("auth.forgot_password.code_sent_to")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.brutalTextSecondary)
                .tracking(2)

            Text(verbatim: email)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white)

            Button(action: { showResetPassword = true }) {
                Text("auth.forgot_password.button.enter_code")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.black)
                    .tracking(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.white)
            }
            .buttonStyle(.plain)

            Button(action: { isEmailSent = false }) {
                Text("auth.forgot_password.button.send_again")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.brutalTextSecondary)
                    .tracking(1)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Reset Password

    private var resetPasswordView: some View {
        VStack(spacing: 20) {
            Text("auth.reset_password.title")
                .font(.system(size: 40, weight: .black))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            MacBrutalTextField(label: String(localized: "auth.reset_password.field.code"), text: $resetCode)
            MacBrutalTextField(label: String(localized: "auth.reset_password.field.new_password"), text: $newPassword, isSecure: true)
            MacBrutalTextField(label: String(localized: "auth.reset_password.field.confirm_password"), text: $confirmPassword, isSecure: true)

            VStack(alignment: .leading, spacing: 8) {
                MacRequirement(text: String(localized: "auth.reset_password.requirement.min_chars"), isMet: newPassword.count >= 8)
                MacRequirement(text: String(localized: "auth.reset_password.requirement.passwords_match"), isMet: !newPassword.isEmpty && newPassword == confirmPassword)
            }
            .padding(12)
            .background(Color.brutalSurface)
            .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))

            if let resetError = resetError {
                Text(resetError.uppercased())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.brutalError)
                    .tracking(1)
            }

            Button(action: resetPassword) {
                HStack {
                    if isResetting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                            .scaleEffect(0.7)
                    } else {
                        Text("auth.reset_password.button.reset")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .tracking(1)
                    }
                }
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(isResetFormValid ? Color.white : Color.brutalTextTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!isResetFormValid || isResetting)
        }
    }

    // MARK: - Success

    private var successView: some View {
        VStack(spacing: 20) {
            Text("auth.reset_password.success.icon")
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.brutalSuccess)

            Text("auth.reset_password.success.title")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.white)

            Text("auth.reset_password.success.message")
                .font(.system(size: 12))
                .foregroundStyle(Color.brutalTextSecondary)
                .multilineTextAlignment(.center)

            Button(action: { dismiss() }) {
                Text("auth.reset_password.success.button.sign_in")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.black)
                    .tracking(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.white)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Logic

    private var isResetFormValid: Bool {
        !resetCode.isEmpty && newPassword.count >= 8 && newPassword == confirmPassword
    }

    private func sendResetEmail() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await AuthService.shared.forgotPassword(email: email.trimmingCharacters(in: .whitespaces))
                await MainActor.run { isEmailSent = true }
            } catch let error as AuthError {
                await MainActor.run { errorMessage = error.errorDescription }
            } catch {
                await MainActor.run { errorMessage = String(localized: "auth.forgot_password.error.unexpected") }
            }
            await MainActor.run { isLoading = false }
        }
    }

    private func resetPassword() {
        guard isResetFormValid else { return }
        isResetting = true
        resetError = nil

        Task {
            do {
                try await AuthService.shared.resetPassword(
                    token: resetCode.trimmingCharacters(in: .whitespaces),
                    newPassword: newPassword
                )
                await MainActor.run { isResetSuccessful = true }
            } catch let error as AuthError {
                await MainActor.run { resetError = error.errorDescription }
            } catch {
                await MainActor.run { resetError = String(localized: "auth.reset_password.error.unexpected") }
            }
            await MainActor.run { isResetting = false }
        }
    }
}
