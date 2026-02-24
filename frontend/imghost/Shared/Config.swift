import Foundation

struct Config {
    static let appGroup = "group.com.imghost.shared"
    static let keychainService = "com.imghost"
    // On macOS, we must NOT set kSecAttrAccessGroup to the bare App Group ID
    // ("group.com.imghost.shared") because the security daemon only recognises
    // the team-ID-prefixed form ("67KC823C9A.group.com.imghost.shared").
    // Setting this to nil lets the system use the default access group, which
    // is the first entry in the keychain-access-groups entitlement — identical
    // for both the main app and its extensions, so items are shared correctly.
    static let keychainAccessGroup: String? = nil

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

    // Upload Quality Settings
    static let uploadQualityKey = "uploadQuality"

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
