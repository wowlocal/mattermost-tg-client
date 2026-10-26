# Seed data

`./seed.py` creates the data below. It is idempotent: objects are found by
natural keys (usernames, team, channel and emoji names), and each seeded
post, reaction set and one-off action is recorded as a preference of
`sysadmin` (category `mmdev_seed`). Re-running creates nothing new, and
`./reset.sh` wipes the records with the rest of the data.

Two kinds of data:

- **Backdated history** goes through the server's bulk import
  (`mmctl import process --local`, file `.state/import/mmdev-seed-import.zip`),
  because REST ignores `create_at` for normal users. It covers the
  firehose, a few weeks of history in most channels, DM/GM history and the
  2019 history of the archived channel. All of it is deterministic (fixed RNG
  seeds and dates), so a re-import would de-duplicate.
- **"Now" data** is created through REST v4 as the real users, so you get
  natural system messages, unread counts, mentions and thread memberships.

Passwords: see `.env` (`SEED_ADMIN_PASSWORD`, `SEED_USER_PASSWORD`). The bot
token and webhook URL are in `.state/credentials.json`.

## Users

| Username | Name | Nickname | Position | Roles | Avatar | Status |
|---|---|---|---|---|---|---|
| `sysadmin` | System Admin | | | **system_admin**; member of both teams | default | |
| `alice` | Alice Anderson | Al | iOS Engineer | system_user; **the main test account** | generated identicon | online |
| `bob` | Bob Brennan | | Backend Lead | **team admin of Engineering**; not in Design | generated identicon | away (manual) |
| `carol` | Carol Núñez | CJ | Product Designer | **team admin of Design** | generated identicon | dnd + custom status 🎨 "In design review" |
| `dave` | Dave Okafor-Lindqvist | | Site Reliability Engineer | system_user | **none** (default avatar) | offline (manual) + custom status 🌴 "OOO until Monday" |
| `buildbot` | Build Bot | | | bot account, owned by sysadmin, with a personal access token | generated | |

Emails are `<username>@example.com`. The server also has its own bots
(`calls` from the prepackaged Calls plugin, and `system-bot`).

## Teams

| Team | Type | Members |
|---|---|---|
| `engineering` "Engineering" | open | sysadmin, alice, bob (admin), carol, dave, buildbot |
| `design` "Design" | invite only | sysadmin, alice, carol (admin), dave, buildbot |

## Custom emoji

`:shipit:`, `:lgtm:` and `:partyblob:` are 128×128 PNGs created by sysadmin.
They are used in reactions, in the import and in message text.

## Channels: Engineering (18, one archived)

