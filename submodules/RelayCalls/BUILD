load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "RelayCallsCore",
    module_name = "RelayCallsCore",
    srcs = glob(["Sources/RelayCallsCore/**/*.swift"]),
    visibility = ["//visibility:public"],
)

swift_library(
    name = "RelayCalls",
    module_name = "RelayCalls",
    srcs = glob(["Sources/RelayCalls/**/*.swift"]),
    deps = [":RelayCallsCore", "//third-party/livekit-sdk:LiveKit"],
    visibility = ["//visibility:public"],
)
