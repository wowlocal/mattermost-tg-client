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
    targets: [
        .target(
            name: "MattermostSyncCore",
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
