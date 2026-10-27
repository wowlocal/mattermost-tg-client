# 5 · Phases

Durations assume 2–3 senior iOS engineers. Phase 1 runs in parallel with Phase 0.

## Phase 0 · Feasibility (2–3 weeks)

**Goal:** prove approach A works before committing.

- [ ] Choose and record the Telegram‑iOS release tag to pin. Clone it with submodules.
- [ ] Install the exact Xcode version from `versions.json`. Build for the simulator following the upstream README, with our own bundle ID and team ID.
- [ ] Bring up a local Mattermost server ([7 · Dev environment](07-dev-environment.md)). Seed it with:
  - 2 teams, ~30 channels, 5 users
  - one channel with 10,000+ posts
  - threads, files, reactions, custom emoji, a bot
- [ ] **Spike A — boot without MTProto.** Find the smallest change that builds `Account` / `AccountContext` with no live network. Write fake peers and messages into Postbox. The chat list and chat screen must render them.
- [ ] **Spike B — MattermostKit skeleton.** Login, `/users/me`, channels, posts, WebSocket events printed. Unit tests against recorded JSON fixtures.
- [ ] **Spike C — message ID allocator.** Implement option 2 from [Domain mapping](02-domain-mapping.md#message-ids) with the listed tests.
- [ ] **Spike D — read‑only integration.** A real Mattermost channel in Telegram's chat screen, including scrolling back through history (hole filling) and jumping to an old post.
- [ ] Inventory the `TelegramEngine` calls reachable from the screens we keep. Classify them (see [Architecture](01-architecture.md#strategy-for-telegramcore)).
- [ ] Work through [Assumptions to verify](09-risks-and-decisions.md#assumptions-to-verify-in-phase-0).

**Exit criteria**

- Spike D works on a device.
- The ID scheme is chosen and tested.
- The boot‑path change is understood and small enough to maintain.

**Go/no‑go:** if Spike A or D needs deep changes across many screens, re‑estimate or stop.

## Phase 1 · Fork hygiene (2–4 weeks, parallel)

- [ ] Rename the app, its bundle IDs (app, extensions), app group, keychain access group and URL scheme.
- [ ] Replace icons, launch screen, About screen, and strings mentioning Telegram.
- [ ] Remove the Telegram API ID/hash configuration and default data centers from the build configuration.
- [ ] Add `MattermostFeatures` flags. Hide every feature listed as "Hide" in [Feature scope](06-feature-scope.md).
- [ ] Remove extensions not needed in v1 (watch app, widgets, Siri intents, broadcast upload). Check the exact list under `Telegram/`.
- [ ] Add empty `MattermostKit`, `MattermostSync` and `MattermostUI` Bazel targets wired into the app.
- [ ] Set up CI: build plus unit tests on every push ([7 · Dev environment](07-dev-environment.md#ci)).
- [ ] Write down the upstream policy and the pinned tag in [Architecture](01-architecture.md#upstream-strategy).

**Exit criteria:** a branded app builds in CI, launches into an empty "Add server" screen, and no Telegram‑only entry point is reachable.

## Phase 2 · MVP (8–12 weeks)

### Auth and accounts

- [ ] Server URL screen:
  - normalize the URL
  - `/system/ping`
  - read the client config (site name, SSO options, MFA, version)
  - reject unsupported versions
- [ ] Login: username or email + password, MFA, SSO (GitLab, OpenID, SAML, Google, Office 365 as configured). Personal access token in debug builds.
- [ ] Token in the Keychain (shared access group for extensions). A 401 leads to a re‑login prompt.
- [ ] Multiple servers as multiple accounts; the switcher shows the server name and icon.
- [ ] Logout: `POST /users/logout` and wipe that account's local data.

### Sync

- [ ] ID map store and allocator (from Spike C).
- [ ] Bootstrap sync with a progress screen on first login.
- [ ] WebSocket with reconnect, resume and catch‑up.
- [ ] Event handling for posts, reactions, read state, channels, membership, users, statuses and typing.
- [ ] History hole filling in both directions, plus permalink jumps.

### Chat list

- [ ] Rows for channels, DMs and GMs: last post preview, time, unread and mention badges, mute icon, avatar (user image or channel initials).
- [ ] Generated team folders plus an "All" tab.
- [ ] Favorites as pinned chats.
- [ ] Swipe actions: mute, mark read/unread, close DM or leave channel.
- [ ] Connection state in the title ("Connecting…", "Updating…").

### Chat screen

- [ ] Inline markdown → entities: mentions, `~channel` links, emoji shortcodes.
- [ ] System posts as service messages.
- [ ] Send, edit, delete, reply (to thread), copy text, copy link.
- [ ] Reactions: add and remove, quick reactions, full Unicode emoji picker.
- [ ] Typing indicators, both incoming and outgoing.
- [ ] Mark read on view; "New messages" separator; jump to first unread.
- [ ] Bot and webhook posts: name and icon overrides; message attachments shown read‑only.

### Media

- [ ] Images, videos and files: thumbnails, previews, full download, gallery viewer, Quick Look and share sheet for files.
- [ ] Upload from library, camera and Files, with progress and cancel. Respect the server's max file size.

### Settings (minimal)

- [ ] Profile view, appearance and themes (local), storage usage, logout, About and licenses.

**Exit criteria**

- The team uses it as their only mobile client on the dev server for one week:
  - every post seen in the web app appears in iOS, and the other way round
  - read state syncs both ways
  - the app recovers from airplane mode, backgrounding and server restarts with no lost or duplicated messages
- No reachable dead Telegram features.

## Phase 3 · Parity (8–12 weeks)

### Notifications

- [ ] Push notifications end to end ([4 · Push](04-push-notifications.md)): registration, the rewritten extension, reply and mark‑read actions, `clear` handling, badges, multiple servers.
- [ ] Per‑channel and global notification settings.

### Threads

- [ ] Collapsed reply threads: hide replies from the main history, add a Threads list screen, follow and unfollow, unread thread badges.

### Finding things

- [ ] Search posts (terms, `from:`, `in:`, dates) using Telegram's search UI.
- [ ] Recent mentions.
- [ ] Saved (flagged) posts.
- [ ] Pinned posts.
- [ ] A channel's files in the "Shared media" tab.

### Directory and membership

- [ ] Browse and join channels.
- [ ] Create public or private channels.
- [ ] Start a DM or GM.
- [ ] Member list, add and remove members (permission‑aware).
- [ ] Channel info: header, purpose, edit, archive, leave.

### Composer

- [ ] `@` mention autocomplete.
- [ ] `~channel` autocomplete.
- [ ] `:emoji:` autocomplete.
- [ ] `@channel`/`@here` confirmation for large channels.
- [ ] Custom emoji in the picker and in reactions.

### Integrations

- [ ] Slash commands with autocomplete.
- [ ] Interactive message attachments: buttons and menus.
- [ ] Interactive dialogs.

### Rich content

- [ ] Link previews (`metadata.embeds`, `/opengraph`).
- [ ] Markdown block bubble: headings, lists, tables, code highlighting.
- [ ] Permalinks and deep links: the app's URL scheme plus universal links for our domain if available.

### Profile and status

- [ ] Online, away, DND (with expiry) and offline status.
- [ ] Custom status as an emoji status.
- [ ] Profile editing and avatar upload.
- [ ] Active sessions screen (reuse Telegram's).

### Sharing

- [ ] Share extension rewritten: share text, links and files to a channel.

**Exit criteria:** feature checklist in [Feature scope](06-feature-scope.md) is green for v1. Beta testers can drop the official app for daily work.

## Phase 4 · Hardening and release (4–6 weeks)

- [ ] Performance targets (adjust after Phase 2 measurements):
  - cold start to chat list in under 1 s from cache
  - smooth scrolling with 2,000 channels and 10,000‑post channels
  - first bootstrap for 500 channels in under 15 s on LTE
- [ ] Offline behaviour, cache eviction, database migration strategy for our ID map and custom tables.
- [ ] Accessibility (VoiceOver, Dynamic Type), localization (prune Telegram's strings to what we use).
- [ ] Security:
  - Keychain only for secrets
  - ATS
  - passcode lock (Telegram's)
  - optional certificate pinning
  - managed app configuration (AppConfig/MDM: server URL, restrictions) for company deployments
- [ ] Crash reporting and privacy‑respecting diagnostics.
- [ ] App Store privacy labels and privacy policy.
- [ ] GPL source publication process ([8 · Legal](08-legal-and-licensing.md)).
- [ ] TestFlight beta, then release through the chosen channel (App Store, Apple Business Manager, or MDM).

**Exit criteria:** release candidate passes the regression checklist on the supported server versions and device matrix.

## Phase 5 · After the release candidate

### 5A · Voice messages (1–2 weeks)

Mattermost has no voice‑message post type: the 11.7 web app and server config have no voice post, recorder or setting (checked 2026‑10‑26). So a Relay voice message is an ordinary post with **one audio file attachment**, which every other Mattermost client shows with its own audio player. Relay adds a marker so it can show its own voice bubble.

- [x] **Recording and sending** with Telegram's composer: hold the mic button to record, slide to cancel, lock, pause and resume, preview before sending. Works in channels, DMs, group messages and thread replies, and offline (queued through the write path; the upload id is kept, as in 4F).
- [x] **Format** (decision V1; default: AAC). Telegram records Ogg/Opus. Send **AAC `.m4a`** (mono, ~32 kbps), transcoded on the device, because it plays in every Mattermost client, Safari included. The alternative is to send Ogg/Opus unchanged: smaller and no transcoding, but not every client plays it inline. Check playback in the web app (Chrome, Safari), the desktop app and the official mobile app before deciding.
- [x] **Marker in the post's `props`** (e.g. `relay_voice: {duration, waveform}`) and a file name like `Voice message 2026-10-26 14.05.m4a`. First check that the server keeps custom `props` from a regular user's post.
- [x] **Receiving:** an audio attachment with the marker becomes Telegram's voice bubble (`TelegramMediaFile` with `.Audio(isVoice: true, duration, waveform)`). Without a waveform, compute it after the download. Other audio files stay music/file bubbles; whether short audio files from other clients should also show as voice is part of V1.
- [x] **Playback** through Telegram's player (FFmpeg plays m4a, ogg, mp3). Consecutive voice messages play one after another; playback speed, raise‑to‑listen and the background audio session work.
- [x] **Listened state:** Mattermost keeps none, so the "not yet played" dot is local to the device and never synced.
- [x] **Gates:** turn on `MattermostFeatures.voiceMessages` (the mic button and the recording UI). Round video messages and voice‑to‑text stay hidden.
- [x] **Notifications:** a voice post's push says "attached a file" (its message text is empty). The notification service extension shows "Voice message" when the post has the marker; full‑content pushes carry no `props`, so this needs a post fetch.
- [x] **Search and media tabs:** the Voice tab lists the chat's voice posts. `MessageSearch` currently assumes there are none.
- [x] **Privacy and permissions:** a Relay wording for the microphone permission; `docs/release/privacy.md` and the privacy labels cover recorded audio sent to the user's own server.
- [x] **Accessibility:** VoiceOver labels for the record button and the voice bubble ("Voice message, 0:12", played or not); the recording hint is announced.
- [x] **Tests:** SwiftPM tests for the marker and waveform encoding. Runtime checks against the dev server: send from Relay and play it in the web app; send an audio file from the web app and play it in Relay; offline send; thread reply; push.

**Exit criteria:** a voice message recorded in Relay plays in the Mattermost web, desktop and mobile apps; Relay shows its own and other Relay users' voice messages as voice bubbles with a waveform; release audit and parked‑request checks stay at 0.

**Done 2026‑10‑27** ([PROGRESS](../PROGRESS.md), design: [mattermost-sync.md "Voice messages (5A)"](../design/mattermost-sync.md#voice-messages-5a), V1 outcome in [09](09-risks-and-decisions.md#v1-outcome-phase-5a-2026-10-27)). Not checked: the Mattermost desktop and official mobile apps (the web app's player markup was checked in Chrome, WebKit and iOS Safari), raise‑to‑listen (needs a device), a real microphone recording (a fake microphone fed Telegram's recorder on the simulator).

## Milestones

| Milestone | When (from start) | Demo |
|---|---|---|
| M0 Go/no‑go | Week 3 | Real channel scrolling in Telegram's chat UI |
| M1 MVP | Month 3–5 | Daily use without push |
| M2 Beta | Month 6–7 | Push, threads, search; external beta testers |
| M3 Release | Month 7–9 | Public or internal release |
