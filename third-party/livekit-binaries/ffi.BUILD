load("@build_bazel_rules_apple//apple:apple.bzl", "apple_static_xcframework_import")

apple_static_xcframework_import(
    name = "RustLiveKitFFI",
    xcframework_imports = glob(["RustLiveKitFFI.xcframework/**"]),
    sdk_frameworks = ["Security", "SystemConfiguration"],
    sdk_dylibs = ["c++"],
    visibility = ["//visibility:public"],
)
