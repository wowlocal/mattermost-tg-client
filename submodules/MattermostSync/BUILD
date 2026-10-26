load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "MattermostSync",
    module_name = "MattermostSync",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/MattermostKit:MattermostKit",
        "//submodules/MattermostSyncCore:MattermostSyncCore",
        "//submodules/MattermostPush:MattermostPush",
        "//submodules/WebPBinding:WebPBinding",
    ],
    visibility = [
        "//visibility:public",
    ],
)
