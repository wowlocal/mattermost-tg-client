# MattermostSync design

**Status:** Draft v0.1 · 2026‑10‑26 · input for Spike D and Phase 2. Builds on [telegram-internals.md](../research/telegram-internals.md) (cited as **R§n**) and the plan docs [02](../plan/02-domain-mapping.md) / [03](../plan/03-sync-engine.md).

## Goals

1. Write Mattermost data into Postbox so Telegram's chat list and chat screens render it unchanged.
2. Replace every Telegram *managed operation* that the kept screens depend on with a Mattermost consumer, keeping the interactive engine APIs as they are (R§2 "pattern worth reusing").
3. Keep upstream edits to narrow, marked injection points (`// MATTERMOST:`).

## Module layout

| Module | Kind | Depends on | Holds |
|---|---|---|---|
| `MattermostKit` | SwiftPM + Bazel | Foundation | REST, WebSocket, models |
| `MattermostSyncCore` | SwiftPM + Bazel | Foundation | ID allocator, markdown → entities, read‑state math, presence and system‑post mapping |
| `MattermostSync` | Bazel only | TelegramCore, Postbox, SwiftSignalKit, MattermostKit, MattermostSyncCore | everything below |
| TelegramCore hooks | upstream edits | — | `MattermostBackend` switch, null network engine, injection points |

**Rule:** MattermostSync uses public TelegramCore/Postbox API. When it needs something internal, add the narrowest public hook in TelegramCore (a protocol or closure on `Account`) instead of moving MattermostSync into TelegramCore. TelegramCore is a huge module; keeping our code out of it keeps incremental builds fast.

## Components

```
MattermostAccount (one per server/account)
 ├─ store: MattermostSyncStore          SQLite: id map, cursors, server/session info
 ├─ client: MattermostClient            REST
 ├─ socket: MattermostWebSocket         live events
 ├─ bootstrap: Bootstrapper             first sync / full resync
 ├─ events: EventApplier                WebSocket events → Postbox
 ├─ catchUp: CatchUp                    after non-resumed reconnect / foreground
 ├─ holes: HoleFiller                   postbox.messageHistoryHolesView() → REST
 ├─ sender: PostSender                  PendingMessageManager seam
 ├─ ops: OperationConsumers             read state, delete, reactions, mute, pins, typing
 ├─ converters: PeerConverter, PostConverter, MediaConverter
 └─ resources: MattermostResources      MediaBox fetchers (files, avatars, emoji)
```

All writes to Postbox go through one serial `MattermostAccount.queue`. Each unit of work does its ID‑map transaction first, then one `postbox.transaction`. The ID map is the source of truth for IDs and is idempotent: if the app dies between the two writes, the hole is still there, the page is refetched, and the same post IDs get the same local IDs.

## Storage: `MattermostSyncStore`

Separate SQLite file per account at `<rootPath>/account-<id>/mattermost/sync.sqlite`. It lives in the app group, so the notification and share extensions can open it. It is **not** a Postbox table: Postbox has no custom‑table API, and a separate file keeps upstream untouched.

| Table | Columns | Purpose |
|---|---|---|
| `server` | url, user_id, site_name, version, capabilities JSON | one row |
| `peers` | mm_id (PK), kind (user/channel/dm/gm), peer_id (Int64), team_id | Mattermost ID ↔ `PeerId` |
| `dm_channels` | channel_id (PK), user_mm_id | DM channel ↔ other user |
| `posts` | post_id (PK), peer_id, local_id, create_at_ms, thread_root_id, tombstone | message ID map (implements `MessageIdStore` from MattermostSyncCore) |
| `pending` | pending_post_id (PK), globally_unique_id, local_message_id | outgoing deduplication |
| `files` | file_id (PK), media_id (Int64) | `MediaId` mapping |
| `cursors` | key (PK), value | `last_sync_at`, WebSocket `connection_id`/`seq` |

The session token is **not** stored here. It goes in the Keychain (shared access group), keyed by account record ID.

### Peer IDs

