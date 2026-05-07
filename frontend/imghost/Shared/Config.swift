import Foundation

struct Config {
    static let appGroup = "group.com.imghost.shared"
    static let keychainService = "com.imghost"
    // Both the main app and share extension must use the SAME explicit keychain
    // access group so they can read each other's tokens.  When kSecAttrAccessGroup
    // is omitted (nil), the system defaults to the app's own application-identifier
    // (e.g. "67KC823C9A.com.codybontecou.imghost" vs
    // "67KC823C9A.com.codybontecou.imghost.ShareExtension"), which are DIFFERENT —
    // causing the share extension to think the user is not logged in.
    //
    // The value here must be the team-ID-prefixed form of the shared keychain
    // group declared in both targets' keychain-access-groups entitlement.
    static let keychainAccessGroup: String? = "67KC823C9A.group.com.imghost.shared"

    // Legacy access group used before this fix.  Kept only so the main app
    // can migrate tokens that were saved under the old (unprefixed) group.
    static let legacyKeychainAccessGroup: String? = "group.com.imghost.shared"

    // Keys for Keychain (legacy - kept for migration)
    static let uploadTokenKey = "uploadToken"

    // History file name
    static let historyFileName = "upload_history.json"
    static let maxHistoryCount = 100

    // Image processing
    static let maxUploadDimension: CGFloat = 4096
    static let thumbnailSize: CGFloat = 400
    static let thumbnailQuality: CGFloat = 0.85
    static let jpegQuality: CGFloat = 0.85
    
    // Upload limits
    static let maxUploadSizeBytes: Int64 = 500 * 1024 * 1024  // 500MB backend limit (Cloudflare Workers max)

    // Link Format Settings
    static let linkFormatKey = "linkFormat"
    static let customLinkFormatKey = "customLinkFormat"
    static let linkWidthKey = "linkWidth"

    // Upload Quality Settings
    static let uploadQualityKey = "uploadQuality"
    static let confirmBeforeUploadKey = "confirmBeforeUpload"

    // Shared UserDefaults
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    // Shared container URL
    static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    // MARK: - Backend Configuration

    /// Backend URL from build configuration
    static var backendURL: String {
        // Read from Info.plist (injected from xcconfig via BACKEND_URL build setting)
        if let url = Bundle.main.object(forInfoDictionaryKey: "BackendURL") as? String,
           !url.isEmpty {
            return url
        }
        // Fallback to hardcoded production URL if build config not set
        return "https://imghost.isolated.tech"
    }
}
