load("@build_bazel_rules_apple//apple:apple.bzl", "apple_dynamic_xcframework_import")

apple_dynamic_xcframework_import(
    name = "RustLiveKitFFI",
    xcframework_imports = glob(["RustLiveKitFFI.xcframework/**"]),
    visibility = ["//visibility:public"],
)
