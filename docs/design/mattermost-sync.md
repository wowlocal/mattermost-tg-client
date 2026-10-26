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

Member *lists*: see "Members, composer, commands, dialogs (3D)".

## Members, composer, commands, dialogs (3D)

| Mattermost | Telegram | Where |
|---|---|---|
| `GET /channels/{id}/members` (pages), `GET /users/autocomplete?in_channel=` (search), `scheme_admin` | `_internal_channelMembers` (`channels.getParticipants`) asks the account's `MattermostMemberProvider` (TelegramCore seam, installed with `Account.mattermostSetMemberProvider`, keyed by the account peer id). Feeds everything built on `ChannelMemberCategoryListContext`: the group info Members pane and its search, `searchPeerMembers`, admin/bot lists, small groups' "N members, M online" (title and group info; groups over 50 still skip Telegram's online count). Admins get admin info ("admin" label). Pages follow Telegram's offset/limit; searches return the first page only. | `MemberLists.swift`; TelegramCore `Mattermost/MattermostMemberProvider.swift`, `ChannelMembers.swift` |
| `user_added` / `user_removed` (others) | `MattermostSync.memberChanges` → `PeerChannelMemberCategoriesContextsManager.externallyAdded/Removed` (MattermostUI `MattermostChatHooks`); the lists also refresh their head every 30 s | `MemberLists.swift` |
| `user_removed` (own, e.g. `/leave`) | the chat leaves the chat list (`.notIncluded`) and the team folders; history stays | `MemberLists.swift` (`applyOwnRemoval`; 3D-2 owns the leave UI) |
| `@` `~` `:` `/` autocomplete | Telegram's suggestion panels: the trigger scan is replaced while Mattermost is on (`ChatContextQuery/MattermostContextQueries.swift`: `@`/`~` after a non-word character, `:` + 2 chars after whitespace, `/` = the whole first line); queries go to `MattermostComposer` (`Composer/Autocomplete.swift`) through `MattermostComposerQueries.swift` (TelegramUI). `@`: in-channel users, then `@here`/`@channel`/`@all` (only with `use_channel_mentions` in the user's system/team/channel roles, `POST /roles/names`, cached 60 s), then the team's other users; `~`: the team's channels as in-memory channel peers with `username` = name (mine first; "~name" in the panel); `:`: `EmojiTable.search` + `GET /emoji/autocomplete`, in the emoji strip (custom emoji insert `:name:` with the reaction image); `/`: `GET /teams/{id}/commands/autocomplete_suggestions` (sub-commands too) in the command panel, a tap inserts the command line. Suggestion-only peers use ids in `[2^39, 2^39 + 2^20)` and are never stored. | as listed |
| Slash commands | `sendCurrentMessage` → `mattermostRunSlashCommand` when `SlashCommand.parse` accepts the text (leading `/`, first word without another `/`, not `//`): `POST /commands/execute` (thread root from the thread view or the reply), the composer clears; unknown trigger → "Send as Message?"; other errors → alert, text restored; `goto_location` on the server → opens the chat (`/join`), else the URL | `Composer/SlashCommands.swift`, TelegramUI `MattermostComposerQueries.swift` |
| `ephemeral_message` | a `Local` message (no unsent flag, `.Incoming` + `NotCountedAsUnread`), in the post's thread, author = the override/bot, or a "System" bot for the server's own answers; "(Only visible to you)" in italics; no buttons/reactions. Button answers still go to the waiting action (toast) | `Composer/EphemeralPosts.swift` |
| `open_dialog` | `MattermostComposer.dialogs` → modal `ItemListController` (MattermostUI `MattermostDialogController`): text (keyboards by subtype), textarea, select (static; users/channels searched on a second screen), bool, radio; defaults, required/length/subtype checks (MattermostKit `DialogElement.validate`), server field errors in red section headers; `POST /actions/dialogs/submit` with the chat of the last command/button tap; Cancel posts `cancelled` when `notify_on_cancel` | `Composer/Dialogs.swift`, MattermostUI |

