// swift-tools-version: 5.9
import PackageDescription

// Small isolated service test target; no SDK, app assets, StoreKit transactions or production calls.
// Broader AuthState/upload/subscription testability remains tracked in imghost issue 5.
let package = Package(
    name: "ImghostAccountConversion",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "AccountConversion", targets: ["AccountConversion"])],
    targets: [
        .target(name: "AccountConversion", path: "Shared/AccountConversion"),
        .testTarget(name: "AccountConversionTests", dependencies: ["AccountConversion"],
                    path: "Tests/AccountConversionTests")
    ]
)
