load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")

# Foundation only: the plugin client, events, models and the UI-free call controllers (RelayDirectCall,
# RelayGroupCall). MattermostSync depends on it; it must never depend on LiveKit.
swift_library(
    name = "RelayCallsCore",
    module_name = "RelayCallsCore",
    srcs = glob(["Sources/RelayCallsCore/**/*.swift"]),
    visibility = ["//visibility:public"],
)

# LiveKit: RelayRoomEngine (the controllers' media engine), the external camera, RelayVideoSink and the CallKit audio
# hooks; plus the first pass's SwiftUI call window (RelayCallSession, RelayCallView) until the adapters replace it.
swift_library(
    name = "RelayCalls",
    module_name = "RelayCalls",
    srcs = glob(["Sources/RelayCalls/**/*.swift"]),
    deps = [":RelayCallsCore", "//third-party/livekit-sdk:LiveKit"],
    visibility = ["//visibility:public"],
)

# Host (macOS) test of the Foundation-only core, the same suite as `swift test` in this directory.
# Run with `./build-input/bazel-9.2.0-darwin-arm64 test //submodules/RelayCalls:RelayCallsCoreTests`.
swift_test(
    name = "RelayCallsCoreTests",
    srcs = glob(["Tests/RelayCallsTests/**/*.swift"]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [":RelayCallsCore"],
)
