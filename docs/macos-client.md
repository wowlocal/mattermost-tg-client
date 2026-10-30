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
| MattermostSync | `Package.swift` for SwiftPM; iOS-only parts (WebP via WebPBinding, voice transcoding via ConvertOpusToAAC and UniversalMediaPlayer, UIKit drawing of group pictures and reactions) behind `#if os(iOS)` or redone with CoreGraphics/ImageIO |
| TelegramCore hooks (`Sources/Mattermost`, `MattermostBackend`, `NullNetworkEngine`) | compiled with the app's TelegramCore package |
| MattermostUI and TelegramUI patches | redone in the macOS app |

The macOS app needs macOS 13 (the Mattermost packages' minimum).

## Phases

1. The app builds against this fork (native libraries, TelegramCore with the hooks).
2. MattermostSync builds for macOS and is linked into the app.
3. Wiring: `MattermostBackend` enabled, `MattermostSync.startLifecycle`/`startAccount`, the resource fetch hook in
   `telegramAccountAuxiliaryMethods`, `mattermostDeclareEncodables`, a login screen (server, credentials, MFA)
   instead of AuthUI that calls `MattermostAccountSetup.probe/login/createAccount`.
4. Telegram-only features hidden (premium, stars, stories, calls, secret chats, wallet, phone and contacts),
   teams as folders, threads, reactions, mentions.
5. Branding (name, icon, bundle id, no Sparkle feed or AppCenter), signing and distribution.
