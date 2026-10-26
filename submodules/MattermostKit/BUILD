load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "MattermostKit",
    module_name = "MattermostKit",
    srcs = glob([
        "Sources/MattermostKit/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    visibility = [
        "//visibility:public",
    ],
)