- Users → `CloudUser`, channels and GMs → `CloudChannel` (GMs as group channels, not `TelegramGroup`: basic groups never get `threadId` on replies; R Assumptions "02").
- DMs → the other user's `CloudUser` peer. The self‑DM → own user peer (Saved Messages).
- **Allocation:** sequential per namespace, starting at 1, per account, skipping the user ids Telegram's code special-cases (`ReservedPeerIds`: 777000 service notifications, 333000, 489000 verification codes, 708513 and 1271266957 Replies, 225079 import, 2666000 anonymous saved messages, 0). **Exception:** the own user's ID is a stable hash of `(server URL, user ID)` placed above the sequential range. Two servers must never give their own users the same `PeerId`, or `SharedAccountContextImpl` deletes one account (R§1.3). Verify the usable `PeerId.Id` payload width (R§3.1) before fixing the hash width.

### Message IDs

MattermostSyncCore's allocator (plan 02, option 2) behind `MessageIdStore`, backed by the `posts` table. Namespace `Cloud` for server posts, `Local` for messages being sent. Contract with Postbox (R§3.3): within a peer, local ID order equals `(create_at, post_id)` order.

**Unread counting (2D).** Mattermost counts a post once; Postbox counts incoming messages. The non-primary messages of a multi-file post carry Postbox's `NotCountedAsUnread` flag (an upstream addition), so adding, reading and deleting them leaves the unread count alone and an album is one unread. **Badges:** the "@" mention badge (tag summary `.unseenPersonalMessage`) is shown for channels only; DMs and GMs show the unread count alone, since Mattermost counts every DM/GM message as a mention.

**Post parts (2C).** A post shown as several messages (one per file, `PostLayout`) owns several ids: its own entry (part 0, the primary message) and parts `<post id>#01`, `#02`, … (`PostParts`). Part keys share the post's `create_at` and sort right after it and before any other post (`#` sorts before `[a-z0-9]`), so the allocator places them like any key. Only cursors (`HistoryHole.cursor`, `fillCursor`, `aroundCursor` return the server post of a part) and deletes (`markDeleted` takes the parts along) know about parts; `insertPost(_:partCount:)` adds missing parts (an edit added files), `removeParts` tombstones extra ones (an edit removed files; a removed part never comes back). Callers turn any entry into its server post with `entry.serverPostId`.

### Media IDs

`MediaId(namespace: Namespaces.Media.CloudImage | CloudFile, id: Int64)` where `id` is allocated sequentially in `files` (no hash collisions). Shared‑record caveat: the same file in two posts gets the same `MediaId`; that's correct.

## Bootstrap

Order matters (R§3.5: read state must exist before messages are added).