## Collapsed reply threads (3B)

**On/off.** On when the server's `CollapsedThreads` allows it (`always_on`, or `default_on`/`default_off` plus the user's `display_settings`/`collapsed_reply_threads` preference, the server default without one). Decided in the bootstrap before anything is written (read states and messages depend on it), persisted in the sync store (cursor `collapsed_threads`, restored when the sync starts so chats open with the right history) and published per account through `MattermostBackend.setCollapsedThreads` (keyed by the account's own peer id). A `preferences_changed`/`config_changed` event switches live (`CollapsedThreads.swift`).

**Hiding replies: a root-post tag (research option (a)).** Every root post (all its parts) carries `MessageTags.mattermostRootPost` (bit 16, in `MessageTags.all` and `upgradedMessageHoles`, so the tag space has holes like the media tags), always, CRT on or off; new posts get it at enqueue (`EnqueueMessage`: no reply target, no thread). While CRT is on, `AccountViewTracker` opens a chat's *main* history (`.peer(peerId, threadId: nil)`, no tag asked for) as the view of that tag, for channels, GMs and DMs (not Saved Messages). Callers keep passing no tag, so everything that keys on `tag == nil` (scroll to the first unread, scroll restoration, read marking, the unread separator: `maxReadIndex` is computed over the tagged entries) behaves as for the main history; media tabs (their own tags) and thread views are unaffected. The tag space's holes are filled by the main history's paging (`HoleFiller`: a `.tag(.mattermostRootPost)` request pages like `.everywhere`, whose hole removal clears tag spaces), so the ID map stays contiguous over all posts. Switching CRT reloads open chat histories (`ChatHistoryListNode` observes `collapsedThreadsUpdates`). Rejected: (b) a reply namespace (reply ids, read states and holes per namespace, the send path's Local→Cloud rewrite and a migration of every reply on each switch); (c) a custom loader (the chat screen is built on Postbox views).

**Counting.** With CRT on, incoming replies are `.NotCountedAsUnread` (the 2D flag) and never get the chat's mention tag; read states and mention badges come from the `_root` counters (`ChannelState.counters(collapsedThreads:)`, `memberMentionCount`); live posts bump `total_msg_count_root` only for roots; an own reply doesn't mark its channel read. Thread unreads are the threads list's.

**Re-rendering on a switch** (`reapplyCollapsedThreads`, also the one-time upgrade of data from before 3B, cursor `thread_layout`): one transaction per chat over its stored messages: root tags, DM replies moved into their root's thread (DM replies now get `threadId` = root like channel replies), reply flags and mention tags, the CRT marker on roots; then the read states from the server counters.

**"N replies" button.** A root's `ReplyThreadMessageAttribute.commentsPeerId` is the chat itself while CRT is on; TelegramUI's `hasCommentButton` then shows Telegram's comment footer ("N Replies" with the latest repliers' avatars) in the chat's history and hides the small count next to the time. The marker is message data, so switching re-renders bubbles with the messages.

**Thread view.** `ChatLocation.replyThread(ChatReplyThreadMessage(threadId: root local id, isForumPost: true))`, i.e. the Postbox thread view `.peer(peerId, threadId)` (no network `ReplyThreadHistoryContext`). The root is shown above the replies as Telegram's comment threads show their post (`ChatHistoryEntriesForView`, from the view's `.message(effectiveTopId)` additional data), with the "Replies" divider; the title is Telegram's "N Replies". Its hole is filled by `fillThreadHole`: the whole thread from `GET /posts/{root}/thread`, in pages of 200 (`direction=down`, `fromPost`/`fromCreateAt`, until `has_next` is false; older servers answer in one page), then the thread hole is removed entirely; new replies arrive live. Opening: the replies button / "View Replies" (`openMessageReplies` → local, `MattermostThreads.swift` in TelegramUI), notification taps on replies (only with CRT on; with CRT off the chat opens at the reply), `postDestination` (permalinks: a reply opens its thread at it), and `navigateToMessage` of a reply hidden by CRT. Sending in a thread view: as in 2A (`threadId` → `root_id`).

