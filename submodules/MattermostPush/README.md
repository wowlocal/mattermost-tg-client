# MattermostPush

Mattermost push notifications without Telegram code, for the app (MattermostSync, TelegramUI) and the
notification service extension (MattermostPushService). Foundation and Security only. See
[Push notifications](../../docs/plan/04-push-notifications.md) and [infra/push-proxy](../../infra/push-proxy/README.md).

| File | What |
|---|---|
| `MattermostPushPayload.swift` | The APNs payload as mattermost-push-proxy 6.6.0 sends it (`type`, `ack_id`, `server_id`, `channel_id`, `post_id`, `root_id`, `sender_*`, `channel_name`, `aps.alert`, badge, …); merging an ID-only acknowledgement's answer |
| `MattermostPushRouting.swift` | Which signed-in account a push belongs to (pushes carry the server, not the user) |
| `MattermostPushText.swift` | Title/body for DMs, channels and thread replies, `session`; the communication-notification sender and group |
| `MattermostPushNames.swift` | "Town Square → alice" when several accounts are signed in (Telegram's rules) |
| `MattermostPushUserInfo.swift` | Keys the extension adds for the app; the target of a tap/action; which notifications a `clear` removes |
| `MattermostPushDevice.swift` | Device ids (`relay_apple[_sandbox]:<token>`), the APNs environment, the registration record |
| `MattermostSessionKeychain.swift` | Session tokens in the app group's Keychain access group (shared with the extension) |
| `MattermostPushDeliveryLog.swift` | Posts already notified per account (two accounts on one server) |

Tests: `swift test` (36). `Tests/MattermostPushTests/Fixtures/` has the payloads: hand-written ones
(`dm`, `channel-mention`, `thread-reply`, `clear`, `update-badge`, `session`) and `captured-*.apns`, real
pushes from the dev server (Mattermost 11.7.14, full contents, collapsed threads on). Each file also works
with `xcrun simctl push <udid> org.relaychat.Relay <file>` (iOS shows it without running the notification
service extension, see infra/push-proxy) and with `tools/relay-remote.py <udid> simulate-push file=<file>`
(debug builds: the extension's code, run in the app).
