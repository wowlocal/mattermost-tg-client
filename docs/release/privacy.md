# Privacy: App Store labels and privacy manifest (draft)

> Draft for the person who publishes Relay. Not legal advice. The App Store answers depend on **who runs the
> push proxy** and **how it logs**; both are open until the distribution decision (D1) is made.

## How data flows

```
Relay (device) ──HTTPS──▶ the user's own Mattermost server(s)          ← everything: login, messages, files, profile
Mattermost server ──▶ push proxy (whoever operates it) ──▶ Apple APNs ──▶ device   ← only when push is enabled
```

- Relay has **no backend of its own** and **no analytics, crash reporting, advertising or tracking SDKs**.
  Nothing is sent to the publisher of the app.
- Everything the app sends goes to the Mattermost server address the user typed at login (or a link into a
  signed-in server). The server belongs to the user or their organisation; it is not the developer's and not a
  "third-party partner" of the developer in Apple's sense.
- **Voice messages (Phase 5A)** are recorded only while the user holds (or has locked) the record button, kept on the
  device until sent, and sent like any file: an audio attachment (`.m4a`) on the user's own Mattermost server, with
  the recording's duration and a 100-point loudness outline (the waveform drawn in the bubble) in the post's
  properties. Recordings are never sent anywhere else and never transcribed (Telegram's voice-to-text stays off). A
  push for a voice message carries the server's "attached a file." like any file post; the notification service
  extension then fetches the post from the user's server to say "Voice message". Whether a voice message was played
  is kept on the device only.
- Link previews never contact the linked site from the device: preview images load from the server or through
  the server's image proxy (Phase 3E). The map in a shared location uses Apple's MapKit.
- **Push notifications** are the one path through infrastructure that may be the publisher's: a Mattermost server
  sends each push to the push proxy configured on the server, which signs it with Relay's APNs key and hands it to
  Apple. Only the holder of Relay's APNs key can run that proxy (`infra/push-proxy/README.md`), so for an App
  Store or TestFlight build it is normally the publisher. The proxy receives the APNs device token and the push
  payload: in the server's `full` content mode that includes the sender, the channel name and the message text;
  `generic` sends no message text, `id_loaded` sends only ids (the device fetches the text from the server).
  The proxy forwards and forgets; it stores nothing, and with `EnableFileLog: false` (our template) its log goes
  to the container's console only.
- On the device: messages and media are cached in the app's data container (Telegram's encrypted Postbox
  database); Mattermost session tokens are in the Keychain (app group access group, `AfterFirstUnlock`), shared
  only with Relay's extensions.