**Threads list** (`Threads.swift`, MattermostUI `MattermostThreadsController`): per team, `GET /users/me/teams/{team}/threads?extended=true` (up to 500), users and missing roots written so rows open their thread. Live: `thread_updated` (upsert; the root's reply count and latest repliers from the server), `thread_read_changed`, `thread_follow_changed`. Entry point: a threads button in the chat list header (the stories button's slot) with the selected team folder's unread threads as badge (`@` when one has a mention); Telegram's chat list has no row type besides chats and the archive, so a "Threads" row would need a new entry kind through ChatListNode. Follow/unfollow: message menu (Follow / Unfollow Thread), the list's long press. Viewing a thread with unread replies marks it read (`AccountContext.applyMaxReadIndex(.replyThread)` → `PUT …/threads/{root}/read/{now, or the seen reply's create_at}`) and clears its notifications.

## Directory and membership (3D-2)

| Mattermost | Telegram | Where |
|---|---|---|
| What the user may do with a channel: the permissions of the system roles (`user.roles`), the team member's roles and the channel member's roles (`POST /roles/names`; a channel or team scheme's roles are part of the members' `roles`) → edit properties, manage members, manage roles, archive, unarchive (`manage_team`), convert to private, leave (not the town square, not GMs) | `MattermostChannelAccess` bits in `TelegramChannel.version` (a field Telegram's UI never reads for these peers), so they are persisted and a change re-renders every screen observing the peer; screens read `TelegramChannel.mattermostAccess` | SyncCore `ChannelAccessRules` (tested); MattermostSync `Directory/ChannelAccess.swift` (roles loaded by the bootstrap; `role_updated`, `memberrole_updated`, the own `user_updated` reload them and rewrite peers whose access changed; `channel_scheme_updated` refreshes the channel); TelegramCore `Mattermost/MattermostChannelAccess.swift` |
| User directory: `GET /users?active=true` pages (`in_team` with `RestrictDirectMessage: team`), `POST /users/search`; Add Members: `in_team` + `not_in_channel` | MattermostUI New Message (the chat list's compose button: `SharedAccountContext.makeComposeController`), New Group Message, Add Members; users are written to Postbox so rows have pictures | `Directory/MattermostDirectory.swift`; MattermostUI `MattermostDirectoryControllers.swift` |
| DM `POST /channels/direct`, GM `POST /channels/group` (2 to 7 others) | the chat opens once `refreshChannel` wrote it (offline: the DM opens anyway and the first message creates it, 2A) | same |
| Browse: `GET /teams/{id}/channels` / `…/channels/deleted` pages, `POST …/channels/search` / `search_archived`, member counts `POST /channels/stats/member_count`; Join `POST /channels/{id}/members` | team tabs, search, Archived switch; a channel the user isn't in opens a preview (name, members, purpose, header, and its newest messages read-only: `GET /channels/{id}/posts` works for non-members of public channels) with Join; joined channels open. Search (3C) opens a not-joined channel in the same preview (`mattermostChannelPreviewController(context:channelId:)`) | same; TelegramUI `MattermostFinding.swift` |
| New Channel `POST /channels` | display name → URL name as Mattermost's clients derive it (SyncCore `ChannelNaming`, tested: `cleanUpUrlable`, 2–64 chars, a generated id when nothing is left), public/private by `create_*_channel`, purpose, header; a taken URL (`store.sql_channel.save_channel.exists`) shows under the URL | MattermostUI `MattermostChannelEditControllers.swift` |
| Channel settings `PUT /channels/{id}/patch`, `DELETE /channels/{id}` (archive), `POST /channels/{id}/restore`, `PUT /channels/{id}/privacy` | the profile's Edit button opens Channel Settings (Telegram's edit mode is not used for channels); archived channels move to Archived Chats and leave the team folders (and come back when restored), and are read-only: their peer gets default banned rights for sending, so the composer shows Telegram's "writing isn't allowed" panel (`Conversation.DefaultRestrictedText`, reworded in Relay.strings) | same; PeerInfoScreen `MattermostPeerInfoDirectory.swift`; `PeerConverter.archivedChannelRights` |
| Members: add `POST /channels/{id}/members`, remove `DELETE …/members/{user}`, channel admin `PUT …/members/{user}/schemeRoles` | the members pane's Add Members, swipe and context menu (Remove / Make or Remove Channel Admin; no Telegram restrictions or rights editor); the acting user's lists update at once (others' role changes send no event, so the change is announced locally), other users' via `user_added`/`user_removed` | same; MattermostUI `MattermostMemberActions.swift` |
| Leave `DELETE /channels/{id}/members/me`; DM/GM close: `direct_channel_show` / `group_channel_show` = false | Telegram's Leave (profile) and Delete/Leave (chat list) end in `removePeerChat` → `CloudChatRemoveChatOperation` → MattermostSync's consumer; a refusal (town square) puts the chat back with a notice; Leave is hidden for the town square and GMs (Mattermost can't leave GMs); a closed DM/GM is forgotten, so its next post loads it again and sets `*_channel_show` back to true (as the web app does; opening it from New Message does too) | `removeChat`, `showDirectChat` in `Directory/MattermostDirectory.swift`, `OperationConsumers.pushDeletion` |
| User profile: nickname, position, email (when the server shows it), local time (automatic or manual zone), custom status (Unicode emoji, expiry) | rows after the username on the profile; the bio row (the position) is shown for bots only | `MattermostDirectory.userProfile`; PeerInfoScreen `mattermostProfileItems` |

## Finding things (3C)

**Seam.** Telegram's search UI calls `searchMessages` (chat list search and its media tabs, search in chat and its results list, hashtag search, the profile's files/links/music search), `searchPeers` (`contacts.search`) and `requestUpdatePinnedMessage` / `requestUnpinAllMessages`. While `MattermostBackend.isEnabled` these ask the account's `MattermostSearchProvider` (TelegramCore `Mattermost/MattermostSearchProvider.swift`, installed by MattermostSync with `Account.mattermostSetSearchProvider`, keyed by the account peer id like the member provider). A provider page is a list of message ids that are already in Postbox; TelegramCore loads the messages and merges pages into `SearchMessagesState` as it merges Telegram's (`nextRate` carries the next page). `searchHashtagPosts` (Telegram's public posts) answers empty; hashtags go through `searchMessages`. `getSearchMessageCount` answers nil.

| Telegram asks | Mattermost |
|---|---|
| `.general` (chat list search; scope everywhere / private chats / groups) | `POST /teams/{id}/posts/search` for every team (or the team of a team folder filter), merged by post id (DMs and GMs come back in every team), newest first. The query goes as typed (`from:`, `in:`, `before:`/`after:`/`on:`, quotes, `-word`, `#tag`, `*`); date filters become `after:`/`before:` of the neighbouring days (both are exclusive on the server). |
| `.peer` (search in chat, results list, "from" member) | the same with `in:<channel id>` (ids work as well as names, for DMs and GMs too) and `from:<username>`; in a thread view only the thread's posts; in a channel's main history under collapsed threads only root posts (stepping through results can only show those; replies are found from the chat list search, which opens their thread). |
| media tabs (tags) | file tags: `POST /teams/{id}/files/search` with an `ext:` filter per tab (photos/videos, music; files: all), then `POST /posts/ids`; the messages of each post that carry the tab's tag. Links: post search filtered to posts with a URL. Voice: none (Mattermost has no voice messages). Empty terms are not searched (the server rejects them). |
| `searchPeers` | `POST /users/search` (users, written as peers; with a DM: "my" results, else "Global Search") and `POST /teams/{id}/channels/search` (public channels; joined ones are "my" results, others previews). |
| pin / unpin / unpin all | `POST /posts/{id}/pin` / `unpin`; the `.pinned` tag of the post's primary message is set when the server accepts (the pinned bar and the "Pinned Messages" list read the tag); `post_edited` echoes and other clients' pins arrive the same way, and a post pinned elsewhere that isn't loaded is stored then. Telegram's "pin and notify" / "pin for me" choice is skipped. DM and self-DM pinning needs `CachedUserData.canPinMessages`, written for every user. |

