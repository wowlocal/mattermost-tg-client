# 9 · Risks and decisions

## Risk register

| # | Risk | Likelihood | Impact | Mitigation | When |
|---|---|---|---|---|---|
| R1 | Message ID / history model mismatch (Int32 IDs, holes) | High | High | Sparse allocation scheme; Spike C with property tests; fallback: bypass holes (option 3) | Phase 0 |
| R2 | Building an `Account` without MTProto needs deep TelegramCore changes | Medium | High | Spike A; prefer a no‑op network or protocol seam over broad edits | Phase 0 |
| R3 | Chat list needs a top message per chat; loading the last post for every channel is too slow | Medium | Medium | Chat‑list inclusion with a minimum timestamp; lazy previews | Phase 0–2 |
| R4 | Collapsed reply threads need main history to exclude thread replies | Medium | Medium | MVP shows replies inline; history filter in Phase 3 | Phase 3 |
| R5 | Push: own proxy needed, ID‑only content may need a license, iOS limits on silent clears | Medium | Medium | Stand up the proxy early in Phase 3; mirror the official app's behaviour | Phase 3 |
| R6 | Undocumented, tightly coupled codebase slows everything | High | Medium | Hire or allocate engineers with Telegram‑iOS or Texture experience; write internal notes as we learn; generous buffer | All |
| R7 | Drifting from upstream; security fixes in shared code missed | High | Low–Medium | Hard fork with a pinned tag; watch upstream for security‑relevant fixes in Postbox, Display and media code | Ongoing |
| R8 | GPL / App Store conflict | Medium | High (public) / Low (internal) | Decide audience early; legal review; publish source | Before release |
| R9 | Build fragility (exact Xcode pin, Bazel, long builds) | High | Medium | Dedicated build machines; document commands; cache | Phase 0–1 |
| R10 | Performance on large servers (thousands of channels or users) | Medium | Medium | Batch APIs, concurrency limits, lazy loading, performance budget in Phase 4 | Phase 2–4 |
| R11 | Users depend on plugins we don't support (Calls, Playbooks, Boards) | Medium | Medium | Clarify v1 scope; "open in browser" fallback for plugin content | Phase 0 decision |
| R12 | Mattermost API differences between server versions | Medium | Low | Minimum supported version; capability detection; tests against 3 versions | Ongoing |

## Assumptions to verify in Phase 0

Telegram‑iOS (at the pinned tag):

- [x] `LICENSE` is GPL‑2.0 — **no LICENSE file exists in the repo**; needs legal confirmation (see 08).
- [ ] `MessageIndex` ordering (timestamp → namespace → id) and holes tracked as Int32 ID ranges per peer and namespace.
- [ ] `PeerReadState` supports ID‑based state with an explicit unread `count`.
- [ ] Chat‑list inclusion can place a peer with no messages using a minimum timestamp.
- [ ] Chat folder `includePeers` has no blocking client‑side limit for generated folders; folder server sync can be disabled cleanly.
- [ ] Main history can exclude thread replies (for collapsed reply threads), or how forum topics do it.
- [ ] Emoji status can show a Unicode emoji + text without Premium checks.
- [ ] Which extensions exist under `Telegram/` and which can be dropped.

Mattermost:

- [ ] WebSocket resume (`connection_id` + `sequence_number`) on the minimum supported server version.
- [ ] `/files/{id}` supports HTTP `Range` requests (video streaming).
- [ ] ID‑only push contents: which server editions or licenses support it.
- [ ] Exact `device_id` platform prefix for our deployed push proxy configuration.
- [ ] Mobile SSO flow (endpoints and callback) for the minimum server version.
- [ ] Push payload field that identifies the server (multi‑server routing).
- [ ] (Only if we want DM "seen" checks) whether other members' `last_viewed_at` is exposed by the channel members API.

## Open decisions

