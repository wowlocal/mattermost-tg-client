# MattermostSyncCore

Pure-Swift logic between the Mattermost API client and Telegram-iOS's Postbox. It is used by `MattermostSync` (which owns Postbox access). See `docs/plan/02-domain-mapping.md` and `docs/plan/03-sync-engine.md`.

- **Foundation and SQLite only**: no package dependencies (not even MattermostKit) and no resources. Inputs are small structs defined here. SQLite is Telegram's vendored SQLCipher under Bazel and the system `SQLite3` module under SwiftPM (see [Sync store](#sync-store-sqlitemattermostsyncstore)).
- Value types, `Sendable`, deterministic. Builds cleanly with `-warnings-as-errors` and `-strict-concurrency=complete`.
- Built by SwiftPM for tests (`swift test`) and by Bazel inside Telegram-iOS (`BUILD`, library only).

```
Sources/MattermostSyncCore/
  MessageIds/   PostOrderKey, MessageIdStore (+ InMemoryMessageIdStore), MessageIdAllocator
  Store/        SQLiteMattermostSyncStore (+ MessageIdStore conformance), schema and migrations, SQLiteConnection
  Markdown/     TextEntity, MattermostMarkdown (parse + serialize), InlineParser, EmojiTable
  Mapping/      ReadStateMapper, PresenceMapper, ServiceAction
```

## Message ids

Telegram needs 32-bit message ids per chat, ordered like the messages. Mattermost has 26-character post ids. `MessageIdAllocator` implements **option 2, sparse allocation with a stored map**.

### Model

- **Ordering key**: `PostOrderKey(createAt ms, postId)`. Post ids compare byte-wise, which matches SQLite `BINARY`. Within a channel, local ids are strictly increasing in key order.
- **Entry**: post → local id, plus a tombstone flag. Deleted posts keep their id, so a replayed `posted` event can't resurrect them. Posts deleted before they were ever mapped are remembered too.
- **Island**: a stretch of history known to be fully loaded, stored by its boundary *keys* (not ids), so renumbering never invalidates it. The lowest island can be flagged `reachesStart`; the highest can be flagged `reachesLatest` (live).
- **Hole**: the id range between two islands, plus the space below the lowest island and above the highest one unless it is flagged. Every hole between islands always keeps at least one free id, so it is a valid Postbox hole range.

### Operations

| Situation | API | Rule |
|---|---|---|
| First post in a channel | any ingest into an empty channel | The newest post of the batch gets `2^30`; the rest go below it, `STEP` (16) apart |
| Newest page (open chat, catch-up) | `ingestLatestPage(_:reachedStart:)` | The island is marked live |
| Page from an anchor (`before=` / `after=`) | `ingestPage(_:extending:direction:reachedEnd:)` | Ids are `STEP` apart, moving away from the anchor |
| Page reaches another island | same | The islands merge (`didCloseHole`); the posts between are spread evenly across the remaining gap |
| Permalink jump | `ingestAround(target:older:newer:…)` | A new island is placed in the gap, proportionally to time, with holes on both sides |
| Single post (WebSocket `posted`, own send, `GET /posts/{id}`) | `insertPost(_:)` | Between two posts of the same island: their midpoint. Newer than a live island: appended. Older than a `reachesStart` island: prepended. Otherwise a single-post island. Idempotent. |
| Delete | `markDeleted(_:)` | Tombstone |
| Lost live sync (non-resumed reconnect, catch-up overflow) | `invalidateLatest()` | Opens a hole above the newest island |
| No room left | automatic | Returns a `RenumberPlan` (see below) |

The general primitive is `ingestRun(_:anchors:reachesStart:reachesLatest:)`: "these posts plus these mapped anchors form one contiguous stretch of history".

### Using it from `MattermostSync`

