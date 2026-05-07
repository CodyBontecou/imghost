import SwiftUI
import AuthenticationServices

struct MacLoginView: View {
    @EnvironmentObject var authState: AuthState

    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showRegister = false
    @State private var showForgotPassword = false

    var body: some View {
        ZStack {
            Color.brutalBackground.ignoresSafeArea()

            HStack(spacing: 0) {
                // Left: Branding
                VStack(spacing: 0) {
                    Spacer()

                    VStack(alignment: .leading, spacing: 12) {
                        Image("AppIconImage")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Text("auth.login.app_name")
                            .font(.system(size: 72, weight: .black))
                            .foregroundStyle(Color.white)

                        HStack {
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: 24, height: 1)
                            Text("auth.login.tagline")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.brutalTextSecondary)
                                .tracking(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 48)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(Color.brutalBackground)

                // Right: Login form
                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: 24) {
                        // Title
                        VStack(alignment: .leading, spacing: 4) {
                            Text("auth.login.section.sign_in")
                                .font(.system(size: 28, weight: .black))
                                .foregroundStyle(Color.white)

                            Text("auth.login.section.hint")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.brutalTextSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Form
                        VStack(spacing: 16) {
                            MacBrutalTextField(label: String(localized: "auth.login.field.email"), text: $email)
                            MacBrutalTextField(label: String(localized: "auth.login.field.password"), text: $password, isSecure: true)
                        }

                        // Error
                        if let errorMessage = errorMessage {
                            Text(errorMessage.uppercased())
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.brutalError)
                                .tracking(1)
                        }

                        // Login button
                        Button(action: login) {
                            HStack(spacing: 8) {
                                if isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                        .scaleEffect(0.7)
                                } else {
                                    Text("auth.login.button.sign_in")
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

                        // Divider
                        BrutalDivider(label: String(localized: "auth.login.divider"))

                        // Apple Sign In
                        SignInWithAppleButton(.signIn) { request in
                            request.requestedScopes = [.email, .fullName]
                        } onCompletion: { result in
                            handleAppleSignIn(result)
                        }
                        .signInWithAppleButtonStyle(.white)
                        .frame(height: 44)
                        .disabled(isLoading)

                        // Anonymous access (no personal info required before purchase)
                        VStack(spacing: 8) {
                            Button(action: continueWithoutAccount) {
                                Text("Continue without account")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .tracking(1)
                                    .foregroundStyle(Color.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading)

                            Text("No email required. Create an account later if you want access on other devices.")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.brutalTextTertiary)
                                .multilineTextAlignment(.center)
                        }

                        // Links
                        HStack(spacing: 16) {
                            Button(action: { showRegister = true }) {
                                Text("auth.login.button.create_account")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.brutalTextSecondary)
                                    .tracking(1)
                            }
                            .buttonStyle(.plain)

                            Button(action: { showForgotPassword = true }) {
                                Text("auth.login.button.forgot_password")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.brutalTextSecondary)
                                    .tracking(1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 340)
                    .padding(48)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(Color.brutalSurface)
            }
        }
        .sheet(isPresented: $showRegister) {
            MacRegisterView()
                .environmentObject(authState)
                .frame(width: 420, height: 560)
        }
        .sheet(isPresented: $showForgotPassword) {
            MacForgotPasswordView()
                .frame(width: 420, height: 480)
        }
    }

    private var isFormValid: Bool {
        !email.isEmpty && email.contains("@") && !password.isEmpty
    }

    private func login() {
        guard isFormValid else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let response = try await AuthService.shared.login(
                    email: email.trimmingCharacters(in: .whitespaces),
                    password: password
                )
                await authState.setAuthenticated(response: response)
            } catch let error as AuthError {
                await MainActor.run { errorMessage = error.errorDescription }
            } catch {
                await MainActor.run { errorMessage = String(localized: "auth.login.error.unexpected") }
            }
            await MainActor.run { isLoading = false }
        }
    }

    private func continueWithoutAccount() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let response = try await AuthService.shared.continueAnonymously()
                await authState.setAuthenticated(response: response)
            } catch let error as AuthError {
                await MainActor.run { errorMessage = error.errorDescription }
            } catch {
                await MainActor.run { errorMessage = String(localized: "auth.login.error.unexpected") }
            }
            await MainActor.run { isLoading = false }
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityTokenData = appleIDCredential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8) else {
                errorMessage = String(localized: "auth.login.error.no_apple_credential")
                return
            }

            isLoading = true
            errorMessage = nil

            let appleResult = AppleSignInResult(
                identityToken: identityToken,
                userIdentifier: appleIDCredential.user,
                email: appleIDCredential.email,
                fullName: appleIDCredential.fullName
            )

            Task {
                do {
                    let response = try await AuthService.shared.signInWithApple(result: appleResult)
                    await authState.setAuthenticated(response: response)
                } catch let error as AuthError {
                    await MainActor.run { errorMessage = error.errorDescription }
                } catch {
                    await MainActor.run { errorMessage = String(localized: "auth.login.error.apple_failed") }
                }
                await MainActor.run { isLoading = false }
            }

        case .failure(let error):
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                errorMessage = String(format: String(localized: "auth.login.error.apple_failed_detailed"), error.localizedDescription)
            }
        }
    }
}
