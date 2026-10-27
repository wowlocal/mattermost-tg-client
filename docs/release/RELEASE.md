# Releasing Relay (TestFlight / App Store)

Step-by-step for the person who owns the Apple Developer account. Everything here up to "Build" was prepared and
checked in the repository (Phase 4A); **nothing was signed or uploaded**: no Apple Developer account, certificate
or profile was available. The sections say what was verified and what wasn't.

Related: [privacy.md](privacy.md) (App Store privacy answers and the privacy manifest),
[managed-configuration.md](managed-configuration.md) (MDM/EMM app configuration keys for company deployments),
[infra/push-proxy/README.md](../../infra/push-proxy/README.md) (APNs key and push proxy),
[docs/BUILD.md](../BUILD.md) (simulator builds), [docs/plan/08-legal-and-licensing.md](../plan/08-legal-and-licensing.md).

## 0. Decide first

| # | Decision | Why it blocks the release | Default in effect |
|---|---|---|---|
| D1 | Distribution: TestFlight internal/external, App Store, Apple Business Manager custom app, ad hoc/MDM | App Store Connect record, review, profile type; GPL/App Store risk (plan 08) | Internal distribution first (TestFlight internal testers) |
| D6 | App name and branding | App Store name, icon, metadata; the bundle id `org.relaychat.Relay` can stay whatever the name becomes, but choose it before creating the App IDs if you want it to match | App Store name "Relay: Team Chat", home screen "Relay"; icon chosen 2026-10-27 (origami pod with a pearl) |
| — | Legal review of the GPL terms before any external distribution | Telegram-iOS has no LICENSE file; telegram.org/apps says GPL v2 or later (plan 08) | Not done |
| — | Who runs the push proxy, and its log retention | App Store privacy answers ([privacy.md](privacy.md)) | — |

## 1. Apple Developer account

1. **Team ID**: developer.apple.com → Membership details (10 characters, e.g. `AB12CD34EF`).
2. **App Group**: Certificates, Identifiers & Profiles → Identifiers → **+** → App Groups →
   `group.org.relaychat.Relay`.
3. **App IDs** (Identifiers → **+** → App IDs → App, *explicit* bundle id). The app ships with three extensions
   (`Telegram/BUILD`, `extensions` of `ios_application`; the Siri intents, widget and broadcast extensions are not
   built for Relay):