**Paging.** The database search backend (the default without Elasticsearch/Bleve) ignores `per_page`, answers page 0 with at most 100 posts and nothing for later pages (`SqlPostStore.SearchPostsForUser`: "we don't support paging for DB search"). The provider asks for a next page when a team's page was full, so a search engine that pages works too; with the database backend a search shows at most 100 posts per team (narrow it with modifiers). `matches` is empty with the database backend: highlighting uses the query's words (`SearchQuery.highlightText`, modifiers removed; also in the chat list search rows).

**Results become messages.** Posts not stored yet (and the roots of replies among them) go through the page-write path as singles: ids from the allocator, a one-post island far back in history, users first. Opening a result is then a permalink (`navigateToChatController` with `subject: .message`): the chat loads the history around it through the hole filler; a reply hidden by collapsed reply threads opens its thread at the reply instead (TelegramUI `MattermostFinding.swift`, the one hook in `navigateToChatControllerImpl`; it also covers saved posts and mentions).

**Not-joined channels.** A public channel found by search that the user isn't a member of is written as a `TelegramChannel` with `participationStatus: .left` (stable peer id from the peers table, no chat-list inclusion, no channel state, so nothing syncs it). Opening it asks "Join ~name?"; joining is 3D-2's `joinChannel` (`POST /channels/{id}/members`, then the channel written like any other), then the chat opens. A read-only preview (history without joining) would need a channel state for a non-member channel, which the catch-up, read-state pusher and counters assume is a member; 3D-2's Browse Channels shows a preview screen instead (`mattermostChannelPreviewController`, internal to MattermostUI), which search could open once it is public.

