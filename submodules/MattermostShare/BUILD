load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Phase 3F: sharing from other apps into Mattermost (the share extension): accounts on the device, the chat a
# Telegram peer stands for, the posts to make and their upload. Foundation only; MattermostSync adds the
# extension's glue (input items, Keychain token, progress as signals).
swift_library(
    name = "MattermostShare",
    module_name = "MattermostShare",
    srcs = glob([
        "Sources/MattermostShare/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/MattermostKit:MattermostKit",
        "//submodules/MattermostSyncCore:MattermostSyncCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)
