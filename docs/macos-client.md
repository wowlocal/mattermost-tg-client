# Relay for macOS

Relay for macOS is Telegram for macOS (TelegramMessenger/telegram-macos) with this repository as its
`submodules/telegram-ios`, the way the iOS app is Telegram-iOS with these modules: the data layer is shared
(MattermostKit, MattermostSyncCore, MattermostSync, and the TelegramCore hooks), the UI is the macOS app's own
(AppKit, TGUIKit), so everything in `MattermostUI` and the TelegramUI patches is redone there.

## Checkout

- macOS app: `~/Developer/relay-mac`, telegram-macos at `d19f811484` (2026-10-09). That commit pins Telegram-iOS
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

## In the app (relay-mac, branch `relay`)

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
  flags), call buttons, Telegram's settings rows (premium, stars, stories, wallet, proxy, privacy, sessions,
  language packs, stickers, Passport, support), the attach menu's polls, checklists, location, gifts and rich text.
- The chat list's compose menu is New Message (people search, opens a DM), New Channel and Browse Channels
  (`RelayUI` on `MattermostDirectory`).
- Own identity: Relay.app (`org.relaychat.RelayMac`, the Swift module keeps the name Telegram), version 1.0.0,
  Relay's icon, Keychain scope `relay.<channel>`, no Telegram app groups (data in Application Support without a group
  entitlement), `Telegram-Mac/Relay.entitlements` (no sandbox, microphone, camera). The share extension is not
  embedded (Telegram's, needs a provisioning profile).

Threads: reply counts show on posts, and opening replies builds the thread location locally (`ChatReplyThreadMessage` with `isForumPost`, as on iOS; Telegram's `fetchAndPreloadReplyThreadInfo` would wait for a discussion message forever). The Mattermost token's Keychain service is per build channel (`MattermostSessionKeychain.service`): with one service a Release launch's token cleanup removed the Debug account's token.

Not done: localization of the Relay screens, a Threads list (iOS has a tab), Mattermost-specific chat and profile
screens, push notifications, sharing, voice transcoding. The emoji panel shows emoji only (no sticker or GIF tabs).

## Building, signing, checking

- Build: `xcodebuild -workspace Telegram-Mac.xcworkspace -scheme Telegram -configuration Debug -derivedDataPath
  /Volumes/X5/relay-mac-dd -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build` (works from an
  agent shell).
- Sign: `tools/relay-mac-sign.sh [Relay.app]` in a GUI session (Rex pane, Terminal); codesign in an agent's
  background session fails with errSecInternalComponent. Apple Development by default, `RELAY_SIGN_IDENTITY` and
  `RELAY_HARDENED=1` for Developer ID with the hardened runtime. An ad-hoc signed build asks for the login keychain
  password after every rebuild (the Keychain item's ACL follows the signature); a stable signature doesn't.
- Release: `tools/relay-mac-release.sh` in a GUI session: Release build, a stripped copy in `build/Relay.app`
  (the unstripped executable is 435 MB), Developer ID signature with the hardened runtime, notarization with the App
  Store Connect API key in `~/.relay-secrets/asc` (an individual key: notarytool takes it without `--issuer`),
  stapled ticket, `build/Relay-<version>-macos-arm64.zip` (119 MB for 1.0.0). A Release build keeps its data under
  `stable/` and has no debug login or remote.
- Debug remote (debug builds): `tools/relay-mac-remote.swift` posts a command on the distributed notification
  `org.relaychat.RelayMac.debug.command` and prints the answer from `relay-debug/result.json`: `state`, `login
  server= login= [password=|RELAY_REMOTE_PASSWORD]`, `login-state`, `open-chat query=`, `send text=`, `thread`, `screen
  name=new-message|new-channel|browse|settings|chats`, `snapshot`. Screen captures need a permission the agent's
  terminal lacks, and neither `layer.render` nor `cacheDisplay` draws TGUIKit's content, so `snapshot` writes each
  window's view tree with TGUIKit `TextView` text (`relay-debug/window-N.txt`); that is how the screens were checked.
- Checked on the dev server: login through the screen (bob) and the debug login (alice), bootstrap of 2 teams and
  56 chats, channel pictures, a chat's history, sending (the post reaches the server), a post by another user arriving
  live, settings and tabs, New Message listing people, a thread with its replies; a notarized Release build launches.
