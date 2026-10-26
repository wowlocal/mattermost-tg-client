// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MattermostPush",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "MattermostPush", targets: ["MattermostPush"]),
    ],
    targets: [
        // Foundation and Security only: Bazel also builds this target for the app and the notification
        // service extension, so it must not gain dependencies or resources.
        .target(
            name: "MattermostPush",
            path: "Sources/MattermostPush"
        ),
        .testTarget(
            name: "MattermostPushTests",
            dependencies: ["MattermostPush"],
            path: "Tests/MattermostPushTests",
            // APNs payloads as the push proxy sends them (docs/research/push-payloads).
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
