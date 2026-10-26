# 4 · Push notifications

## How Mattermost push works

```
Mattermost server ──HTTP──▶ push proxy ──▶ APNs ──▶ device
                                                 └─▶ Notification Service Extension
```

- The Mattermost server does not talk to APNs directly. It sends to a **push proxy**.
- Mattermost's hosted push service only serves the official app bundle IDs, so **we must run our own `mattermost-push-proxy`** (Apache‑2.0, Go, available as a container). It is configured with:
  - our APNs auth key (`.p8`), key ID and team ID
  - topic = our bundle ID
  - separate entries for development (sandbox) and production APNs
- Mattermost server: System Console → Push Notification Server = our proxy's URL.
- Push contents setting, one of:
  - generic (no message text)
  - full (text in the payload)
  - ID‑only (the device fetches the content). Best for privacy, but may require a licensed server edition (*verify*).

## Client: registration

1. Request notification permission; register for remote notifications.
2. Send the APNs token with `PUT /users/sessions/device` and `{"device_id": "<platform>:<token>"}`.
   - `<platform>` must match a platform entry in our push proxy's configuration. The official app uses a versioned identifier; confirm the exact format against the proxy version we deploy.
3. Re‑register on token change, on login, and on app upgrade.
4. Logout ends the session server‑side, which removes the device.

## Client: Notification Service Extension

Telegram's extension decrypts Telegram‑encrypted pushes and reads Postbox. **Rewrite it** for Mattermost payloads. Use the official app as a behaviour reference only; don't copy its code (see [Legal](08-legal-and-licensing.md)).

Steps for a `message` push:

1. Parse the payload: `type`, `ack_id`, `post_id`, `channel_id`, `root_id`, `sender_id`, `sender_name`, `channel_name`, `message`, `badge`, ID‑only flag, server identifier (for multi‑server routing; *verify the field*).
2. Pick the account (server) the push belongs to. Read its token from the shared keychain.
3. For ID‑only pushes, fetch the content through the ack endpoint or `GET /posts/{id}` within the extension's time budget. Fall back to generic text on timeout.
4. Acknowledge delivery: `POST /notifications/ack`.
5. Build the notification:
   - title and body
   - `threadIdentifier` = channel ID, for grouping
   - sender avatar through a communication notification (`INSendMessageIntent`), as Telegram already does
   - badge
6. Optionally write the post into a small app‑group cache so the chat opens instantly. Writing into Postbox from the extension is possible (Telegram does it) but can be deferred.

Other push types:

| Type | Handling |
|---|---|
| `clear` | Remove delivered notifications for that channel; update the badge |
| `update_badge` | Update the badge |
| `session` | Session expired; show "Log in again" |

How "clear" and "update_badge" can be handled silently on iOS depends on how the server sends them. Mirror the official app's behaviour. Silent handling may need background pushes handled by the main app.

## Notification actions

- **Reply**: send through `POST /posts` from the background (reuse Telegram's notification reply action).
- **Mark as read**: `POST /channels/members/me/view`.
- Tapping a notification opens the channel, or the thread for replies, at the post.

## Settings

Per channel, using channel `notify_props`:

- push: all / mentions / none
- mute
- ignore channel mentions

Global (`/users/me/patch` notify props):

- keywords
- DND
- push when away or offline

These map onto Telegram's notification settings screens where possible. The rest goes into a new section.

## Infrastructure

`infra/push-proxy/` contains:

- the container setup for `mattermost-push-proxy`
- a config template with placeholders only

The APNs key is mounted from a secret store at deploy time. **Never commit the key or put it in logs or release assets.**

Needs:

- a public HTTPS endpoint the Mattermost server can reach
- monitoring (delivery errors, APNs feedback)

## Testing

- Local: `xcrun simctl push <device> <bundle-id> payload.apns` with sample payloads for each type. Keep fixtures in the repo.
- End to end: dev server → push proxy (sandbox APNs) → development build on a device.
- Cases:
  - app killed / in background / in foreground
  - muted channel
  - DND
  - multiple servers
  - expired session
  - ID‑only timeout

## Implementation (Phase 3A)

What was built and verified against Mattermost 11.7.14 and mattermost-push-proxy 6.6.0 (details: [infra/push-proxy](../../infra/push-proxy/README.md), [BUILD.md](../BUILD.md#push-notifications-on-the-simulator-phase-3a)):

- **Platform prefix**: `relay_apple:<token>` (production APNs) and `relay_apple_sandbox:<token>` (sandbox), matching the two `ApplePushSettings` entries of our proxy; no `-v<N>` suffix (the proxy reads it as an app version). The ack's `platform` is `ios` (the server special-cases it).
- **Server identifier**: every push carries `server_id` = the server's `DiagnosticId` (client config), stored with the account at login. Pushes carry no user id, so several accounts on one server are told apart by channel membership, the sender, `@mentions` and a delivery log (two pushes for one post go to two accounts); `session` pushes by asking the server whose token it rejects (`MattermostPushRouter`).
- **ID‑only** needs a licensed server: unlicensed servers send "generic" instead. The extension merges the acknowledgement's answer for `id_loaded` pushes (unverified).
- **Shared keychain**: session tokens live in the app group's Keychain access group (`group.org.relaychat.Relay`, no Keychain Sharing capability needed); the extension acknowledges pushes with them. Older app-only tokens move on first read.
- **`clear`** is a background push (content-available, no alert): the app removes the channel's delivered notifications (thread replies stay on a collapsed-threads channel read). It never reaches the extension, and it is not delivered to a force-quit app. Reading a channel in Relay removes its notifications too (the server sends no `clear` to the reading session). **`update_badge`** carries only `aps.badge`, which iOS applies. **`session`** says "Session Expired … Open Relay to log in again".
- **Actions**: category `CAN_REPLY` (the server's) with Reply (the write path, so it is retried offline) and Mark as Read (`/channels/members/me/view`, plus the thread for a collapsed-thread reply). A tap opens the chat at the post, or the thread view for a channel thread reply.
- **Simulator testing**: `xcrun simctl push` never runs a notification service extension; debug builds run the extension's code in the app (`simulate-push`). The extension itself runs only with real APNs delivery, which needs the APNs key.
