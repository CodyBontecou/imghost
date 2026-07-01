import Foundation

/// Offline-safe, privacy-safe analytics for activation, paywall, and conversion debugging.
///
/// Privacy contract:
/// - Allowed: anonymous install ID, app/build version, platform, coarse onboarding step,
///   paywall context, subscription/tier state, product ID, purchase outcome, coarse upload
///   source/type/size buckets, and coarse error category.
/// - Prohibited: email, filenames, image URLs, delete URLs, file paths, user-entered text,
///   raw dates, IP addresses, device names, and any media contents.
nonisolated final class AppAnalytics: @unchecked Sendable {
    static let shared = AppAnalytics()

    private static let queueKey = "app.analytics.queue.v1"
    private static let installIDKey = "app.analytics.install_id.v1"
    private static let maxQueueSize = 100
    private static let retryDelayNanoseconds: UInt64 = 30_000_000_000

    private let state: AppAnalyticsClientState
    private let transport: AppAnalyticsTransport
    private let isEnabled: Bool

    init(
        defaults: UserDefaults = .standard,
        transport: AppAnalyticsTransport? = nil,
        isEnabled: Bool = AppAnalytics.defaultEnabled
    ) {
        self.isEnabled = isEnabled
        self.transport = transport ?? CloudflareAppAnalyticsTransport(
            installIDStore: AppAnalyticsInstallIDStore(defaults: defaults)
        )
        self.state = AppAnalyticsClientState(
            defaults: defaults,
            queueKey: Self.queueKey,
            maxQueueSize: Self.maxQueueSize,
            retryDelayNanoseconds: Self.retryDelayNanoseconds
        )
    }

    func track(_ eventName: AppAnalyticsEventName, properties: [String: String] = [:]) {
        guard isEnabled else { return }

        let payload = AppAnalyticsPayload(
            eventId: UUID().uuidString.lowercased(),
            eventName: eventName.rawValue,
            properties: Self.baseProperties().merging(properties) { _, new in new }
        )
        state.enqueue(payload)
        state.startFlushIfNeeded(transport: transport)
    }

    func flush() {
        guard isEnabled else { return }
        state.startFlushIfNeeded(transport: transport)
    }

    func flushAndWait() async {
        guard isEnabled else { return }
        await state.flushAndWait(transport: transport)
    }

    private static var defaultEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["APP_ANALYTICS_ENABLED"] == "1"
        #else
        true
        #endif
    }

    private static func baseProperties(bundle: Bundle = .main) -> [String: String] {
        var properties: [String: String] = ["platform": AppAnalyticsPlatform.current.rawValue]

        if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           AppAnalyticsSanitizer.isAppVersion(version) {
            properties["appVersion"] = version
        }

        if let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           AppAnalyticsSanitizer.isBuildNumber(build) {
            properties["buildNumber"] = build
        }

        return properties
    }
}

// MARK: - Typed event helpers

extension AppAnalytics {
    func trackAppLaunched() {
        track(.appLaunched)
    }

    func trackTabSelected(_ tab: AppAnalyticsTab) {
        track(.tabSelected, properties: ["tab": tab.rawValue])
    }

    func trackOnboardingStarted(step: AppAnalyticsOnboardingStep) {
        track(.onboardingStarted, properties: ["onboardingStep": step.rawValue])
    }

    func trackOnboardingStepViewed(_ step: AppAnalyticsOnboardingStep) {
        track(.onboardingStepViewed, properties: ["onboardingStep": step.rawValue])
    }

    func trackOnboardingSkipped(step: AppAnalyticsOnboardingStep) {
        track(.onboardingSkipped, properties: ["onboardingStep": step.rawValue])
    }

    func trackOnboardingCompleted(step: AppAnalyticsOnboardingStep = .startFree) {
        track(.onboardingCompleted, properties: ["onboardingStep": step.rawValue])
    }

    func trackAuthScreenViewed(method: AppAnalyticsAuthMethod) {
        track(.authScreenViewed, properties: ["authMethod": method.rawValue])
    }