**Saved posts** (Mattermost's flagged posts; Telegram's Saved Messages stay the self-DM): `flagged_post` preferences, loaded on every new WebSocket connection and kept current by `preferences_changed`/`preferences_deleted`. The message menu offers Save Post / Remove from Saved (optimistic, reverted on failure); `GET /users/me/posts/flagged` (all teams, `team_id` supported) lists them in Settings → Saved Posts; an unsave (here or elsewhere) removes the row at once, a save elsewhere reloads the list.

**Recent mentions**: Mattermost's own definition, an OR search (`is_or_search`) for `@username`, the first name when `first_name` is on, and the `mention_keys` (not `@channel`/`@all`/`@here`), in every team, merged. Settings → Recent Mentions; the keys are highlighted in the rows.

**Where.** Saved Posts and Recent Mentions are Settings rows under Saved Messages (ChatListUI `MattermostPostListController`, Telegram's search result rows): Settings already holds the account's own lists (Saved Messages, Devices), Relay's tab bar has only Chats and Settings, and the chat list header's free slot is taken by the threads button (3B). Mattermost's mobile app has them as tabs.

## Rich content and links (3E)

| Mattermost | Telegram | Where |
|---|---|---|
| `metadata.embeds` `opengraph` | `TelegramMediaWebpage` (loaded content, type `article`) on the text message: site name (`og:site_name`, else the host), title, description, the first `og:image` with dimensions (from the embed or `metadata.images`) as a `MattermostURLImageResource` photo; large under the text when at least 400 px wide (and not wider than 3:1, `WebpagePreviewMessageAttribute.forceLargeMedia`), else a thumbnail beside it | `LinkPreviewConverter` |
| `image` embed (a link to a picture) | webpage of type `photo`: the picture, large, the host as the site | same |
| `permalink` embed (`EnablePermalinkPreviews`) | webpage: the linked post's author as title, its text (markdown rendered as plain text, 300 characters), `~channel` as the site; tapping it opens the post (below). Shown whatever the user's link preview setting, as in the web app (marked `isSafe` in its `WebpagePreviewMessageAttribute`, which is how the re-render tells it from link cards) | same |
| `link` embed (no preview data), `message_attachment` | no card (Mattermost shows none, or the attachment) | — |
| embeds added later (the server fetches the page after posting, then `post_edited`) | the edit rewrites the message; the webpage's media id includes a hash of its content (`webpage:<post>:<hash>`), so a changed preview is a new media entry rather than an update of a shared one | `LinkPreviewConverter.result` |
| `props.remove_link_preview` ("Remove preview" in the web app) | no card | |

One card per post, and only when the message carrying the text has no other media (Telegram shows one media per message): posts with files or an attachment image keep those. Messages with link entities or a card get the `.webPage` tag, so the profile's Links tab lists them.

**Settings** (`RichContentSettings`, `Sync/RichContent.swift`): the server's `EnableLinkPreviews`, `EnablePermalinkPreviews`, `HasImageProxy`, `EnableLatex` + `EnableInlineLatex`, and the user's `display_settings` `link_previews` and `render_emoticons_as_emoji` (both default on). Read by the bootstrap before posts are written (and restored from the sync store at start, cursor `rich_content_settings`), changed live by `config_changed` / `preferences_changed` / `preferences_deleted`. A change, and the first launch of a build with 3E (cursor `rich_content`), re-renders what the user is likely to see: with link previews off every stored link card is dropped at once (no network); then the newest page (60 posts) of every chat is fetched again and rewritten, because the stored messages no longer have their markdown and embeds (about 0.3 s for 53 chats on the dev server). Older history keeps its rendering until it is loaded again.

**`POST /posts/ids` has no embeds** (11.7: `metadata` carries files, reactions and emoji, but never `embeds` or `images`, while `GET /posts/{id}`, channel pages, `since=` lists, threads and WebSocket events do). So the re-render uses channel pages, and posts first stored through `/posts/ids` (search results, file tabs, threads list roots, found while not loaded) show no card until the page around them is loaded.

**Images: no third-party fetches from the device.** Preview images on the server itself load directly (as attachment images do since 2C). Images elsewhere load only through the server's image proxy, `GET /api/v4/image?url=<url>` with the session, when the server has one (`HasImageProxy`); the server never rewrites embed image URLs itself, Mattermost's clients build the proxy URL (`getImageSrc`), and so does `fetchURLImage`. Without a proxy the card shows its text only: Mattermost's own clients would then load the picture straight from the linked site, which tells every site linked in a channel the device's address and when the message was read. The same rule now applies to attachment `image_url`s. The decision is made when the post is converted (an image that can't load is left out) and again when the image is fetched.

**Markdown blocks** (MattermostSyncCore `MattermostMarkdown`):
- *Headings*: bold plus `TextEntityType.heading(level)`, stored as `MessageTextEntityType.Custom(type: MattermostCustomEntity.heading(level))`; TextFormat (`MattermostHeadings.swift`, one call in `stringWithAppliedEntities`) scales the fonts in the range (h1 1.4×, h2 1.28×, h3 1.16×, h4 1.08×, h5–h6 1×). Telegram has no heading entity and its text layout no paragraph spacing, so blank lines between blocks stay the spacing. Other renderers (chat list, notifications, reply previews) show bold text.
- *Lists*: `•`, `◦`, `‣` by depth; continuation lines and nested blocks are indented by whitespace as wide as the prefix in SF Pro (an en space for a bullet, figure spaces for digits, a punctuation space for the period), since Telegram's text layout has no hanging indents and ASCII spaces are much narrower than a bullet or a number (measured with CoreText; scales with the font size).
- *Code blocks*: `pre` with the language mapped to the highlighter's (libprisma, Prism grammars) names (`golang`→`go`, `c++`→`cpp`, `zsh`→`bash`, `pgsql`→`sql`, …; Prism's own aliases such as `js`, `py`, `yml` pass through), so Telegram's code block shows the language and highlights it.
- *Tables*: up to 30 monospaced characters per line, an aligned grid in a `pre` block labelled "Table" (with the delimiter row's column alignment; the label row keeps Telegram's copy button off the first line); wider tables as one record per row: the first column in bold, then `Column: value` lines (labels in italic) keeping the cells' links, mentions and emoji, records separated by blank lines. A grid wraps unreadably in a bubble (about 30 characters fit on a phone); Telegram's Instant View table renderer needs a whole page and its own controller, too heavy for a bubble.
- *Inline LaTeX* (`$…$`, with `EnableLatex` and `EnableInlineLatex`): inline code without the dollars (no typesetting). LaTeX code blocks are code blocks (Prism highlights `latex`).
- *Emoticons*: Mattermost's web and mobile apps render `:)`, `;-)`, `:D`, `:P`, `<3`, `:(`, … as emoji by default (webapp `utils/emoticons`, user setting "Render emoticons as emoji"); the parser does the same, only between non-word characters (so `http://`, `10:30`, `Note:D` stay), never in code or URLs.

**Links.** `MattermostLink` (SyncCore) parses a URL against the signed-in servers (each account's server URL and its `SiteURL`): same host, port and path prefix, then `/<team>/pl/<post>`, `/<team>/channels/<name>`, `/<team>/messages/@<user>`, `/<team>/messages/<group message name>`, `/<team>/threads/<root>`, and `/_redirect/pl|channels/…` (channel mentions are `_redirect` links since 2C). The current account wins when several accounts are on one server. `MattermostSync.linkDestination` resolves it: a post is fetched (`GET /posts/{id}`), mapped and opened in its chat at the post (the history around it loads through the hole filler), or in its thread when collapsed reply threads hide it (and for thread links); a channel the user is in opens; a public channel the user isn't in becomes a preview peer and asks to join (3C); a DM is created if needed (3D-2's `openDirectMessage`); failures are alerts (deleted or inaccessible post, unknown channel or user, offline). A link of another account's server switches to that account first (`navigateToChat(accountId:)`). TelegramUI hooks: the external-URL opener (`openCheckedExternalUrl`, which every link tap and every URL from the system reaches) and `openUserGeneratedUrl` (no "Open this link?" prompt for these links).

**App links.** `relay://<host>[:<port>][/<server path>]/<route>` with the routes above, e.g. `relay://chat.example.com/eng/pl/<post id>` or `relay://localhost:8065/engineering/channels/town-square`; the server is named by host and port (without a port, the server on its scheme's default port wins). `relay` is the registered URL scheme (`Telegram/BUILD`, since Phase 1); Telegram's own `relay://` links (`relay://localpeer`, `resolve`, …) don't name a server and keep their meaning. `mattermost://` links (the Mattermost mobile app's scheme, same layout) are understood when tapped inside Relay, but the scheme is not registered: two apps claiming one scheme get links handed to either at random, which would break the official app's links. Universal links (`https://` links opening the app) need an `apple-app-site-association` file on a domain associated with the app; every Mattermost server is its own domain that Relay doesn't control, so they can't work (a server operator could host the file for one server, with the app's team id).

**Copy Link / Share Link** (message menu, after Save Post): `MattermostSync.permalink` = `<SiteURL, else the server URL>/<team>/pl/<post id>`, the team being the channel's, or the user's first team for DMs and group messages (Mattermost resolves the post's channel itself). Copy puts it on the pasteboard with Telegram's "Link copied" toast; Share opens the system share sheet with the URL (Telegram's share sheet sends to Telegram chats). Not offered for service messages and messages not on the server.

## Media resources

`MattermostFileResource(fileId, variant)`, `MattermostAvatarResource(userId, lastPictureUpdate)`, `MattermostURLImageResource(url)` (attachment images, webhook icons, link preview images: on the server directly, elsewhere only through the server's image proxy, see "Rich content and links (3E)"; flattened onto white because Telegram draws photos opaque), all `TelegramMediaResource` + `PostboxCoding`, registered in `mattermostDeclareEncodables()` (app and every extension; R§6). Type names are part of the storage format: never rename them. Fetched through the auxiliary `fetchResource` hook with a `URLSession` that adds the bearer token and supports byte ranges.

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
