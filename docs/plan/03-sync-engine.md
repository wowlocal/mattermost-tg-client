# 3 · Sync engine

`MattermostSync` replaces Telegram's `AccountStateManager` and update handling. It keeps Postbox consistent with the server using REST for bootstrap, catch‑up and history, and the WebSocket for live events.

## API surface for v1

All paths are relative to `/api/v4`. `me` can be used in place of the current user's ID.

| Area | Endpoints |
|---|---|
| Server | `GET /system/ping`, `GET /config/client?format=old`, `GET /license/client?format=old` |
| Auth | `POST /users/login` (with MFA `token`), `POST /users/logout`; SSO through Mattermost's mobile SSO flow in `ASWebAuthenticationSession`; personal access tokens |
| Me & teams | `GET /users/me`, `GET /users/me/preferences`, `GET /users/me/teams`, `GET /users/me/teams/members`, `GET /users/me/teams/unread` |
| Channels | `GET /users/me/teams/{team_id}/channels`, `GET /users/me/teams/{team_id}/channels/members`, `GET /users/me/teams/{team_id}/channels/categories`, `POST /channels/members/me/view`, `POST /channels`, `POST /channels/direct`, `POST /channels/group`, `POST /channels/{id}/members`, `GET /teams/{team_id}/channels` (browse) |
| Posts | `GET /channels/{id}/posts` (`page`, `per_page`, `before`, `after`, `since`), `GET /posts/{id}`, `GET /posts/{id}/thread`, `POST /posts`, `PUT /posts/{id}/patch`, `DELETE /posts/{id}`, `POST /users/me/posts/{id}/set_unread`, `POST /teams/{team_id}/posts/search`, `GET /channels/{id}/pinned` |
| Threads | `GET /users/me/teams/{team_id}/threads`, `PUT /users/me/teams/{team_id}/threads/{id}/read/{timestamp}`, `PUT`/`DELETE /users/me/teams/{team_id}/threads/{id}/following` |
| Reactions | `POST /reactions`, `DELETE /users/me/posts/{post_id}/reactions/{emoji_name}` |
| Files | `POST /files`, `GET /files/{id}`, `GET /files/{id}/thumbnail`, `GET /files/{id}/preview`, `GET /files/{id}/info` |
| Users | `POST /users/ids`, `POST /users/usernames`, `POST /users/status/ids`, `GET /users/{id}/image`, `GET /users/autocomplete`, `POST /users/search` |
| Emoji | `GET /emoji`, `GET /emoji/name/{name}`, `GET /emoji/{id}/image` |
| Integrations | `GET /teams/{team_id}/commands/autocomplete_suggestions`, `POST /commands/execute`, `POST /posts/{id}/actions/{action_id}`, `POST /actions/dialogs/submit` |
| Push | `PUT /users/sessions/device`, `POST /notifications/ack` |
| Misc | `POST /opengraph`, WebSocket at `/websocket` |

## Server capabilities

At login and on `config_changed`/`license_changed`, read the client config and license. Store as capabilities:

- server version
- collapsed reply threads (CRT) setting
- custom emoji enabled
- max file size
- allowed SSO providers
- MFA required
- whether the server is licensed (affects push content options)

Screens read capabilities to hide unsupported features. Refuse servers older than the minimum version (see decisions).

## Bootstrap (first login and full resync)

1. `GET /users/me`, `GET /users/me/preferences`.
2. `GET /users/me/teams`, `GET /users/me/teams/members`.
3. For each team, in parallel with a concurrency limit:
   - channels
   - channel members (read state, notify props)
   - sidebar categories
4. Collect the user IDs for DM partners and GM members. Fetch them with `POST /users/ids` in batches, and statuses with `POST /users/status/ids`.
5. Write all peers, chat‑list inclusion, read states and team folders in one Postbox transaction.
6. **Chat‑list rows without messages.** Telegram orders the chat list by each chat's top message. Loading the last post of every channel at login is too expensive on large servers (hundreds or thousands of channels).
   - Plan: include each peer in the chat list with a minimum timestamp of `channel.last_post_at`, if Postbox supports that (assumed: a "has messages or minimum timestamp" chat‑list inclusion option).
   - Then fetch the last page for unread channels and recently active channels first, and for the remaining visible rows lazily.
   - *Verify in Phase 0.*
7. Open the WebSocket. Record `lastSyncAt` (server time).

Show a progress screen during the first bootstrap only. Later launches render from Postbox immediately and catch up in the background.

## WebSocket

- Connect to `wss://<server>/api/v4/websocket` with the session token.
- Use exponential backoff with jitter. Reconnect when the app comes to the foreground and when the network path changes.
- On servers that support it, resume with `connection_id` + `sequence_number` so missed events are replayed.
- If the `hello` event shows a new connection (not resumed), run **catch‑up**.
- Send `user_typing` actions (throttled) while composing.