    func trackAuthStarted(method: AppAnalyticsAuthMethod) {
        track(.authStarted, properties: [
            "authMethod": method.rawValue,
            "authOutcome": AppAnalyticsAuthOutcome.started.rawValue,
        ])
    }

    func trackAuthFinished(method: AppAnalyticsAuthMethod, outcome: AppAnalyticsAuthOutcome, error: Error? = nil) {
        var properties = [
            "authMethod": method.rawValue,
            "authOutcome": outcome.rawValue,
        ]
        if let error {
            properties["errorCategory"] = AppAnalyticsErrorCategory(error).rawValue
        }
        track(.authFinished, properties: properties)
    }

    func trackSubscriptionStatus(status: AppAnalyticsSubscriptionStatus, tier: String, trialDaysRemaining: Int?) {
        track(.subscriptionStatusChecked, properties: [
            "subscriptionStatus": status.rawValue,
            "tier": AppAnalyticsTier(tier).rawValue,
            "trialDaysBucket": AppAnalyticsTrialDaysBucket(daysRemaining: trialDaysRemaining).rawValue,
        ])
    }

    func trackSubscriptionStatusError(_ error: Error) {
        track(.subscriptionStatusChecked, properties: [
            "subscriptionStatus": AppAnalyticsSubscriptionStatus.error.rawValue,
            "tier": AppAnalyticsTier.unknown.rawValue,
            "trialDaysBucket": AppAnalyticsTrialDaysBucket.none.rawValue,
            "errorCategory": AppAnalyticsErrorCategory(error).rawValue,
        ])
    }

    func trackSettingsUpgradeTapped(context: AppAnalyticsPaywallContext = .settings, status: AppAnalyticsSubscriptionStatus? = nil, tier: String? = nil) {
        var properties: [String: String] = [
            "paywallContext": context.rawValue,
            "cta": AppAnalyticsCTA.upgrade.rawValue,
        ]
        if let status { properties["subscriptionStatus"] = status.rawValue }
        if let tier { properties["tier"] = AppAnalyticsTier(tier).rawValue }
        track(.settingsUpgradeTapped, properties: properties)
    }

    func trackPaywallShown(context: AppAnalyticsPaywallContext, status: AppAnalyticsSubscriptionStatus? = nil, tier: String? = nil) {
        var properties: [String: String] = ["paywallContext": context.rawValue]
        if let status { properties["subscriptionStatus"] = status.rawValue }
        if let tier { properties["tier"] = AppAnalyticsTier(tier).rawValue }
        track(.paywallShown, properties: properties)
    }

    func trackPaywallTierSelected(_ tier: String, context: AppAnalyticsPaywallContext) {
        track(.paywallTierSelected, properties: [
            "tier": AppAnalyticsTier(tier).rawValue,
            "paywallContext": context.rawValue,
        ])
    }

    func trackPaywallBillingSelected(_ period: AppAnalyticsBillingPeriod, context: AppAnalyticsPaywallContext) {
        track(.paywallBillingSelected, properties: [
            "billingPeriod": period.rawValue,
            "paywallContext": context.rawValue,
        ])
    }

    func trackPaywallCTATapped(_ cta: AppAnalyticsCTA, productId: String?, billingPeriod: AppAnalyticsBillingPeriod, context: AppAnalyticsPaywallContext) {
        track(.paywallCTATapped, properties: [
            "cta": cta.rawValue,
            "productId": AppAnalyticsProductID(productId).rawValue,
            "billingPeriod": billingPeriod.rawValue,
            "paywallContext": context.rawValue,
        ])
    }

    func trackPaywallContinueFreeTapped(context: AppAnalyticsPaywallContext) {
        track(.paywallContinueFreeTapped, properties: [
            "cta": AppAnalyticsCTA.continueFree.rawValue,
            "paywallContext": context.rawValue,
        ])
    }

    func trackPurchaseStarted(productId: String?) {
        track(.purchaseStarted, properties: [
            "productId": AppAnalyticsProductID(productId).rawValue,
            "billingPeriod": AppAnalyticsBillingPeriod(productId: productId).rawValue,
            "purchaseOutcome": AppAnalyticsPurchaseOutcome.started.rawValue,
        ])
    }

