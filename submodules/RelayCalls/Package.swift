// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "RelayCalls",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "RelayCallsCore", targets: ["RelayCallsCore"]),
        .library(name: "RelayCalls", targets: ["RelayCalls"]),
    ],
    dependencies: [.package(name: "LiveKit", path: "../../third-party/livekit-sdk")],
    targets: [
        .target(name: "RelayCallsCore"),
        .target(name: "RelayCalls", dependencies: ["RelayCallsCore", .product(name: "LiveKit", package: "LiveKit")]),
        .testTarget(name: "RelayCallsTests", dependencies: ["RelayCallsCore"]),
    ],
    swiftLanguageModes: [.v5]
)