1. **Hole fill.** Postbox asks to fill `.range(start:end:)`. Call `fillCursor(direction:boundaryLocalId:)` and you get `.before(postId)`, `.after(postId)` or `.latest`. Fetch with `per_page`, then call `ingestPage(…, extending: cursorPost, direction:, reachedEnd: posts.count < perPage)` (or `ingestLatestPage` for `.latest`). For `.aroundId`, use `aroundCursor(localId:)`. `HistoryHole.cursor(direction:)` does the same for a hole from `holes()`.
2. **Apply an `IngestResult`** in one Postbox transaction:
   - If `renumberPlan` is set: delete every message at a `from` id, then re-insert each at its `to` id. Ids can be swapped between moved posts, so don't interleave deletes and inserts per move. Also remap any other stored local ids: read state, thread ids (`root_id` → local id), reply references.
   - Insert the `.inserted` allocations. Skip `.deleted` ones (tombstones).
   - Remove `islandRange` from Postbox's hole index; everything inside an island is loaded. After a renumber, rebuild holes inside `renumberPlan.affectedRange` from `holes`.
3. **Persistence**: `SQLiteMattermostSyncStore` (below) implements `MessageIdStore`. Each allocator call reads through the query methods and then calls `apply(_:)` exactly once; run it inside `store.transaction { … }` so the whole operation is one transaction. `InMemoryMessageIdStore` is the reference implementation; both have `validate(channelId:)` for debugging.
4. **Catch-up** (`since=`): apply new posts with `insertPost` in time order, or, if the newest island was live up to `lastSyncAt`, as one `ingestPage(…, extending: newestPost, direction: .newer, reachedEnd: true)`. If there are too many, call `invalidateLatest()` and let hole filling load them.

### Renumbering

When a gap has no room left:

- **A hole ran out** (paging into a gap that is too small). Shift the smaller of the two neighbouring island parts (up to `maximumIslandShift` = 10,000 posts) into the hole beyond it. This restores `STEP` spacing. The hole being filled gets at least half of the freed space, so the next pages fit.
- **A gap inside an island ran out** (repeated late inserts between the same posts). Renumber the smallest window around the insertion that leaves at least `minimumSpacingAfterRenumber` (4) between posts. The window grows towards whichever side frees more ids per renumbered post, so usually only a handful of posts move.
- **Fallback**: the window keeps growing, up to a whole-channel relayout. Beyond capacity (about 2^31 posts), `capacityExhausted` is thrown and nothing is written.

### Deviations from the plan's rules

- **Pages next to an almost-full hole are compressed** before anything is renumbered. Spacing is `min(STEP, room / (2 × posts))`, never below 4, so the hole keeps at least half its space. Exact `STEP` spacing would force a renumber whenever a hole has less than `16 × page` ids left.
- **A page that closes a hole spreads its posts evenly** across the remaining gap instead of `STEP` from the anchor. Nothing more will be paged into that gap, and even spacing leaves the most room for late inserts.
- **"Renumber the smaller island"** becomes "shift the smaller *part* of an island between the insertion and the island's far edge". This only applies to exhausted holes. An exhausted gap *inside* an island uses a minimal local window instead: moving a whole island for one late insert would rewrite thousands of messages.
- **Proportional placement** gives every hole a floor share (≥ 1/(8·holes) of the free space), so a hole that is short in time still has room. Time below the oldest known post is measured from `historyFloorTime` (2010-01-01); imports older than that still work, they're just placed less proportionally. The open space above the newest island counts as at least the other holes combined, or 30 days, whichever is larger.
- **A single late post that falls into a hole** becomes its own island. The plan only covers inserts between known neighbours.

## Sync store (`SQLiteMattermostSyncStore`)

The per-account store from the design doc's "Storage" section: one SQLite file (`<rootPath>/account-<id>/mattermost/sync.sqlite`; the caller passes the path, missing directories are created) holding the message id map and every other id mapping the sync engine needs.

```swift
let store = try SQLiteMattermostSyncStore(path: path)   // creates/migrates; WAL, synchronous=NORMAL, foreign keys on
let result = try store.transaction { store in           // BEGIN IMMEDIATE … COMMIT
    try store.allocatePeer(mattermostId: userId, kind: .user)
    let mediaId = try store.allocateMediaId(fileId: fileId)
    return try allocator.ingestPage(posts, extending: anchor, direction: .older, reachedEnd: end, channelId: channelId, store: &store)
}
```

