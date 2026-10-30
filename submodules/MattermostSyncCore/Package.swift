// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MattermostSyncCore",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "MattermostSyncCore", targets: ["MattermostSyncCore"]),
    ],
    dependencies: [
        // Telegram's SQLCipher, as in the iOS app (BUILD): in the macOS app this module and Postbox share one
        // SQLite module, the system SQLite3 next to sqlcipher's declarations doesn't compile.
        .package(name: "sqlcipher", path: "../sqlcipher"),
    ],
    targets: [
        .target(
            name: "MattermostSyncCore",
            dependencies: [
                .product(name: "sqlcipher", package: "sqlcipher"),
            ],
            path: "Sources/MattermostSyncCore"
        ),
        .testTarget(
            name: "MattermostSyncCoreTests",
            dependencies: ["MattermostSyncCore"],
            path: "Tests/MattermostSyncCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
