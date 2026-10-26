load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Mattermost push notifications without Telegram code: the APNs payload the push proxy sends, the account a
# push belongs to, the notification text, device ids for `PUT /users/sessions/device`, and the session
# tokens in the shared Keychain group. Used by the app (MattermostSync, TelegramUI) and by the notification
# service extension. Tests: `swift test` in this directory.
swift_library(
    name = "MattermostPush",
    module_name = "MattermostPush",
    srcs = glob([
        "Sources/MattermostPush/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    visibility = [
        "//visibility:public",
    ],
)