    func trackPurchaseFinished(productId: String?, outcome: AppAnalyticsPurchaseOutcome, error: Error? = nil) {
        var properties: [String: String] = [
            "productId": AppAnalyticsProductID(productId).rawValue,
            "billingPeriod": AppAnalyticsBillingPeriod(productId: productId).rawValue,
            "purchaseOutcome": outcome.rawValue,
        ]
        if let error {
            properties["errorCategory"] = AppAnalyticsErrorCategory(error).rawValue
        }
        track(.purchaseFinished, properties: properties)
    }

    func trackRestoreStarted() {
        track(.restoreStarted, properties: [
            "cta": AppAnalyticsCTA.restore.rawValue,
            "purchaseOutcome": AppAnalyticsPurchaseOutcome.started.rawValue,
        ])
    }

    func trackRestoreFinished(outcome: AppAnalyticsPurchaseOutcome, error: Error? = nil) {
        var properties: [String: String] = [
            "cta": AppAnalyticsCTA.restore.rawValue,
            "purchaseOutcome": outcome.rawValue,
        ]
        if let error {
            properties["errorCategory"] = AppAnalyticsErrorCategory(error).rawValue
        }
        track(.restoreFinished, properties: properties)
    }

    func trackUploadSourceSelected(_ source: AppAnalyticsUploadSource) {
        track(.uploadSourceSelected, properties: ["uploadSource": source.rawValue])
    }

    func trackUploadConfirmed(source: AppAnalyticsUploadSource, filename: String? = nil, byteCount: Int? = nil) {
        track(.uploadConfirmed, properties: uploadProperties(source: source, outcome: nil, filename: filename, byteCount: byteCount))
    }

    func trackUploadStarted(source: AppAnalyticsUploadSource, filename: String? = nil, byteCount: Int? = nil) {
        track(.uploadStarted, properties: uploadProperties(source: source, outcome: .started, filename: filename, byteCount: byteCount))
    }

    func trackUploadFinished(source: AppAnalyticsUploadSource, filename: String? = nil, byteCount: Int? = nil) {
        track(.uploadFinished, properties: uploadProperties(source: source, outcome: .succeeded, filename: filename, byteCount: byteCount))
    }

    func trackUploadFailed(source: AppAnalyticsUploadSource, error: Error, filename: String? = nil, byteCount: Int? = nil) {
        var properties = uploadProperties(source: source, outcome: .failed, filename: filename, byteCount: byteCount)
        properties["errorCategory"] = AppAnalyticsErrorCategory(error).rawValue
        let event: AppAnalyticsEventName = AppAnalyticsErrorCategory(error).isUploadLimit ? .uploadLimitHit : .uploadFailed
        track(event, properties: properties)
    }

    private func uploadProperties(
        source: AppAnalyticsUploadSource,
        outcome: AppAnalyticsUploadOutcome?,
        filename: String?,
        byteCount: Int?
    ) -> [String: String] {
        var properties: [String: String] = [
            "uploadSource": source.rawValue,
            "fileTypeGroup": AppAnalyticsFileTypeGroup(filename: filename).rawValue,
            "fileSizeBucket": AppAnalyticsFileSizeBucket(byteCount: byteCount).rawValue,
        ]
        if let outcome {
            properties["uploadOutcome"] = outcome.rawValue
        }
        return properties
    }
}

// MARK: - Event model