1. REST, in parallel where possible: me, preferences, teams, team members; per team: channels, channel members, sidebar categories; users for DMs/GMs (`POST /users/ids`), statuses.
2. **Postbox transaction 1 (structure):**
   - `updatePeersCustom` for all users and channels (`accessHash: .personal(0)`, R§4).
   - Chat‑list inclusion for **every** channel and DM: `.ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: last_post_at)` (R§3.6; without it channel history stays "loading", R§3.3 "CloudChannel gate").
   - Remove chat‑list holes for `.root` and archive (R§3.7).
   - `resetIncomingReadStates` with `.idBased(...)` for every peer (counts from Mattermost; max IDs resolved once posts are known, see below).
   - Mention badges with `replaceMessageTagSummary(.unseenPersonalMessage)`.
   - Favorites → `setPinnedItemIds`.
   - Team folders → `ChatListFiltersState` (local only; Telegram's filter sync is never started).
3. **Latest page per channel**, prioritized: unread channels first, then by `last_post_at`, concurrency ~4. Each page goes through the normal page‑write path (below) with `location: .UpperHistoryBlock`, which clears the hole above the oldest loaded post (R§3.3).
4. Store `last_sync_at = server time of step 1`. Open the WebSocket.

Later launches skip bootstrap and run catch‑up.

## Writing a page of posts (shared by bootstrap, hole fill, catch‑up)

1. Collect users and channels referenced by the page that are not yet known; fetch and write them first.
2. Allocate local IDs for the page through the allocator (ID‑map transaction).
3. Convert each post with `PostConverter` → `StoreMessage`:
   - `id` = (peer, Cloud, local ID); `timestamp` = `create_at / 1000`
   - `flags`: `.Incoming` unless `user_id == me`
   - `authorId` = user peer
   - `text` + `TextEntitiesMessageAttribute` from the markdown parser
   - `threadId` = root post's local ID when `root_id` is set; reply → `ReplyMessageAttribute(messageId: root)`
   - root posts with replies → `ReplyThreadMessageAttribute(count: reply_count, latestUsers: participants…)`
   - `EditedMessageAttribute` when `edit_at > 0`
   - `ReactionsMessageAttribute` from `metadata.reactions`
   - media from `metadata.files` (`TelegramMediaImage` for images with dimensions, `TelegramMediaFile` otherwise); several files → one message per file (see "Rendering (2C)")
   - system posts → `TelegramMediaAction(.customText)` with mention entities (see "Rendering (2C)")
   - `tags`: `.photoOrVideo`, `.file`, `.webPage`, `.unseenPersonalMessage` (mentions of me) as appropriate
4. One Postbox transaction: `addMessages`, then `removeHole` for the covered range (see the fill contract), then read‑state adjustments.

## Hole filling (`HoleFiller`)

Replaces `managedMessageHistoryHoles` (R§3.3). Observes `postbox.messageHistoryHolesView()`, keeps one in‑flight fetch per `(peerId, threadId, space)`.

| Hole request | Mattermost call |
|---|---|
| `.range(start, end)` going older from boundary local ID `b` | `GET /channels/{c}/posts?before=<post(b)>&per_page=60` |
| `.range` going newer from `b` | `GET /channels/{c}/posts?after=<post(b)>&per_page=60` |
| `.aroundId(x)` (permalink) | `GET /posts/{x}`, plus `before=x` and `after=x` in parallel |
| `threadId != nil` | `GET /posts/{root}/thread` |
| `space: .tag(.pinned)` | `GET /channels/{c}/pinned` |
| `space: .tag(...)` file tags (photos/videos, files, music, voice, GIFs; 2D) | `POST /files/search` with `in:<channel id>` (100 files per page, up to 20 pages), then `POST /posts/ids` for the posts not loaded (plus their thread roots), written one by one; one search per channel serves every file tab; all file tag holes removed |
| other `space: .tag(...)` (links, …) | local only: the tag hole is removed, the tab shows the loaded history (Mattermost can't search for posts with links) |

**Fill contract (load‑bearing, R§3.3):** always remove at least the requested range, even for an empty response, or the request repeats every 20 s forever. When a page reaches the channel's first post (`prev_post_id == ""`), remove the hole down to 1.

## Live events and catch‑up

As in plan 03. Additions from the research:
- Feed `Account`'s "is updating" override from bootstrap/catch‑up state and the null engine's connection state from the WebSocket state, so the title shows "Connecting…"/"Updating…" truthfully.
- `channel_viewed` from another device → `applyIncomingReadMaxId`.
- A 401 anywhere → `delegate.networkSessionAuthorizationRequired()` path (R seam step 1) → re‑login.

## Replacing managed operations

Status: all done in Phase 2A (2026‑10‑26). Code in `submodules/MattermostSync/Sources/Write/`.

| UI action | Postbox write (unchanged) | Telegram consumer (disabled) | Mattermost consumer |
|---|---|---|---|
| send | `.Unsent` message | `PendingMessageManager` network part | `PostSender` (`MattermostMessageSender`, installed with `Account.mattermostSetMessageSender`): `POST /files` with progress, `POST /posts` with `pending_post_id` = `globallyUniqueId`, one at a time per channel; Local → Cloud rewrite in place (`applyOwnPost`) |
| edit | `PendingUpdateMessageManager` | `requestEditMessage` | `PUT /posts/{id}/patch` (text only) |
| delete | `CloudChatRemoveMessages` op log | `managedCloudChatRemoveMessagesOperations` (gated in `Account.init`) | `DELETE /posts/{id}`; 403 → post restored + toast; "for me" stays local |
| react | pending `.updateReaction` | `managedApplyPendingMessageReactionsActions` (never started) | `POST /reactions` / `DELETE …/reactions/{name}`, optimistic, rollback on failure |
| mark read | read‑state sync table | `managedSynchronizePeerReadStates` | `POST /channels/members/me/view` (Spike D) |
| mute | pending notification settings | `managedPendingPeerNotificationSettings` (never started) | member notify props `mark_unread: mention` / `all` |
| pin chat | `SynchronizePinnedChats` op log; team folder `pinnedPeers` | `managedSynchronizePinnedChatsOperations` (never started) | Favorites sidebar category (both categories in one `PUT`); `favorite_channel` preference on old servers |
| typing | local typing activities | `managedLocalTypingActivities` (gated in `Account.init`) | WebSocket `user_typing` (`parent_id` in threads), throttled |

Each consumer observes the same Postbox source the Telegram one does (`KeyedOperationRunner`). Consumers that Telegram starts in `Account.init` are gated off by `MattermostBackend.isEnabled` there; the rest live in `AccountTaskManager`, which never starts.

**Send details.**
- Order and offline: transient errors (offline, server down, 5xx, 429) are retried with a backoff of up to 5 s, woken by a WebSocket reconnect; messages stay pending (clock) and go out in order. Other errors fail the message (Telegram's failed state; "Resend" re-enqueues it).
- Echo deduplication: the `pending` table row is written before the request. The WebSocket `posted` echo of a request in flight is ignored (the response rewrites, so `deliveredMessageEvents` fires); an echo without a request in flight (app restarted) rewrites the message itself.
- The delivered event is emitted inside the rewriting transaction (as Telegram's `pendingMessageEvent`), before PendingMessageManager sees the unsent id disappear.
- Media data of the upload is moved to the `MattermostFileResource` ids (file and preview; thumbnail when the local image has one).

**Synthetic configuration** (`SyntheticConfiguration.swift`): at every start the app configuration (ui‑inventory §0.2 keys; `MaxPostSize` from the client config after bootstrap) and an `AvailableReactions` list: about 65 picker emoji (enabled), the server's custom emoji (enabled, `:name:`), the built‑in emoji that reactions use (disabled, so those reactions render; added as posts and `reaction_added` events with new emoji arrive, kept in the `reaction_emoji` cursor; listing all 1,900 emoji made the list 4.4 MB), plus the `CloudTopReactions` list the context menu reads. Reaction files are static WebP "custom emoji" files whose `LocalFileMediaResource` ids are hashes in a reserved range; `MattermostReactionImages` renders them on demand (Apple Color Emoji glyph, or the custom emoji image from `GET /emoji/{id}/image`).

## Rendering (2C)

| Mattermost | Telegram | Where |
|---|---|---|
| Post with N files | N messages: images first (one `groupingKey`: an album), then other files (another key: a file group); text on the last file, else the album's first image; reactions, reply count, pinned flag, buttons on the primary (part 0), which Telegram reads them from for the whole group; thread/reply references on every part | `PostLayout`, `PostConverter.storeMessages`, `writeMessages` (reconciles parts on edits) |
| Reaction / reply / edit / delete of any part | the post (`postReference` → `serverPostId`); reactions written to the primary | `OwnPosts`, `OperationConsumers` |
| Album sent from the app | one post with all files (`MattermostMessageSender.sendMessageGroup`); the Local group is rewritten part by part (paired by uploaded file id) | `PostSender`, `applyOwnPost` |
| `props.attachments` | pretext, then a block quote (stands in for the colour bar, which Telegram can't colour per message) with author, title (link), text, fields (`Title: value`), footer + date; first `image_url`/`thumb_url` on the server as the photo, text above it (`InvertMediaMessageAttribute`) | `AttachmentConverter` |
| Buttons / menus | inline keyboard (`ReplyMarkupMessageAttribute`, callback data = `MattermostPostActionData` JSON, styles good/danger/primary); tap → `MattermostPostActions.perform` → `POST /posts/{id}/actions/{id}` (`selected_option` for menus; user/channel menus offer the known users/channels); the integration's update arrives as `post_edited`, its ephemeral answer (`ephemeral_message`) as a toast | `PostActions.swift`; TelegramUI `MattermostPostActions.swift` (hooked into `requestMessageActionCallback`) |
| `override_username` / `override_icon_url` (webhooks, bots) | a synthetic bot user per override (`override:<name>\n<icon>` in the peers table) as the author: name, avatar and bubble grouping follow without upstream changes | `OverridePeers.swift` |
| System posts | `.customText` service message from `ServiceAction.formattedText`: users as `TextMention`, new header/purpose/name in bold | `PostConverter.serviceAction` |
| `:name:` custom emoji in text | `.CustomEmoji` entity over the `:name:` text, file = the reaction image file of `:name:` (static WebP rendered from `/emoji/{id}/image`), stored with `storeMediaIfNotPresent` so `associatedMedia` resolves offline; only names in `metadata.emojis` (others stay text, as on Mattermost) | `PostConverter`, `MattermostReactionImages` |
| Member count | `/channels/{id}/stats` → `CachedChannelData.participantsSummary.memberCount` (after bootstrap, channel refresh, `user_added`/`user_removed`); the chat title and group info skip Telegram's online-member lists | `MemberCounts.swift`; TelegramUI `ChatControllerContentData`, `PeerInfoData` |

Member *lists* (group info Members pane, @-mention suggestions) still come from `channels.getParticipants` through `ChannelMemberListContext`; feeding them needs a TelegramCore seam in `_internal_channelMembers` (later).

## Media resources

`MattermostFileResource(fileId, variant)`, `MattermostAvatarResource(userId, lastPictureUpdate)`, `MattermostURLImageResource(url)` (same-origin images only: attachment images, webhook icons; flattened onto white because Telegram draws photos opaque), all `TelegramMediaResource` + `PostboxCoding`, registered in `mattermostDeclareEncodables()` (app and every extension; R§6). Type names are part of the storage format: never rename them. Fetched through the auxiliary `fetchResource` hook with a `URLSession` that adds the bearer token and supports byte ranges.

## Login (Phase 2B, implemented)

Option (a) from R§1.4 / ui-inventory §4.3: Telegram's auth record stays; `UnauthorizedApplicationContext` shows `MattermostLoginController` (MattermostUI) instead of `AuthorizationSequenceController`, and `UnauthorizedAccount.init` skips the MTProto key prefetch and backup-address discovery. Screens: server address (ping, client config, license; minimum version `ServerCompatibility.minimumVersion`, 11.7) → credentials (login id + password as the config allows, SSO buttons) → MFA code. On success `MattermostAccountSetup.createAccount` (shared with the env-var debug login):
1. Creates the `MattermostSyncStore` (server info, capabilities, own-user peer id = hash of server URL + user id) and stores the token in the Keychain (key: account record id).
2. Writes `AuthorizedAccountState(peerId: ownUserPeerId)` and the own user into the auth record's postbox (the debug login uses a new record and postbox).
3. Repeats `switchToAuthorizedAccount`: `updateRecord` (environment + sort order), `setCurrentId`, `removeAuth`.
4. Bootstrap runs when the account loads. The same user can't be added twice (it would collide on the own peer id).

"Add Account" (Settings, logout options, account switcher) is Telegram's `beginNewAuth` unchanged; cancel removes the auth record.

**Logout:** Telegram marks the record `.loggedOut`; its `managedCleanupAccounts` is skipped while `MattermostBackend.isEnabled` (it waits for an MTProto answer that never comes). `MattermostSync.startLifecycle` watches the records instead: stop the sync, `POST /users/logout` (best effort), remove the Keychain token, remove the record, delete `<root>/account-<id>`. Keychain tokens of records that no longer exist (they survive reinstalls) are removed at launch.

**Session expiry:** a 401 to a request sent with the token (MattermostKit `Configuration.onUnauthorized`, confirmed with `GET /users/me`) or a rejected WebSocket stops the sync and marks the session expired (flag in the sync store, kept across launches). MattermostUI asks "Session Expired → Log In" (again whenever the app becomes active); while expired, `Account.mattermostSessionExpired` makes the network state read online and the chat list title "Session Expired" (a tap opens the re-login, `MattermostBackend.requestRelogin`). **Sends while expired** stay pending: `PostSender` writes with the account's running sync and otherwise waits for the next one (a re-login); a 401 during a send is confirmed with `GET /users/me`, expires the session and waits too. A logout ends the wait (the message fails). Re-login as the same user stores the new token and restarts the sync on the existing data; as a different user, the old account is logged out (data deleted) and a new account created, because ids, read state and caches belong to the old user.

## Spike D scope (read‑only)

1. Debug login with credentials from `infra/dev-server/.env` (alice), replacing Spike A's fake seeder.
2. Bootstrap: peers, chat list, read states, team folders, latest page per channel.
3. Hole filler: scrolling back through `firehose` (10,000+ posts) and opening an old permalink.
4. WebSocket `posted`/`post_edited`/`post_deleted`/`reaction_added` applied live (posting from the web app or API as bob shows up in the simulator).
5. No sending yet.

**Exit:** a real channel scrolls back to its first post without stalls or duplicate/missing posts, and live posts appear within a second.
