import SwiftUI

struct MacForgotPasswordView: View {
    @Environment(\.dismiss) var dismiss

    let passwordResetService: AuthService

    init(passwordResetService: AuthService = .shared) {
        self.passwordResetService = passwordResetService
    }

    @State private var email = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isRequestAccepted = false
    @State private var acceptedEmail = ""
    @State private var showResetPassword = false
    @State private var isActive = false
    @State private var requestOperation: UUID?
    @State private var resetOperation: UUID?

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
                    Button(action: closeSheet) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.brutalTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "button.cancel"))
                    .accessibilityIdentifier("auth.forgot.cancel")
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
                        } else if isRequestAccepted {
                            emailSentView
                        } else {
                            requestCodeView
                        }
                    }
                    .padding(24)
                }
            }
        }
        .onAppear { isActive = true }
        .onDisappear { retireOperations(); isActive = false }
    }

    // MARK: - Request Code

    private var requestCodeView: some View {
        VStack(spacing: 20) {
            Text("auth.forgot_password.title")
                .font(.system(size: 40, weight: .black))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            MacBrutalTextField(
                label: String(localized: "auth.forgot_password.field.email"), text: $email,
                fieldAccessibilityIdentifier: "auth.forgot.email",
                fieldAccessibilityLabel: String(localized: "auth.forgot_password.field.email")
            )

            if let errorMessage = errorMessage {
                Text(errorMessage.uppercased())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.brutalError)
                    .tracking(1)
                    .accessibilityIdentifier("auth.forgot.error")
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
            .accessibilityLabel(Text("auth.forgot_password.button.send_code"))
            .accessibilityIdentifier("auth.forgot.sendCode")

            Button(action: enterExistingCode) {
                Text("auth.forgot_password.button.existing_code")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.brutalTextSecondary)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityIdentifier("auth.forgot.existingCode")
        }
    }

    // MARK: - Email Sent

    private var emailSentView: some View {
        VStack(spacing: 20) {
            Text(verbatim: "✓")
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.brutalSuccess)

            Text("auth.forgot_password.request_accepted")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.brutalTextSecondary)
                .tracking(2)
                .accessibilityLabel(Text("auth.forgot_password.request_accepted"))
                .accessibilityIdentifier("auth.forgot.requestAccepted")

            Text(verbatim: acceptedEmail)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white)

            Button(action: enterExistingCode) {
                Text("auth.forgot_password.button.enter_code")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.black)
                    .tracking(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.white)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("auth.forgot.enterCode")

            Button(action: {
                retireOperations()
                isRequestAccepted = false
            }) {
                Text("auth.forgot_password.button.send_again")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.brutalTextSecondary)
                    .tracking(1)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("auth.forgot.sendAgain")
        }
    }

    // MARK: - Reset Password

    private var resetPasswordView: some View {
        VStack(spacing: 20) {
            Text("auth.reset_password.title")
                .font(.system(size: 40, weight: .black))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            MacBrutalTextField(
                label: String(localized: "auth.reset_password.field.code"), text: $resetCode,
                fieldAccessibilityIdentifier: "auth.reset.code",
                fieldAccessibilityLabel: String(localized: "auth.reset_password.field.code")
            )
            MacBrutalTextField(
                label: String(localized: "auth.reset_password.field.new_password"), text: $newPassword, isSecure: true,
                fieldAccessibilityIdentifier: "auth.reset.newPassword",
                fieldAccessibilityLabel: String(localized: "auth.reset_password.field.new_password")
            )
            MacBrutalTextField(
                label: String(localized: "auth.reset_password.field.confirm_password"), text: $confirmPassword, isSecure: true,
                fieldAccessibilityIdentifier: "auth.reset.confirmPassword",
                fieldAccessibilityLabel: String(localized: "auth.reset_password.field.confirm_password")
            )

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
                    .accessibilityLabel(Text(resetError.uppercased()))
                    .accessibilityIdentifier("auth.reset.error")
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
            .accessibilityLabel(Text("auth.reset_password.button.reset"))
            .accessibilityIdentifier("auth.reset.submit")

            Button(action: {
                // Internal stages do not disappear as separate views.
                retireOperations()
                showResetPassword = false
            }) {
                Text("auth.reset_password.button.back")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("auth.reset.back")
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
                .accessibilityIdentifier("auth.reset.success")

            Button(action: closeSheet) {
                Text("auth.reset_password.success.button.sign_in")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.black)
                    .tracking(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.white)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("auth.reset.backToSignIn")
        }
    }

    // MARK: - Logic

    private var isResetFormValid: Bool {
        !resetCode.isEmpty && newPassword.count >= 8 && newPassword == confirmPassword
    }

    @MainActor
    private func retireOperations() {
        requestOperation = nil
        resetOperation = nil
        isLoading = false
        isResetting = false
    }

    @MainActor
    private func closeSheet() {
        retireOperations()
        isActive = false
        dismiss()
    }

    @MainActor
    private func enterExistingCode() {
        guard isActive, !isLoading, !isResetting else { return }
        retireOperations()
        showResetPassword = true
    }

    @MainActor
    private func sendResetEmail() {
        guard isActive, !showResetPassword, !isRequestAccepted,
              !email.isEmpty, email.contains("@"), !isLoading else { return }
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

    @MainActor
    private func resetPassword() {
        guard isActive, showResetPassword, isResetFormValid, !isResetting else { return }
        let submittedCode = resetCode.trimmingCharacters(in: .whitespaces)
        let submittedPassword = newPassword
        let operation = UUID()
        resetOperation = operation
        isResetting = true
        resetError = nil

        Task { @MainActor in
            do {
                try await passwordResetService.resetPassword(token: submittedCode, newPassword: submittedPassword)
                guard isActive, resetOperation == operation else { return }
                isResetSuccessful = true
            } catch let error as AuthError {
                guard isActive, resetOperation == operation else { return }
                resetError = error.errorDescription
            } catch {
                guard isActive, resetOperation == operation else { return }
                resetError = String(localized: "auth.reset_password.error.unexpected")
            }
            guard isActive, resetOperation == operation else { return }
            resetOperation = nil
            isResetting = false
        }
    }
}
