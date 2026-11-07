load("@build_bazel_rules_apple//apple:apple.bzl", "apple_dynamic_xcframework_import")

apple_dynamic_xcframework_import(
    name = "LiveKitWebRTC",
    xcframework_imports = glob(["LiveKitWebRTC.xcframework/**"]),
    visibility = ["//visibility:public"],
)
