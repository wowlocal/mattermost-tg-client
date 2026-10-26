load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "MattermostSyncCore",
    module_name = "MattermostSyncCore",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        # SQLiteMattermostSyncStore uses Telegram's SQLCipher (`import sqlcipher`); SwiftPM builds
        # fall back to the system SQLite3 module. Never link the system libsqlite3 here.
        "//submodules/sqlcipher:sqlcipher",
    ],
    visibility = [
        "//visibility:public",
    ],
)
