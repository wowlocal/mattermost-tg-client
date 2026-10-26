# Progress log

Working log for the Mattermost client fork. Each work session reads this first and updates it last. Plan: [PLAN.md](../PLAN.md).

## Current state

- **Phase:** 0 (Feasibility), started 2026‑10‑26.
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
| MattermostKit (REST + WebSocket client) | `submodules/MattermostKit` | Agent working |
| MattermostSyncCore (ID allocator, markdown, mapping helpers) | `submodules/MattermostSyncCore` | Agent working |
| Local Mattermost server + seed + fixtures | [infra/dev-server](../infra/dev-server/README.md) | Done: Mattermost 11.7.14 ESR (Team Edition) at http://localhost:8065, reset+seed 56 s |
| Telegram internals map (Spike A prep, assumptions) | [telegram-internals.md](research/telegram-internals.md) | Done |
| Spike A: null network engine + seeded account | TelegramCore, `submodules/MattermostSync` | Agent working (only workstream running Bazel) |

## Phase 0 checklist

- [x] Choose and record the pinned upstream commit; clone with submodules
- [x] Simulator build with our bundle ID
- [x] Local Mattermost server seeded
- [ ] Spike A: boot without MTProto, fake data renders
- [ ] Spike B: MattermostKit skeleton with tests
- [ ] Spike C: message ID allocator with tests
- [ ] Spike D: real channel history in the chat screen
- [x] TelegramEngine inventory for kept screens (research doc §7)
- [x] Assumptions in 09 verified (code reading; see research doc table)

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
