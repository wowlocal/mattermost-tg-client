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
        # Phase 3F: the share extension's posting (accounts, chats, planning, upload).
        "//submodules/MattermostShare:MattermostShare",
        "//submodules/WebPBinding:WebPBinding",
        # Phase 5A: voice recordings transcoded to AAC, waveforms of received voice messages (FFmpeg decoding).
        "//submodules/Media/ConvertOpusToAAC:ConvertOpusToAAC",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
    ],
    visibility = [
        "//visibility:public",
    ],
)
