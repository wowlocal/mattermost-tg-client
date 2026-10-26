// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MattermostShare",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "MattermostShare", targets: ["MattermostShare"]),
    ],
    dependencies: [
        .package(path: "../MattermostKit"),
        .package(path: "../MattermostSyncCore"),
    ],
    targets: [
        // Foundation only: Bazel builds this target for the app and the share extension (MattermostSync links it).
        .target(
            name: "MattermostShare",
            dependencies: [
                .product(name: "MattermostKit", package: "MattermostKit"),
                .product(name: "MattermostSyncCore", package: "MattermostSyncCore"),
            ],
            path: "Sources/MattermostShare"
        ),
        .testTarget(
            name: "MattermostShareTests",
            dependencies: ["MattermostShare"],
            path: "Tests/MattermostShareTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
