// swift-tools-version: 5.9
import PackageDescription

// Production coordinator, AuthState, single-item session store and UI sources with deterministic
// network/Security.framework fault injection. No production calls or StoreKit transactions.
// Broader upload/StoreKit/lifecycle acceptance remains tracked in imghost issue 5.
let package = Package(
    name: "ImghostAccountConversion",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "AccountConversion", targets: ["AccountConversion"])],
    targets: [
        .target(name: "AccountConversion", path: "Shared", sources: [
            "AccountConversion", "Models/AuthState.swift", "Models/AuthResponse.swift", "Models/User.swift"
        ]),
        .testTarget(name: "AccountConversionTests", dependencies: ["AccountConversion"],
                    path: "Tests/AccountConversionTests")
    ]
)