"Hist." is the number of backdated posts imported over the last ~60 days.
The read state is alice's after seeding (see [Alice's unread state](#alices-unread-state)).

| Channel | Type | Creator → members | Hist. | Test cases |
|---|---|---|---|---|
| `town-square` | O | everyone (default) | 30 | **`@channel` mention** by bob with priority `important`; `white_check_mark` reactions; `system_join_team` messages |
| `off-topic` | O | everyone (default) | 25 | **jumbo emoji** (`:coffee:` ×3, a lone 🎉), a ZWJ emoji 🐈‍⬛, custom emoji reaction `:partyblob:`; **muted for alice** (`mark_unread: mention`) |
| `firehose` | O | bob → alice, carol (joined), dave (added) | – | **11,726 posts back to 2013**, see [Firehose](#firehose) |
| `backend` | O | bob → alice (joined), carol, dave | 25 | header **changed** by bob (`system_header_change`); **@alice mention**; Go code block; thread **T2** (alice **unfollowed**); alice has a **server-side draft** here |
| `ios` | O | alice → bob, carol, dave | 30 | **edited post** (alice: "Xcode 26" → "Xcode 26.1"); **deleted post** (bob); **pinned** post; purpose **changed** (`system_purpose_change`); bot post with attachment fields; **@alice mention**; thread **T4** with an @alice mention in a reply |
| `android` | O | bob → alice, dave (both joined) | 8 | carol **joined and left** (`system_join_channel`, `system_leave_channel`) |
| `releases` | O | bob → alice, carol, dave, buildbot | 15 | **pinned** release notes (headings, lists, table, emoji) and checklist; many reactions incl. custom `:lgtm:`; thread **T3** (alice **follows explicitly** without having replied); bot post |
| `code-review` | O | carol → alice, bob, dave | 12 | **markdown-heavy post**: H1–H3, ordered/nested/task lists, aligned table, Swift code block, nested block quote, links, `~channel` and `@user` mentions, inline code, bold/italic, strikethrough, emoji shortcodes, hashtag, horizontal rule. Also a **~6,000-character post** ("Show more"), code blocks in json/bash/diff/go/none, LaTeX, and thread **T6** (fully read) |
| `architecture` | O | bob → alice, carol, dave | 10 | thread **T1**: pinned RFC root with **119 visible replies** (120 created, #51 deleted), an image in reply #65, reactions `+1`, custom `:shipit:` and `eyes`; an image post |
| `incidents` | **P** | dave → alice, bob | 10 | **@alice mention** in a private channel; header with emoji, URL and markdown link |
| `leads` | **P** | bob → alice | 8 | dave **added then removed** by sysadmin (`system_add_to_channel`, `system_remove_from_channel`) |
| `security` | **P** | bob → dave | 6 | **alice is not a member**: must not show up for her |
| `integrations` | O | bob → alice, carol, dave, buildbot | – | **bot posts** with Slack-style attachments: **buttons** (good/danger), a **static select menu**, **users** and **channels** dynamic menus, fields, pretext, title links, footer icon, `image_url`; **webhook posts** (type `slack_attachment`) with username override, color bars, `thumb_url`, a button, `icon_emoji`. Action URLs point at `http://localhost:9/...` (nothing) |
| `media` | O | carol → alice, bob, dave | 5 | **file attachments**: 1600×1000 PNG, 600×900 JPEG (portrait), **a post with 5 images** (PNG and JPEG; square, phone screenshot, 3:1 panorama, small), PDF, `.txt` + `.log`, WAV, SVG, a ~6 MB ZIP (download progress), Swift + JSON files, an image and a PDF in one post |
| `random-links` "Random Links" | O | dave → alice, bob, carol (joined) | 5 | **OpenGraph previews** (GitHub, YouTube, crdt.tech), markdown link, inline markdown image from the server, **permalink preview** of the release notes; display name changed from "Links" (`system_displayname_change`) |
| `on-call` "On-call 📟" | O | dave → alice, bob | 12 | emoji in the display name |
| `sandbox` | O | alice → bob | – | **scratch channel for `capture-fixtures.py`**: its posts appear and get deleted |
| `legacy-2019` | O, **archived** | bob → alice, dave | 40 (2019) | **archived channel** with 2019 history (`system_channel_deleted`); `ExperimentalViewArchivedChannels` is on |

## Channels: Design (16)

| Channel | Type | Creator → members | Hist. | Test cases |
|---|---|---|---|---|
| `town-square`, `off-topic` | O | default | 15, 10 | |
| `ui-kit` | O | carol → alice, dave | 12 | **@alice mention**; screenshot image |
| `critiques` "Critiques ✏️" | O | carol → alice, dave | 8 | thread **T5** with 3 images in the root, alice participated, **read** |
| `research` "User Research" | O | carol → alice | 8 | PDF |
| `design-systems` | O | carol → alice, dave | 6 | table |
| `brand` | **P** | carol → dave | 5 | **alice is not a member** |
| `icons` | O | dave → alice, carol | 5 | image |
| `motion`, `accessibility`, `copywriting` | O | | 4–6 | plain chatter |
| `moodboard` | O | carol → alice, dave | 4 | 2 images |
| `design-ops` | **P** | carol → alice | 4 | |
| `handoff` "Handoff to Engineering" | O | alice → carol | 4 | text file |
| `really-long-channel-name-for-truncation-tests` | O | carol → alice | 3 | **62-char display name** (the limit is 64) |
| `intl` "Международный · 国際 · دولي 🌍" | O | carol → alice, dave | 4 | **Cyrillic, Japanese, Arabic (RTL), Hebrew, Chinese**, ZWJ emoji/flags, combining marks, zalgo text |

## Direct and group messages

| Channel | History | "Now" posts |
|---|---|---|
| alice ↔ bob | 60 | small talk, a reaction, **an image**; **2 unread** for alice; in alice's Favorites |
| alice ↔ carol | 20 | read |
| alice ↔ dave | 10 | read; one post **saved** by alice |
| bob ↔ carol | 15 | (alice not a member) |
| carol ↔ dave | 8 | (alice not a member) |
| **alice ↔ alice (self-DM)** | – | notes, a link and a text file ("Saved Messages") |
| **GM alice, bob, carol** | 20 | **@alice mention**, unread |
| **GM alice, bob, carol, dave** | 12 | an image, read |
| **buildbot → alice** (bot DM) | – | attachment with a button; unread |

## Firehose

`engineering/firehose`: **11,726 user posts** (plus 4 join messages).

- **240 posts from 2013-03-04 to 2013-06-28**, presented as a HipChat import.
  Timestamps have second precision, and **37 groups of posts share the exact
  same `create_at` (to the millisecond)**. The first post is **pinned** and
  **saved by alice**.
- Then **nothing until 2024-11-01**: an 11-year gap for hole-filling and
  jump-to-date logic.
- **11,486 posts from 2024-11-01 to 2026-10-23**: weekday-heavy conversations
  between alice, bob, carol and dave. About **390 seconds contain 3 or more
  posts** (bursts like "wait / no / it's the CDN / not redis", spread across
  distinct milliseconds within one second). There are markdown, code
  snippets, mentions (imported, so they create no badges) and occasional
  reactions, including custom emoji.
- **122 imported threads (628 replies)**. The largest, dated 2025-06-12, is the
  root "Postmortem thread for the June firehose outage" with 60 replies.
  Another post from 2025-02-03 is **pinned**.
- alice's last-viewed point is **25 root posts from the end**, so "jump to
  first unread" lands near the bottom.

## Threads (collapsed reply threads)

| | Where | State for alice |
|---|---|---|
| T1 | `architecture`, RFC root by bob, 119 visible replies | followed (participated), **unread from reply #101** (20 unread) |
| T2 | `backend`, carol's proposal | alice replied, then **unfollowed** (absent from her threads list) |
| T3 | `releases`, dave's retro | **explicitly followed** without replying; 2 unread follow-ups |
| T4 | `ios`, bob's metadata question | auto-followed through an **@alice mention in a reply**; **unread mention** |
| T5 | `design/critiques` | participated, **read** |
| T6 | `code-review`, alice's SwiftLint question | participated, **read** |

Engineering totals: 4 followed threads, 3 unread, 1 with an unread mention.

## Reactions, pins, saved posts

- Reactions with unicode emoji (`+1`, `white_check_mark`, `tada`, `rocket`,
  `heart`, `heart_eyes`, `fire`, `eyes`, `joy`, `laughing`) and custom emoji
  (`shipit`, `lgtm`, `partyblob`), several with multiple users. There are also
  about 1,200 imported reactions in the firehose.
- **Pinned**: release notes and checklist (`releases`), min-iOS post (`ios`),
  T1 root (`architecture`), and two firehose posts (2013 and 2025).
- **Saved by alice** (`flagged_post` preferences): release notes, T1 root,
  the 5-image post, the markdown post, dave's DM and the 2013 firehose welcome post.

## Alice's unread state

Produced by `set_unread` / `view` calls at the end of the seed, so it is the
same after every run unless someone logs in as alice and reads things.

| Channel | Unread (root posts) | Mentions |
|---|---|---|
| engineering/town-square | 3 | **1** (`@channel`) |
| engineering/backend | 2 | **1** |
| engineering/ios | 2 | **1** |
| engineering/incidents (private) | 3 | **1** |
| design/ui-kit | 2 | **1** |
| DM bob | 2 | **2** (DMs count as mentions) |
| DM buildbot | 1 | **1** |
| GM alice, bob, carol | 1 | **1** |
| engineering/firehose | 25 | 0 |
| engineering/code-review, integrations | 4, 4 | 0 |
| engineering/media, on-call | 3, 3 | 0 |
| engineering/android | 2 | 0 |
| engineering/off-topic (muted) | 1 | 0 |
| design/intl | 3 | 0 |
| design/design-systems, icons, copywriting, moodboard, long-name channel | 1 each | 0 |
| everything else | read | |

Sidebar (Engineering): a custom category **"Spike D"** (ios, architecture,
backend), and **Favorites** holding `releases` and the DM with bob.

## System messages you will find

`system_join_team`, `system_join_channel`, `system_add_to_channel`,
`system_leave_channel`, `system_remove_from_channel`,
`system_header_change`, `system_purpose_change`,
`system_displayname_change` and `system_channel_deleted`. They come from
the real actions above, not from fake posts.

## Edge cases at a glance

- Posts with identical `create_at` (2013) and bursts within one second (2024–2026)
- An 11-year gap in the firehose; history starting in 2013
- Edited post (`edit_at` set), deleted post, deleted thread reply
- A ~6,000-character post; a 62-character channel display name; unicode, RTL, ZWJ and zalgo text
- An archived channel; private channels alice can't see; a muted channel
- Posts with 5 attachments; non-image files (PDF, WAV, ZIP, SVG, code); a 6 MB download
- Interactive attachments whose action URLs are unreachable
- A bot DM and bot posts, webhook posts with overrides
- A server-side draft, custom statuses, manual away/dnd/offline statuses
