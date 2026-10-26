load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Relay's notification service for Mattermost pushes: account routing, acknowledgement, text, communication
# notification with the sender's picture (MattermostPushServiceHandler.swift). Run by the notification
# service extension, and by debug builds of the app to deliver pushes on a simulator.
swift_library(
    name = "MattermostPushService",
    module_name = "MattermostPushService",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AppLockState:AppLockState",
        "//submodules/NotificationsPresentationData:NotificationsPresentationData",
        "//submodules/MattermostKit:MattermostKit",
        "//submodules/MattermostSyncCore:MattermostSyncCore",
        "//submodules/MattermostPush:MattermostPush",
    ],
    visibility = [
        "//visibility:public",
    ],
)
