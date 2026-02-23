import SwiftUI

struct MacRegisterView: View {
    @EnvironmentObject var authState: AuthState
    @Environment(\.dismiss) var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.brutalBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("CREATE ACCOUNT")
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
                    VStack(spacing: 20) {
                        // Hero
                        Text("CREATE\nACCOUNT")
                            .font(.system(size: 40, weight: .black))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // Form
                        VStack(spacing: 14) {
                            MacBrutalTextField(label: "Email", text: $email)
                            MacBrutalTextField(label: "Password", text: $password, isSecure: true)
                            MacBrutalTextField(label: "Confirm Password", text: $confirmPassword, isSecure: true)
                        }

                        // Requirements
                        VStack(alignment: .leading, spacing: 8) {
                            MacRequirement(text: "At least 8 characters", isMet: password.count >= 8)
                            MacRequirement(text: "Passwords match", isMet: !password.isEmpty && password == confirmPassword)
                        }
                        .padding(12)
                        .background(Color.brutalSurface)
                        .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))

                        // Error
                        if let errorMessage = errorMessage {
                            Text(errorMessage.uppercased())
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.brutalError)
                                .tracking(1)
                        }

                        // Register button
                        Button(action: register) {
                            HStack(spacing: 8) {
                                if isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                        .scaleEffect(0.7)
                                } else {
                                    Text("CREATE ACCOUNT")
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                        .tracking(1)
                                }
                            }
                            .foregroundStyle(Color.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(isFormValid ? Color.white : Color.brutalTextTertiary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!isFormValid || isLoading)

                        // Back to login
                        Button(action: { dismiss() }) {
                            Text("ALREADY HAVE AN ACCOUNT? SIGN IN")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.brutalTextSecondary)
                                .tracking(1)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(24)
                }
            }
        }
    }

    private var isFormValid: Bool {
        !email.isEmpty && email.contains("@") && password.count >= 8 && password == confirmPassword
    }

    private func register() {
        guard isFormValid else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let response = try await AuthService.shared.register(
                    email: email.trimmingCharacters(in: .whitespaces),
                    password: password
                )
                await authState.setAuthenticated(response: response)
                await MainActor.run { dismiss() }
            } catch let error as AuthError {
                await MainActor.run { errorMessage = error.errorDescription }
            } catch {
                await MainActor.run { errorMessage = "An unexpected error occurred." }
            }
            await MainActor.run { isLoading = false }
        }
    }
}

struct MacRequirement: View {
    let text: String
    let isMet: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(isMet ? "✓" : "○")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(isMet ? Color.brutalSuccess : Color.brutalTextTertiary)

            Text(text.uppercased())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(isMet ? Color.white : Color.brutalTextSecondary)
                .tracking(1)
        }
    }
}
