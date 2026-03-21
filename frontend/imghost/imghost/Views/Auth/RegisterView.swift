import SwiftUI

struct RegisterView: View {
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

            ScrollView {
                VStack(spacing: 0) {
                    // Hero text
                    VStack(alignment: .leading, spacing: 8) {
                        Text("auth.register.title")
                            .font(.system(size: 56, weight: .black))
                            .foregroundStyle(.white)
                            .lineSpacing(-8)

                        HStack {
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: 24, height: 1)

                            Text("auth.register.subtitle")
                                .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                                .tracking(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 40)

                    // Form
                    VStack(spacing: 16) {
                        BrutalTextField(
                            label: String(localized: "auth.register.field.email"),
                            text: $email,
                            keyboardType: .emailAddress,
                            textContentType: .emailAddress,
                            autocapitalization: .never
                        )

                        BrutalTextField(
                            label: String(localized: "auth.register.field.password"),
                            text: $password,
                            isSecure: true,
                            textContentType: .newPassword
                        )

                        BrutalTextField(
                            label: String(localized: "auth.register.field.confirm_password"),
                            text: $confirmPassword,
                            isSecure: true,
                            textContentType: .newPassword
                        )

                        // Password requirements
                        BrutalCard(backgroundColor: .brutalSurface) {
                            VStack(alignment: .leading, spacing: 8) {
                                BrutalRequirement(
                                    text: String(localized: "auth.register.requirement.min_chars"),
                                    isMet: password.count >= 8
                                )
                                BrutalRequirement(
                                    text: String(localized: "auth.register.requirement.passwords_match"),
                                    isMet: !password.isEmpty && password == confirmPassword
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

                    // Register button
                    BrutalPrimaryButton(
                        title: String(localized: "auth.register.button.create_account"),
                        action: register,
                        isLoading: isLoading,
                        isDisabled: !isFormValid
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 24)

                    Spacer(minLength: 48)

                    // Back to login
                    HStack(spacing: 8) {
                        Text("auth.register.prompt.have_account")
                            .brutalTypography(.monoSmall, color: .brutalTextTertiary)
                            .tracking(1)

                        BrutalTextButton(title: String(localized: "auth.register.button.sign_in"), color: .white) {
                            dismiss()
                        }
                    }
                    .padding(.bottom, 32)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.brutalBackground, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    private var isFormValid: Bool {
        !email.isEmpty &&
        email.contains("@") &&
        password.count >= 8 &&
        password == confirmPassword
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
            } catch let error as AuthError {
                await MainActor.run {
                    errorMessage = error.errorDescription
                }
            } catch {
                await MainActor.run {
                    errorMessage = String(localized: "auth.register.error.unexpected")
                }
            }

            await MainActor.run {
                isLoading = false
            }
        }
    }
}

struct BrutalRequirement: View {
    let text: String
    let isMet: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: isMet ? "✓" : "○")
                .brutalTypography(.mono, color: isMet ? .brutalSuccess : .brutalTextTertiary)

            Text(text.uppercased())
                .brutalTypography(.monoSmall, color: isMet ? .white : .brutalTextSecondary)
                .tracking(1)
        }
    }
}

#Preview {
    NavigationStack {
        RegisterView()
            .environmentObject(AuthState.shared)
    }
}
