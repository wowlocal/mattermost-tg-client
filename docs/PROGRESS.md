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
| 2B | Login UI (server URL → password/SSO → MFA), root swap (Phase 1 step 13), Add server, logout, session expiry | Done; merged into main by the 2C agent (SSO unverified); screenshots `docs/research/phase2b-*.png` |
| 2C | Rendering gaps: multi-file posts (grouped messages), Slack-style attachments + interactive buttons/menus, webhook name/icon overrides, Mattermost service messages, custom emoji, channel member counts | Done (2026‑10‑26); screenshots `docs/research/phase2c-*.png` |
| 2D | MVP polish: DM/GM badges (count only), album unread counting, media tabs via file search, special peer ids, Devices → Mattermost sessions, leftover Telegram UI, expired-session UX, strings into Relay.strings, system-message markdown, full emoji table | Agent working (main checkout) |

## Phase 3

| # | Workstream | Status |
|---|---|---|
| 3A | Push notifications: push proxy infra, device registration, Notification Service Extension rewrite, reply/mark-read actions, open-on-tap | Done on branch `worktree-agent-a53718b0b6fd32339` (screenshots `docs/research/phase3a-*.png`); 2D agent merging into main. **Real APNs needs the user's key** (steps in `infra/push-proxy/README.md`) |
| 3B | Collapsed reply threads: channel history without replies, thread view, Threads list per team, follow/unfollow, thread read state, `_root` unread counts | Agent working (own worktree) |
| 3C | Search (posts), recent mentions, saved posts, pinned posts, channel files | Next |
| 3D | Directory & membership (browse/join/create channels, DM/GM creation, member lists, channel info edit/archive/leave), composer autocomplete (@ ~ :), slash commands, interactive dialogs | Next |
| 3E | Link previews, markdown block bubble (headings/lists/tables/code), permalinks & deep links | Next |
| 3F | Own status (online/away/DND/offline, custom status), profile editing + avatar, share extension | Next |

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

