// AdManager.swift
//
// Manages Google AdMob banner and interstitial ads for the ad-supported free tier.
//
// Setup:
//   1. Add the Google Mobile Ads Swift Package to the project:
//      https://github.com/googleads/swift-package-manager-google-mobile-ads
//   2. Add your AdMob App ID to Info.plist under the key GADApplicationIdentifier
//   3. Set ADS_ENABLED = true in the active build configuration xcconfig
//   4. Replace the test IDs in AdUnitID with your real ones from AdMob console
//
// All ad calls are guarded with #if canImport(GoogleMobileAds) so the app
// compiles and runs cleanly before the SDK is installed.

import SwiftUI
import Combine

// ---------------------------------------------------------------------------
// Ad unit IDs
// ---------------------------------------------------------------------------

enum AdUnitID {
    // Replace with real IDs from AdMob console before shipping
    static let banner      = "ca-app-pub-3940256099942544/2934735716" // AdMob test banner
    static let interstitial = "ca-app-pub-3940256099942544/4411468910" // AdMob test interstitial
}

// ---------------------------------------------------------------------------
// AdManager — handles UMP consent and interstitial lifecycle
// ---------------------------------------------------------------------------

@MainActor
final class AdManager: ObservableObject {
    static let shared = AdManager()

    @Published private(set) var interstitialReady = false
    @Published private(set) var adsEnabled = false

    private init() {}

    /// Call once at app launch (before any ad requests).
    /// Handles ATT + UMP consent flow automatically.
    func initialize() {
#if canImport(GoogleMobileAds)
        // Request consent information update (handles ATT + GDPR)
        let parameters = UMPRequestParameters()
        parameters.tagForUnderAgeOfConsent = false

        UMPConsentInformation.sharedInstance.requestConsentInfoUpdate(with: parameters) { [weak self] error in
            guard error == nil else { return }
            Task { @MainActor in
                self?.presentConsentFormIfNeeded()
            }
        }
#endif
    }

#if canImport(GoogleMobileAds)
    private func presentConsentFormIfNeeded() {
        let status = UMPConsentInformation.sharedInstance.consentStatus
        guard status == .required else {
            startAds()
            return
        }

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = windowScene.windows.first?.rootViewController else { return }

        UMPConsentForm.loadAndPresentIfRequired(from: root) { [weak self] _ in
            Task { @MainActor in
                self?.startAds()
            }
        }
    }

    private func startAds() {
        GADMobileAds.sharedInstance().start { [weak self] _ in
            Task { @MainActor in
                self?.adsEnabled = true
                self?.loadInterstitial()
            }
        }
    }

    private var interstitialAd: GADInterstitialAd?

    func loadInterstitial() {
        let request = GADRequest()
        GADInterstitialAd.load(withAdUnitID: AdUnitID.interstitial, request: request) { [weak self] ad, error in
            Task { @MainActor [weak self] in
                self?.interstitialAd = ad
                self?.interstitialReady = error == nil
            }
        }
    }

    /// Show the interstitial if ready. Reloads a fresh one afterwards.
    func showInterstitialIfReady() {
        guard let ad = interstitialAd,
              let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = windowScene.windows.first?.rootViewController else { return }

        ad.present(fromRootViewController: root)
        interstitialAd = nil
        interstitialReady = false
        loadInterstitial() // Preload next
    }
#else
    func loadInterstitial() {}
    func showInterstitialIfReady() {}
#endif
}

// ---------------------------------------------------------------------------
// AdBannerView — drop-in SwiftUI banner wrapper
// ---------------------------------------------------------------------------

struct AdBannerView: View {
    var body: some View {
#if canImport(GoogleMobileAds)
        GADBannerRepresentable(adUnitID: AdUnitID.banner)
            .frame(height: 50)
#else
        EmptyView()
#endif
    }
}

#if canImport(GoogleMobileAds)
private struct GADBannerRepresentable: UIViewRepresentable {
    let adUnitID: String

    func makeUIView(context: Context) -> GADBannerView {
        let banner = GADBannerView(adSize: GADAdSizeBanner)
        banner.adUnitID = adUnitID
        banner.rootViewController = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first?.rootViewController }
            .first
        banner.load(GADRequest())
        return banner
    }

    func updateUIView(_ uiView: GADBannerView, context: Context) {}
}
#endif