| # | Decision | Options | Recommendation | Needed by |
|---|---|---|---|---|
| D1 | Audience and distribution | Personal · internal company (TestFlight, Business Manager, MDM) · public App Store | Internal first; public only after legal review | Phase 0 |
| D2 | Minimum Mattermost server version | Current ESR · latest only · older | Current ESR and newer | Phase 0 |
| D3 | Team mapping | Folders · separate accounts | Folders | Phase 0 |
| D4 | v1 must‑haves | Calls, Playbooks, interactive bots, … | Core messaging + interactive bots; Calls later | Phase 0 |
| D5 | Team size and timeline | — | 2–3 senior iOS + 0.5 backend/DevOps | Phase 0 |
| D6 | App name and branding | — | Neutral name, own icon | Phase 1 |
| D7 | Thread presentation in MVP | Inline replies · collapsed threads | Inline in MVP, collapsed threads in Phase 3 | Phase 2 |
| D8 | Push content mode | Generic · full · ID‑only | ID‑only if the license allows, else generic | Phase 3 |
| D9 | Telegram‑iOS tag to pin | Latest stable at start | Latest stable release at Phase 0 start | Phase 0 |
| D10 | Source hosting (GPL) | Public repo · source on request | Public repo at each released commit | Before first external build |
| D11 | Deleted posts display | Remove · "deleted" placeholder | Placeholder (matches Mattermost) | Phase 2 |
| D12 | DM "seen" checks | Off · derived from `last_viewed_at` | Off (matches Mattermost) | Phase 2 |
| V1 | Voice message format and detection | AAC `.m4a` (transcoded) · Ogg/Opus as recorded; voice bubbles for Relay's marked posts only · also short audio files from other clients | **Taken in 5A (2026‑10‑27): AAC `.m4a`, marked posts only** (see "V1 outcome" below) | Phase 5A |

### V1 outcome (Phase 5A, 2026‑10‑27)

- **Format: AAC‑LC in `.m4a`** (`audio/mp4`, mono, 48 kHz, ~32 kbps), transcoded on the device with Telegram's own
  `convertOpusToAAC`. Evidence: the Mattermost 11.7 web app (its bundle in the dev server's container) classifies
  attachments by extension (`AUDIO_TYPES`: `mp3 wav wma m4a flac aac ogg m4r`) and plays audio in its file preview with a
  plain `<video controls><source src=…>`, switching to a download view when the browser can't decode the file. With
  that markup Relay's `.m4a` played in Chrome 155, WebKit on macOS 27 (a `WKWebView`) and Safari on iOS 26.5; an
  Ogg/Opus file played in Chrome and iOS Safari but in the macOS WebKit view only loaded its metadata (its clock did not
  move in 10 s). AAC is also the format the platforms' own media frameworks decode (AVFoundation can't read Ogg/Opus).
  The Mattermost desktop and official mobile apps, Safari on macOS and Firefox were **not** checked
  ([evidence](../research/phase5a/v1-playback.txt)). Cost: 19–57 ms per recording on the simulator, files 10–16 % larger
  than the Opus recording.
- **Detection: marked posts only.** A voice bubble needs the `props.relay_voice` marker (`{v, duration, waveform}`) and
  exactly one audio file; other audio files (other clients, Relay's own file sends) stay files. The server keeps a
  regular user's custom `props` (11.7, checked through REST as alice and read back by bob in `GET /posts/{id}` and a
  channel page; 12.0.1's `SanitizeProps` removes only a fixed list of integration and notification keys — source read,
  not run).

## Staffing

| Role | Allocation | Focus |
|---|---|---|
| Senior iOS engineer (lead) | 1.0 | TelegramCore/Postbox integration, sync engine, ID scheme |
| Senior iOS engineer | 1.0 | Screens, MattermostUI, media, composer |
| iOS engineer (optional third) | 1.0 | Push, extensions, settings, testing |
| Backend / DevOps | 0.5 | Dev servers, push proxy, CI runners, release pipeline |
| Design | 0.25 | Branding, new screens (threads, attachments, login) |

Useful experience: Swift and Objective‑C, Bazel, AsyncDisplayKit/Texture, reactive programming (SwiftSignalKit/RxSwift), SQLite, the Mattermost API.

Effort summary: MVP in ~3–5 months; parity release in ~7–9 months (see [Phases](05-phases.md#milestones)).
