// swift-tools-version:5.9
import PackageDescription

// The macOS client (relay-mac) builds this module with SwiftPM; the iOS app builds it with Bazel (BUILD).
// iOS-only dependencies (WebPBinding, ConvertOpusToAAC, UniversalMediaPlayer) stay out: the code that uses them
// is behind `#if os(iOS)`, and WebP comes from the macOS app's libwebp instead.
let package = Package(
    name: "MattermostSync",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "MattermostSync", targets: ["MattermostSync"]),
    ],
    dependencies: [
        .package(name: "SSignalKit", path: "../SSignalKit"),
        .package(name: "Postbox", path: "../Postbox"),
        .package(name: "TelegramCore", path: "../TelegramCore"),
        .package(name: "MattermostKit", path: "../MattermostKit"),
        .package(name: "MattermostSyncCore", path: "../MattermostSyncCore"),
        .package(name: "MattermostPush", path: "../MattermostPush"),
        .package(name: "MattermostShare", path: "../MattermostShare"),
        // The macOS app's WebP (relay-mac/submodules/libwebp), used by MattermostPlatformImage.
        .package(name: "libwebp", path: "../../../libwebp"),
    ],
    targets: [
        .target(
            name: "MattermostSync",
            dependencies: [
                .product(name: "SwiftSignalKit", package: "SSignalKit"),
                .product(name: "Postbox", package: "Postbox"),
                .product(name: "TelegramCore", package: "TelegramCore"),
                .product(name: "MattermostKit", package: "MattermostKit"),
                .product(name: "MattermostSyncCore", package: "MattermostSyncCore"),
                .product(name: "MattermostPush", package: "MattermostPush"),
                .product(name: "MattermostShare", package: "MattermostShare"),
                .product(name: "libwebp", package: "libwebp"),
            ],
            path: "Sources"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