| Bundle id | Target | Capabilities |
|---|---|---|
| `org.relaychat.Relay` | the app | **Push Notifications**, **App Groups** (`group.org.relaychat.Relay`), **Communication Notifications** |
| `org.relaychat.Relay.NotificationService` | notification service extension (Mattermost push → readable notification, avatars, ack) | **App Groups**, **Communication Notifications** |
| `org.relaychat.Relay.NotificationContent` | notification content extension (Telegram's expanded notification view) | **App Groups** |
| `org.relaychat.Relay.Share` | share extension | **App Groups** |

   - **Keychain Sharing is not needed**: Mattermost session tokens live in the app group's Keychain access group
     (`MattermostSessionKeychain`), which every target with the app group may use.
   - Not needed (Telegram-only, off for this bundle id in `Telegram/BUILD`): Siri, iCloud, Apple Pay, CarPlay,
     unrestricted VoIP, Associated Domains, Sign in with Apple, notification filtering, background GPU.
4. **APNs key** for the push proxy: follow [infra/push-proxy/README.md](../../infra/push-proxy/README.md)
   "Production / a real APNs key" (Keys → APNs, Sandbox & Production, download the `.p8` once, note the Key ID).
   The key never goes into this repository. The proxy needs a public HTTPS endpoint that the users' Mattermost
   servers can reach, and each server's admin sets **System Console → Push Notification Server** to it
   (`EmailSettings.PushNotificationServer`). Without that, the app works but gets no pushes.
5. **Certificates**: an **Apple Distribution** certificate (for TestFlight/App Store/ad hoc) and, for device
   debugging, an **Apple Development** certificate. Create the CSR in Keychain Access; install the downloaded
   certificate so that it and its private key are in the **login keychain** (`security find-identity -v -p
   codesigning` must list it).
6. **Provisioning profiles**: one per bundle id above (4 profiles), type **App Store Connect** for
   TestFlight/App Store (or **Ad Hoc** with registered devices for direct installs). Create them *after* the
   capabilities are set; regenerate them whenever a capability changes.

## 2. Repository configuration

1. **Team id**: `build-config/appstore-configuration.json` (release) and
   `build-config/development-configuration.json` (development device builds) still carry Telegram's team id
   `C67CF9S4VU` / a placeholder. Set `team_id` to your Team ID in both. Make.py only picks profiles whose
   `application-identifier` is `<team_id>.org.relaychat.Relay[.<extension>]`.
2. **`build-config/appstore-configuration.json`** is the configuration for anything you distribute. It differs from
   the development one in exactly the flags that matter for shipping:
   - `is_internal_build: "false"` — no Telegram "internal" extras, no default file logging;
   - `is_appstore_build: "true"` — without it Telegram's hidden debug tap on the Chats tab (10 quick taps) runs
     `preconditionFailure("debug tap")`, i.e. **crashes the app**;
   - `appstore_id`: the numeric Apple ID of the app once the App Store Connect record exists (used for "rate
     the app" / App Store links; `0` until then).
3. **Communication notifications on devices**: `Telegram/BUILD` adds
   `com.apple.developer.usernotifications.communication` to the app's device entitlements for `org.relaychat.Relay`
   (Phase 4A); the App ID must therefore have the capability (step 1.3) or signing/installation fails. The
   notification service extension takes its entitlements from its profile.
4. **Version and build number** (Phase 4A):
   - Marketing version (`CFBundleShortVersionString`) = `versions.json` → `"app"`, now **`0.1.0`** (was Telegram's
     `13.0.1`). It goes into the app, every extension and the embedded frameworks (`VersionInfoPlist` genrule in
     `Telegram/BUILD`). The other keys of `versions.json` (`xcode`, `bazel`, `macos`) are the toolchain pins and are
     independent of `"app"`; nothing in the app compares the version number. The upstream Telegram version this
     fork is based on is recorded by the `upstream-pin` tag (13.0.1, `5c20d095d1ab`), not by `versions.json`.
   - Build number (`CFBundleVersion`) = Make.py `--buildNumber`. Use the commit count of `main`, as upstream's CI
     does: `--buildNumber=$(git rev-list --count HEAD)`. It increases with every commit, identifies the commit,
     and needs no stored counter. **Build releases from `main` only** (another branch can have the same count).
   - Bump `"app"` for each version you submit for review (`0.1.0` → `0.1.1` / `0.2.0`); TestFlight accepts many
     builds per version.

## 3. Codesigning directory

Make.py's `--codesigningInformationPath <dir>` expects the layout of `build-system/fake-codesigning`:

```
<dir>/
  profiles/   *.mobileprovision   # the 4 profiles; any file names (matched by application-identifier)
  certs/      *.p12 / *.cer       # optional here: only copied for Xcode project generation
```

Keep `<dir>` **outside the repository** (e.g. `~/.relay-signing/appstore/`). Make.py copies the profiles into
`build-input/configuration-repository/provisioning/` (git-ignored) and maps them by bundle id suffix: `''` →
`Telegram.mobileprovision`, `.Share` → `Share`, `.NotificationService` → `NotificationService`,
`.NotificationContent` → `NotificationContent` (`build-system/Make/BuildConfiguration.py`). It also reads
`aps-environment` from the app's profile (`production` for App Store/Ad Hoc profiles) and fails if the app's
profile has no Push capability. Signing itself uses the certificate + private key from your **login keychain**
that matches the profile (bazel's `rules_apple`); the `certs/` folder is not imported by a local build.

## 4. Build

```sh
git checkout main && git pull
git submodule update --init --recursive --depth 1 --jobs 8
python3 build-system/Make/Make.py --cacheDir <bazel disk cache dir> build \
  --configurationPath build-config/appstore-configuration.json \
  --codesigningInformationPath ~/.relay-signing/appstore \
  --buildNumber=$(git rev-list --count HEAD) \
  --configuration=release_arm64
```

- Output: `bazel-bin/Telegram/Telegram.ipa` (the bundle inside is `Telegram.app`; its display name is Relay) and
  dSYMs next to it (`release_arm64` sets `--apple_generate_dsym`). Copy both somewhere safe; the next build
  overwrites them.
- `release_arm64` = `-c opt`, whole-module optimisation, `-Osize`, dead stripping. `DEBUG` is not defined, so
  every Relay debug hook, the debug remote and the debug screens are compiled out (section 6).
- A first release build takes much longer than a debug build (whole-module optimisation of the large modules).
- **Not verified**: a `release_arm64` build was never signed (no account/profiles). The same sources were built
  as `release_sim_arm64` (section 6), which compiles identically except for the CPU slice and signing.

## 5. Upload to TestFlight

1. **App Store Connect** → Apps → **+** New App: platform iOS, name (D6), primary language English, bundle id
   `org.relaychat.Relay`, SKU (any, e.g. `relay-ios`). Note the app's Apple ID → `appstore_id` in
   `build-config/appstore-configuration.json` (next build).
2. **Validate, then upload** (either):
   - Transporter (Mac App Store app): drag `Telegram.ipa` in → Deliver; or
   - command line with an App Store Connect API key (Users and Access → Integrations → App Store Connect API;
     the `.p8` goes in `~/.appstoreconnect/private_keys/`):

     ```sh
     xcrun altool --validate-app -f Telegram.ipa -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
     xcrun altool --upload-app   -f Telegram.ipa -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
     ```

     (Upstream's CI uses `altool --upload-app` with an app-specific password instead.)
3. Upload the dSYMs only if a crash reporter is added later; App Store Connect symbolicates TestFlight crash logs
   from the uploaded build's symbols.
4. **Export compliance**: Relay uses only standard encryption (HTTPS/TLS through the system, SQLCipher for the local
   database, Keychain) → "uses encryption: yes, exempt (standard encryption only)". Consider adding
   `ITSAppUsesNonExemptEncryption = false` to the Info.plist once confirmed, so TestFlight stops asking per build.
5. TestFlight → Internal Testing: add the testers (up to 100 App Store Connect users; no review needed). External
   testing needs Beta App Review and the beta "What to Test" text, contact and privacy policy URL.
6. **Test with real pushes** before inviting anyone: a TestFlight build is a production-APNs build
   (`aps-environment` = `production`), so it registers `relay_apple:<token>` (`apple_rn:<token>` on Mattermost 12
   and newer, which refuse other platform names) and needs the proxy's `relay_apple` and `apple_rn` entries with your
   key (push-proxy README step 6 describes the sandbox check; repeat it with a TestFlight build).
7. **Run the regression checklist** ([REGRESSION.md](REGRESSION.md)) on the candidate before inviting testers, on
   the current Mattermost ESR and the newest release, and add a results table for the run.

## 6. Audit: no debug code in the release

Every Relay debug facility is compiled only with `DEBUG` (Swift `-DDEBUG` comes from bazel's `-c dbg`; `-c opt`
builds don't define it): the `RELAY_DEBUG_*` launch hooks, the debug remote (`org.relaychat.Relay.debug`
notification, `Documents/relay-debug/`), the debug screens (`RELAY_DEBUG_OPEN_SCREEN`), the debug composer /
search / threads / links / directory / profile commands, the in-app push simulation and the debug login. Telegram's
hidden tab-bar gestures (10 taps on Settings: Telegram's debug menu; on Chats: a deliberate crash in non-App Store
configurations) are off in Relay release builds. Check a release build with:

```sh
tools/relay-release-audit.sh bazel-bin/Telegram/Telegram.ipa
```

It unzips the `.ipa`, runs `strings` over every Mach-O binary (app, frameworks, extensions) and fails on debug
markers (`RELAY_DEBUG`, `relay-debug`, `org.relaychat.Relay.debug`, the debug types and fields, debug command names,
the dev-server address), on an ATS exception for the app's own connections (`NSAllowsArbitraryLoads`,
`NSExceptionDomains`), on a bundle without `PrivacyInfo.xcprivacy`, and on closed-source/analytics SDK symbols.

**App Transport Security** (`Telegram/BUILD`, `RelayAppReleaseATSInfoPlist`): release builds connect to servers over
HTTPS only — Telegram's `NSAllowsArbitraryLoads` is gone and the login refuses `http://` addresses ("Relay only
connects to servers over HTTPS."). The one exception is `NSAllowsArbitraryLoadsInWebContent`: Telegram's in-app
browser (the default for links in messages) may open `http://` pages; it covers WKWebView content only. App
Review may ask for a justification ("in-app browser for links users share"); dropping it means `http://` links fail
in the in-app browser (users can switch Settings → Open Links In to Safari). Servers on a LAN need HTTPS too (a
certificate from a public CA, or an internal CA installed on the devices through a configuration profile/MDM). If
D1 ends up needing plain-HTTP LAN servers, the switch is two places: `NSAllowsLocalNetworking` in the release ATS
fragment and `RelayBranding.allowsInsecureLocalServers`.

Two layers, two jobs: the **login policy** refuses every `http://` address in release builds; **ATS** (its defaults,
no exception) blocks plain HTTP to other hosts at the network layer. ATS's defaults do *not* block `localhost`:
observed in 4A, an account a debug build had created on `http://localhost:8065` kept syncing after a release build
was installed over it. That only happens on development machines (release builds can't create such an account).

## 7. App Store Connect metadata

- **Name / subtitle / icon**: D6, decided 2026-10-27: "Relay: Team Chat" (home screen "Relay"). The icon is
  `Telegram/Telegram-iOS/Relay.icon`, one bitmap layer (`Assets/Relay.png`, made with Codex image generation; the
  login logo uses the same artwork).
- **Description**: must not present the app as Telegram or Mattermost (plan 08, trademarks). Something like "Relay
  is a client for Mattermost servers…" only if Mattermost's trademark guidelines allow the wording; otherwise
  describe it without the name.
- **Category**: Business or Productivity. **Age rating**: 17+ is typical for apps with unrestricted
  user-generated content (chat with arbitrary servers); answer the questionnaire accordingly.
- **Privacy**: App Privacy answers and the privacy policy URL from [privacy.md](privacy.md).
- **Support URL**: e.g. the repository's issues page.
- **App Review notes**: reviewers need a **test server and account**. Provide a Mattermost server reachable over
  HTTPS from the internet with a demo user (Relay has no demo mode), and say that the app is a client for
  self-hosted Mattermost servers.
- **Screenshots**: 6.9" and 6.5" iPhone (and 13" iPad, the app is universal), from a demo server.

## 8. GPL source offer

Relay is built from Telegram-iOS, whose source is published under the GNU GPL v2 or later (telegram.org/apps; no LICENSE file in the repository,
see plan 08). Everyone who gets the app must be able to get the complete corresponding source:

- The source is public at **https://github.com/wowlocal/mattermost-tg-client** (shown in Settings → About Relay →
  Source Code, with the open-source licenses).
- **Tag every uploaded build** at the exact commit it was built from and push the tag, e.g.
  `git tag relay-0.1.0-$(git rev-list --count HEAD) && git push origin --tags`. The About screen shows
  `0.1.0 (<build>)`, which identifies the tag.
- Keep the third-party notices (Settings → About Relay → Open Source Licenses; regenerate
  `Telegram/Relay/RelayLicenses.json` with `tools/relay-licenses/update.sh` after a build when dependencies change).
- No closed-source code may be linked: Phase 4A removed Telegram's Google RecaptchaEnterprise binary (Telegram's
  signup captcha), which could not be part of the source offer; `tools/relay-release-audit.sh` fails if it (or an
  analytics SDK) comes back.
- Before external distribution: legal review (plan 08, "App Store and the GPL").

## 9. Company deployments (MDM / EMM)

Relay reads managed app configuration with the **same keys as Mattermost's mobile app** (`serverUrl`, `serverName`,
`allowOtherServers`, `username`, `inAppPinCode`, `blurApplicationScreen`, `copyAndPasteProtection`,
`jailbreakDetection`, `vendor`) plus Relay's `relayCertificatePins` (SPKI SHA-256 certificate pins per host). The
administrator's guide with the table of keys, Relay's behaviour for each, the differences from Mattermost's app and an
example: [managed-configuration.md](managed-configuration.md). For App Store distribution through an MDM, assign the
App Store app (or an Apple Business Manager custom app, D1) and attach the configuration to bundle id
`org.relaychat.Relay`.

## What was verified (Phase 4A) and what wasn't

Verified on a simulator ("Relay Release iPhone 17 Pro", iOS 26.5) with `release_sim_arm64` +
`build-config/appstore-configuration.json`, driven by real taps and typing (AXe; release builds have no debug
remote), against the dev server behind a throwaway TLS proxy (nginx, a test CA trusted with
`xcrun simctl keychain … add-root-cert`):

- The release build compiles with no source changes needed beyond the debug guards (warnings are errors in the
  Relay modules), installs and runs.
- `http://localhost:8065` at login → "Can't Connect — Relay only connects to servers over HTTPS."
  (`docs/research/phase4a-release-http-refused.png`).
- `https://localhost:8443` → credentials → chat list (`phase4a-release-chatlist.png`); a channel with albums: images
  and avatars load over HTTPS (`phase4a-release-media.png`); a message typed and sent from the composer reached the
  server (`phase4a-release-sent.png`); `lsof` on the app: only `127.0.0.1:8443`.
- An `http://example.com/` link from a message opens in the in-app browser (`phase4a-release-http-link.png`; WebKit
  may upgrade well-known hosts to HTTPS by itself, so this shows links work, not that the exception was required).
- About Relay: `0.1.0 (<build>)`, the source URL; Open Source Licenses and a license text
  (`phase4a-about.png`, `phase4a-licenses.png`, `phase4a-license-text.png`).
- `tools/relay-release-audit.sh`: 0 debug markers (20 before), no ATS exception for the app's own connections,
  privacy manifests in the app and all three extensions, 0 closed-source SDK markers (244 RecaptchaEnterprise strings
  before).
- Debug builds still log in to `http://localhost:8065` and keep the debug remote (see docs/PROGRESS.md, 4A).

Not verified (needs the account or wasn't possible here): device signing with real profiles, `release_arm64` on a
device, `altool` validation/upload, TestFlight processing, production APNs through a hosted push proxy, the
notification service extension on a real device, communication notifications on a device (the new entitlement),
App Review; Telegram's 10-tap gestures being gone (AXe taps arrive ~1 s apart, slower than the gesture's window;
the gate is a compile-time condition); the share and notification extensions in a release build (no UI path to
them here).
