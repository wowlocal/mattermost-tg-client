# Release-candidate regression checklist

Run this before handing a build to testers (Phase 4 exit criterion: "release candidate passes the regression checklist
on the supported server versions and device matrix"). It lists every user-facing feature in
[plan 06](../plan/06-feature-scope.md) and [PROGRESS](../PROGRESS.md), how to exercise it, what must happen, and how
the result is checked. The last run's results are at the end ([Results](#results)).

## What to run it on

| | |
|---|---|
| **Release candidate** | `release_sim_arm64` with `build-config/appstore-configuration.json` (BUILD.md "Release builds"); `tools/relay-release-audit.sh bazel-bin/Telegram/Telegram.ipa` must pass first |
| **Debug build** | `debug_sim_arm64` (BUILD.md "Simulator build") for the items marked **D**: they need the debug remote (`tools/relay-remote.py`) or a `RELAY_DEBUG_*` hook, which release builds don't contain |
| **Servers** (D2) | the current Mattermost ESR (11.7) and the newest Mattermost release; core items (marked ★) on both |
| **Devices** | a small phone (iPhone 17e), a large phone (iPhone 17 Pro Max), an iPad (iPad Air 13-inch), on each installed iOS (26.5, 27.0): the smoke set (marked ●) plus the layout checks in section S |

## Setup

- **Release builds refuse `http://` servers**, so put a TLS proxy in front of the dev server and trust its CA on the
  simulator: nginx on the dev server's compose network, `proxy_pass http://mmdev-mattermost-1:8065` with the WebSocket
  upgrade headers, published on `127.0.0.1:8443`, a leaf certificate for `localhost`/`127.0.0.1` from a throwaway CA
  (BUILD.md "Phase 4G"); `xcrun simctl keychain <udid> add-root-cert ca.pem` on every simulator used. The account's
  server is then `https://localhost:8443`.
- **Real taps**: `tools/relay-axe.py <udid> …` (AXe, addressed by accessibility label; `tap-text`/`wait-text` find text
  by OCR where AXe's tree is blind: Telegram's alerts, action sheets, tab bar, the chat list header). Release builds
  have nothing else. `export AXE=/path/to/axe` (XcodeBuildMCP's `bundled/axe`).
- **Server-side checks**: REST as the test users (`/api/v4/…` with a session token from `POST /users/login`; the
  passwords are in `infra/dev-server/.env`, never on a command line or in output), `tools/mm-dev-auth.py` (MFA codes,
  sessions, revocation), `infra/push-proxy/configure-dev-server.py --sessions <user>` (push device ids).
- **Logs on a release build**: Settings → About Relay → Diagnostics → Save Diagnostic Logs writes Telegram's file log
  (`<app group>/telegram-data/logs/app-logs/*.txt`, MattermostSync lines start with `[Mattermost]`). Every build
  writes one unified-log line per launch, `[Relay] perf: chat list ready <ms> after didFinishLaunching, <ms> after
  process start` (`xcrun simctl spawn <udid> log stream --style compact --predicate 'eventMessage CONTAINS "[Relay]"'`).
- **Users**: alice (main), bob (the other side), carol (MFA), dave (session revocation), sysadmin. Don't revoke or
  log out alice/bob sessions: other simulators and the user's device may use them.

### Driving tips (learned in 4E)

- AXe frames of Telegram list items can be stale after scrolling; prefer `tap-text` (OCR) for Settings rows, and
  scroll so the target is mid-screen: the floating tab bar covers the bottom ~90 pt and takes the touch.
- A swipe is a fling (momentum); to reach a chat use the chat list search instead of scrolling.
- Don't tap a focused text field again: the edit menu appears and AXe's hardware-keyboard typing can be lost until
  the app restarts. Typing `/` with AXe's hardware keyboard had the same effect on one simulator: type `/` with the
  software keyboard (`numbers` key, then `/`).
- Wait ~1 s after focusing a field before typing, or the first characters are lost while the keyboard comes up.
- Long-pressing on a link opens the link's menu, not the message's: long-press the bubble away from links.
- `Copy` / `Copy Link` put the text on the Mac's pasteboard too (the simulator syncs it).

## Legend

**Build**: R = runs on the release build with real taps; **D** = needs a debug build; R/D = the main part on release,
details on debug. ★ = core set for the second server version. ● = device-matrix smoke set.

## A · Accounts and login

| ID | Item | Steps → expected | How checked | Build |
|---|---|---|---|---|
| A1 ★● | Server screen | Fresh install → "Relay … Enter the address of your team's server", footer "Works with Mattermost 11.7 and newer." → `https://localhost:8443` → Connect → credentials screen with "localhost:8443 · Mattermost <version>" | AXe tree (`TextField "Server address"`, `Button "Connect"`) | R |
| A2 | HTTPS only | `http://localhost:8065` → "Can't Connect / Relay only connects to servers over HTTPS."; `foo bar` → "That doesn't look like a server address" | OCR of the alert | R |
| A3 ★● | Password login | alice + password → Log In → chat list; the notification permission prompt comes after login (Allow); iOS may offer "Save Password?" (Not Now) | AXe, server `GET /users/me/sessions` has a new session | R |
| A4 | Wrong password | → "Can't Log In" with the server's message; fields kept | OCR | R |
| A5 ★ | MFA | carol → "Enter Your Code"; `000000` → "That code didn't work…"; `mm-dev-auth.py code carol` → chat list | OCR; MFA must be on for carol (`enable-mfa carol` stores the secret in `build-input/`) | R |
| A6 ★ | Several accounts | Settings → Edit → Add Another Account (or long-press the Settings tab → Add Account) → second account; long-press the Settings tab → switcher lists status, custom status, Add Account, both accounts → switch back and forth | OCR of the switcher; each account's chat list | R |
| A7 ★ | Log out | Settings → Edit → Log Out → alternatives screen → Log Out → OK → the account's server session ends, the app shows the other account (or the server screen when it was the last) | server sessions count drops by one | R |
| A8 | Session expiry | `mm-dev-auth.py revoke-sessions dave` → bring Relay to the foreground → title "Session Expired" + alert → Log In → "Log In Again" with dave prefilled → password → chat list, local data kept | OCR; sessions | R |
| A9 | Too-old server | A server older than 11.7 → "This server runs Mattermost … Relay needs Mattermost 11.7 or newer" | MattermostKit `ServerCompatibility` tests (no old server kept) | — |
| A10 | SSO | GitLab/OpenID/SAML button → system web sheet → token | Not testable on the dev server (no IdP); unverified since 2B | — |

## B · Chat list

| ID | Item | Steps → expected | How checked | Build |
|---|---|---|---|---|
| B1 ★● | Rows, folders, badges | Chat list shows channels, DMs, GMs with preview, time, unread and mention badges; tabs **All Chats** + one per team with unread counts; "Archived Chats" holds archived channels | OCR; unread counts vs `GET /users/me/teams/unread` | R |
| B2 | Favorites | Long-press a row → Pin → server preference `favorite_channel`; Unpin removes it | REST preferences | R |
| B3 | Swipe and row menu | Swipe left: Mute / Delete / Archive; Mute → channel `notify_props.mark_unread=mention`, Unmute → `all`; long-press: Mark as Read/Unread, Pin, Mute, Delete | REST channel member | R |
| B4 | Connection state | Server stopped → title "Connecting…"; back → "Chats" | OCR | R |
| B5 ★ | Live order | bob posts → row jumps to the top with a badge | OCR | R |
| B6 | CRT preview | Rows preview and sort by the newest root post under collapsed threads | `dump-chatlist` | D |

## C · History and live updates

| ID | Item | Steps → expected | How checked | Build |
|---|---|---|---|---|
| C1 ★● | Open a chat | Opens at the newest messages (or the first unread), marks read | OCR; server `msg_count` | R |
| C2 ★ | Paging | Fling up through ~firehose → older pages load, dates go back (to 2013 with `scroll to=top`) | OCR of dates; `scroll to=top` | R/D |
| C3 | First unread | A chat with unread posts opens at the first unread, the down button counts the rest | OCR | R |
| C4 | Permalinks | See J3 | | |
| C5 ★ | Live | bob posts, edits, reacts, deletes via REST while the chat is open → appear / "edited" / reaction / gone | OCR | R |
| C6 ★ | Reconnect | Stop the server container ~30 s → "connecting…"; start → posts made meanwhile appear, title back | OCR; `docker stop/start mmdev-mattermost-1` | R |
| C7 | Rendering | System messages, bot/webhook name+icon overrides, attachments (title, fields, footer, colour bar), custom emoji, markdown table/headings/code, mixed image+file posts | Screenshots of ~4C Accessibility, ~integrations, ~sandbox | R |

## D · Writing

| ID | Item | Steps → expected | How checked | Build |
|---|---|---|---|---|
| D1 ★● | Send | Type `… **bold** :smile:` → Send → server post with the markdown; bubble bold + 😄 | REST `GET /channels/{id}/posts` | R |
| D2 ★● | Thread reply | In a thread view, send → server `root_id` = the root | REST | R |
| D3 ★ | Edit | Long-press own post → Edit → change → ✓ → server `edit_at`, bubble "edited" | REST | R |
| D4 ★ | Delete | Long-press own post → Delete → "Delete for everyone" → server 404 | REST | R |
| D5 ★ | Reactions | Long-press → 👍 → server `+1`; tap own reaction → removed; long touch on a reaction → who reacted | REST `/posts/{id}/reactions` | R |
| D6 | Typing | bob's WebSocket `user_typing` → "••• Bob" in the header; typing in Relay → bob's WebSocket gets `typing` | WebSocket client as bob | R |
| D7 ★ | Media | Attach → Gallery (photo permission) → 2 photos + caption → one post with 2 files; File tab → document picker; a file over the server's `MaxFileSize` is refused | REST `file_ids` | R |
| D8 ★ | Offline queue | Server stopped, send → clock; server back → posted once | REST | R |
| D9 | Upload ids kept across a restart | `RELAY_DEBUG_SEND_DELAY` (BUILD.md "Phase 4F") | log | D |
| D10 | Forward | Long-press → Forward → chat → posted (known gap: without attribution) | REST | R |
| D11 | `@channel` confirmation | Not implemented (plan 05 Phase 3 composer): a `@channel` in a large channel is sent without asking | — | — |

## E · Collapsed threads

| ID | Item | Steps → expected | How checked | Build |
|---|---|---|---|---|
| E1 ★● | Thread view | Channel shows roots with "N Replies" → tap → root + replies | OCR | R |
| E2 ★ | Threads list | Chat list threads button (badge) → per-team tabs, "N UNREAD · M MENTIONS"; open an unread thread → it leaves the server's unread list | REST `/users/{id}/teams/{team}/threads?unread=true` | R |
| E3 | Follow | Root's menu → Unfollow Thread / Follow Thread → server followed list | REST | R |
| E4 | Unread separator | A followed thread with unread replies opens at the first unread with "Unread Messages" | `replies post=…` + log | D |

## F · Integrations

| ID | Item | Steps → expected | How checked | Build |
|---|---|---|---|---|
| F1 | Buttons and menus | Attachment buttons/menu (~4C Accessibility): menu → option sheet; unreachable integration → "Action integration error." | OCR | R |
| F2 | Dialogs | `/relaydemo dialog` with a responder (BUILD.md "Phase 3D") | `dialog*` commands | D |
| F3 ★ | Slash commands | `/away` → "You are now away (Only visible to you)", server status away | REST status | R |
| F4 | Command autocomplete | `/aw` → "/away Set your status away" suggestion | OCR | R |

## G · Autocomplete

| ID | Item | Steps → expected | How checked | Build |
|---|---|---|---|---|
| G1 ★ | `@` `~` `:` | `@bo` → Bob/Build Bot; `~relay-3e` → 3E Links / 3E Public; `:smi` → emoji strip; picks insert `@bob `, `~relay-3e-links `, 😄 | REST message text | R |

## H · Finding things

| ID | Item | Steps → expected | How checked | Build |
|---|---|---|---|---|
| H1 ★● | Search | Chat list search "deploy" → messages from all chats; tap → the chat at the post | OCR | R |
| H2 | People and channels | Search "car" → Carol (people), channels | OCR | R |
| H3 | Recent mentions | Settings → Recent Mentions → list; live while open | OCR | R |
| H4 | Saved posts | Message menu → Save Post → server `flagged_post`; Settings → Saved Posts lists it | REST preferences | R |
| H5 | Pins | Message menu → Pin → "Pinned Message" bar → server `/channels/{id}/pinned` | REST | R |
| H6 | Files | Chat profile → Files tab, its search | OCR; `peerinfo-search` | R/D |
| H7 | In-chat search | Chat → search icon → query; replies found under CRT | `chat-search` | R/D |

## I · Directory and membership

| ID | Item | Steps → expected | How checked | Build |
|---|---|---|---|---|
| I1 ★ | Browse and join | Compose → Browse Channels (team tabs, Archived switch) → unjoined channel → preview (purpose, recent messages) → Join Channel → chat | REST membership | R |
| I2 | Create | Compose → New Channel → name (URL follows) → Create → chat; server channel | REST | R |
| I3 | DM / GM | Compose → a person → DM; New Group Message → people → Create → GM (existing one reopens) | OCR | R |
| I4 | Channel settings | Profile → Edit → purpose → Save (server); Archive Channel → confirm (server `delete_at`); Leave → confirm (server 403) | REST | R |
| I5 | Members | Profile → Add Members → person → Add (1) → server members; member menu: promote/remove | REST | R |

## J · Rich content and links

| ID | Item | Steps → expected | How checked | Build |
|---|---|---|---|---|
| J1 | Link previews | ~3E Links: OpenGraph cards, permalink card | Screenshot | R |
| J2 | Markdown blocks | Headings, lists, tables, highlighted code (~4C Accessibility, ~3E Links) | Screenshot | R |
| J3 ★ | Permalinks and `relay://` | Tap `https://<server>/<team>/pl/<post>` → the chat at the post; `xcrun simctl openurl <udid> relay://<host>/<team>/pl/<post>` → "Open in Relay?" → Open → the post | OCR | R |
| J4 | Copy / Share Link | Message menu → Copy Link (post permalink); on a link → the link | `xcrun simctl pbpaste` | R |

## K · Status, profile, notification preferences

| ID | Item | Steps → expected | How checked | Build |
|---|---|---|---|---|
| K1 ★ | Status | Settings → status row → Online / Away / Do Not Disturb (30 min, 1 h, …) / Offline → server status, `dnd_end_time` | REST `/users/me/status` | R |
| K2 | Custom status | Custom Status → text + Clear After → Set → server `props.customStatus` with `expires_at`; Clear | REST | R |
| K3 | Profile | Settings → Edit → nickname/position → Done → server; Change Profile Photo | REST | R |
| K4 | Others' status | Bob's DM title "away"/"do not disturb until …", dots in rows | OCR | R |
| K5 | Notification prefs | Settings → Notifications and Sounds → Push Notifications and Mentions → push level → server `notify_props.push`; a chat's Notifications → Customize | REST | R |

## L · Share extension

| ID | Item | Steps → expected | How checked | Build |
|---|---|---|---|---|
| L1 ★ | Share | Any share sheet (e.g. Diagnostics → Export) → Relay → "Share to / Select chats" → a chat + comment → Send → post with the file and comment | REST | R |

## M · Push notifications (simulator)

| ID | Item | Steps → expected | How checked | Build |
|---|---|---|---|---|
| M1 ★ | Delivery | With the push proxy's real APNs key, Relay in the background, bob DMs alice → banner "bob / text" with bob's picture (communication notification; the notification service extension ran: proxy log "Acknowledged delivery receipt") | Screenshot; `docker logs relaypush-push-proxy-1` | R |
| M2 | Without a real key | `infra/push-proxy/sim-bridge.py --deliver app` or `simulate-push` (runs the extension's code in the app) | BUILD.md "Push notifications" | D |
| M3 ★ | Open on tap | Tap the banner → the chat (thread aware) | OCR | R |
| M4 | Reply / Mark as Read actions | `notification-reply`, `notification-read` | remote | D |
| M5 | Badge, clear | Read elsewhere → `clear` push removes the notification, badge updates | remote | D |

## N · Security and diagnostics

| ID | Item | Steps → expected | How checked | Build |
|---|---|---|---|---|
| N1 ★ | Passcode | Settings → Privacy and Security → Passcode Lock → Turn Passcode On → code twice → lock icon by "Chats" → tap → "Enter your Relay Passcode"; wrong code stays, right code unlocks; Turn Passcode Off (code, confirm) | AXe keypad taps | R |
| N2 | Managed configuration | `simctl spawn … defaults write org.relaychat.Relay com.apple.configuration.managed -dict …` + background/foreground: `inAppPinCode` → "Passcode Required — <vendor> requires a passcode"; `serverUrl`/`allowOtherServers=false` prefill and lock the address; `blurApplicationScreen`, `copyAndPasteProtection` (managed-configuration.md) | OCR | R |
| N3 | Certificate pinning | `relayCertificatePins` wrong pin for the host → "Connecting…", -1202 in the log; the leaf's pin → connected | OCR; log | R |
| N4 | Copy/paste protection | See BUILD.md "Phase 4G" | `pasteboard` | D |
| N5 | Diagnostics | Settings → About Relay → Diagnostics: Save Diagnostic Logs; Export Diagnostics → zip in the share sheet | OCR | R |
| N6 | Jailbreak | `RELAY_DEBUG_JAILBROKEN=1` → "Device Not Allowed" | | D |

## O · Settings, storage, hidden features

| ID | Item | Steps → expected | How checked | Build |
|---|---|---|---|---|
| O1 | Devices | Settings → Devices → this device + Mattermost sessions; Terminate (use dave) | OCR | R |
| O2 | Storage | Settings → Data and Storage → Storage Usage → per-chat sizes, Clear | OCR | R |
| O3 | Appearance | Themes, text size, chat background (local) | Screenshot | R |
| O4 ● | About | Version `0.1.0 (<build>)`, Source Code (GitHub), Open Source Licenses (Telegram-iOS GPL …) | AXe | R |
| O5 | No Telegram-only entry points | Tab bar Chats/Settings only; no stories, stickers, premium, calls, secret chats, phone/contacts; attach menu Gallery/File/Location/Audio/Contact; no voice-recording tip (fixed 4E); passcode texts without secret chats or wallets (fixed 4E) | Screenshots | R |

## P · Accessibility, appearance, languages

| ID | Item | Steps → expected | How checked | Build |
|---|---|---|---|---|
| P1 | VoiceOver labels | Login fields "Server address", rows "Bob Brennan, Away", thread rows, Settings rows, status dots | `relay-axe.py tree`; `ax-tree` (debug, sees more) | R/D |
| P2 ● | Largest text | `xcrun simctl ui <udid> content_size accessibility-extra-extra-extra-large` → relaunch → chat list, chat, threads, login grow and wrap | Screenshots | R |
| P3 | Dark mode | `xcrun simctl ui <udid> appearance dark` | Screenshots | R |
| P4 | Right-to-left | `simctl launch … -AppleLanguages "(ar)" -AppleLocale ar_SA` → Arabic/Hebrew posts align right, nothing overlaps | Screenshots | R |

## Q · Performance (plan 05 Phase 4 targets)

| ID | Item | Target / steps | How checked | Build |
|---|---|---|---|---|
| Q1 ★ | Cold start from cache | < 1 s to the chat list: terminate, launch, 7 runs, median of "after process start" | `[Relay] perf:` lines | R |
| Q2 | Chat list scroll | Smooth with the large-server data (`tools/mm-large-server.py join`): flings on release; `chatlist-scroll "folder=4B Large" seconds=8 speed=7000` for frame numbers | screenshots; remote | R/D |
| Q3 | First bootstrap | 500+ chats < 15 s on LTE: log out, log in, "bootstrap: done in" (Save Diagnostic Logs on) | log | R |
| Q4 | Launch catch-up | "catch-up since …: N channels … in <ms>" | log | R |
| Q5 | Memory, parked requests | `tools/relay-session.py <udid> --minutes 5`: 0 parked Telegram requests, memory flat | session file | D |

## R · Release hygiene

| ID | Item | Expected | How checked | Build |
|---|---|---|---|---|
| R1 | Release audit | 0 debug markers, no ATS exception for the app's own connections, privacy manifests present, 0 closed-source/analytics markers | `tools/relay-release-audit.sh` | R |
| R2 | Unit tests | MattermostKit, MattermostSyncCore, MattermostPush, MattermostShare pass | `swift test` (BUILD.md "Pure Swift packages") | — |

## S · Device matrix layout checks

| ID | Item | Expected | Build |
|---|---|---|---|
| S1 ● | Small phone (iPhone 17e) | Login, chat list, chat, thread, search, settings fit; nothing clipped | R |
| S2 ● | Large phone (iPhone 17 Pro Max), landscape | Chat and chat list usable in landscape | R |
| S3 ● | iPad (regular width) | Split view: chat list beside the chat; landscape and portrait | R |
| S4 ● | Largest text on each | As P2 | R |

## Results

### Run 1 · 2026-10-27 (Phase 4E)

**Builds** (all `release_sim_arm64`, `appstore-configuration.json`, `tools/relay-release-audit.sh` passed for each:
0 debug markers, no ATS exception for the app's own connections, privacy manifests present, 0 closed-source /
analytics markers):

| Build | Commit | What changed |
|---|---|---|
| RC1 `0.1.0 (31839)` | `efb8503e` | `main` + a cold-start timing line in every build |
| RC2 `0.1.0 (31842)` | `1046516e` | no voice-recording tip, wallet warning or secret-chat note; All Chats as a stored folder (did not show in release builds) |
| RC3 `0.1.0 (31843)` | `26aad49d` | All Chats tab added where the tab strip is built |
| **RC4 `0.1.0 (31844)`** | `0feeacc5` | push registration on Mattermost 12 (the candidate) |

Debug items ran on `debug_sim_arm64` of the same tree on "Relay iPhone 17 Pro" (iOS 26.5).

**Servers**: Mattermost **11.7.14** ESR (Team Edition, the dev server, through `https://localhost:8443`) and
**12.0.1** (Team Edition; the newest release: Docker Hub `latest` = `12.0` = `12.0.1`, digest `8ca1050c…`;
`12.1.0-rc2`/`release-12` is a release candidate), a throwaway compose project seeded with `infra/dev-server/seed.py`
unchanged, through `https://localhost:8444`, removed afterwards.

Result legend: **P** pass · **F** fail (fixed: see note) · **G** known gap · **—** not run on that build/server ·
**D** ran on the debug build.

| ID | 11.7 (release) | 12.0.1 (release) | Notes |
|---|---|---|---|
| A1 | P | P | footer "localhost:8443 · Mattermost 11.7.14" / "… 12.0.1" |
| A2 | P | — | `http://localhost:8065` → "Relay only connects to servers over HTTPS."; `foo bar` → not an address |
| A3 | P | P | alice; permission prompt after login (Allow), iOS "Save Password?" (Not Now) |
| A4 | P | — | "Can't Log In" with the server's text |
| A5 | P | P | carol: wrong code → "That code didn't work…"; current code → chat list |
| A6 | P | P | alice + carol / dave on 11.7, alice on both servers; **G**: the switcher and Settings list show the same name twice, no server |
| A7 | P | P | sessions 3 → 2 (11.7), 2 → 1 (12.0.1); also with the server gone (local data removed) |
| A8 | P | — | `revoke-sessions dave` → "Session Expired" title + alert → Log In Again (dave prefilled) → chat list |
| A9 | — | — | covered by MattermostKit tests (`ServerCompatibility`) |
| A10 | — | — | no SSO provider on the dev servers |
| B1 | F → P | P | RC1: no "All" tab (only team tabs; the unfiltered list had no tab to return to) → fixed in RC3. 12.0.1: Engineering 14 / Design 10 = REST (unread channels + DMs/GMs) |
| B2 | P | — | Pin/Unpin → `favorite_channel` preference |
| B3 | P | — | swipe: Mute/Delete/Archive; Mute → `mark_unread=mention`, Unmute → `all`; long-press: Mark as Read, Pin, Mute, Delete |
| B4 | P | P | "Connecting…" / "connecting…" while the server was stopped |
| B5 | P | — | rows move up on bob's posts |
| B6 | — | — | debug; verified in 4F, not re-run |
| C1 | P | P | Sandbox at the newest posts; 2D Library at the first unread (19 below) |
| C2 | P | — | Firehose: ~65 flings back to January, pages kept loading |
| C3 | P | — | |
| C5 | P | P | bob's post, edit ("edited"), 🎉, delete appear live |
| C6 | P | P | server stopped 20–25 s; back: queued post on the server 1.9 s (11.7) / 6.5 s (12.0.1) after `/ping` answered, bob's post live, title restored |
| C7 | P | — | 4C channel: table, attachment fields/footer, buttons, menu; service messages |
| D1 | P | P | `**bold** :smile:` on the server, bold + 😄 in the bubble |
| D2 | P | P | thread reply `root_id` (12.0.1: via the root's Reply, which opens the thread) |
| D3 | P | P | `edit_at` set, "edited" |
| D4 | P | P | "Delete for everyone" → 404 |
| D5 | P | P | 👍 on the server; a tap on the own reaction removes it |
| D6 | P | — | incoming "••• Bob" (WebSocket `user_typing` as bob); outgoing `typing` reached bob's socket |
| D7 | P | — | Gallery (photo permission) → 2 photos + caption → one post, 2 files |
| D8 | P | P | see C6 |
| D9 | — | — | debug; verified in 4F |
| D10 | G | — | Forward posts the text as the user's own post, no attribution (known since 2A) |
| D11 | G | G | `@channel` confirmation for large channels not implemented (plan 05 Phase 3 composer) |
| E1 | P | P | "13 Replies" / "55 Replies" → thread view |
| E2 | P | P | Threads: "ENGINEERING · 3 UNREAD · 2 MENTIONS" (11.7), "· 1 MENTION" (12.0.1); opening an unread thread clears it on the server |
| E3 | P | — | Unfollow / Follow Thread on the server |
| E4 | — | — | debug; verified in 4F |
| F1 | P | — | menu sheet (Staging/Production/Cancel); unreachable integration → "Action integration error." |
| F2 | — | — | needs an integration responder (3D-1); not re-run |
| F3 | P | P | `/away` → "You are now away (Only visible to you)", status away (manual) |
| F4 | P | P | `/aw` → "/away Set your status away" |
| G1 | P | P | `@bo` → Bob/Build Bot; `~relay-3e` → 3E Links/3E Public; `~back` → Backend; `:smi` → emoji strip |
| H1 | P | P | "deploy": results from all chats; a result opens the chat at the post |
| H2 | P | — | "Car" → Carol's DM and GMs |
| H3 | P | — | Recent Mentions list |
| H4 | P | — | Save Post → `flagged_post` (removed again) |
| H5 | P | — | Pin → "Pinned Message" bar, server `/pinned` (unpinned again) |
| H6 | P | — | profile → Files: names, sizes, dates |
| H7 | P | — | "UNREAD" in Sandbox: 1 of 35 = REST search |
| I1 | P | P | preview with purpose and recent posts → Join Channel → member |
| I2 | P | — | New Channel "4E RC Check" → created (then archived) |
| I3 | P | — | New Group Message carol + dave → the existing GM opens |
| I4 | P | — | purpose saved; Archive → `delete_at`; Leave → 403 for alice |
| I5 | P | — | Add Members → bob; member menu (promote/remove) not run |
| J1 | P | — | 3E Links cards (OpenGraph, text-only, permalink card) |
| J2 | P | — | table and heading in the 4C channel |
| J3 | P | P | tapped permalink → DM at the post; `relay://localhost:8443/…` / `…:8444/…` → "Open in Relay?" → the post on the right account |
| J4 | P | — | a link's Copy Link (the Mac's pasteboard changes too) |
| K1 | P | P | DND 30 min → `dnd_end_time` +30 min; Online |
| K2 | P | — | custom status text + 1 Hour → `expires_at` +1 h (cleared afterwards) |
| K3 | P | — | position edited (restored by REST) |
| K4 | P | — | DM title "away"/"online", row dots |
| K5 | P | — | push level All Activity → `push=all`, back to `mention` |
| L1 | P | P | Diagnostics export → share sheet → Relay → "Share to" → chat + comment → post with the file |
| M1 | P | F → partly fixed | 11.7: real APNs (push proxy with the APNs key): banner "bob / …" with bob's picture, proxy "Acknowledged delivery receipt". 12.0.1 refused Relay's device id (see "Differences") → fixed in RC4: registers `apple_rnbeta:…`; delivery needs the proxy re-rendered (`infra/push-proxy/up.sh`), not done |
| M2 | D: P | — | `simulate-push` captured DM → "bob → alice / Fixture: a direct message" |
| M3 | P | — | banner tap → the DM |
| M4, M5 | — | — | debug; verified in 3A/4G |
| N1 | P | — | 6-digit passcode, lock icon, wrong code refused, unlock, Turn Passcode Off |
| N2 | P | — | `inAppPinCode` + `vendor` → "Passcode Required — Example Corp requires…"; deleted → gone |
| N3 | P | — | wrong pin → "Connecting…", `-1202` in the log; leaf pin + wrong backup → connected |
| N4, N6 | — | — | debug; verified in 4G |
| N5 | P | — | Save Diagnostic Logs on; Export → zip in the share sheet |
| O1 | P | — | this device + Mattermost sessions |
| O2 | P | — | Storage Usage 1.7 MB by category |
| O3 | — | — | |
| O4 | P | — | 0.1.0 (31843/31844), Source Code, Open Source Licenses |
| O5 | F → P | — | RC1: "Hold to record audio. Tap to switch to video." tip on first chat open (recording is hidden); "All secret chats will be lost" in the passcode note; wallet warning on Turn Passcode Off → fixed in RC2. Attach menu: Gallery, File, Location, Audio, Contact |
| P1 | P | — | AXe found every control used here by its label (fields, buttons, rows, thread rows) |
| P2 | P | — | largest text: chat list, chat, threads (also on every matrix device) |
| P3 | P | — | dark: chat list, chat, threads |
| P4 | P | — | Arabic/Hebrew posts right-aligned, layout left-to-right, no overlap |
| Q1 | P | P | see Performance |
| Q2 | P | — | release: flings through ~500 rows of "4B Large"; debug `chatlist-scroll`: 961 frames, 0 dropped |
| Q3 | P | P | 602 chats: 3.08 s (11.7); 39 chats: 2.62 s (12.0.1) |
| Q4 | P | — | launch catch-up of 602 channels 47–59 ms |
| Q5 | D: P | — | `relay-session.py` 5 min on the final debug build: 0 parked requests (`final: []`), footprint 122 MB at the end |
| R1 | P | | each RC |
| R2 | P | | MattermostKit 212 (5 skipped), MattermostSyncCore 181, MattermostPush 42, MattermostShare 9 (1 skipped) |

**Totals** (91 items; S1–S4 are in the device matrix below): **11.7**: 78 pass (M2 and Q5 on the debug build; B1
and O5 after fixes made in this run), 2 known gaps (D10, D11), 11 not run (debug-only items verified in earlier
phases, A9, A10, O3). **12.0.1**: 29 items run (the ★ core except B5, C2, D7, M3 and N1, plus others), 28 pass, M1 failed and is fixed on the app
side, with delivery pending a proxy re-render.

#### Performance (release build, simulator "iPhone 17 Pro", iOS 26.5, server on the same Mac)

| Measure | Release (4E) | Debug (4B) | Target |
|---|---|---|---|
| Cold start → chat list ready, alice ~70 chats (7 runs) | median **786 ms** (785–803) after process start; 326 ms after `didFinishLaunching` | 1,140–2,000 ms; 489–691 ms | < 1 s |
| Same, alice 602 chats (`mm-large-server.py join`) | median **807 ms** (794–871); 346 ms | — | < 1 s |
| Same, two accounts (11.7 + 12.0.1), RC4 | median **803 ms** (790–817); 334 ms | — | < 1 s |
| First bootstrap, 602 chats (logout, login) | chat list 1.5 s after Log In, newest pages 602/602 in 2.89 s, **done in 3.08 s** | 5.7 s | < 15 s on LTE |
| Catch-up at launch, 602 channels | 47–59 ms (782 ms right after the join: 547 channels, 1,064 new posts) | 46–117 ms | — |
| Chat list scroll, 4B Large | flings render without blank rows (release); 0 dropped frames of 961 at 7,000 pt/s (debug) | 0 dropped | smooth |

The simulator draws on the Mac's GPU and the server is local: device numbers will differ (slower dyld, network).

#### Device matrix (RC3 `31843`, release; created, smoked and deleted one at a time)

| Device | iOS 26.5 | iOS 27.0 |
|---|---|---|
| iPhone 17e (small) | P: login, All tab, chat, send, thread, search, Settings/About, landscape chat and list (lldb rotation), largest text; also RC1 → RC2 → RC3 upgrade with the account kept | P (same set) |
| iPhone 17 Pro Max (large) | P (same set) | P (same set) |
| iPad Air 13-inch (M4) | P: split view (list + chat/thread/settings detail), send, thread, search, Settings, largest text. Touches didn't reach the app right after login until a relaunch (once; suspected iOS's Save Password sheet) | P (same set; taps worked right after login) |

iPad landscape not checked: `requestGeometryUpdate` doesn't rotate an iPad simulator's screen and nothing else here
can. Screenshots: `docs/research/phase4e-matrix-*.png`.

#### Differences between 11.7.14 and 12.0.1 found

- **Push device ids**: 12.0.1 accepts only the official apps' platforms in `PUT /users/sessions/device`
  (`model.IsValidDeviceId`: `apple_rn`, `apple_rnbeta`, `android_rn`, each with an optional `-v<N>`) and answers
  Relay's `relay_apple[_sandbox]:<token>` with 400 `api.context.invalid_body_param.app_error`, so a Relay account on
  12 had no push device and got no pushes. Fixed (`0feeacc5`): a refused registration is repeated as
  `apple_rn` / `apple_rnbeta` and kept per account; the push proxy template has entries for both with Relay's topic.
- Nothing else differed in the core set: login (`/system/ping`, client config, MFA), channels/teams/unread counts,
  posts/threads/CRT, search, reactions, preferences, status, files, WebSocket events, `/away`, autocomplete,
  permalinks and the share extension behaved the same. 12.0.1 took longer to be ready after a restart (posts went out
  6.5 s after `/ping` answered, 1.9 s on 11.7).

#### Open gaps (steps to reproduce)

1. **Pushes on Mattermost 12 need the proxy's new entries**: run `infra/push-proxy/up.sh` (re-renders the config with
   `apple_rn`/`apple_rnbeta`), then on a 12 server: Relay in the background, a DM from another user → banner. Until
   then the proxy logs "No push target for platform apple_rnbeta".
2. **Same name on two servers**: log in as alice on two servers → the Settings tab's long-press menu and the Settings
   account list show "Alice Anderson" twice with nothing telling the servers apart (plan 05: "the switcher shows the
   server name and icon").
3. **`@channel` confirmation** (plan 05 Phase 3): `@channel` in a channel with many members is sent without asking.
4. **Forward** posts without attribution (2A gap).
5. **Reply count after another client deletes a reply**: the debug account on "Relay iPhone 17 Pro" kept "14 Replies"
   after the release build deleted one of the 14 (server 13) until it relaunched; seen once, not reproduced on purpose.
6. **iPad**: right after logging in on iPad Air 13 (iOS 26.5) touches didn't reach the app until it was relaunched;
   not on iOS 27.0. Not investigated. iPad landscape unchecked (no rotation driver).
7. The "All Chats" tab written as a stored folder (`311b59b3`) showed in debug builds and not in release builds; not
   root-caused, replaced by the UI-side tab (`26aad49d`).
8. Bob's DM row avatar blank after opening the DM (4G gap, still there).