nonisolated enum AppAnalyticsEventName: String, Sendable {
    case appLaunched = "app_launched"
    case tabSelected = "tab_selected"
    case onboardingStarted = "onboarding_started"
    case onboardingStepViewed = "onboarding_step_viewed"
    case onboardingSkipped = "onboarding_skipped"
    case onboardingCompleted = "onboarding_completed"
    case authScreenViewed = "auth_screen_viewed"
    case authStarted = "auth_started"
    case authFinished = "auth_finished"
    case subscriptionStatusChecked = "subscription_status_checked"
    case settingsUpgradeTapped = "settings_upgrade_tapped"
    case paywallShown = "paywall_shown"
    case paywallTierSelected = "paywall_tier_selected"
    case paywallBillingSelected = "paywall_billing_selected"
    case paywallCTATapped = "paywall_cta_tapped"
    case paywallContinueFreeTapped = "paywall_continue_free_tapped"
    case purchaseStarted = "purchase_started"
    case purchaseFinished = "purchase_finished"
    case restoreStarted = "restore_started"
    case restoreFinished = "restore_finished"
    case uploadSourceSelected = "upload_source_selected"
    case uploadConfirmed = "upload_confirmed"
    case uploadStarted = "upload_started"
    case uploadFinished = "upload_finished"
    case uploadFailed = "upload_failed"
    case uploadLimitHit = "upload_limit_hit"
    case exportStarted = "export_started"
    case exportFinished = "export_finished"
}

nonisolated struct AppAnalyticsPayload: Codable, Equatable, Sendable {
    let eventId: String
    let eventName: String
    let properties: [String: String]
}

nonisolated enum AppAnalyticsPlatform: String, Sendable {
    case iOS = "ios"
    case macOS = "macos"

    static var current: AppAnalyticsPlatform {
        #if os(macOS)
        return .macOS
        #else
        return .iOS
        #endif
    }
}

nonisolated enum AppAnalyticsOnboardingStep: String, CaseIterable, Sendable {
    case hostImages = "host_images"
    case shareAnywhere = "share_anywhere"
    case directLinks = "direct_links"
    case organized = "organized"
    case startFree = "start_free"

    static func step(forPage index: Int) -> AppAnalyticsOnboardingStep {
        switch index {
        case 0: return .hostImages
        case 1: return .shareAnywhere
        case 2: return .directLinks
        case 3: return .organized
        default: return .startFree
        }
    }
}

nonisolated enum AppAnalyticsTab: String, Sendable {
    case media
    case upload
    case settings

    init(index: Int) {
        switch index {
        case 1: self = .upload
        case 2: self = .settings
        default: self = .media
        }
    }
}

nonisolated enum AppAnalyticsPaywallContext: String, Sendable {
    case onboarding
    case settings
    case postAuth = "post_auth"
    case subscriptionGate = "subscription_gate"
    case uploadLimit = "upload_limit"
    case exportLimit = "export_limit"
    case unknown
}

nonisolated enum AppAnalyticsSubscriptionStatus: String, Sendable {
    case loading
    case free
    case noSubscription = "no_subscription"
    case trialing
    case trialExpired = "trial_expired"
    case subscribed
    case expired
    case cancelled
    case error

    init(rawStatus: String) {
        switch rawStatus {
        case Self.loading.rawValue: self = .loading
        case Self.free.rawValue: self = .free
        case Self.noSubscription.rawValue: self = .noSubscription
        case Self.trialing.rawValue: self = .trialing
        case Self.trialExpired.rawValue: self = .trialExpired
        case Self.subscribed.rawValue: self = .subscribed
        case Self.expired.rawValue: self = .expired
        case Self.cancelled.rawValue: self = .cancelled
        default: self = .error
        }
    }
}

nonisolated enum AppAnalyticsTier: String, Sendable {
    case free
    case trial
    case pro
    case enterprise
    case ultimate
    case unknown

    init(_ tier: String?) {
        switch tier {
        case "free": self = .free
        case "trial": self = .trial
        case "pro": self = .pro
        case "enterprise": self = .enterprise
        case "ultimate": self = .ultimate
        default: self = .unknown
        }
    }
}

nonisolated enum AppAnalyticsTrialDaysBucket: String, Sendable {
    case none
    case zero = "0"
    case oneToThree = "1_3"
    case fourToSeven = "4_7"
    case eightToFourteen = "8_14"
    case fifteenPlus = "15_plus"

    init(daysRemaining: Int?) {
        guard let daysRemaining else {
            self = .none
            return
        }
        switch daysRemaining {
        case ...0: self = .zero
        case 1...3: self = .oneToThree
        case 4...7: self = .fourToSeven
        case 8...14: self = .eightToFourteen
        default: self = .fifteenPlus
        }
    }
}

