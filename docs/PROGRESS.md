# Progress log

Working log for the Mattermost client fork. Each work session reads this first and updates it last. Plan: [PLAN.md](../PLAN.md).

## Current state

- **Phase:** 0 done (go), Phase 1 and Phase 2 in progress.
- **Upstream pin:** Telegram‑iOS `5c20d095d1ab` (app 13.0.1, tag `upstream-pin`), the newest commit built with Xcode 27.0 (installed). Master needs Xcode 27.1.
- **Working name:** "Relay" (`org.relaychat.Relay`, URL scheme `relay`). Placeholder until D6 is decided.
- **Build:** simulator build works; commands in [BUILD.md](BUILD.md). Stock app launches on the dedicated "Relay iPhone 17 Pro" simulator (iOS 26.5).

## Decisions taken by default

The open decisions in [09](plan/09-risks-and-decisions.md#open-decisions) were not answered, so the plan's recommendations are in effect until the user says otherwise:

| # | Default in effect |
|---|---|
| D1 | Internal distribution first |
| D2 | Current Mattermost ESR and newer |
| D3 | Teams as generated folders |
| D4 | Core messaging + interactive bot messages; Calls later |
| D6 | Working name "Relay" |
| D7 | Inline replies in MVP; collapsed threads in Phase 3 |
| D9 | Pinned to `5c20d095d1ab` (Xcode 27.0 compatible) |

## Workstreams

| Workstream | Location | Status |
|---|---|---|
| Upstream checkout | repo root | Done (shallow, submodules shallow) |
| iOS 27 simulator runtime | `xcodebuild -downloadPlatform iOS` | Downloading (not blocking: iOS 26.5 works) |
| First simulator build (stock code, our bundle ID) | [BUILD.md](BUILD.md) | Done: builds in ~9 min, launches |
| MattermostKit (REST + WebSocket client) | [submodules/MattermostKit](../submodules/MattermostKit/README.md) | Done: 139 tests pass; Bazel target builds |
| MattermostSyncCore (ID allocator, markdown, mapping helpers) | [submodules/MattermostSyncCore](../submodules/MattermostSyncCore/README.md) | Done: 57 tests incl. property tests; BUILD file present, not yet built by Bazel |
| Local Mattermost server + seed + fixtures | [infra/dev-server](../infra/dev-server/README.md) | Done: Mattermost 11.7.14 ESR (Team Edition) at http://localhost:8065, reset+seed 56 s |
| Telegram internals map (Spike A prep, assumptions) | [telegram-internals.md](research/telegram-internals.md) | Done |
| SQLite sync store (ID map, peers, cursors) | `submodules/MattermostSyncCore/Sources/MattermostSyncCore/Store` | Done: 100 tests (allocator suites also run on SQLite); Bazel build via sqlcipher untested until Spike D |
| Spike A: null network engine + seeded account | TelegramCore, `submodules/MattermostSync` | Done (commit `f0820341`); screenshots in `docs/research/spike-a-*.png` |
| Spike D: real data as alice (bootstrap, holes, live events) | `submodules/MattermostSync` | Done (commit `030401d2`); screenshots `docs/research/spike-d-*.png` |
| UI inventory for Phase 1 hiding, tabs, settings, login reuse, rebrand | [ui-inventory.md](research/ui-inventory.md) | Done |
| Phase 1 steps 2–12 (feature flags, tabs, settings, chat/peer-info gates, services, rebrand, About) | merged into main (`4bc94bf0`) | Done; screenshots `docs/research/phase1-*.png` |

## Phase 0 checklist

- [x] Choose and record the pinned upstream commit; clone with submodules
- [x] Simulator build with our bundle ID
- [x] Local Mattermost server seeded
- [x] Spike A: boot without MTProto, fake data renders
- [x] Spike B: MattermostKit skeleton with tests
- [x] Spike C: message ID allocator with tests
- [x] Spike D: real channel history in the chat screen
- [x] TelegramEngine inventory for kept screens (research doc §7)
- [x] Assumptions in 09 verified (code reading; see research doc table)

**Phase 0 exit: GO.** All spikes passed; the seam is small (null network engine + marked hooks).

## Phase 2 breakdown

| # | Workstream | Status |
|---|---|---|
| 2A | Write path: send (text, replies, files) via PendingMessageManager seam, edit, delete, reactions (+ reaction list), typing out, mute/favorite consumers, synthetic AppConfiguration (Phase 1 step 1) | Done (2026‑10‑26); screenshots `docs/research/phase2a-*.png` |
| 2B | Login UI (server URL → password/SSO → MFA), root swap (Phase 1 step 13), Add server, logout, session expiry | Agent working (own worktree + simulator) |
| 2C | Rendering gaps: multi-file posts (grouped messages), bot attachments bubble, webhook name/icon overrides, Mattermost service-message type, custom emoji, channel member counts | Later |
| 2D | Media tabs via file search, notification extension encodables, skip Telegram special user ids, ATS local-networking only, DM mention-badge decision; Devices → Mattermost sessions; remove "Auto-Login via Telegram"; Notifications/Reactions subtitle; theme carousel | Later |

## Log

### 2026‑10‑26

- Freed disk: internal now ~154 GB free.
- Pinned upstream, checked out into this repo, committed plan docs.
- Started: simulator runtime download, first build, four agents (MattermostKit, MattermostSyncCore, dev server, Telegram internals research).
- Build fixes (commit `d5181136`): `Make.py build --disableProvisioningProfiles`; stubbed the one iOS 27.1‑SDK call (`Display/WindowContent.swift`, marked `MATTERMOST:`). Installed the Metal toolchain.
- First simulator build succeeded; stock app launches under `org.relaychat.Relay`.
- Telegram internals research done. Corrections to the plan:
  - Main history can't exclude thread replies; collapsed threads need new work (tag bit for root posts is the least invasive option).
  - Emoji status only references custom-emoji files; custom status text needs a new field.
  - Map GMs to `TelegramChannel` (group) instead of `TelegramGroup`: basic groups never get `threadId` on replies.
  - Holes are per (peer, namespace, tag space); a fill must remove at least the requested range or it is retried every 20 s.
  - Each server's own user needs a distinct local `PeerId`, or the shared context deletes one account.
  - Every channel needs a chat-list inclusion, or its history stays "loading".
- Spike A started (agent): null `NetworkEngine`, skip `resetStateManagement`, seeded authorized account.
- iOS 27.0 simulator runtime installed (iOS 26.5 sim still used for the spike).
- Wrote [MattermostSync design](design/mattermost-sync.md): module layout, SQLite ID map store, bootstrap order, hole-fill contract, managed-operation replacements, Spike D scope.
- Dev server done: 5 users, bot, 2 teams / 34 channels, `firehose` 11,730 posts (2013 + 2024–2026), threads, reactions, custom emoji, files, interactive posts; 35 REST + 12 WebSocket fixtures in `infra/dev-server/fixtures/`. Note: 11.x sends `multiple_channels_viewed` instead of `channel_viewed`; Team Edition used because the unlicensed Enterprise image caps history at 10,000 posts.
- MattermostKit done. Findings from the real 11.7 server that matter for MattermostSync:
  - A resumed WebSocket gets **no** `hello`; missed events are replayed. The client probes with a ping right after connect to tell "resumed" from "new connection".
  - An invalid token still gets a WebSocket upgrade, then silence; the client times out the handshake and checks `GET /users/me`.
  - Use `channelsViewed` (handles `multiple_channels_viewed` and `channel_viewed`).
  - Use `xcrun swift` (or `/usr/bin/swift`): the swiftly 6.3.3 `swift` first on PATH can't build against the Xcode 27 SDK.
- MattermostSyncCore done. Allocator deviations worth knowing: pages squeeze spacing near a full hole; renumbering moves the smaller part of an island (≤10,000 posts) or a small window for repeated late inserts; a late post landing in a hole becomes a one-post island. **Callers must remap every stored local id (read state, thread roots, replies) when applying a renumber plan.** Markdown gaps: reference links, HTML entities, LaTeX, emoticons.
- Both SwiftPM packages pin `.swift-version` = `xcode` so plain `swift test` uses Xcode's toolchain.
- **Spike A done.** App boots into a seeded chat list and opens chats with zero sockets (checked with `lsof` sampling, simulator network log, `nettop`). Gotchas for Spike D:
  - A chat screen only appears once all its loading signals fire; `xcrun simctl launch --console-pty` shows which one is stuck.
  - Contact sync must be turned off at account setup (as Telegram's login does), or a contacts signal never fires.
  - Every user needs cached user data written, or DMs and Saved Messages never open.
  - Channel messages use thread 1, replies the thread of their target, Saved Messages the own peer id as thread; every used thread needs its holes cleared.
  - Opening a channel still triggers Telegram's channel polling (parked); switch it off before MVP.
  - Also fixed: the call reflector benchmark sent UDP to Telegram (internal builds); now off.
  - Debug hook: `SIMCTL_CHILD_RELAY_DEBUG_OPEN_CHAT=1|ios-team|town-square|dm|off-topic|saved`.
- Spike D started (agent): debug login as alice, bootstrap, hole filler, WebSocket events, converters, media resources.
- License check: Telegram-iOS has no LICENSE file (pinned commit or history); README only asks forks to publish their code. Updated plan 08: license terms need legal confirmation before external distribution.
- SQLite sync store done (`SQLiteMattermostSyncStore`): allocator calls must run inside `store.transaction {}`; posts are keyed by Mattermost channel id; only the app writes the ID map. Spike D told to switch to it.
- UI inventory done. Key points: a synthetic local `AppConfiguration` hides Premium/Stars/gifts with no upstream edit (Phase 1 step 1, goes with MattermostSync); Calls/Contacts tabs removable with two small changes; login = new `ItemListController` screens (not Telegram's auth flow); reaction picker is empty until MattermostSync writes `AvailableReactions`; Log Out does nothing for phone-less users; strings are English-only.
- Phase 1 steps 2–12 started in a separate worktree (agent). Steps 1 and 13 + AvailableReactions wait for Spike D.
- **Spike D done.** Debug login as alice (env vars), bootstrap 0.7–4.6 s for 39 chats, hole filler, WebSocket + catch-up, converters, media resources, read-state push. Verified: chat list = REST (0 mismatches), full firehose history 11,730/11,730, live events 35–80 ms, only localhost traffic.
  - Mattermost paging gap: `before`/`after` skip posts in the cursor's exact millisecond; worked around (drop the cut group at a full page's end).
  - Known gaps moved to 2C/2D. Dev server was reset at the end (all server IDs changed).
- **Phase 1 steps 2–12 done** on branch `worktree-agent-a8ee3495c11158817`: `MattermostFeatures` flags (follow `MattermostBackend.isEnabled`), Chats+Settings tabs, settings trimmed (two-row Privacy screen, Language hidden), chat-screen/chat-list/peer-info gates, link/share/quick-action filters, no StoreKit/CallKit/VoIP/Siri/widget/broadcast extensions, Relay rebrand (strings overlay `Telegram-iOS/Relay.strings`, placeholder icon from `tools/relay-icon/`), About Relay (source URL TODO). Debug hook `RELAY_DEBUG_OPEN_SCREEN=settings|compose|peerinfo|attach|privacy|data|notifications|appearance|about`.
  - Open: Devices still opens Telegram's sessions screen; "Auto-Login via Telegram" in Open Links In; Notifications → Reactions subtitle says "Stories"; theme carousel shows one theme. Moved to 2D.
  - Builds: string-key or TelegramCore changes ≈15 min near-full rebuild; other incremental builds a few minutes.
- Phase 1 merged into main (`4bc94bf0`, by the 2A agent); its worktree removed and Bazel output expunged (12 GB). 2B started in a new worktree.
- **Phase 2A done** (write path, main checkout). TelegramCore seam `MattermostMessageSender` (PendingMessageManager keeps its bookkeeping; PendingUpdateMessageManager hands over edits); MattermostSync `Write/`: sender, consumers for reactions, deletes, mute, favorites, typing; synthetic AppConfiguration + reaction list with on-device emoji images. Debug hook `RELAY_DEBUG_WRITE` (engine calls, see BUILD.md), `RELAY_DEBUG_NO_PERMISSION_PROMPTS=1`, `RELAY_DEBUG_OPEN_SCREEN=reactions`.
  - Verified against the dev server (REST as alice/bob, bob's WebSocket): text with markdown, thread reply (`root_id`), image (1200×800 JPEG), text file, reactions add/remove incl. custom `:partyblob:` and two own reactions on one post, edit (`edit_at`), own delete (404 after), deleting bob's DM post → 403, restored + toast, offline (server stopped): 3 messages pending then sent in order on reconnect, rejected post → failed state → resend, typing (`parent_id` in threads, throttled to the server's 5 s), mute/unmute and favorites both directions incl. team-folder pins, no duplicates after WebSocket echoes, only `127.0.0.1:8065` sockets.
  - Findings: on 11.7 the server does not move a channel out of its previous sidebar category when it is added to Favorites (the client PUTs both); DM favorites are per team; `channel_member_updated` carries the member as a JSON string with an empty broadcast channel; Telegram's context-menu reaction bar reads the `CloudTopReactions` list (not `AvailableReactions`) when all reactions are allowed; the notifications prompt persists across app launches until answered (reboot the simulator).
  - Gaps: albums go out as one post per item (multi-file posts are 2C); no timed mute on Mattermost (any mute is indefinite); favorites order not pushed; upload file ids live in memory (restart between upload and post re-uploads); `pending_post_id` dedupe across restarts relies on the server's short pending-post cache; "delete for me" is local only; admins can't delete others' posts from the UI yet (no admin rights on peers); forwards are re-posted without attribution; only text typing is sent.

