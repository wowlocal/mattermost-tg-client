// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MattermostKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "MattermostKit", targets: ["MattermostKit"]),
    ],
    targets: [
        // Foundation only: this target is also compiled by Bazel inside the
        // Telegram-iOS build, so it must not gain dependencies or resources.
        .target(
            name: "MattermostKit",
            path: "Sources/MattermostKit"
        ),
        .testTarget(
            name: "MattermostKitTests",
            dependencies: ["MattermostKit"],
            path: "Tests/MattermostKitTests",
            // Real responses recorded from the dev server
            // (infra/dev-server/capture-fixtures.py), copied here.
            resources: [.copy("Fixtures/Captured")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
