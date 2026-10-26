# 6 · Feature scope

Legend: **Keep** = reuse Telegram's feature, adapted to Mattermost data · **Hide** = flag off in v1 · **Build** = new work · **Later** = after v1.

## Keep (Telegram features we reuse)

| Feature | Adaptation |
|---|---|
| Chat list with folders, pinning, swipe actions | Folders generated per team; pins = Favorites |
| Chat screen: bubbles, input panel, attach menu, reply, edit, context menu | Mattermost actions behind the same UI |
| Forward | Maps to Mattermost's forward‑post feature (server version permitting); otherwise hide |
| Media viewer and gallery | Mattermost file resources |
| Search UI | Mattermost post search |
| Profile and channel info screens | Mattermost users and channels |
| Shared media tab | Channel files |
| Multi‑account switcher | Multiple servers |
| Themes, appearance, chat backgrounds (local) | Local only |
| Passcode lock | As is |
| Storage usage and cache management | As is |
| Active sessions screen | Mattermost sessions API |
| Notification settings screens | Mattermost notify props |
| Share extension | Rewritten backend |
| Notification service extension | Rewritten ([4 · Push](04-push-notifications.md)) |
| Scheduled messages UI | **Later**: maps to Mattermost scheduled posts on newer servers |
| Drafts | Local in v1; **Later**: server‑synced drafts |

## Hide (Telegram‑only, no Mattermost equivalent)

| Feature | Notes |
|---|---|
| Secret chats | |
| Stories | |
| Sticker and GIF stores, sticker packs | GIF search could come back later as GIPHY |
| Premium, Stars, boosts, giveaways, gifts | |
| Payments, bot payments | |
| Ads, sponsored messages | |
| Phone‑number login, contact sync, QR login | Replaced by the Mattermost login |
| Voice and video calls, group calls | **Later**: Mattermost Calls plugin is a separate project |
| Broadcast channels (Telegram "channels") | All Mattermost channels map to supergroups |
| Bot inline mode, mini apps, web apps | |
| Telegram Passport | |
| Business features, nearby people | |
| MTProto proxy settings | Replace with optional HTTP proxy only if needed |
| Telegram privacy settings | Mostly server‑side Telegram concepts |
| Message translation | Telegram‑server feature |
| Voice‑to‑text | Telegram‑server feature |

## Build (new for Mattermost)

| Feature | Phase |
|---|---|
| Server selection, login, MFA, SSO | 2 |
| Team folders generation | 2 |
| Markdown → entities parser | 2 |
| System messages (join, leave, header change, …) | 2 |
| Message attachments bubble (read‑only) | 2 |
| Collapsed reply threads, Threads list | 3 |
| Markdown block bubble (headings, lists, tables) | 3 |
| Interactive attachments (buttons, menus), interactive dialogs | 3 |
| Slash commands with autocomplete | 3 |
| `@`, `~`, `:` autocomplete | 3 |
| Channel browser, create channel, start DM or GM | 3 |
| Channel header and purpose display | 3 |
| Custom emoji (picker, reactions, inline) | 3 |
| Custom status, DND with expiry | 3 |
| Saved posts, recent mentions screens | 3 |
| Permalinks and deep links | 3 |
| Managed app configuration (AppConfig/MDM) | 4 |
| Voice messages: record, send as an audio attachment, voice bubble with waveform ([5A](05-phases.md#5a--voice-messages-12-weeks)) | 5 |

## Later (after v1)

- Calls (Mattermost Calls plugin)
- Playbooks, Boards, AI and other plugin UIs
- Message priority and acknowledgements
- Custom sidebar categories
- Server‑synced drafts, scheduled posts
- iPad layout polish (Telegram supports iPad; verify it still works, then improve)
- Widgets, Apple Watch, Siri / App Intents