nonisolated enum AppAnalyticsProductID: String, Sendable {
    case starterMonthly = "imghost.pro.monthly"
    case starterYearly = "imghost.pro.yearly"
    case proMonthly = "imghost.enterprise.monthly"
    case proYearly = "imghost.enterprise.yearly"
    case ultimateMonthly = "imghost.ultimate.monthly"
    case ultimateYearly = "imghost.ultimate.yearly"
    case unknown

    init(_ productId: String?) {
        switch productId {
        case Self.starterMonthly.rawValue: self = .starterMonthly
        case Self.starterYearly.rawValue: self = .starterYearly
        case Self.proMonthly.rawValue: self = .proMonthly
        case Self.proYearly.rawValue: self = .proYearly
        case Self.ultimateMonthly.rawValue: self = .ultimateMonthly
        case Self.ultimateYearly.rawValue: self = .ultimateYearly
        default: self = .unknown
        }
    }
}

nonisolated enum AppAnalyticsBillingPeriod: String, Sendable {
    case monthly
    case yearly
    case unknown

    init(productId: String?) {
        guard let productId else {
            self = .unknown
            return
        }
        if productId.hasSuffix(".yearly") {
            self = .yearly
        } else if productId.hasSuffix(".monthly") {
            self = .monthly
        } else {
            self = .unknown
        }
    }
}

nonisolated enum AppAnalyticsPurchaseOutcome: String, Sendable {
    case started
    case succeeded
    case failed
    case cancelled
    case pending
}

nonisolated enum AppAnalyticsAuthMethod: String, Sendable {
    case emailLogin = "email_login"
    case emailRegister = "email_register"
    case apple
    case anonymous
    case unknown
}

nonisolated enum AppAnalyticsAuthOutcome: String, Sendable {
    case started
    case succeeded
    case failed
}

nonisolated enum AppAnalyticsUploadSource: String, Sendable {
    case photoLibrary = "photo_library"
    case filePicker = "file_picker"
    case dragDrop = "drag_drop"
    case paste
    case shareExtension = "share_extension"
    case macShareExtension = "mac_share_extension"
    case unknown
}

nonisolated enum AppAnalyticsUploadOutcome: String, Sendable {
    case started
    case succeeded
    case failed
    case cancelled
    case blocked
}

nonisolated enum AppAnalyticsFileTypeGroup: String, Sendable {
    case image
    case video
    case audio
    case pdf
    case archive
    case text
    case document
    case other
    case unknown

    init(filename: String?) {
        guard let ext = filename?.split(separator: ".").last?.lowercased() else {
            self = .unknown
            return
        }

        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg", "ico": self = .image
        case "mov", "mp4", "m4v", "avi", "webm": self = .video
        case "mp3", "wav", "aiff", "m4a", "aac", "flac": self = .audio
        case "pdf": self = .pdf
        case "zip", "gz", "gzip", "tar", "rar", "7z": self = .archive
        case "txt", "md", "rtf", "html", "css", "js", "json", "xml": self = .text
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx": self = .document
        default: self = .other
        }
    }
}

nonisolated enum AppAnalyticsFileSizeBucket: String, Sendable {
    case unknown
    case zeroToOneMB = "0_1mb"
    case oneToFiveMB = "1_5mb"
    case fiveToFiftyMB = "5_50mb"
    case fiftyToOneHundredMB = "50_100mb"
    case oneHundredToFiveHundredMB = "100_500mb"
    case fiveHundredMBPlus = "500mb_plus"

    init(byteCount: Int?) {
        guard let byteCount else {
            self = .unknown
            return
        }

        switch byteCount {
        case ..<1_000_000: self = .zeroToOneMB
        case ..<5_000_000: self = .oneToFiveMB
        case ..<50_000_000: self = .fiveToFiftyMB
        case ..<100_000_000: self = .fiftyToOneHundredMB
        case ..<500_000_000: self = .oneHundredToFiveHundredMB
        default: self = .fiveHundredMBPlus
        }
    }
}