| Area | API |
|---|---|
| Message ids | `MessageIdStore` conformance; `allEntries(channelId:)`, `validate(channelId:maxId:)`, `removeChannel(_:)` (full resync); `setThreadRootIds(_:channelId:)` + `threadReplies(rootPostIds:channelId:)` to find the replies of a root moved by a `RenumberPlan` |
| Peers | `allocatePeer(mattermostId:kind:teamId:)` (sequential per namespace from 1, stable; updates kind/team), `reserveOwnUserPeerId(userId:hash:)`, `peer(mattermostId:)`, `peer(namespace:peerId:)`, `peer(channelId:)` (a DM resolves to the other user's peer) |
| DM channels | `setDirectChannel(channelId:userId:)`, `directChannelUserId(channelId:)`, `directChannelId(userId:)` |
| Pending posts | `registerPendingPost(_:)` (idempotent per `pendingPostId`), `pendingPost(pendingPostId:)` / `(globallyUniqueId:)` / `(channelId:localMessageId:)`, `allPendingPosts()`, `removePendingPost(pendingPostId:)` |
| Files | `allocateMediaId(fileId:)` (sequential from 1, stable), `mediaId(fileId:)`, `fileId(mediaId:)` |
| Cursors | `cursor(_:)`, `setCursor(_:_:)` (nil removes); keys in `MattermostSyncCursorKey` |
| Server | `serverInfo()`, `setServerInfo(_:)` (url, user id, site name, version, capabilities JSON) |

### Schema (version 1)

| Table | Key | Notes |
|---|---|---|
| `schema_version` | — | one row; forward-only migrations in `MattermostSyncStoreSchema.migrations`, all pending ones in one transaction. A file from a newer build throws `unsupportedSchemaVersion`. |
| `server` | `id = 1` | one row |
| `peers` | `mm_id` | `kind` (`user`/`channel`/`gm`), `namespace` (0 CloudUser, 1 CloudChannel), `peer_id`, `team_id`; unique `(namespace, peer_id)` |
| `dm_channels` | `channel_id` | `user_mm_id`, indexed |
| `sequences` | `name` | next candidate of each sequential allocator (`peer.0`, `peer.1`, `media`) |
| `post_channels` | `channel_key` | channel id interned to an integer (keeps the id map small) |
| `posts` | `(channel_key, create_at_ms, post_id)` | `local_id`, `tombstone`, `thread_root_id`; clustered by the ordering key, unique indexes on `(channel_key, post_id)` and `(channel_key, local_id)`, partial index on thread roots |
| `post_tombstones` | `(channel_key, post_id)` | posts deleted before they were mapped |
| `islands` | `(channel_key, ordinal)` | boundary keys and flags |
| `pending` | `pending_post_id` | `channel_id`, unique `globally_unique_id`, `local_message_id` (indexed with the channel) |
| `files` | `file_id` | unique `media_id` |
| `cursors` | `key` | `value` |

`posts`, `post_tombstones` and `islands` reference `post_channels` with `ON DELETE CASCADE`. Every protocol query is an index search with no sort step (`testQueriesUseIndexes` checks the plans; the thread index is named with `INDEXED BY` because without `ANALYZE` statistics SQLite would scan the channel instead).

### Behaviour

- **Same semantics as `InMemoryMessageIdStore`** for every change set the allocator produces (a lockstep test compares every result and query). The schema also enforces unique local ids and post ids per channel, so an invalid change set fails as a whole instead of being stored. Renumber moves are applied in two passes (park on negative ids, then the final ids) because moves can shift into each other's ids.
- **Atomicity**: every write method is one transaction; inside `transaction(_:)` they nest as savepoints. `apply(_:)` writes all parts of a change set or nothing.
- **Errors**: typed methods throw `MattermostSyncStoreError`. `MessageIdStore` methods can't throw, so they record the first failure in `messageIdError`, return empty results and skip `apply` while it is set. `transaction(_:)` clears it on entry and, if set on exit, rolls back and throws it. Outside a transaction, check `messageIdError` and call `clearMessageIdError()`.
- **Peer ids**: users get CloudUser ids, channels and GMs share CloudChannel ids. A DM isn't a peer of its own: `dm_channels` maps it to the other user (the own user for the self-DM). `reserveOwnUserPeerId(userId:hash:)` stores the caller's stable hash of `(server URL, user id)`; sequential allocation skips any taken id, so it never collides even if the hash is small. Call it at login, before the own user is allocated any other way.
- **Threading**: no internal locking or queue. Use one instance from one serial queue at a time (`MattermostAccount.queue`). Other processes may open the same file (WAL, 5 s busy timeout); only the app should write the id map, because channel keys are cached per connection.
- **SQLite library**: `#if canImport(sqlcipher) import sqlcipher #else import SQLite3`. Under Bazel the target depends on `//submodules/sqlcipher:sqlcipher`, so the app never links the system libsqlite3 next to SQLCipher. Only the C API both provide is used (open/prepare/bind/step/column/finalize/exec, `sqlite3_busy_timeout`). The file is not encrypted (no `PRAGMA key`).

### Deviations from the design doc

- `posts` is keyed by an interned channel key instead of `peer_id`: the `MessageIdStore` protocol is keyed by Mattermost channel id, and a DM's peer is the other user, so the channel is the natural key. `peer(channelId:)` maps a channel to its peer.
- `peers.kind` has no `dm` value; DMs live in `dm_channels` only.
- `pending` also stores `channel_id`, since local message ids are per peer.
- Extra tables: `post_channels`, `post_tombstones`, `islands`, `sequences`.

## Markdown → text + entities

`MattermostMarkdown.parse(_:) -> FormattedText` returns plain text plus `TextEntity(range:type:)`. Ranges are in **UTF-16 code units** (NSString indices), as in Telegram's `MessageTextEntity`. Entity types mirror Telegram's, plus Mattermost-specific ones: `mention(username:)`, `channelMention(name:)`, `specialMention(.channel/.here/.all)`, `hashtag`, `customEmoji(name:)`.

- **Inline**: `**`/`__` bold, `*`/`_` italic (intraword `_` and CommonMark's flanking and "multiple of 3" rules), `~~strike~~`, code spans, `[text](url "title")` (balanced parens, `<…>` destinations; `javascript:`/`data:`/`vbscript:`/`file:` links lose their target), `![alt](src)` as a link, `<autolinks>`, bare `http(s)://`/`ftp://`/`www.` URLs (GFM trailing-punctuation rules), emails, `@user.name` (trailing `.`/`-`/`_` excluded, lowercased), `@channel/@here/@all`, `~channel-name`, `#hashtags` (must start with a letter and have at least 3 characters, Unicode allowed), `:emoji:` (about 610 built-in names and aliases; unknown ones keep `:name:` and get `customEmoji`), and backslash escapes. Nested and overlapping formatting gives correctly nested ranges. URLs, code, mentions and emoji are atomic, so `_`/`*` inside them never start emphasis.
- **Blocks**: fenced (with language) and indented code → `pre`; `>` quotes → `blockQuote` (nested quotes flattened); headings → a bold line; lists → `• `/`◦ `/`▪ ` or `1. ` prefixes with indented continuation lines, and task items `☐`/`☑`; GFM tables → an aligned monospaced `pre` block; rules → `———`. Every newline is kept, since Mattermost renders soft breaks as line breaks.
- **Reverse**: `MattermostMarkdown.markdown(from:)` converts composer entities (bold, italic, strike, code, pre, textUrl) back to markdown. Plain text is passed through unescaped, because users type markdown themselves. Underline and other entity types are dropped (their text stays). Crossing ranges are split so they nest, whitespace at range edges is moved outside the delimiters, and italic uses `_` except inside words.

## Mapping helpers

- `ReadStateMapper.readState(knownPosts:counters:)` or `readState(channelId:store:counters:)` returns `maxIncomingReadId` (the newest known post with `create_at ≤ last_viewed_at`), `maxKnownId`, `unreadCount = total_msg_count − msg_count` and `mentionCount`. The `_root` variants are used when collapsed threads are on; counts are clamped at 0.
- `PresenceMapper.presence(status:lastActivityAt:dndEndTime:now:)` maps to `.online(until: now+60)`, `.recently`, `.lastSeen(at:)` or `.unknown`, plus `isAway`/`isDoNotDisturb` flags. How `away` is shown is configurable. Map to Telegram as `.present(until:)` / `.recently` / `.present(until: lastSeen)` / `.none`.
- `ServiceAction.from(type:userId:message:props:)` maps system posts (join/leave/add/remove for channel and team, header/purpose/display-name changes, archive/restore, privacy conversions, …) to a renderable action. It returns nil for posts that render as ordinary messages (`me`, `system_auto_responder`). `fallbackText(name:)` gives English text for previews.

## Tests

```
swift test
```

`.swift-version` pins swiftly to the `xcode` toolchain in this directory. The swiftly Swift 6.3.3 toolchain on the dev Mac can't load the Swift overlay of the installed SDK's Foundation (`Date` and `String.trimmingCharacters` are missing, and it prints `unknown argument: '-target-arch-variant'`). Without swiftly, `xcrun swift test` does the same.

The tests cover the plan's Spike C scenarios: initial page, backward paging over 10,000 posts, a permalink jump then paging until the islands join, late inserts, same-millisecond/same-second bursts, 2013 imports mixed with 2026, gap and hole exhaustion with renumber plans, cursors and tombstones. There are also **property tests**: seeded random interleavings of every operation (paging both ways, permalinks, live/late/burst posts, deletes, disconnect/catch-up, replays) against a simulated server, in three id-space sizes. After each step they check that ids are unique, positive and in range, strictly ordered by `(createAt, postId)`, that every renumber plan matches the actual id changes, that every island really is contiguous on the server, and that holes contain no mapped ids. Set `SIM_TRACE=<dir>` to dump the operation log of a failing seed and `SIM_STATS=1` to print per-seed operation counts.

The scenario and property tests run twice: against `InMemoryMessageIdStore` and, through subclasses in `Tests/MattermostSyncCoreTests/Store/`, against `SQLiteMattermostSyncStore` on temp files (property steps inside `transaction`; every store is closed and reopened at the end and must read back identically). The store tests add a lockstep comparison of the allocator and every query against the in-memory store, atomicity of failed `apply` calls and transactions, migrations (empty file, failed migration, newer file), query plans, and the peer, DM, pending, file, cursor and server tables.

Markdown tests are table-driven per feature, with UTF-16 offset checks for emoji, skin tones, ZWJ sequences, flags and Cyrillic text, pathological inputs, random-input validity, and round trips for the reverse direction.

## Known limitations

- Mattermost orders pages by `create_at` only. Posts in the same millisecond can therefore be split across a page boundary differently from `(createAt, postId)` order. Ordering stays correct, but the missing post only appears once it arrives as a late insert or a later page.
- A renumber plan changes ids that other stored data may reference; the caller must remap them. `fillCursor(.newer)` can't fill from the channel start (it returns nil; fill that hole with `.older`).
- Markdown not supported: reference-style links, HTML and HTML entities (`&amp;` stays literal), LaTeX, emoticons such as `:)`, and skin-tone emoji suffixes. Lists are always rendered tight, ordered lists are renumbered from their first number, and table cells lose inline formatting. Column widths count grapheme clusters, so wide characters misalign. Quotes and lists nested deeper than 32 levels stay plain text.
- Reverse direction: CommonMark can't express every range. For example, bold over `(x)` glued to letters on both sides fails the flanking rules. `parse` also trims trailing whitespace, so a round trip isn't byte-identical for such text.

## Diagnostics (Phase 4G)

`Diagnostics/` holds the testable half of Relay's local diagnostics (the app side is MattermostUI `RelayDiagnostics`):

- `DiagnosticsRedactor`: scrubs exported logs line by line: credentials (`Bearer …`, `token=…`, passwords, cookies),
  email addresses and APNs tokens removed, Mattermost ids replaced by salted pseudonyms (`<id:3f9a1c>`, stable within
  one export, random salt per export).
- `DiagnosticReportStore`: MetricKit's JSON reports on disk, bounded by age (30 days), count (40) and total size
  (4 MB); a single report over 1 MB is not kept.