| Event | Action |
|---|---|
| `hello` | Record server version and connection ID; catch up if not resumed |
| `posted` | Insert the message (deduplicate by post ID and `pending_post_id`); update chat‑list order, unread count, and mention badge (`mentions` in the event) |
| `post_edited` | Update text, entities and media; set the edited attribute |
| `post_deleted` | Delete the message (or show a "deleted" placeholder; decide in design) |
| `post_unread` | Update read state |
| `reaction_added`, `reaction_removed` | Update the reactions attribute |
| `channel_viewed`, `multiple_channels_viewed` | Mark read (read on another device) |
| `typing` | Typing indicator |
| `status_change` | Presence |
| `user_updated`, `new_user` | Update the user peer |
| `channel_created`, `channel_updated`, `channel_converted`, `channel_deleted`, `channel_restored` | Update the channel peer and chat list |
| `channel_member_updated` | Notification settings (mute), roles |
| `user_added`, `user_removed`, `added_to_team`, `leave_team` | Membership → chat list and team folders |
| `direct_added`, `group_added` | New DM or GM |
| `preferences_changed`, `preferences_deleted` | Favorites, display settings, saved posts |
| `sidebar_category_created`, `_updated`, `_deleted`, `_order_updated` | Regenerate folders and pins |
| `thread_updated`, `thread_read_changed`, `thread_follow_changed` | Threads (CRT) |
| `emoji_added` | Custom emoji cache |
| `config_changed`, `license_changed` | Capabilities |

Unknown events are logged and ignored.

## Catch‑up

Runs after a non‑resumed reconnect, on foreground, and from a background refresh task.

1. Refresh channel members for all teams (unread counts, `last_viewed_at`, notify props).
2. For each channel with `last_post_at > lastSyncAt`, call `GET /channels/{id}/posts?since=<lastSyncAt>`. This returns posts created, edited or deleted since then. Apply them.
   - If one channel has too many changes, insert a hole instead and let history loading fill it on demand.
3. Refresh statuses for visible users.
4. Advance `lastSyncAt` to the server time of the oldest successful response.

## Ordering and idempotency

- One serial queue applies all server data to Postbox, in transactions.
- Posts are upserted by post ID.
- An edit is applied only if its `update_at` is newer than the stored one.
- Deletes leave a tombstone in the ID map so a late `posted` event can't resurrect the post.
- Event handlers must be idempotent: catch‑up and resume can replay the same data.

## Outgoing pipeline

1. The composer writes a Local‑namespace message with `pending_post_id`, in Telegram's normal "sending" state.
2. Attachments: `POST /files` with `client_ids`, with progress reported into the media upload state. Cancellation is supported.
3. `POST /posts` with `channel_id`, `message`, `root_id`, `file_ids`, `pending_post_id`.
4. On success: allocate the Cloud ID, replace the Local message, store `pending_post_id ↔ postId`.
5. On failure: mark as failed (Telegram's resend UI). Retry automatically on transient errors (network, 5xx, 429 with `Retry-After`), never on 4xx.
6. Messages composed offline queue in order per channel and are sent when back online.

Edit → `PUT /posts/{id}/patch`. Delete → `DELETE /posts/{id}`. Reactions are optimistic and rolled back on failure.

## History loading (filling holes)

When a chat screen reaches a hole, Postbox asks for it to be filled. `MattermostSync` translates the request:

| Postbox request | Mattermost call |
|---|---|
| Older than boundary post `P` | `GET /channels/{id}/posts?before=P&per_page=60` |
| Newer than boundary post `P` | `GET /channels/{id}/posts?after=P&per_page=60` |
| Around a permalink post `X` | `GET /posts/{X}` + `before=X` + `after=X`, in parallel |
| Thread | `GET /posts/{root}/thread` (paged on newer servers) |

IDs are allocated with the scheme in [Domain mapping → Message IDs](02-domain-mapping.md#message-ids). The filled range is then removed from the hole set.

## Media fetching

- A `MediaBox` fetcher for the Mattermost resources (file, thumbnail, preview, avatar, emoji), with the auth header.
- Use HTTP range requests for video streaming, if `/files/{id}` supports `Range` (*verify*). Otherwise download progressively.
- Reuse Telegram's storage‑usage screen and cache limits for eviction.

## Background behaviour

- WebSocket only while in the foreground.
- In the background: push notifications ([4 · Push](04-push-notifications.md)) plus a `BGAppRefreshTask` that runs catch‑up.
- Coming to the foreground triggers reconnect plus catch‑up. The UI shows Telegram's "Updating…" / "Connecting…" title states, wired to sync state.