nonisolated enum AppAnalyticsErrorCategory: String, Sendable {
    case network
    case auth
    case subscriptionRequired = "subscription_required"
    case freeFileSize = "free_file_size"
    case freeDailyLimit = "free_daily_limit"
    case freeStorageFull = "free_storage_full"
    case storeUnavailable = "store_unavailable"
    case paymentNotAllowed = "payment_not_allowed"
    case verificationFailed = "verification_failed"
    case userCancelled = "user_cancelled"
    case configuration
    case server
    case unknown

    init(_ error: Error) {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost:
                self = .network
            default:
                self = .server
            }
            return
        }

        if let imghostError = error as? ImghostError {
            switch imghostError {
            case .notConfigured, .invalidURL, .invalidResponse:
                self = .configuration
            case .subscriptionRequired:
                self = .subscriptionRequired
            case .emailVerificationRequired:
                self = .auth
            case .freeTierFileSizeExceeded:
                self = .freeFileSize
            case .freeTierDailyLimitReached:
                self = .freeDailyLimit
            case .freeTierStorageFull:
                self = .freeStorageFull
            case .uploadFailed(let statusCode, _):
                if statusCode == 401 || statusCode == 403 { self = .auth }
                else if statusCode >= 500 { self = .server }
                else { self = .unknown }
            default:
                self = .unknown
            }
            return
        }

        if let authError = error as? AuthError {
            switch authError {
            case .networkError:
                self = .network
            case .noRefreshToken, .refreshFailed, .invalidCredentials, .accountSuspended, .invalidToken, .tokenExpired, .sessionExpired, .notAuthenticated, .alreadyVerified:
                self = .auth
            case .serverError, .tooManyRequests, .emailAlreadyRegistered:
                self = .server
            }
            return
        }

        self = .unknown
    }

    var isUploadLimit: Bool {
        switch self {
        case .freeFileSize, .freeDailyLimit, .freeStorageFull, .subscriptionRequired:
            return true
        default:
            return false
        }
    }
}

nonisolated enum AppAnalyticsCTA: String, Sendable {
    case subscribe
    case restore
    case continueFree = "continue_free"
    case upgrade
    case retry
    case unknown
}

// MARK: - Transport

nonisolated protocol AppAnalyticsTransport: Sendable {
    func send(_ payload: AppAnalyticsPayload) async throws
}

nonisolated enum AppAnalyticsTransportError: Error, Equatable, Sendable {
    case permanentPayloadRejection(statusCode: Int)
}

nonisolated final class CloudflareAppAnalyticsTransport: AppAnalyticsTransport, @unchecked Sendable {
    private let endpointURL: URL
    private let installIDStore: AppAnalyticsInstallIDStore
    private let session: URLSession

    init(
        endpointURL: URL? = URL(string: Config.backendURL)?.appendingPathComponent("v1").appendingPathComponent("events"),
        installIDStore: AppAnalyticsInstallIDStore = AppAnalyticsInstallIDStore(),
        session: URLSession = .shared
    ) {
        self.endpointURL = endpointURL ?? URL(string: "https://imghost.isolated.tech/v1/events")!
        self.installIDStore = installIDStore
        self.session = session
    }

    func send(_ payload: AppAnalyticsPayload) async throws {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        request.httpBody = try JSONEncoder().encode(AppAnalyticsIngestEnvelope(
            installId: installIDStore.installID(),
            events: [payload]
        ))

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if (200..<300).contains(httpResponse.statusCode) {
            return
        }

        if httpResponse.statusCode == 400 || httpResponse.statusCode == 413 {
            throw AppAnalyticsTransportError.permanentPayloadRejection(statusCode: httpResponse.statusCode)
        }

        throw URLError(.badServerResponse)
    }
}

nonisolated private struct AppAnalyticsIngestEnvelope: Encodable {
    let installId: String
    let events: [AppAnalyticsPayload]
}

nonisolated final class AppAnalyticsInstallIDStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let queue = DispatchQueue(label: "com.codybontecou.imghost.app-analytics-install-id")

    init(defaults: UserDefaults = .standard, key: String = "app.analytics.install_id.v1") {
        self.defaults = defaults
        self.key = key
    }

    func installID() -> String {
        queue.sync {
            if let existing = defaults.string(forKey: key), UUID(uuidString: existing) != nil {
                return existing.lowercased()
            }

            let generated = UUID().uuidString.lowercased()
            defaults.set(generated, forKey: key)
            return generated
        }
    }
}

