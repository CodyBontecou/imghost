import Foundation

extension AuthState {
    #if !SHARE_EXTENSION
    func makeEmailConversionFlow() -> EmailConversionCoordinator {
        EmailConversionCoordinator(service: EmailConversionService(baseURL: URL(string: Config.backendURL)!),
            authState: self, login: { try await AuthService.shared.login(email: $0, password: $1) })
    }

    #endif

    static let shared = AuthState(dependencies: Dependencies(
        sessions: KeychainService.shared.sessions,
        user: { try await AuthService.shared.getCurrentUser() },
        refresh: { try await AuthService.shared.refreshTokens() },
        sync: {
            #if !SHARE_EXTENSION
            try? await ImageSyncService.shared.syncImages()
            #endif
        },
        resetSubscription: {
            #if !SHARE_EXTENSION
            SubscriptionState.shared.reset()
            #endif
        }))
}
