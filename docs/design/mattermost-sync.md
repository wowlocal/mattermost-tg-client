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
| `pending` | pending_post_id (PK), globally_unique_id, local_message_id, uploaded_files (4F) | outgoing deduplication; file ids a message already uploaded |
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
   - `updatePeersCustom` for all users and channels (`accessHash: .personal(…)`, R§4; channels `0`, users `1` since
     4H: Postbox stores 0 as "no access hash", and a user read back without one has no `PeerReference`).
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
| Post with N files | N messages: images first (one `groupingKey`: an album), then other files (another key: a file group; 4F: one key for a post with both, so Telegram's bubble shows the mosaic with the files below it as one bubble); text on the last file, else the album's first image; reactions, reply count, pinned flag, buttons on the primary (part 0), which Telegram reads them from for the whole group; thread/reply references on every part | `PostLayout`, `PostConverter.storeMessages`, `writeMessages` (reconciles parts on edits) |
| Reaction / reply / edit / delete of any part | the post (`postReference` → `serverPostId`); reactions written to the primary | `OwnPosts`, `OperationConsumers` |
| Album sent from the app | one post with all files (`MattermostMessageSender.sendMessageGroup`); the Local group is rewritten part by part (paired by uploaded file id) | `PostSender`, `applyOwnPost` |
| `props.attachments` | pretext, then a block quote (the colour bar: 4F colours it with the attachment's `color` through a custom entity TextFormat applies) with author (`author_icon` inline, 4F), title (link; `thumb_url` inline after it, 4F), text, fields (`Title: value`), footer (`footer_icon` inline, 4F) + date; first `image_url`/`thumb_url` on the server as the photo, text above it (`InvertMediaMessageAttribute`) | `AttachmentConverter` |
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

**Threads list** (`Threads.swift`, MattermostUI `MattermostThreadsController`): per team, `GET /users/me/teams/{team}/threads?extended=true` (up to 500), users and missing roots written so rows open their thread. Live: `thread_updated` (upsert; the root's reply count and latest repliers from the server), `thread_read_changed`, `thread_follow_changed`. Entry point: the **Threads tab** of the root tab bar (Chats · Threads · Mentions · Settings, since 2026‑10‑27; before that a threads button in the chat list header). The tab is made at launch, picks the first team once the account has synced, and on each opening switches to the team of the chat list's selected team folder ("All" keeps the team); its badge is the unread followed threads of all teams (`@` in front when one has a mention). Telegram's chat list has no row type besides chats and the archive, so a "Threads" row would need a new entry kind through ChatListNode. Follow/unfollow: message menu (Follow / Unfollow Thread), the list's long press. Viewing a thread with unread replies marks it read (`AccountContext.applyMaxReadIndex(.replyThread)` → `PUT …/threads/{root}/read/{now, or the seen reply's create_at}`) and clears its notifications.

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
| `.peer` (search in chat, results list, "from" member) | the same with `in:<channel id>` (ids work as well as names, for DMs and GMs too) and `from:<username>`; in a thread view only the thread's posts; in a channel's main history replies too (4F; under collapsed threads stepping to a reply opens its thread, the newest result shown while typing is shown as its root). |
| media tabs (tags) | file tags: `POST /teams/{id}/files/search` with an `ext:` filter per tab (photos/videos, music; files: all), then `POST /posts/ids`; the messages of each post that carry the tab's tag. Links: post search filtered to posts with a URL. Voice: none (Mattermost has no voice messages). Empty terms are not searched (the server rejects them). |
| `searchPeers` | `POST /users/search` (users, written as peers; with a DM: "my" results, else "Global Search") and `POST /teams/{id}/channels/search` (public channels; joined ones are "my" results, others previews). |
| pin / unpin / unpin all | `POST /posts/{id}/pin` / `unpin`; the `.pinned` tag of the post's primary message is set when the server accepts (the pinned bar and the "Pinned Messages" list read the tag); `post_edited` echoes and other clients' pins arrive the same way, and a post pinned elsewhere that isn't loaded is stored then. Telegram's "pin and notify" / "pin for me" choice is skipped. DM and self-DM pinning needs `CachedUserData.canPinMessages`, written for every user. |

**Paging.** The database search backend (the default without Elasticsearch/Bleve) ignores `per_page`, answers page 0 with at most 100 posts and nothing for later pages (`SqlPostStore.SearchPostsForUser`: "we don't support paging for DB search"). The provider asks for a next page when a team's page was full, so a search engine that pages works too; with the database backend a search shows at most 100 posts per team (narrow it with modifiers). `matches` is empty with the database backend: highlighting uses the query's words (`SearchQuery.highlightText`, modifiers removed; also in the chat list search rows).

**Results become messages.** Posts not stored yet (and the roots of replies among them) go through the page-write path as singles: ids from the allocator, a one-post island far back in history, users first. Opening a result is then a permalink (`navigateToChatController` with `subject: .message`): the chat loads the history around it through the hole filler; a reply hidden by collapsed reply threads opens its thread at the reply instead (TelegramUI `MattermostFinding.swift`, the one hook in `navigateToChatControllerImpl`; it also covers saved posts and mentions).

**Not-joined channels.** A public channel found by search that the user isn't a member of is written as a `TelegramChannel` with `participationStatus: .left` (stable peer id from the peers table, no chat-list inclusion, no channel state, so nothing syncs it). Opening it asks "Join ~name?"; joining is 3D-2's `joinChannel` (`POST /channels/{id}/members`, then the channel written like any other), then the chat opens. A read-only preview (history without joining) would need a channel state for a non-member channel, which the catch-up, read-state pusher and counters assume is a member; 3D-2's Browse Channels shows a preview screen instead (`mattermostChannelPreviewController`, internal to MattermostUI), which search could open once it is public.

**Saved posts** (Mattermost's flagged posts; Telegram's Saved Messages stay the self-DM): `flagged_post` preferences, loaded on every new WebSocket connection and kept current by `preferences_changed`/`preferences_deleted`. The message menu offers Save Post / Remove from Saved (optimistic, reverted on failure); `GET /users/me/posts/flagged` (all teams, `team_id` supported) lists them in Settings → Saved Posts; an unsave (here or elsewhere) removes the row at once, a save elsewhere reloads the list.

**Recent mentions**: Mattermost's own definition, an OR search (`is_or_search`) for `@username`, the first name when `first_name` is on, and the `mention_keys` (not `@channel`/`@all`/`@here`), in every team, merged. The **Mentions tab** (since 2026‑10‑27; was Settings → Recent Mentions); the keys are highlighted in the rows.

**Where.** Saved Posts is a Settings row under Saved Messages (ChatListUI `MattermostPostListController`, Telegram's search result rows): Settings already holds the account's own lists (Saved Messages, Devices). Recent Mentions started there too and became the Mentions tab (2026‑10‑27), with Threads, as in Mattermost's mobile app: a tab bar with only Chats and Settings took a lot of room for two buttons.

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

## Own status, profile, notifications, sharing (3F)

| Mattermost | Telegram | Where |
|---|---|---|
| Own status: `GET /users/me/status` (bootstrap, every new WebSocket connection), own `status_change` (another device, the server ending a DND, auto away); set with `PUT /users/{id}/status` (`dnd_end_time` in Unix seconds, truncated to the minute by the server, which restores the previous status at the end) | Settings: a row named after the status (icon in its colour, "Until 4:35 PM" for a DND end) → Status screen (Online / Away / Do Not Disturb with 30 min, 1 h, 2 h, tomorrow 9:00, a date and time / Offline); the same choices at the top of the Settings tab's long-press menu (Do Not Disturb pushes its durations). The own presence in Postbox carries the status too. | MattermostSync `Profile/MattermostProfile.swift` (`MattermostProfile` API); SyncCore `DoNotDisturbDuration`; MattermostUI `MattermostStatusControllers.swift`; PeerInfoScreen `MattermostProfileSettings.swift` |
| Others' status: `status_change` is sent **only to the user whose status changed** (11.x); clients poll `POST /users/status/ids` | the presence carries `MattermostPresenceStatus` (TelegramCore, encoded only when set): `away` → "away", `dnd` → "do not disturb until 5:38 PM" (`stringAndActivityForUserPresence`: chat titles, profiles, member lists). MattermostSync polls the DM partners and known users (≤ 400) while connected, at least every 20 s (`UsersStatusAndProfileFetchingPollIntervalMilliseconds`), and writes changed presences; a DND's end comes from the same request. | `startStatusPolling`, `PeerConverter.presence` |
| Custom status (`props.customStatus`; `PUT/DELETE /users/me/status/custom`; recent ones in the `custom_status` / `recent_custom_statuses` preference, which the server keeps) | Telegram's emoji status slot next to the name (chat list rows, chat title, profile and Settings headers, account list): `PeerEmojiStatus(.emoji(fileId))` of the locally rendered static emoji image (the reaction image files of 2A/2C: Unicode glyphs, `:name:` custom emoji from the server), its file stored with `storeMediaIfNotPresent`; a text-only status shows 💬 as Mattermost does. Mattermost never announces an expired status (clients hide it), so MattermostSync rewrites users when their status expires (`scheduleCustomStatusExpiry`). Live via `user_updated`. Custom Status screen: emoji (Telegram's emoji keyboard in `EmojiStatusSelectionController`, which now hands back Unicode emoji as a file whose `.CustomEmoji` alt is the emoji), text (100), clear after (don't clear, 30 min, 1 h, 4 h, today, this week, a date and time), recent statuses, Mattermost's default suggestions, Clear. Tapping the emoji next to the own name opens it; next to someone else's name, a toast with their status. | `PeerConverter.customStatusEmoji`, `MattermostReactionImages`; SyncCore `CustomStatusDuration`, `CustomStatusSuggestion`; MattermostUI; `EmojiStatusSelectionComponent` (one hunk) |
| Profile: `PUT /users/me/patch` (first/last name, nickname, position, username, email with the current password); `POST/DELETE /users/me/image` | Telegram's Edit Profile (Settings → Edit) for Mattermost accounts: names in the header, nickname and position inputs, Username and Email rows (own screens, checked locally: SyncCore `UsernameRules`), Add Account, Log Out; Done saves the changed fields. What SSO/LDAP/SAML users may change follows `auth_service` and the client config's `Ldap*AttributeSet`/`Saml*AttributeSet` (SyncCore `ProfileFieldAccess`). The picture flow is Telegram's (picker, editor, removal); the upload/removal signal is Mattermost's (a 512 px JPEG); the own user is reloaded after it, so `last_picture_update` changes the avatar resource id and every cached picture is replaced (a removed picture has a negative `last_picture_update` on 11.x → Telegram's initials). Own `user_updated` reloads `GET /users/me` (the event's copy is sanitized: no notify props). | `MattermostProfile.updateProfile`, `setProfilePicture`; PeerInfoScreen `settingsEditingItems` gate, Done handler, `updateProfilePhoto` / removal hooks |
| User notify props (`push`, `push_status`, `push_threads`, `mention_keys`, `first_name`, `channel`) | Settings → Notifications → MATTERMOST → Push Notifications and Mentions (SettingsUI opens it through `MattermostUIHooks`, AccountContext): push for all / mentions, DMs, GMs / nothing; when online-away-offline / away-offline / offline; all replies to followed threads (collapsed threads); first name, channel-wide mentions, keywords. Saved at once (the full props map with the changed keys). | SyncCore `UserNotificationPreferences`; MattermostUI `MattermostProfileControllers.swift` |
| Channel member notify props (`push`, `push_threads`, `ignore_channel_mentions`, `mark_unread`, `channel_auto_follow_threads`) | the chat profile's Notifications → Customize opens Mattermost's settings instead of Telegram's: default/all/mentions/nothing, thread replies and follow all new threads (collapsed threads), ignore channel-wide mentions (channels), mute. `PUT …/members/me/notify_props`, then the channel is rewritten (mute → Telegram's mute). | SyncCore `ChannelNotificationPreferences`; `PeerInfoScreenPerformButtonAction` (one hunk) |
| Share extension | Telegram's share extension and its chat picker (over each account's Postbox via `standaloneStateManager`, null network; the picker's avatars load with the account's session: `MattermostShareExtension.prepareAccount`). Send runs `mattermostShareExternalItems`: the other app's items (`TGItemProviderSignals`: text, URL, image, file, video, audio) become texts and files; MattermostShare finds the account (`<root>/account-<id>/mattermost/sync.sqlite`, read-only) and its token (shared Keychain group, 3A), the Mattermost chat of each chosen peer (channel, GM, DM — created with `POST /channels/direct` when missing — or a thread's root post when the picker passes a thread id), plans the posts (comment + texts as one message, at most 10 files per post, the message on the first) and uploads (`POST /files`, then `POST /posts`). The server's `MaxFileSize` is checked first. No stories, no Telegram chat import. Simulator builds give the extension the app group (`ShareSimulatorEntitlements`). | `submodules/MattermostShare` (SwiftPM, tested, live test against the dev server); MattermostSync `Share/MattermostShareExtension.swift`; ShareExtensionContext |

## Runtime hygiene and performance (4B)

**Nothing reaches the null network engine in normal use.** Every Telegram request that a kept screen or manager still
issued (a scripted 10-minute session parked 941 requests of 51 functions, 264 never disposed) is switched off at its
start site while `MattermostBackend.isEnabled` (all `// MATTERMOST:`), returning what Telegram itself returns for a
peer it can't address (an empty list, `nil`, `.none`, no value) rather than an error:

| Where | What is off |
|---|---|
| `Account.init` | presence (`account.updateStatus` every 30 s), autolock reports, configuration updates (`help.getConfig`, `getDefaultHistoryTTL`), story subscriptions |
| `AccountViewTracker` | view counts, reaction polling, story stats, live locations, extended/unsupported/secret media, inline calls, can-send checks; history validation (channels, threads, scheduled) |
| Cached peer data (`users.getFullUser`, `channels.getFullChannel`, `getPeerSettings`) | answered locally; the peer view tells MattermostSync instead (below) |
| Engine functions | sticker sets (a pack not stored loads as `.none`), featured packs, chat/cloud themes and wallpapers, gift codes, send-as peers, top peers, stories, saved reaction tags, group-call join-as, boosts, user photos (the gallery shows the current photo), media-tab counts and sparse positions/calendar, profile gifts, saved music, groups in common, post-search flood, content settings, notification exceptions, privacy settings, composer link previews |
| Settings / `AccountContext` | privacy, exceptions, archived stickers, two-step verification, Telegram sessions, personal channels; the country list (bundled only) |

`NullNetworkStatistics` counts what still arrives (per function: total, not disposed, the first caller's stack in
debug builds; debug remote `runtime`), and the engine no longer keeps parked requests: a fire-and-forget caller's
subscriber chain was never released.

**`MattermostChatObserver`** (TelegramCore → MattermostSync `ChatObserver`) replaces what Telegram did while a chat is
on screen: a peer view's cached-data refresh (at most every 5 minutes per peer) loads a channel's member count (at
most once a minute), so the bootstrap no longer asks `/channels/{id}/stats` for every chat at every launch; an opened
chat history catches up a stale channel (below).

**Bootstrap** (first sync): structure as before, then the newest page of every chat (unread first, then by
`last_post_at`) fetched 6 at a time and written in batches of 25 chats — one users request (≤100 ids each), one
Postbox transaction, one thread-roots request per batch — while the next batch loads. One transaction per page made
600 chats take 87 s on the local server (each transaction also re-renders the chat list); batched: 5.7 s.

**Catch-up** (non-resumed reconnect, foreground, background refresh; concurrent requests join the running one): reload
channels and members; ask `since=` only for channels whose `last_post_at` is newer than `last_sync_at` (600 requests →
the active ones); quiet channels get their read state from the new counters (one transaction, only those whose
counters moved) and become **stale** (`stale_channels` cursor: channel → the `since` it still needs). A stale channel
is caught up when its chat opens or when a later catch-up fetches it anyway (with the older `since`), because edits,
deletions and reactions don't move `last_post_at`. Channels the user was added to meanwhile are written in one
transaction. Launch catch-up of 600 chats: 1.8–2.3 s → 50–120 ms.

**Connection:** after more than 10 s in the background each account pings its WebSocket (3 s timeout) and reconnects
if it is dead or waiting for a retry; a socket waiting out its backoff (up to 60 s) reconnects as soon as a REST
request gets an answer (`MattermostClient.Configuration.onServerReached`) or `NWPathMonitor` reports the network
back. Sends queued while offline go out with the sender's own retry (≤ 5 s).

**Background refresh:** `BGAppRefreshTask` `org.relaychat.Relay.refresh` (Telegram's Info.plist already permits
`<bundle id>.refresh`; `UIBackgroundModes` has `fetch`), registered by `RelayBackgroundRefresh` (TelegramUI) when
`MattermostBackend.isEnabled`, scheduled at each entry into the background (earliest 15 minutes later): waits up to
25 s for the accounts to start, then catches every running account up (`MattermostSync.backgroundRefresh`).

**Cache:** Mattermost media (`mm-file-…`, `mm-avatar-…`, `mm-url-…`) is fetched through `MediaBox.fetchedResource`
like Telegram's, so `StorageBox` attributes each file to the chat (and message) that showed it: Storage Usage lists
it per chat and category, Clear removes it, and `AutomaticCacheEvictionContext` evicts it by the keep-media
settings (verified with a per-chat exception, debug remote `storage`; the evicted files load again when shown).
Part of the files on disk (about 40 % by size in the check) is attributed to no chat — not investigated; those
go only with Clear for all chats or the cache size limit.

## Known-gaps burn-down (4F)

| Gap | Now | Where |
|---|---|---|
| Chat list under collapsed threads | A row previews and sorts by its newest **root** post (Mattermost's `last_root_post_at`). Postbox gained a persisted chat-list top-message tag (`Transaction.setChatListTopMessageTag`, MetadataTable key 7): rows follow the newest message carrying the tag, except one peer (Saved Messages), falling back to the newest message; changing it recomputes every row. MattermostSync sets it to `.mattermostRootPost` while CRT is on (bootstrap structure transaction, every switch) and sorts not-loaded chats by `last_root_post_at`. | Postbox `ChatListTable`, `MessageHistoryTable.topIndex(peerId:tag:)`, `MessageHistoryTagsTable.newestIndex`; `CollapsedThreads.applyChatListOrder` |
| Thread unread separator | A followed thread with unread replies opens at its first unread reply (incoming, after the thread's `last_viewed_at`) with Telegram's "Unread Messages" separator: `MattermostChatObserver.threadReadState` (TelegramCore seam) answers inside the view's transaction; `AccountViewTracker` anchors the thread view there with a fixed read state (Postbox keeps none for these threads). Reading marks the thread read up to the seen reply (3B). | `Threads.threadReadState`; TelegramCore `AccountViewTracker` |
| Mixed posts | One grouping key for images + other files: one bubble (mosaic, files, text). Stored messages were upgraded by the rich-content re-render (version 2: newest page per chat). | `PostLayout` |
| Attachment polish | `color` (`#rgb`, `#rrggbb`, good/warning/danger/primary/success as Mattermost's mobile app) → `MattermostCustomEntity.quoteColor(rgb:)` over the quote; TextFormat recolours its `TextNodeBlockQuoteData`. `author_icon` (round), `footer_icon`, `thumb_url` → inline custom-emoji images (`MattermostIconResource`, a transparent 160 px WebP, loaded like attachment images: the server or its image proxy). A 75 px thumbnail beside the text has no Telegram equivalent (as the photo it would be stretched to the bubble). | `AttachmentConverter`, `MattermostReactionImages.iconFile`; TextFormat `MattermostHeadings.swift` |
| Ephemeral messages | Removed when the sync starts (relaunch, re-login): the only incoming `Local` messages. | `EphemeralPosts.removeEphemeralMessages` |
| Search in chat (CRT) | Replies included (as Mattermost); a reply opens its thread when stepped to or picked from the list; the newest result shown while typing is shown as its root rather than pushing the thread. | `MessageSearch`; TelegramUI `ChatControllerUpdateSearch` (one hunk), `MattermostThreads` |
| Permalink into an unjoined channel | The preview's Join resolves the link again and opens the post (or its thread) in place of the preview. | TelegramUI `MattermostLinks`; MattermostUI preview `afterJoin` |
| DND/away dots | Chat list rows: Mattermost's away (yellow) and DND (red with a bar) dots instead of Telegram's green online dot; the DM header avatar shows the partner's dot (online/away/DND), live. | TelegramPresentationData `MattermostStatusIcons.swift`; `ChatListItem`, `ChatAvatarNavigationNode` |
| Push sender name | The notification names the sender in the recipient's display format (`name_format` preference, else `TeammateNameDisplay`; `LockTeammateNameDisplay`), not the server's `sender_name` ("@bob"). The app stores the format in `sync.sqlite` (`push_name_format`); the extension fetches the sender (`GET /users/{id}`, cached a day). | MattermostPush `MattermostPushSenderName` (tested); `MattermostPushServiceHandler` |
| DMs/GMs closed elsewhere | `direct_channel_show` / `group_channel_show` events close (forget) or reopen the chat live. | `MattermostDirectory.applyDirectChannelVisibility` |
| Recent mentions live | New posts with a mention key (`SearchQuery.textMentions`, tested) join an open list at the top. | `SavedPosts.MattermostPostList` |
| Uploads across a restart | Store schema 2: `pending.uploaded_files`; each message records its uploads with a pending row of its own; `uploadMedia` after a restart reuses them. | SyncCore store (tested); `PostSender` |
| Admin delete | `ChannelAccessRules.canDeleteOthersPosts` (`delete_others_posts`; tested) → `MattermostChannelAccess.deleteOthersPosts`; the message menu offers Delete for others' messages (one hunk in `ChatInterfaceStateContextMenus`); deletion is 2A's `DELETE /posts/{id}`. | `ChannelAccess.swift` |

## Security and diagnostics (4G)

| Area | How | Where |
|---|---|---|
| Managed app configuration | `UserDefaults.standard["com.apple.configuration.managed"]` with the Mattermost mobile app's EMM keys + `relayCertificatePins`, parsed by `MattermostManagedConfiguration`; read at launch (before accounts start), on becoming active and on `UserDefaults.didChangeNotification`. The app writes the extensions' part (pins, server restriction) to `<root>/relay-managed-configuration.json`. Admin guide: [release/managed-configuration.md](../release/managed-configuration.md). | MattermostKit `Managed/`; MattermostSync `MattermostManagedSettings`; MattermostUI `RelayManagedConfigurationPresenter` |
| Server restriction | The probe and `createAccount` refuse other servers; `startAccount` and every configuration change log out accounts on other servers (`logoutFromAccount`, the usual lifecycle), and the UI names them once they're gone. The login's address field is prefilled (`serverUrl`) and locked (`MattermostAuthField.isLocked`), the login id prefilled (`username`). | `MattermostSync.enforceServerRestriction`; `MattermostLoginController` |
| Certificate pinning | `MattermostServerTrust.shared` decides server trust challenges of `MattermostURLSession.current` (every default client and WebSocket): pinned host → system trust + an SPKI pin in the chain, else refused; unpinned → system. On a pin change the session is renewed (no connection or TLS session reused) and WebSockets reconnect. Extensions load the app's copy (NSE per push, share extension once). A refusal surfaces as `URLError(.serverCertificateUntrusted)` with the host (login: "The certificate of … isn't the one your organization requires"). | MattermostKit `Security/` |
| Passcode, app switcher, pasteboard | `MattermostManagedApp.policy` (AccountContext) carries what upstream code reads: `AppLock` covers the window whenever inactive (`blurApplicationScreen`); the passcode options hide Turn Off and limit Auto-Lock to ≤ 5 min (`inAppPinCode`); MattermostUI asks for a passcode until one is set (Telegram's `applicationPasscodeSetupController`, 5-minute start) and corrects longer auto-lock values; the composer's paste asks `RelayPasteboardGuard` (`copyAndPasteProtection`: own copies local-only and cleared in the background, outside content refused). Notification Reply / Mark as Read get `.authenticationRequired` while a passcode exists. | AppLock, PasscodeOptionsController, ChatTextInputPanelNode, AppDelegate (`// MATTERMOST:`) |
| Diagnostics | MetricKit payloads → `DiagnosticReportStore` (app container, 30 days / 40 / 4 MB); Settings → About Relay → Diagnostics: Telegram's file log switch, export = summary (versions, servers, passcode/managed keys) + reports + the newest logs (≤ 12 MB, `DiagnosticsRedactor`) zipped with `NSFileCoordinator(.forUploading)` → share sheet. | MattermostSyncCore `Diagnostics/`; MattermostUI `RelayDiagnostics` |
| DM delete permission | `LimitsConfiguration.canRemoveIncomingMessagesInPrivateChats` = `delete_others_posts` of the system roles (written after the roles load); `maxMessageRevokeIntervalInPrivateChats` = forever. | `ChannelAccess.writeDirectMessageDeletePermission` |

## Voice messages (5A)

Mattermost has no voice-message post type (11.7 and 12.0), so a Relay voice message is an ordinary post with **one
audio file and no text**, marked in `props` so Relay shows it as Telegram's voice bubble; every other client shows an
audio file with its own player (decision V1 in [plan 09](../plan/09-risks-and-decisions.md#open-decisions)).

```json
"props": {"relay_voice": {"v": 1, "duration": 12, "waveform": "<base64 of Telegram's packed waveform>"}}
```

| Step | How | Where |
|---|---|---|
| Recording | Telegram's recorder and composer unchanged: hold the mic button, slide left to cancel, slide up to lock, pause/resume, preview with trimming, send. `MattermostFeatures.voiceMessages` is on (the mic button); round video messages stay off (a tap on the mic shows "Hold to record audio." instead of switching to video), view-once is hidden. | `ChatTextInputPanelNode`, `ChatController`, `ChatControllerLoadDisplayNode` (`// MATTERMOST:`) |
| Upload | `PostSender.upload` transcodes the recording (Telegram's Ogg/Opus `audio/ogg`) with Telegram's own `convertOpusToAAC` (FFmpeg decode, AVAssetWriter AAC-LC, mono, 48 kHz, 32 kbps) into a temporary `.m4a`, uploaded as `audio/mp4` named `Voice message 2026-10-27 14.05.m4a` (the recording's time in the device's time zone; the prefix is `Relay.VoiceMessage.FileName`, set by MattermostUI). A failed transcoding sends the Ogg/Opus file as `.ogg`, still marked. A forwarded voice message (already the server's file) goes as it is. | `Write/VoiceMessages.swift`, `PostSender` |
| Post | `outgoingDraft` adds the marker from the local file's `.Audio(isVoice: true, duration, waveform)` (the recorder's 100 × 5-bit waveform, 63 bytes). Offline sends queue like any other (transient errors retried, the uploaded file id kept with the pending row, 4F). After the post, the AAC file (not the Ogg recording) is moved to the sent message's `MattermostFileResource`; after a restart between upload and post the sent message downloads it instead. | `OwnPosts` |
| Receiving | `PostConverter.voiceMarker`: the marker **and exactly one audio file** (`audio/*` or an audio extension) → `TelegramMediaFile` with `.Audio(isVoice: true, duration, waveform)` + the file name, tag `.voiceOrInstantVideo` (the Voice tab, the playlist that plays the next voice message). A marker on anything else is ignored; audio files without a marker stay files (V1). Same converter for live events, pages, hole fills, catch-up and search results. | `Converters/PostConverter.swift`, `MediaConverter.swift` |
| Missing waveform | A marked post without a usable waveform (another client's marker): the file is downloaded and decoded (`SoftwareAudioSource`, FFmpeg: m4a, Ogg/Opus, mp3, wav) and Telegram's recorder normalisation applied (`VoiceWaveform.fromPCM`); stored in `sync.sqlite` (`voice_waveform:<file id>`) so rewrites keep it, and written into the message. One at a time. | `Write/VoiceMessages.swift` |
| Listened state | Incoming voice messages carry `ConsumableContentMessageAttribute` (Telegram's "not played" dot), set to played by Telegram's player. Local only: never sent anywhere (TelegramCore no longer queues `SynchronizeConsumeMessageContents` operations while the Mattermost backend is on, `MarkMessageContentAsConsumedInteractively.swift`); every rewrite of a post keeps the stored value (`PostConversionContext.existingConsumed`). Outgoing voice messages have no dot (Mattermost can't tell whether the other side played it). | `PageWriter.writeMessages` |
| Existing data | Rich-content version 3: an upgrade re-renders the newest page of every chat and rewrites every **stored** post that has an audio file (`POST /teams/{id}/files/search` with audio extensions, then `POST /posts/ids`), so voice messages stored as files by an older build become voice bubbles. | `Sync/RichContent.swift` |
| Search | The Voice tabs (chat list search, a chat's profile) search audio files (`ext:m4a ext:ogg …`) and keep the messages with the voice tag; the profile's tab also fills from the channel file search (`HoleFiller.loadChannelFiles`). | `Search/MessageSearch.swift` |
| Notifications | A file-only post's push says "attached a file." (any push contents mode) and carries no `props`. The notification service extension fetches the post (`GET /posts/{id}`, in parallel with the acknowledgement and the avatar, ~50 ms on the dev server) and, for a marked post without text, shows "Voice message" (`Relay.Push.VoiceMessage`, read from the app bundle's strings: the extension has none). The first, network-free version still says "attached a file." if time runs out. | `MattermostPushServiceHandler`, `MattermostPushTextBuilder(voiceMessage:)` |
| Previews | The chat list, reply panels and VoiceOver use Telegram's own texts for a voice file ("Voice Message"). VoiceOver adds "Played" / "Not played" for received voice messages; the preview's Delete and Record more buttons got labels. | `ChatMessageItemView`, `ChatTextInputPanelNode` |

**Format (V1).** AAC in MP4 rather than the recorded Ogg/Opus: checked 2026-10-27, the Mattermost 11.7 web app previews
`AUDIO_TYPES` (`mp3 wav wma m4a flac aac ogg m4r`, by extension) in its file preview with a plain `<video controls>`
element and falls back to a download view when the browser can't decode it. In that markup Relay's `.m4a` played in
Chrome 155, WebKit on macOS 27 and Safari on iOS 26.5; an Ogg/Opus file played in Chrome and iOS Safari but not in the
macOS WebKit view (metadata only). AAC is also the format the platforms' own media frameworks decode (AVFoundation can't
read Ogg/Opus; Telegram itself converts a voice message to AAC before handing it to Apple's speech recognizer); the
official mobile and desktop apps were not checked ([evidence](../research/phase5a/v1-playback.txt)). Cost: 19–57 ms to transcode 4–12 s on the simulator; the AAC file is
10–16 % larger than Telegram's Opus recording.

**Debug hooks** (BUILD.md "Phase 5A"): `RelayDebugFakeMicrophone` replaces the microphone inside
`ManagedAudioRecorderContext` (debug builds only) with a file or a tone, so the recorder's own encoding, waveform,
preview and send paths run on a simulator without opening the Mac's microphone.

## Daily-use gaps (4H)

| Gap | Now | Where |
|---|---|---|
| Names | Users are named as the user's "Teammate Name Display" has them (`display_settings`/`name_format`, else the server's `TeammateNameDisplay`; the server's when `LockTeammateNameDisplay`): the names go into the user peers (`UserDisplayName.peerNames`: `full_name` → first/last name, `nickname_full_name` → the nickname, else the full name, `username` → the username, each falling back to the username), so chat titles, chat list rows, message authors, the `@` list, member lists, profiles and search follow without upstream changes. Group messages are titled with the other members' display names, sorted (`getGroupDisplayNameFromUserIds`); their members are loaded by username at the bootstrap. A profile whose title isn't the full name shows a "full name" row. The own user keeps the real names (Settings, Edit Profile). A changed format (`preferences_changed`/`_deleted`, `config_changed`) or a build with a new `userPeersVersion` rewrites every stored user (`POST /users/ids`, 100 per request; 1,629 users in 0.2–0.4 s) and every group message title; cursor `user_names_format`. Postbox's chat list view now replaces a renamed message author too (it replaced `message.peers` only, so "Author:" lines kept the old name). Interactive menus, dialogs and permalink card titles use the same names. | `Sync/DisplayNames.swift`, `PeerConverter`; SyncCore `Mapping/Naming.swift`; Postbox `ChatListViewState.swift`; PeerInfoScreen `MattermostPeerInfoDirectory.swift` |
| `@channel` confirmation | Sending `@all`, `@channel` or `@here` (`ChannelWideMention.mentions`: the markdown's special mentions, not in code) asks first when the web app would (11.7): the server's `EnableConfirmNotificationsToChannel`, the user's `use_channel_mentions` in the channel, more than 5 members (`GET /channels/{id}/stats` at send time). The web app's wording, people = members − 1, "at least … other people" for `@here` alone, "in N timezones" when `GET /channels/{id}/timezones` lists any. Cancel keeps the text; Confirm sends. The web app doesn't consult the sender's `ignore_channel_mentions` (it only decides whether that member is notified), so neither does Relay. Composer sends only (a caption with media and edits don't ask, as in the web app for edits). | `Composer/ChannelMentions.swift`; TelegramUI `MattermostComposerQueries.swift`, `ChatControllerNode.sendCurrentMessage` (one hunk) |
| Forward | Mattermost's forward (web app `forwardPost`): a post whose message is the forwarded post's permalink (optionally after a comment), no files copied; the server adds a `permalink` embed with the forwarded post, so every client previews it. Telegram's Forward with the sender's name now posts exactly that (`OwnPosts.outgoingDraft`, no upload); "Hide Sender Name" (Telegram's copy; Telegram's default for the user's own messages) still copies text and files. Posts of private channels, DMs and GMs can only be forwarded into their own channel (the web app's rule): the forward picker refuses other chats with the web app's notice ("This message is from a private conversation and can only be shared with bob."); paths that don't ask (the share sheet) send a copy. Rendering: a plain forward (only a permalink, with the embed) is shown as Telegram's forwarded message: "Forwarded from <author>" (the forwarded post's author and date; tapping opens the post where it is stored, else the author's profile), the forwarded post's text, files and attachments (`PostLayout` takes the files from the embed, grouping keys stay the forward's), the forward's own reactions, replies, pin and thread. A forward with a comment keeps 3E's card under the comment. Without the embed (no access, deleted, previews off) it is the link. `POST /posts/ids` has no embeds, so paths that write from it fetch plain forwards on their own (`withForwardPreviews`). | `Write/Forwards.swift`, `Converters/ForwardedPost.swift`, `PostLayout`, `PostConverter`, `OwnPosts`; SyncCore `Mapping/Forwarding.swift`; TelegramUI `MattermostForwarding.swift`, `ChatControllerForwardMessages.swift` (two hunks) |
| Same user on two servers | Each account's server under its name in the Settings account list and the Settings tab's switcher: the host (with port and path), "site name · host" when the site name isn't Mattermost's default; VoiceOver reads both. | `MattermostSync.serverLabel(accountPeerId:)`; AccountContext `MattermostUIHooks.accountServerLabel`; `PeerInfoScreenMemberItem`, `AccountPeerContextItem` |
| Blank DM avatar | Root cause: user peers had access hash `.personal(0)`, which Postbox stores as none, so a user read back from the database had no `PeerReference`; the chat list loads photo avatars through `AvatarNode.setPeerV2` / `DirectMediaImageCache`, which needs one, and remembered the attempt, so the row stayed blank (other screens use the older loader, which doesn't). Users now carry `.personal(1)`; every stored user is rewritten once (`userPeersVersion` 2). | `PeerConverter.userAccessHash` |
| Reply counts after deletions | A deleted reply (live `post_deleted`, or in a `since=` list) recounts its root from the server (`POST /posts/ids`, the stored latest repliers kept). Before, only `thread_updated` (thread followers) corrected it. | `Threads.refreshThreadRootCounts`; `EventApplier.applyDeleted`, `CatchUp.applySince` |
| Stale chat-list previews | The catch-up checks the row message of every quiet channel (no new post since the last sync) with one `POST /posts/ids` per 100 chats: updated since then (`update_at`: edits, reactions) → fetched on its own (`GET /posts/{id}`, embeds) and rewritten; deleted (or gone) → removed, so the row shows the message before. (Edits move `last_post_at` on 11.7, so edited channels are caught up as active ones anyway.) The rest of a quiet channel's history stays stale until it opens (4B). Launch catch-up of ~100 chats: 44–47 ms. | `CatchUp.refreshChatListPreviews` |
| Members pane | The town square's members are the team's: no Add Members and no Remove (the server refuses removals: `api.channel.remove.default.app_error`). | SyncCore `ChannelAccessRules` |

## Media resources

`MattermostFileResource(fileId, variant)`, `MattermostAvatarResource(userId, lastPictureUpdate)`, `MattermostURLImageResource(url)` (attachment images, webhook icons, link preview images: on the server directly, elsewhere only through the server's image proxy, see "Rich content and links (3E)"; flattened onto white because Telegram draws photos opaque), `MattermostIconResource(url, round)` (4F: attachment icons as inline custom-emoji WebP images, transparent), all `TelegramMediaResource` + `PostboxCoding`, registered in `mattermostDeclareEncodables()` (app and every extension; R§6). Type names are part of the storage format: never rename them. Fetched through the auxiliary `fetchResource` hook with a `URLSession` that adds the bearer token and supports byte ranges.

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
