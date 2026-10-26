load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Relay's own screens for the Mattermost backend: login (server, credentials, MFA, SSO), re-login after a
# session expires, and their debug driver. See docs/research/ui-inventory.md §4.
swift_library(
    name = "MattermostUI",
    module_name = "MattermostUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/AccountContext:AccountContext",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/SolidRoundedButtonNode:SolidRoundedButtonNode",
        "//submodules/CodeInputView:CodeInputView",
        "//submodules/OverlayStatusController:OverlayStatusController",
        "//submodules/ItemListUI:ItemListUI",
        # Phase 3D: live updates of the open member lists.
        "//submodules/TemporaryCachedPeerDataManager:TemporaryCachedPeerDataManager",
        # Phase 3B: the threads screen's avatars.
        "//submodules/AvatarNode:AvatarNode",
        # Phase 3D-2: the user and channel directories (peer rows, action rows, icons, channel naming rules).
        "//submodules/ItemListPeerItem:ItemListPeerItem",
        "//submodules/ItemListPeerActionItem:ItemListPeerActionItem",
        "//submodules/AppBundle:AppBundle",
        # Phase 3F: Do Not Disturb and custom status end dates.
        "//submodules/TelegramUI/Components/ItemListDatePickerItem:ItemListDatePickerItem",
        # Phase 4G: the passcode a managed configuration requires (setup, settings, debug).
        "//submodules/PasscodeUI:PasscodeUI",
        "//submodules/PasscodeCore:PasscodeCore",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/MattermostSyncCore:MattermostSyncCore",
        "//submodules/MattermostKit:MattermostKit",
        "//submodules/MattermostSync:MattermostSync",
        # Phase 3A: the debug remote's simulated push delivery.
        "//submodules/MattermostPush:MattermostPush",
        "//submodules/MattermostPushService:MattermostPushService",
    ],
    visibility = [
        "//visibility:public",
    ],
)
