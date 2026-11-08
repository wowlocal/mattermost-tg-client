# Relay for macOS

Relay for macOS is Telegram for macOS (TelegramMessenger/telegram-macos) with this repository as its
`submodules/telegram-ios`, the way the iOS app is Telegram-iOS with these modules: the data layer is shared
(MattermostKit, MattermostSyncCore, MattermostSync, and the TelegramCore hooks), the UI is the macOS app's own
(AppKit, TGUIKit), so everything in `MattermostUI` and the TelegramUI patches is redone there.

## Checkout

- macOS app: [wowlocal/relay-mac](https://github.com/wowlocal/relay-mac) (`main`; locally `~/Developer/relay-mac`, branch `relay`, `upstream` is telegram-macos), telegram-macos at `d19f811484` (2026-10-09). That commit pins Telegram-iOS
  `5bb60920e2`, 14 commits before this fork's upstream base `5c20d095d1`; TelegramCore and Postbox differ in three
  files between them, so the app compiles against this fork with no merge. (telegram-macos `master` already pins
  a Telegram-iOS 307 commits newer; moving to it means merging upstream here first.)
- `submodules/telegram-ios` is a worktree of this repository on the `macos` branch. Its nested submodules are
  cloned from the main checkout (`git -c protocol.file.allow=always submodule update --init …`); only the ones the
  macOS build uses: td, dav1d, libvpx, webrtc, wallet-engine, mtproto-engine, tgcalls, rlottie, tlottie.
- `submodules/tgcalls` is the public `6926af0` (2026-05-16), the commit telegram-macos `master` pins:
  `d19f811484` pins one that is not public, and this fork's tgcalls (`a024eaa`) carries the wasm call core, whose
  WAMR headers the macOS package has no path to (and its `tools/` testbench has a `main()` SwiftPM reads as an
  executable target).
- Xcode 27: `scripts/xcode27.sh apply` (deployment target 12.0 in the library projects, `ImplicitStrongCapture` a
  warning in TelegramCore, Metal shaders compiled), and the abseil `ABSL_ATTRIBUTE_LIFETIME_BOUND` patch in tg_owt
  that `scripts/setup_build_env.sh` applies. Homebrew no longer has `openssl@1.1`; the libraries build without it.
- Native libraries: `scripts/configure_frameworks.sh` with `PATH` including `/opt/homebrew/opt/rustup/bin` (cargo
  from Homebrew's rustup), `RUSTUP_TOOLCHAIN=1.96.1` and `CMAKE_POLICY_VERSION_MINIMUM=3.5`. Three traps:
  - The engines' build scripts run the pinned toolchain's `cargo` directly, so `rustc` comes from the rustup proxy,
    which picks the default toolchain in a dependency's directory; proc macros built by another rustc fail with
    "can't find crate for `zeroize_derive`". `RUSTUP_TOOLCHAIN` makes both the same.
  - Inside Xcode's environment the wallet engine's proc-macro dylibs don't load ("mis-aligned LINKEDIT string
    pool"); its standalone script outside Xcode builds it (INSTALL.md "Rebuilding only the wallet engine"), and the
    frameworks script then adopts the output.
  - `scripts/xcode27.sh` doesn't know `core-xprojects/mtproto-engine`: its deployment target goes to 12.0 by hand.

## Modules on macOS

| Module | macOS |
|---|---|
| MattermostKit, MattermostSyncCore, MattermostPush, MattermostShare | SwiftPM manifests already (macOS 13) |
| MattermostSync | `Package.swift` for SwiftPM. Drawing (group pictures, reaction images, flattened photos) goes through `MattermostPlatformImage` (UIKit on iOS, AppKit and the macOS app's libwebp on macOS); voice transcoding and waveform decoding are iOS-only for now (macOS sends the Ogg recording) |
| TelegramCore hooks (`Sources/Mattermost`, `MattermostBackend`, `NullNetworkEngine`) | compiled with the app's TelegramCore package |
| MattermostUI and TelegramUI patches | redone in the macOS app |

The macOS app needs macOS 13 (the Mattermost packages' minimum).

## In the app (wowlocal/relay-mac)

Mostly as in this repository's iOS app, at the matching places of the macOS app:

- `SharedAccountContext` starts `MattermostSync.startAccount` instead of Telegram's state management and
  `MattermostSync.startLifecycle` at launch; debug builds log in from `RELAY_DEBUG_MM_URL`/`_LOGIN`/`_PASSWORD`.
- `UnauthorizedApplicationContext` shows `RelayLoginController` (package `RelayUI`: server, login id, password, MFA
  code), which creates the account on the auth record with `MattermostAccountSetup`.
- Mattermost files and avatars load through `relayFetchResource` in TelegramMediaUtils' fetch hook;
  `mattermostDeclareEncodables` runs at launch.
- The connection status, the chat header and the wakeup manager read `Account.externalIsUpdating` (Telegram's state
  manager never runs). Sparkle never checks Telegram's feeds.
- Hidden with the shared `MattermostFeatures` flags: Contacts and Calls tabs (the tab indices follow from the
  flags; Relay has no call history), Telegram's settings rows (premium, stars, stories, wallet, proxy, privacy, sessions,
  language packs, stickers, Passport, support), the attach menu's polls, checklists, location, gifts and rich text.
- A Threads tab after Chats (`RelayThreadsController` on `MattermostSync.threadList`, as the iOS tab).
- The chat list's compose menu is New Message (people search, opens a DM), New Channel and Browse Channels
  (`RelayUI` on `MattermostDirectory`).
- Own identity: Relay.app (`org.relaychat.RelayMac`, the Swift module keeps the name Telegram), version 1.0.0,
  Relay's icon, Keychain scope `relay.<channel>`, no Telegram app groups (data in Application Support without a group
  entitlement), `Telegram-Mac/Relay.entitlements` (no sandbox, microphone, camera). The share extension is not
  embedded (Telegram's, needs a provisioning profile).

Threads: reply counts show on posts, and opening replies builds the thread location locally (`ChatReplyThreadMessage` with `isForumPost`, as on iOS; Telegram's `fetchAndPreloadReplyThreadInfo` would wait for a discussion message forever). With collapsed threads on, Reply (the menu, double-click, swipe, ⌘↑/⌘↓) on a post in a chat's history opens that post's thread with the composer focused, as on iOS (`ChatController.openMattermostThread`, in `setupReplyMessage`): it is how a thread is started. Before, the reply was sent from the chat's own composer as a thread reply, which collapsed threads hide, so the post seemed to vanish, and a thread could only be opened once it had replies (View N Replies, channels only). The Mattermost token's Keychain service is per build channel (`MattermostSessionKeychain.service`): with one service a Release launch's token cleanup removed the Debug account's token.

Notifications: macOS has no push, so MattermostSync hands a new post by someone else (live, not a system post) to `AccountStateManager.mattermostNotifyMessages`, which runs Telegram's own notify decision (`messagesForNotification`: mute and chat settings) and puts the result on the notification pipe the app listens to. The app's notification manager combined that pipe with Telegram's reaction notifications, which never emit with Mattermost, so it starts them empty.

Calls (`docs/livekit-calls-native-ui.md`): Telegram-Mac's own call screens run on the shared core through
`packages/RelayTelegramCalls`. `PCallSession`'s uses go through a `PresentationPeerCall` protocol (TelegramCallsCore)
that `RelayPeerCallSession` (over `RelayDirectCall`) also implements, so a DM call is `PeerCallScreen`, the call
header and Telegram's tones; `RelayPresentationGroupCall` implements `PresentationGroupCall` over `RelayGroupCall`
for `GroupCallContext`. CallsUI and GroupCallScreenUI reach the package through `RelayCallHooks` (installed in
`main.swift`; those packages stay at macOS 10.13): `phoneCall`, `requestOrJoinGroupCall`, `createVoiceChat`,
`selectGroupCallJoiner` and the join panel's `getGroupCallPanelData` branch on it. `SharedWakeupManager` rings from
`relayCallEvents` (a ring while another call runs is declined as busy, Telegram's policy); a group message ring shows
`PeerCallScreen` in its conference mode and, once answered, moves the window into the group call, as Telegram's
incoming group calls do. Video is LiveKit's camera (picked by `AVCaptureDevice.uniqueID`) and ScreenCaptureKit
screen share (Telegram's source picker, matched by display or window id), drawn by Telegram's Metal renderer through
`LiveKitVideoSource`. Call entry points follow `MattermostFeatures.relayCalls` (DM call buttons, Voice Chat for
channels and group messages a member can call in). `PrivateCallScreen` processes its asset catalog (it was copied
uncompiled, and `NSImage(resource:)` trapped: the old crash on Call).

The app links two WebRTCs with one `webrtc::` C++ namespace: tg_owt (`libmac_framework_objc_static.a`, what tgcalls is
compiled against) and LiveKit's `LiveKitWebRTC.framework`. The app target names the tg_owt archive in `OTHER_LDFLAGS`
so that it comes before the package frameworks on the link line; otherwise the linker binds tgcalls' references to
LiveKit's copy (other sources, other layouts) and Telegram's screen source picker crashed on open. Check a build with
`nm -m Relay.debug.dylib | grep '(from LiveKitWebRTC)' | grep 6webrtc` (no output). Tones and LiveKit device selection
run off the main thread: a slow audio server froze the call screen otherwise. Scripted peers for the dev server:
`tools/relay-calls-peer.py` (ring, answer, decline, channel calls, tone and test-pattern media, received frame stats).

Not done: localization of the Relay screens (Relay is English-only, as on iOS), Mattermost-specific chat and profile
screens, notifications while Relay isn't running (no push on macOS), sharing, voice transcoding. The emoji panel shows emoji only (no sticker or GIF tabs). Reaction "animations" are the static WebP images (`MattermostReactionImages`), so the message menu's reaction bar keeps them out of its Lottie player (`ReactionView.playsAnimations`): fed to it, a second hover replaced the failed animation, the released renderer reported `.stoped`, and the bar removed its static image, so the emoji disappeared.

## Building, signing, checking

- Build: `xcodebuild -workspace Telegram-Mac.xcworkspace -scheme Telegram -configuration Debug -derivedDataPath
  /Volumes/X5/relay-mac-dd -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build` (works from an
  agent shell).
- Sign: `tools/relay-mac-sign.sh [Relay.app]` in a GUI session (Rex pane, Terminal); codesign in an agent's
  background session fails with errSecInternalComponent. Apple Development by default, `RELAY_SIGN_IDENTITY` and
  `RELAY_HARDENED=1` for Developer ID with the hardened runtime. An ad-hoc signed build asks for the login keychain
  password after every rebuild (the Keychain item's ACL follows the signature); a stable signature doesn't. With
  nobody to answer that prompt (a locked screen) the build's account manager waits in `PasscodeKeychain.read` and the
  debug remote answers `authorized: false`; signing the build first fixes it (the script worked from an agent shell
  inside Rex with the login keychain unlocked).
- Release: `tools/relay-mac-release.sh` in a GUI session, the way Snippets ships (wowlocal/snippets
  `Distribution/Release`): Release build with CFBundleVersion = the commit count (`RELAY_VERSION` sets the marketing
  version), a stripped copy (the unstripped executable is 435 MB), Developer ID signature with the hardened runtime,
  notarization with the App Store Connect API key in `~/.relay-secrets/asc` (an individual key: notarytool takes it
  without `--issuer`), stapled ticket, `build/updates/Relay-<version>-<build>.zip` (universal, about 119 MB). Then
  Sparkle 2.9.5's `generate_appcast` writes `build/updates/appcast.xml` signed with Relay's EdDSA key
  (`~/.relay-secrets/sparkle/relay-mac-ed25519.key`; the public half is `SUPublicEDKey`), without deltas (the app's
  Sparkle is 1.21 and can't apply Sparkle 2's deltas), and curl's AWS SigV4 uploads the zip and the appcast to
  `macos-releases/relay/` on Yandex Object Storage (Snippets' bucket), where `SUFeedURL` points; settings and keys in
  `~/.relay-secrets/macos-release.env`. A Release build keeps its data under `stable/` and has no debug login or
  remote. The updater uses only the appcast (Telegram's internal source reads Telegram's update channel).
- Every appcast item needs a description: Relay up to 1.0.1 (22) crashes on an update without one (Telegram's
  updater reads `SUAppcastItem.itemDescription`, an implicitly unwrapped String). The release writes
  `build/updates/Relay-<version>-<build>.html` from `RELAY_NOTES` (one line per item) or the "Relay for macOS:" commit
  subjects since the last `relay-mac-*` tag, and release and publish refuse an appcast with an item lacking one.
- Up to 1.0.1 a reset of the updater during a download started another download of the same zip (1.0.0 ran four,
  progress past 100%); from 1.0.2 a reset while downloading, unarchiving or installing does nothing.
- Bucket keys: `tools/relay-mac-bucket-keys.sh --paste` writes them into `~/.relay-secrets/macos-release.env` without
  echoing the secret, then publishes. Its `yc` path cannot log in with an OAuth token: Yandex Cloud refuses OAuth tokens
  issued after 2026-06-01 for IAM exchange, and `yc config set token` puts the token into its log file's name.
  `tools/relay-mac-publish.sh` uploads an already built release.
- Debug remote (debug builds): `tools/relay-mac-remote.swift` posts a command on the distributed notification
  `org.relaychat.RelayMac.debug.command` and prints the answer from `relay-debug/result.json`: `state`, `login
  server= login= [password=|RELAY_REMOTE_PASSWORD]`, `login-state`, `open-chat query=`, `send text=`, `thread`, `notifications`, `screen
  name=new-message|new-channel|browse|settings|chats|threads`, `snapshot`; for calls `call user= [video=1]`,
  `call-state` (Telegram's call/group state, windows, the Relay controllers' media and per video source frame counts,
  permissions), `call-accept`, `call-decline`, `call-hangup [end=1]`, `call-mute on|off`, `call-video on|off`,
  `call-screen on|off` (Telegram's source picker), `join-call channel=` (the join panel), `messages`, `windows`,
  `click text= [window= event= row=1]`, `screen-list`, `screen-picker`, `accounts`, `add-account`, `switch-account id=`; for chats and menus `chat-state`, `chat-messages [count=]`, `compose text= [send=1 clear=1]` (the composer's own send), `rightclick text=` (the row's `showContextMenu`, what a right click runs once the pointer is inside), `menu-item text=`, `close-menus`, `views class= text=`, `hover class= [index= state=normal|hover wait=]` (sets the control's `controlState`, as `mouseEntered` does, and answers its subtree with the number of drawn layers), `press class= [index=]`
  (a bare first word is the action, a second one its value). `RELAY_DEBUG_NO_PERMISSION_PROMPTS=1` lets calls start
  while a microphone or camera prompt is unanswered; `RELAY_DEBUG_NO_AUDIO_ENGINE=1` keeps LiveKit's audio engine off
  (a Mac whose audio server stalls); a crash's stack is scanned into `relay-debug/crash-scan.txt`. Screen captures need a permission the agent's
  terminal lacks, and neither `layer.render` nor `cacheDisplay` draws TGUIKit's content, so `snapshot` writes each
  window's view tree with TGUIKit `TextView` text (`relay-debug/window-N.txt`); that is how the screens were checked.
- Checked on the dev server: login through the screen (bob) and the debug login (alice), bootstrap of 2 teams and
  56 chats, channel pictures, a chat's history, sending (the post reaches the server), a post by another user arriving
  live, settings and tabs, New Message listing people, a thread with its replies, a notification for a post in another channel; a notarized Release build launches.
