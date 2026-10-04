#if RESET_CODE_ENTRY_TEST_HOST
import SwiftUI
import Foundation
import Combine

// This entry point belongs only to two isolated host targets. The original app
// entry points and their startup tasks are never linked into these executables.
@main
struct ResetCodeEntryTestApp: App {
    private let service: AuthService
    private let fixture: ResetCodeEntryFixture

    init() {
        fixture = .shared // Validate synthetic URL/case ownership before rendering.
        // Defensive process registration precedes construction of any view/default
        // service. The exercised reset instance also installs it explicitly below.
        guard URLProtocol.registerClass(ResetCodeEntryURLProtocol.self) else {
            fatalError("Cannot install isolated transport interceptor")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResetCodeEntryURLProtocol.self]
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        service = AuthService(session: URLSession(configuration: configuration))
    }

    var body: some Scene {
        WindowGroup {
            ResetCodeEntryHostRoot(service: service, fixture: fixture)
                .environmentObject(AuthState.shared) // Construction only; no auth checks or account methods.
                .preferredColorScheme(.dark)
        }
        #if os(macOS)
        Window("Synthetic transport", id: "fixture") {
            ResetCodeEntryDiagnostics(fixture: fixture)
        }
        .defaultSize(width: 360, height: 100)
        .defaultPosition(.topLeading)
        #endif
    }
}

private struct ResetCodeEntryHostRoot: View {
    let service: AuthService
    let fixture: ResetCodeEntryFixture
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            LoginView(passwordResetService: service)
            #else
            MacLoginView(passwordResetService: service)
                .frame(minWidth: 960, minHeight: 560)
            #endif
            #if os(iOS)
            ResetCodeEntryDiagnostics(fixture: fixture)
            #endif
        }
        #if os(macOS)
        .onAppear { openWindow(id: "fixture") }
        #endif
        // No production startup, analytics, StoreKit, ads, session checks,
        // migration, Keychain calls or proxy production actions here.
    }
}

private struct ResetCodeEntryDiagnostics: View {
    let fixture: ResetCodeEntryFixture
    @State private var snapshot = ""
    private let clock = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            Text("Synthetic transport receipts")
                .accessibilityIdentifier("fixture.receipts")
                .accessibilityValue(snapshot)
            Button("Release held transport") { fixture.releaseHeld() }
                .accessibilityIdentifier("fixture.release")
        }
        .font(.system(size: 10))
        .padding(4)
        .onReceive(clock) { _ in snapshot = fixture.snapshotJSON }
    }
}
#endif