- 2B asked to merge main (with 2A) into its branch before final checks. 2C started on main.
- **Phase 2B done** (branch `worktree-agent-a9d3edda1bc80d75a`, main merged in at `d3473fb9` (2A) and `ae224eb0` (2C so far); also Phase 1 step 13). New module `MattermostUI`: server address → credentials (login id/password per the server config, SSO buttons) → MFA (`CodeInputView`), Relay-branded, as the root of Telegram's auth record (ui-inventory §4.3 option (a); `UnauthorizedAccount` no longer prefetches MTProto keys). `MattermostAccountSetup` (MattermostSync) is shared by the screens and the env-var debug login. Add Account = Telegram's `beginNewAuth`; logout and session expiry in `MattermostSync.startLifecycle` (Telegram's `managedCleanupAccounts` cleanup is skipped). Screenshots `docs/research/phase2b-*.png`; checks via the debug remote (`tools/relay-remote.py`) and `tools/mm-dev-auth.py` (docs/BUILD.md).
  - Verified on the merged build (simulator "Relay Phase1 iPhone 17 Pro"): fresh install → server screen; invalid address, unreachable port, non-Mattermost HTTP server, wrong password and duplicate account errors; `localhost:8065` (no scheme) falls back to http in debug builds; alice → chat list; Add Account → bob (distinct own peer ids `16218611695608`/`14091109874792`), switching both ways, each with its own data; carol with MFA (wrong code → inline error, TOTP code → in); logout of one account (record, `account-<id>` directory, Keychain token and the server session gone; others stay), logout of the last → server screen; dave's sessions revoked → "Session Expired" on the next activation (or 401) → re-login as dave keeps the account and catches up; re-login as bob instead replaces dave's account. Env-var debug login still works (and logout afterwards shows the login).
  - Minimum server version: one constant, `ServerCompatibility.minimumVersion` (11.7), unit-tested with the URL normalization, the wrong-MFA-code error and the 401 hook in MattermostKit (154 tests pass, 5 skipped).
  - Findings: a wrong MFA code is `api.user.check_user_mfa.bad_code.app_error` (not the "MFA required" id); a revoked session gets no WebSocket close and no 401 until the next request, so tokens are checked when the app becomes active; an unlicensed 11.7 Team Edition server never reports `EnableSignUpWithGitLab` even with GitLab SSO configured, so SSO buttons could not be shown or run (SSO stays unverified); iOS offers to save passwords after the credentials step (scripted runs clear debug-filled passwords); a notifications prompt left unanswered survives app reinstalls until the simulator reboots (launch with `RELAY_DEBUG_NO_PERMISSION_PROMPTS=1`).
  - Gaps: login strings are English literals in MattermostUI (not in `Relay.strings`); Telegram's 3-account limit (Premium limit screen) still applies to Add Account from Settings; while a session is expired the title shows "Connecting…"; sends during an expired session fail (resend after re-login); Keychain tokens are app-only (no shared access group for extensions yet).
  - Dev server: MFA active for carol; dave's sessions revoked.
- **Pre-release audit item (Phase 4):** confirm every `RELAY_DEBUG_*` hook, the debug remote and debug screens are compiled out of release builds (`#if DEBUG`), and remove `NSAllowsArbitraryLoads`.
- 2B worktree removed (branch kept until merged); Phase 1 branch deleted. 3A (push) started in a worktree.
- 2B merged into main by the 2C agent (`3e28a5ef`); merged build smoke-tested (login screens → alice via the debug remote, chat list, chats).
- **Phase 2C done** (main checkout). Design: mattermost-sync.md "Rendering (2C)".
  - **Multi-file posts:** one message per file (images → album, other files → file group, text on the last file or the album's first image; reactions/reply count/pin/buttons on the primary). MattermostSyncCore post parts (`<post id>#01…`, sorted right after the post; cursors give the server post; deletes take the parts): 16 new tests, property tests now mix multi-part posts and part edits (118 tests; MattermostKit 155 after the 2B merge, incl. channel stats). Albums and grouped files from the app go out as one post (`MattermostMessageSender.sendMessageGroup`).
  - **Attachments:** pretext/author/title(link)/text/fields/footer as formatted text in a block quote, first same-origin `image_url` as the photo (flattened onto white; Telegram draws photos opaque). Buttons and menus as an inline keyboard (good/danger/primary styles); taps routed from `ChatController.requestMessageActionCallback` to `POST /posts/{id}/actions/{id}`, menus via an option sheet (static options, users, channels); integration updates arrive as edits, ephemeral answers as a toast, failures as an alert.
  - **Overrides:** a synthetic bot user per `override_username` + `override_icon_url` as the author (name, icon, bubble grouping; no upstream change); icons prefetched.
  - **System posts:** custom-text service messages with user mentions (bold, mention entities) and bold values. **Custom emoji:** `:name:` of the server's emoji as custom-emoji entities (the 2A reaction image files, stored for `associatedMedia`); reactions already rendered them. **Member counts:** `/channels/{id}/stats` → "N members"; Telegram's online-member lists skipped in the title and group info.
  - Verified (simulator + REST): 5-image album, file group, image+PDF post; album and grouped files sent from the app as one post (3 and 2 `file_ids`); reaction on an album part lands on the post (+1 by alice), caption edit, reply to a part gets `root_id` = album post and bumps the album's reply count, delete via a part and via the post (all parts gone locally, 404 on the server, thread reply with it); live album from bob with inline `:partyblob:`; bob's edit removing a file shrinks the group; Approve button and a menu choice reach a local responder through the server (`selected_option` in the integration's context; post updated, ephemeral answer shown); the responder (Python stdlib, scratch only) ran in a `python:3.13-alpine` container sharing the Mattermost container's network namespace, because the server only allows `localhost` integration URLs (`AllowedUntrustedInternalConnections` is fixed by the compose env); users menu and the seed's unreachable action URL → "Action integration error." alert; webhook name/icon overrides incl. a relative icon URL; service messages; member counts; firehose paged 11,730/11,730 with 0 stalls; only `127.0.0.1:8065` sockets.
  - Taps were driven by debug hooks that call the chat's own `requestMessageActionCallback` closure (`RELAY_DEBUG_OPEN_SCREEN=button:<title>`, `RELAY_DEBUG_SELECT_OPTION`); no physical taps (no UI automation here).
  - Gaps: a file removed by an edit and re-added later at the same position stays hidden (tombstoned part); Postbox counts every message of an album as unread once the user reads locally (Mattermost counts one post); a post with images and other files shows two bubbles; attachment colour, `thumb_url`, `author_icon`/`footer_icon` not shown; images not on the server are not loaded (no image proxy); markdown in a new header/purpose shows raw in the service message; some emoji shortcodes are missing from `EmojiTable` (`:floppy_disk:` stays text); interactive dialogs (`trigger_id`) unsupported; ephemeral answers are toasts, not chat messages; the group info Members pane and @-mention suggestions still need a TelegramCore seam in `_internal_channelMembers` (`GET /channels/{id}/members`); an override's profile shows "Send Message", which fails.
  - Dev server state left by 2C: test posts in ~integrations (responder posts 3.0.0/3.0.1/3.0.2, `deploy-bot` and `backup-cron` webhook posts) and ~media (bob's live album, edited); ~sandbox header changed by bob.
- 2B merged into main by the 2C agent (`3e28a5ef`); 2B branch deleted. **Decision (D11-like, made by me as default):** DMs/GMs show unread count only, no "@" badge (Mattermost counts every DM/GM message as a mention). 2D started.
- **3A done** (branch `worktree-agent-a53718b0b6fd32339`): push proxy 6.6.0 (`relay_apple` / `relay_apple_sandbox`), registration per account (permission asked after login), tokens moved to the shared Keychain group `group.org.relaychat.Relay`, NSE logic in `MattermostPushService` (routing via server DiagnosticId + membership/mention heuristics, communication notifications with avatars, ack), reply/mark-read actions, open-on-tap (thread aware), `clear`/`update_badge`/`session`.
  - **Not yet exercised:** the real NSE — `simctl push` never launches service extensions; verified via a debug in-app `simulate-push` path instead. Needs the user's APNs key: see `infra/push-proxy/README.md` (App IDs + capabilities, .p8 key, Team ID in `build-config/development-configuration.json`).
  - Gaps: grouping by channel only (two accounts in one channel stack together); a DM `clear` with two local accounts may clear the other's; sender shown as @username; ID-only push untested (needs a license); `clear`/`update_badge` don't reach a force-quit app.
- 3A worktree removed (branch kept until 2D merges it). 3B (collapsed threads) started in a worktree. Phase 3 split into 3A–3F.
- **Phase 3A (push notifications)** on branch `worktree-agent-a53718b0b6fd32339` (contains 2B): `infra/push-proxy` (mattermost-push-proxy 6.6.0 by digest, `relay_apple`/`relay_apple_sandbox`, dev-server wiring by REST + compose override for the pinned `SendPushNotifications`, `sim-bridge.py`), `submodules/MattermostPush` (payload, routing, text, device ids, shared Keychain; 36 SwiftPM tests incl. real captured payloads), `submodules/MattermostPushService` (the extension's pipeline: route, ack, text, communication notification with the sender's picture), MattermostSync `Push/` (registration per account, taps, Reply via the write path, Mark as Read, clear), small TelegramUI hooks (token, responses, foreground presentation, categories), simulator entitlements. Screenshots `docs/research/phase3a-*.png`.
  - Verified on the simulator ("Relay Push iPhone 17 Pro"): real APNs sandbox token, `PUT /users/sessions/device` per account (server shows `relay_apple_sandbox:…`), logout removes it; server → proxy → APNs (403 `InvalidProviderToken` with a throwaway key); DM, channel mention, collapsed-thread reply rendered as communication notifications with avatar, lock screen / banner / Notification Center, background / locked / killed; alice + bob routed correctly ("→ alice"/"→ bob", one `@all` push each); acks reach the server and proxy; Reply and Mark as Read reach the server; taps open the DM at the post, the thread view, and switch account at a cold start; `clear` removes, `update_badge` sets the badge; only 127.0.0.1:8065 traffic from the app.
  - Findings: `simctl push` never runs service extensions (the extension's code is run in the app via the debug remote `simulate-push`); the real extension needs a real APNs key (steps in `infra/push-proxy/README.md`); `tools/sim-allow-notifications.py` grants notification permission on a shut-down simulator; AXe needs `touch --delay 0.15` for SpringBoard platters.
  - Dev server state: SendPushNotifications on (mattermost container recreated with `infra/push-proxy/dev-server-push.override.yml`), push server `http://push-proxy:8066`, proxy `relaypush-push-proxy-1` running with a throwaway key. `infra/dev-server/up.sh` turns pushes off again.