// MARK: - Queueing

nonisolated private final class AppAnalyticsClientState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.codybontecou.imghost.app-analytics-client")
    private let defaults: UserDefaults
    private let queueKey: String
    private let maxQueueSize: Int
    private let retryDelayNanoseconds: UInt64

    private var payloads: [AppAnalyticsPayload]
    private var flushTask: Task<Void, Never>?

    init(defaults: UserDefaults, queueKey: String, maxQueueSize: Int, retryDelayNanoseconds: UInt64) {
        self.defaults = defaults
        self.queueKey = queueKey
        self.maxQueueSize = max(0, maxQueueSize)
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.payloads = Self.load(defaults: defaults, queueKey: queueKey)
        trimToQueueCap()
        save()
    }

    func enqueue(_ payload: AppAnalyticsPayload) {
        queue.sync {
            payloads.append(payload)
            trimToQueueCap()
            save()
        }
    }

    func startFlushIfNeeded(transport: AppAnalyticsTransport) {
        queue.sync {
            guard flushTask == nil else { return }

            flushTask = Task.detached(priority: .utility) { [weak self, transport] in
                await self?.flushLoop(transport: transport)
            }
        }
    }

    func flushAndWait(transport: AppAnalyticsTransport) async {
        startFlushIfNeeded(transport: transport)
        let task = queue.sync { flushTask }
        await task?.value
    }

    private func flushLoop(transport: AppAnalyticsTransport) async {
        var stoppedAfterFailure = false

        while let payload = nextPayload() {
            do {
                try await transport.send(payload)
                removeSentPayload(payload)
            } catch let error as AppAnalyticsTransportError {
                switch error {
                case .permanentPayloadRejection:
                    removeSentPayload(payload)
                    continue
                }
            } catch {
                stoppedAfterFailure = true
                break
            }
        }

        queue.sync {
            if payloads.isEmpty {
                flushTask = nil
            } else if stoppedAfterFailure, retryDelayNanoseconds > 0 {
                flushTask = Task.detached(priority: .utility) { [weak self, transport, retryDelayNanoseconds] in
                    try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                    await self?.flushLoop(transport: transport)
                }
            } else if stoppedAfterFailure {
                flushTask = nil
            } else {
                flushTask = Task.detached(priority: .utility) { [weak self, transport] in
                    await self?.flushLoop(transport: transport)
                }
            }
        }
    }

    private func nextPayload() -> AppAnalyticsPayload? {
        queue.sync { payloads.first }
    }

    private func removeSentPayload(_ payload: AppAnalyticsPayload) {
        queue.sync {
            guard payloads.first == payload else { return }
            payloads.removeFirst()
            save()
        }
    }

    private func trimToQueueCap() {
        guard maxQueueSize > 0 else {
            payloads.removeAll()
            return
        }

        if payloads.count > maxQueueSize {
            payloads.removeFirst(payloads.count - maxQueueSize)
        }
    }

    private func save() {
        guard !payloads.isEmpty else {
            defaults.removeObject(forKey: queueKey)
            return
        }

        if let data = try? JSONEncoder().encode(payloads) {
            defaults.set(data, forKey: queueKey)
        }
    }

    private static func load(defaults: UserDefaults, queueKey: String) -> [AppAnalyticsPayload] {
        guard let data = defaults.data(forKey: queueKey) else { return [] }
        return (try? JSONDecoder().decode([AppAnalyticsPayload].self, from: data)) ?? []
    }
}

nonisolated private enum AppAnalyticsSanitizer {
    static func isAppVersion(_ value: String) -> Bool {
        value.range(of: #"^\d+(?:\.\d+){0,3}$"#, options: .regularExpression) != nil
    }

    static func isBuildNumber(_ value: String) -> Bool {
        value.range(of: #"^\d{1,12}$"#, options: .regularExpression) != nil
    }
}
