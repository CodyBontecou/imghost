import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @EnvironmentObject var authState: AuthState

    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var isAppleSignInLoading = false
    @State private var errorMessage: String?
    @State private var showRegister = false
    @State private var showForgotPassword = false
    @State private var showPlansPreview = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.brutalBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        // Top bar with logo
                        HStack {
                            Spacer()
                            Image("AppIconImage")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 16)

                        // Hero text
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SIGN\nIN")
                                .font(.system(size: 72, weight: .black))
                                .foregroundStyle(.white)
                                .lineSpacing(-8)

                            HStack {
                                Rectangle()
                                    .fill(Color.white)
                                    .frame(width: 24, height: 1)

                                Text("ACCESS YOUR IMAGES")
                                    .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                                    .tracking(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, 32)
                        .padding(.bottom, 48)

                        // Sign in with Apple
                        VStack(spacing: 24) {
                            SignInWithAppleButton(.signIn) { request in
                                request.requestedScopes = [.email, .fullName]
                            } onCompletion: { result in
                                handleAppleSignInResult(result)
                            }
                            .signInWithAppleButtonStyle(.white)
                            .frame(height: 52)
                            .disabled(isAppleSignInLoading || isLoading)
                            .overlay {
                                if isAppleSignInLoading {
                                    Rectangle()
                                        .fill(Color.black.opacity(0.3))
                                    ProgressView()
                                        .tint(.black)
                                }
                            }

                            BrutalDivider(label: "or")

                            // Form
                            VStack(spacing: 16) {
                                BrutalTextField(
                                    label: "Email",
                                    text: $email,
                                    keyboardType: .emailAddress,
                                    textContentType: .emailAddress,
                                    autocapitalization: .never
                                )

                                BrutalTextField(
                                    label: "Password",
                                    text: $password,
                                    isSecure: true,
                                    textContentType: .password
                                )
                            }

                            // Error message
                            if let errorMessage = errorMessage {
                                Text(errorMessage.uppercased())
                                    .brutalTypography(.monoSmall, color: .brutalError)
                                    .tracking(1)
                                    .multilineTextAlignment(.center)
                            }

                            // Login button
                            BrutalPrimaryButton(
                                title: "Sign In",
                                action: login,
                                isLoading: isLoading,
                                isDisabled: !isFormValid
                            )

                            // Forgot password
                            BrutalTextButton(title: "Forgot Password?") {
                                showForgotPassword = true
                            }
                        }
                        .padding(.horizontal, 24)

                        Spacer(minLength: 48)

                        // View Plans link
                        BrutalTextButton(title: "View Pro Plans") {
                            showPlansPreview = true
                        }
                        .padding(.bottom, 16)

                        // Register link
                        HStack(spacing: 8) {
                            Text("NO ACCOUNT?")
                                .brutalTypography(.monoSmall, color: .brutalTextTertiary)
                                .tracking(1)

                            BrutalTextButton(title: "Create One", color: .white) {
                                showRegister = true
                            }
                        }
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $showRegister) {
                RegisterView()
            }
            .navigationDestination(isPresented: $showForgotPassword) {
                ForgotPasswordView()
            }
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showPlansPreview) {
                NavigationStack {
                    PaywallView()
                        .environmentObject(SubscriptionState.shared)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    showPlansPreview = false
                                } label: {
                                    Image(systemName: "xmark")
                                        .foregroundColor(.white)
                                }
                            }
                        }
                }
                .preferredColorScheme(.dark)
            }
        }
    }

    private var isFormValid: Bool {
        !email.isEmpty && !password.isEmpty && email.contains("@")
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
                await MainActor.run {
                    errorMessage = error.errorDescription
                }
            } catch {
                await MainActor.run {
                    errorMessage = "An unexpected error occurred."
                }
            }

            await MainActor.run {
                isLoading = false
            }
        }
    }

    private func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Invalid Apple ID credential."
                return
            }

            guard let identityTokenData = appleIDCredential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8) else {
                errorMessage = "Could not retrieve identity token."
                return
            }

            let appleResult = AppleSignInResult(
                identityToken: identityToken,
                userIdentifier: appleIDCredential.user,
                email: appleIDCredential.email,
                fullName: appleIDCredential.fullName
            )

            signInWithApple(result: appleResult)

        case .failure(let error):
            if let authError = error as? ASAuthorizationError,
               authError.code == .canceled {
                return
            }
            errorMessage = "Apple Sign-In failed: \(error.localizedDescription)"
        }
    }

    private func signInWithApple(result: AppleSignInResult) {
        isAppleSignInLoading = true
        errorMessage = nil

        Task {
            do {
                let response = try await AuthService.shared.signInWithApple(result: result)
                await authState.setAuthenticated(response: response)
            } catch let error as AuthError {
                await MainActor.run {
                    errorMessage = error.errorDescription
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Apple Sign-In failed. Please try again."
                }
            }

            await MainActor.run {
                isAppleSignInLoading = false
            }
        }
    }
}

#Preview {
    LoginView()
        .environmentObject(AuthState.shared)
}