- **Diagnostics (Phase 4G) stay on the device unless the user exports them.** Relay has no crash reporter or
  analytics SDK. Two local sources:
  - **MetricKit**: iOS hands the app its own daily metrics and diagnostic reports (crashes, hangs, disk writes,
    CPU exceptions: call stacks of Relay's code, device model, iOS version, app version, no user data). Relay keeps
    them as JSON in its container, at most 30 days, 40 reports and 4 MB (`DiagnosticReportStore`). (iOS also shares
    these reports with the developer through App Store Connect if the user turned on "Share With App Developers" in
    iOS Settings → Privacy → Analytics; that is Apple's, not Relay's.)
  - **Diagnostic log**: Telegram's file log with MattermostSync's lines, **off by default in release builds**
    (Settings → About Relay → Diagnostics → Save Diagnostic Logs). The log records what the app does (connections,
    sync steps, errors) and Mattermost ids (posts, channels, users); it never records message text, search terms,
    names, passwords or session tokens (checked in 4G: the lines that did log a username, search terms, a custom
    status text or the full APNs device token were changed).
  - **Export** (Settings → About Relay → Diagnostics → Export Diagnostics) makes a zip and opens the system share
    sheet; nothing is sent unless the user picks a destination. It contains a summary (Relay and iOS version,
    device model, language, each account's server address and Mattermost version and sync state, whether a
    passcode is set, which managed configuration keys are set — not their values), the stored MetricKit reports and
    the logs of the app and its extensions. Before export the logs and summary are scrubbed again
    (`DiagnosticsRedactor`): credentials (`Bearer …`, `token=…`, passwords, cookies) and email addresses removed,
    APNs tokens removed, and every Mattermost id replaced by a pseudonym that is stable within one export but can't be
    matched to the server or across exports.
- **Managed configuration** (MDM, Phase 4G, [managed-configuration.md](managed-configuration.md)) is read on the
  device only. The app copies the certificate pins and the server restriction into its app group for its
  extensions; nothing of it is sent anywhere.

## App Store Connect: App Privacy answers (proposal)

Apple's definition: data is **collected** when it is "transmitted off the device in a way that allows you and/or
your third-party partners to access it for a period longer than what is necessary to service the transmitted
request in real time". Data that only goes to a server the user chose, and that the developer cannot access, is
not collected by the developer.

**Proposed answer: "Data Not Collected"**, on these conditions (each must stay true):

1. The app contains no analytics/crash/ads SDK (true today; re-check before each release, see "Checks" below).
   Recorded audio (voice messages, 5A) goes only to the user's own server, like photos and files, so it is not
   "Audio Data" collected by the developer.
   Diagnostics (MetricKit reports, the optional log) leave the device only when the user exports them and picks
   where to send them, so they are not "collected" in Apple's sense; if the publisher ever asks users to send
   exports to a support address and keeps them, declare **Diagnostics → Crash Data / Performance Data / Other
   Diagnostic Data** (App Functionality, not linked, not tracking).
2. The push proxy (if the publisher runs it) does not retain payloads or device tokens beyond forwarding them:
   no file logs, console logs not shipped to a log store, or at least no payload contents at the configured
   log level. If its logs are kept, answer instead:
   - **User Content → Other User Content** (message text in pushes, `full` mode) and **Identifiers → Device ID**
     (APNs token): *App Functionality*, **not linked** to identity unless the logs also hold the user id (the
     push payload carries the Mattermost user/channel/post ids → then **linked**), **not used for tracking**.
   - Or require servers to use `generic` / `id_loaded` push contents, which removes message text from the proxy.
3. Relay keeps no server-side account system of its own (true: accounts are the Mattermost server's).

**Tracking:** No (no data is combined with third-party data, no IDFA, no data brokers).

**Privacy policy URL** (required even for "Data Not Collected"): publish a short page, e.g. in the repository
(`https://github.com/wowlocal/mattermost-tg-client/blob/main/docs/release/privacy-policy.md` once written) or the
publisher's website. Points it must make: no data to the developer; data goes to the server the user signs in to,
under that server operator's policy; push notification relay as above; on-device storage and how to delete it
(log out / delete the app); contact address.

## Privacy manifest (`PrivacyInfo.xcprivacy`)

`Telegram/Relay/PrivacyInfo.xcprivacy` is bundled into the app and each shipped extension (Share, NotificationService,
NotificationContent) through `Telegram/BUILD` (`RelayPrivacyManifest`). It declares:

- `NSPrivacyTracking`: false; `NSPrivacyTrackingDomains`: none.
- `NSPrivacyCollectedDataTypes`: none (see the conditions above; add entries here too if the answers change).
- `NSPrivacyAccessedAPITypes` — required-reason APIs found in the shipped binaries (symbol and selector scan of
  the release build, see "Checks"), with the reason that matches what the code does:

| Category | Where (examples) | Reason |
|---|---|---|
| File timestamp (`stat`/`fstat`/`lstat`, `creationDate`, `modificationDate`, `contentModificationDateKey`) | Postbox media cache cleanup (`TimeBasedCleanup`, `MediaBox`), log rotation (`TelegramCore/Utils/Log.swift`), SQLCipher, the notification extension's avatar cache, the media editor's drafts | `C617.1` (files inside the app's container / app group container) |
| System boot time (`systemUptime`, `mach_absolute_time`) | passcode lock timers, MtProtoKit's monotonic clock, WebRTC/FFmpeg timers, media editor | `35F9.1` (elapsed time between events in the app) |
| Disk space (`systemFreeSize`, `statfs`/`statvfs`) | low-storage warning before downloads (`CheckDiskSpace`), the storage usage screen and chat-list storage hint, SQLCipher | `E174.1` (enough space before writing files) and `85F4.1` (shown to the user) |
| Active keyboards (`activeInputModes`) | the composer restores the keyboard language last used in a chat (`ChatInputTextNode`, `ASEditableTextNode`) | `54BD.1` (customise the UI based on the active keyboards) |
| User defaults (`UserDefaults`) | app settings and launch flags, app-only (no `suiteName` app-group defaults) | `CA92.1` (app-only defaults) |

The bundled frameworks (`TelegramUIFramework` etc.) are our own code built from source, so the app's manifest
covers them. If App Store Connect answers an upload with **ITMS-91053 "Missing API declaration"** naming a
framework, add the same file to that framework bundle (or the missing category/reason to the manifest) and upload
again.

## Checks before each release

Run on the release build's `Payload/Telegram.app` (see `docs/release/RELEASE.md` "Audit"):

- No tracking/analytics SDKs: `find Telegram.app -name '*.framework'` lists only Relay's own frameworks
  (MtProtoKit, SwiftSignalKit, Postbox, TelegramCore, TelegramUI); no `RecaptchaEnterprise`, `AppCenter`,
  `Firebase*`, `GoogleUtilities`.
- Required-reason APIs: `nm -u` on each binary for `_stat`, `_fstat`, `_lstat`, `_getattrlist`, `_statfs`,
  `_statvfs`, `_mach_absolute_time`, and `strings` for the selectors `systemUptime`, `activeInputModes`,
  `systemFreeSize`, `creationDate`, `modificationDate`, `NSUserDefaults`; each category found must be in the
  manifest.
- No network destinations other than the user's server(s) during a smoke test (`lsof -i -a -p <pid>` on the
  simulator app; Phase 2–3 checks always showed only the server).

## Usage descriptions (Info.plist)

Relay asks for: camera, microphone, photo library (read/add), contacts (only when sharing a contact), location
(only when sharing a location), Face ID (passcode unlock), motion (location sharing). All are requested at the
moment of use, never at launch. Wording lives in `Telegram/BUILD` (`TelegramInfoPlist`) and
`Telegram/Telegram-iOS/en.lproj/InfoPlist.strings`. The microphone (asked the first time the record button is held,
5A): "Relay uses the microphone to record voice messages and videos with sound. A recording is sent to your Mattermost
server only when you send it." Voice messages add no required-reason API category (the recorder, AVFoundation's
AAC encoder and FFmpeg were already in the binaries), so the privacy manifest is unchanged.
