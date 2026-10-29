# Building

Working commands for this fork. Upstream's notes live in the root `CLAUDE.md` (written for Telegram's own signing setup; the commands below replace its build command for us).

## Requirements

- Xcode **27.0** (the fork is pinned to upstream `5c20d095d1ab`, see [PROGRESS.md](PROGRESS.md)).
- Metal toolchain: `xcodebuild -downloadComponent MetalToolchain` (Xcode 27 ships without it; the build fails in `MetalCompile` otherwise).
- An iOS simulator runtime. The app's minimum iOS is 15.0, so the installed iOS 26.5 runtime works.
- Bazel is downloaded by `Make.py` into `build-input/` (version pinned in `versions.json`).
- Disk cache on `/Volumes/X5/relay-bazel-cache` (any APFS volume works; not ExFAT, Bazel needs symlinks). The Bazel output base stays in `~/Library/Caches/bazel`.

## Simulator build

```sh
python3 build-system/Make/Make.py --cacheDir /Volumes/X5/relay-bazel-cache build \
  --configurationPath build-config/development-configuration.json \
  --xcodeManagedCodesigning --disableProvisioningProfiles \
  --buildNumber=1 --configuration=debug_sim_arm64
```

- `--disableProvisioningProfiles` is our addition to `Make.py build` (simulator only). The upstream fake profiles only match Telegram's own bundle ID.
- Add `--continueOnError` after `build` to collect all compile errors in one pass.
- First build: ~9 minutes on this machine (3,869 actions). Incremental builds are much faster.
- Output: `bazel-bin/Telegram/Telegram.ipa`. Always install from the `.ipa`, never from `Telegram_archive-root/`, which goes stale on incremental builds (see root `CLAUDE.md`).

## Release builds (Phase 4A)

```sh
python3 build-system/Make/Make.py --cacheDir /Volumes/X5/relay-bazel-cache build \
  --configurationPath build-config/appstore-configuration.json \
  --xcodeManagedCodesigning --disableProvisioningProfiles \
  --buildNumber=1 --configuration=release_sim_arm64
tools/relay-release-audit.sh bazel-bin/Telegram/Telegram.ipa
```

- `release_sim_arm64` / `release_arm64` build with `-c opt` (whole-module optimisation, `-Osize`): `DEBUG` is not defined, so the debug login, every `RELAY_DEBUG_*` hook, the debug remote and the debug screens below are **not compiled** (`#if DEBUG` around whole files and call sites). Release builds can't be driven by `tools/relay-remote.py`; use AXe or real taps.
- A full release build takes ~25 minutes here (TelegramCore and TelegramUI compile as whole modules); incremental release builds are much slower than debug ones.
- `build-config/appstore-configuration.json` is the distribution configuration (`is_internal_build` false, `is_appstore_build` true, team id to fill in). `development-configuration.json` also builds `release_sim_arm64`, but has Telegram's internal-build flags (file logging; 10 taps on Chats would crash were it not for Relay's gate in `TelegramRootController`).
- `tools/relay-release-audit.sh` fails on debug markers in any binary, ATS exceptions for the app's own connections, missing privacy manifests and closed-source/analytics SDK symbols.
- Device builds, signing and TestFlight: [release/RELEASE.md](release/RELEASE.md).
- **App Transport Security**: release builds allow no plain HTTP for the app's own connections (the login refuses `http://` servers: "Relay only connects to servers over HTTPS."); only web content in the in-app browser may be `http://`. Debug builds add `NSAllowsLocalNetworking` (`http://localhost:8065`, LAN). ATS's defaults don't block `localhost`, so an account a debug build created on `http://localhost:8065` keeps working if a release build is installed over it. To try a release build against the dev server, put a TLS proxy in front of it and trust its CA on the simulator (`xcrun simctl keychain <udid> add-root-cert ca.pem`), then log in to `https://localhost:<port>`.
- **Version**: `versions.json` `"app"` (`0.1.0`) is `CFBundleShortVersionString`; `--buildNumber` is `CFBundleVersion` (release builds: `git rev-list --count HEAD` on main).

## Device builds (your own team)

```sh
RELAY_TEAM_ID=<team id> tools/relay-device-build.sh build            # debug_arm64; or: build release_arm64
tools/relay-device-build.sh install <udid or name>                   # xcrun devicectl list devices
RELAY_TEAM_ID=<team id> tools/relay-device-build.sh appstore         # release_arm64 for TestFlight (RELEASE.md §4–5)
```

- **Once, in the Apple Developer portal** (Certificates, Identifiers & Profiles): the App Group `group.org.relaychat.Relay`; explicit App IDs `org.relaychat.Relay` (Push Notifications, App Groups, Communication Notifications), `.NotificationService` (App Groups, Communication Notifications), `.NotificationContent` and `.Share` (App Groups), each with the group assigned (App Groups → Configure); one **iOS App Development** profile per App ID with your Apple Development certificate and your devices. Put the four `.mobileprovision` files in `~/.relay-secrets/profiles/` (or `RELAY_PROFILES_DIR`). Xcode's automatic signing can't make these here: `Make.py` signs with explicit profiles (`--codesigningInformationPath`).
- The script writes the team id only into git-ignored `build-input/` (`relay-device-configuration.json`, `relay-device-team-id`); the committed configurations keep the placeholder. Device extensions take their entitlements from their profiles, the app from `TelegramEntitlements` (checked against its profile), so a missing capability fails the build rather than the app at run time.
- **Run the device build in its own checkout** (e.g. `git worktree add --detach .claude/worktrees/device main`, then the submodules from the main checkout: `git config submodule.<name>.url <main checkout>/<path>` and `git -c protocol.file.allow=always submodule update`, plus `build-input/bazel-*` copied over) when simulator work is going on: a device build repoints `bazel-bin` and rewrites `build-input/configuration-repository`.
- **Signing needs the GUI login session.** `codesign` (run by Bazel's sign actions) uses the developer key in the login keychain, which a background session cannot unlock or ask about: there the build compiles everything and then fails every sign action with `errSecInternalComponent` (`launchctl managername` prints `Background`; `security show-keychain-info` says "User interaction is not allowed"). Run the build from a terminal in the logged-in desktop session, and shut down that checkout's Bazel server first so it restarts there (`build-input/bazel-* shutdown`): the sign actions run inside the server's session. A re-run after such a failure only re-signs (~30 s).
- `debug_arm64` keeps `NSAllowsLocalNetworking`, so it can log in to a dev server on the LAN over `http://`; `release_arm64` only accepts HTTPS servers. The dev server listens on `127.0.0.1` only, so a device needs it exposed (for example on a Tailscale or LAN address) before it can log in there.
- Real pushes need the APNs key in the push proxy ([infra/push-proxy](../infra/push-proxy/README.md) "Production / a real APNs key"); a development build registers as `relay_apple_sandbox`.

## Run on the simulator

A dedicated simulator, "Relay iPhone 17 Pro" (iOS 26.5), is used so other projects' simulators aren't touched. Its UDID is in `build-input/relay-sim-udid`.

```sh
UDID=$(cat build-input/relay-sim-udid)
STAGE=$(mktemp -d)
unzip -q -o bazel-bin/Telegram/Telegram.ipa -d "$STAGE"
xcrun simctl boot "$UDID" 2>/dev/null
xcrun simctl terminate "$UDID" org.relaychat.Relay 2>/dev/null
xcrun simctl install "$UDID" "$STAGE/Payload/Telegram.app"
xcrun simctl launch "$UDID" org.relaychat.Relay
xcrun simctl io "$UDID" screenshot /tmp/relay.png
```

### Login

A fresh install opens the login (MattermostUI): server address → credentials or SSO → MFA code. Debug builds accept `http://` for local servers (`http://localhost:8065`); release builds only HTTPS. Log out in Settings → Log Out (or the account's context menu), add accounts in Settings → Add Account (with one account: Log Out → Add Another Account, or long-press the Settings tab).

### Debug login and debug hooks (debug builds only)

To skip the login screens, launch with credentials in the environment (`SIMCTL_CHILD_` prefix for `simctl launch`; optional `RELAY_DEBUG_MM_MFA=<code>`):

```sh
PW=$(grep '^SEED_USER_PASSWORD=' infra/dev-server/.env | cut -d= -f2-)
SIMCTL_CHILD_RELAY_DEBUG_MM_URL=http://localhost:8065 SIMCTL_CHILD_RELAY_DEBUG_MM_LOGIN=alice \
SIMCTL_CHILD_RELAY_DEBUG_MM_PASSWORD="$PW" xcrun simctl launch "$UDID" org.relaychat.Relay
```

The credentials are only used when no account exists yet (they go through the same `MattermostAccountSetup` as the login screens; on failure the login screens appear). Later launches reuse the account (token in the Keychain, sync state in `<account>/mattermost/sync.sqlite`). Log out or uninstall the app to log in again. More hooks (see `submodules/MattermostSync/Sources/Debug/MattermostDebug.swift`): `RELAY_DEBUG_OPEN_CHAT=firehose|engineering/town-square|dm:bob|saved`, `RELAY_DEBUG_OPEN_POST=<post id>` (permalink), `RELAY_DEBUG_PAGE=<channel>` (pages through the whole history and writes `Documents/relay-debug/<channel id>.json`), `RELAY_DEBUG_DUMP_CHATLIST=1` (`Documents/relay-debug/chatlist.json`), `RELAY_DEBUG_ID_SPACE=300000` (small message id space to force renumbering). MattermostSync logs with a `[Relay]` prefix: `xcrun simctl spawn "$UDID" log stream --style compact --predicate 'eventMessage CONTAINS "[Relay]"'`.

### Debug remote (debug builds only)

There is no UI automation, so MattermostUI listens for commands that drive the login screens and the account lifecycle through the same code paths as taps (`submodules/MattermostUI/Sources/MattermostDebugRemote.swift`). `tools/relay-remote.py` writes the command into the app's `Documents/relay-debug/command.json`, posts the Darwin notification `org.relaychat.Relay.debug` and prints the app's answer (with the visible login screen, accounts, Keychain tokens and account directories):

```sh
tools/relay-remote.py "$UDID" state
tools/relay-remote.py "$UDID" fill field=url text=http://localhost:8065   # server screen
tools/relay-remote.py "$UDID" press button=primary                         # Connect / Log In
tools/relay-remote.py "$UDID" fill field=login text=alice                  # credentials screen
tools/relay-remote.py "$UDID" fill field=password text="$PW"
tools/relay-remote.py "$UDID" fill field=code text=$(tools/mm-dev-auth.py code carol)   # MFA screen
tools/relay-remote.py "$UDID" add-account                                  # Settings → Add Account
tools/relay-remote.py "$UDID" switch username=bob                          # account switcher
tools/relay-remote.py "$UDID" logout username=alice                        # Settings → Log Out → OK
tools/relay-remote.py "$UDID" relogin                                      # "Log In" on "Session Expired"
tools/relay-remote.py "$UDID" press button=confirm                         # "Continue" on "Log In as …?"
tools/relay-remote.py "$UDID" dismiss-alerts                               # "OK" on a login error alert
tools/relay-remote.py "$UDID" not-now                                      # "Not Now" on "Session Expired"
tools/relay-remote.py "$UDID" title-relogin                                # tap on the chat list title "Session Expired"
tools/relay-remote.py "$UDID" open-saved                                   # the current account's Saved Messages
tools/relay-remote.py "$UDID" send-saved text="hello"                      # send to Saved Messages (also while expired)
```

Launch with `SIMCTL_CHILD_RELAY_DEBUG_NO_PERMISSION_PROMPTS=1` from the first launch on: an unanswered notifications prompt is SpringBoard's and survives app restarts and reinstalls until the simulator reboots. Passwords filled by the remote are cleared once they are submitted, so iOS doesn't cover the screen with "Save Password?".

Chat-screen commands (Phase 3B, collapsed reply threads; TelegramUI `RelayDebugThreads.swift`, output in the result's `extra`), each through the code path of the tap it stands for:

```sh
tools/relay-remote.py "$UDID" chat query=architecture             # open a chat (as RELAY_DEBUG_OPEN_CHAT names it)
tools/relay-remote.py "$UDID" visible                             # visible messages: post ids, thread ids, root tags, replies buttons
tools/relay-remote.py "$UDID" replies index=0                     # the newest visible "N replies" button (or post=<root id>)
tools/relay-remote.py "$UDID" scroll to=top                       # scroll the visible chat (top/bottom)
tools/relay-remote.py "$UDID" post post=<post id>                 # permalink: a reply opens its thread at it (CRT on)
tools/relay-remote.py "$UDID" follow                              # Follow / Unfollow Thread in the visible thread
tools/relay-remote.py "$UDID" menu post=<post id>                 # the message's context menu
tools/relay-remote.py "$UDID" threads                             # the threads screen of a team, pushed (team=<id>)
tools/relay-remote.py "$UDID" threads-list                        # what the threads screen lists (team=<id>)
tools/relay-remote.py "$UDID" threads-row index=0                 # open a row of the threads screen
tools/relay-remote.py "$UDID" check-thread post=<root id>         # load a thread and compare it with the server's
tools/relay-remote.py "$UDID" dump-chatlist                       # Documents/relay-debug/chatlist.json now
tools/relay-remote.py "$UDID" back                                # pop the top screen
```

### Login and account lifecycle checks

`tools/mm-dev-auth.py` (standard library only; reads `infra/dev-server/.env`, keeps TOTP secrets in `build-input/dev-mfa-secrets.json`):

- MFA: `enable-server-mfa` (sysadmin, once), `enable-mfa carol`, `code carol` (current 6-digit code), `disable-mfa carol`.
- Session expiry: `revoke-sessions dave` (sysadmin) ends all of dave's sessions; the app shows "Session Expired" at its next request (a 401), a WebSocket reconnect, or when it becomes active (send it to the background and back: `xcrun simctl launch "$UDID" com.apple.Preferences`, then launch Relay again). Logging in again as the same user keeps the local data; as another user, the old account's data is deleted and a new account is created.

Use users nobody else is using for these (carol for MFA, dave for revocation): other agents and scripts log in as alice and bob.

#### Write-path hook (Phase 2A, debug builds only)

`RELAY_DEBUG_WRITE='<action>;<action>;…'` runs actions after the bootstrap, through the same engine calls the composer, context menus and chat list use (never MattermostKit directly). Fields are separated by `|`; `<chat>` is as for `RELAY_DEBUG_OPEN_CHAT`; `<msg>` is `last`, `mine`, `other` or a post id. Combine with `RELAY_DEBUG_OPEN_CHAT` to watch it happen. Every action logs `debug-write: … → result` to the `[Relay]` stream.

| Action | Engine call |
|---|---|
| `send\|<chat>\|<text>` (`**b**`, `_i_`, `` `c` `` become composer entities) | `enqueueMessages` |
| `reply\|<chat>\|<msg>\|<text>` | `enqueueMessages` with a reply subject |
| `senduser\|<username>\|<text>` (a new chat; creates the DM channel) | `enqueueMessages` to the user's peer |
| `image\|<chat>\|<caption>` / `file\|<chat>\|<name>\|<content>` | `enqueueMessages` with local media, as the media picker |
| `react\|<chat>\|<msg>\|<emoji>` / `unreact\|…` | `updateMessageReactionsInteractively` |
| `edit\|<chat>\|<msg>\|<text>` | `account.pendingUpdateMessageManager.add` |
| `delete\|<chat>\|<msg>` | `deleteMessagesInteractively(.forEveryone)` |
| `resend\|<chat>` | `resendMessages` on the chat's failed messages |
| `typing\|<chat>[\|<msg in thread>]` | `account.updateLocalInputActivity(.typingText)` |
| `mute\|<chat>`, `unmute\|<chat>` | `engine.peers.updatePeerMuteSetting` |
| `pin\|<chat>`, `unpin\|<chat>` | `engine.peers.toggleItemPinned(.group(.root))` (all chats) |
| `folderpin\|<chat>\|<team>`, `folderunpin\|…` | `engine.peers.toggleItemPinned(.filter(…))` (a team folder tab) |
| `wait\|<s>`, `waitfor\|offline`, `waitfor\|online` | pauses (e.g. stop the server while `waitfor\|offline` waits) |
| `album\|<chat>\|<count>\|<caption>` (generated JPEGs) / `files\|<chat>\|<count>\|<caption>` (text files) | `enqueueMessages` with one local grouping key, as the media picker's album or grouped files (sent as one post) |

```sh
SIMCTL_CHILD_RELAY_DEBUG_OPEN_CHAT=sandbox \
SIMCTL_CHILD_RELAY_DEBUG_WRITE='send|sandbox|Hello **world**;reply|sandbox|last|in a thread;react|sandbox|last|👍' \
  xcrun simctl launch "$UDID" org.relaychat.Relay
```

Failed writes the UI can't show (a refused delete, an unsendable message) appear as toasts (`MattermostSync.notices`).

#### Interactive message hooks (Phase 2C, debug builds only)

`RELAY_DEBUG_OPEN_SCREEN=button:<title>` taps the inline button with that title on the newest message of the chat that `RELAY_DEBUG_OPEN_CHAT` opened, through the chat's `requestMessageActionCallback` exactly as a tap does. For a menu button (title ends in ` ▾`) the option sheet opens; `RELAY_DEBUG_SELECT_OPTION=<option text or value>` picks that option four seconds later (time for a screenshot). Ephemeral answers show as a toast, refused actions as an alert.

#### Phase 3D: composer, slash commands, dialogs (debug builds only)

The simulator takes no scripted touches here (AXe's HID taps had no effect on this Xcode 27 setup, which has no Simulator.app), so the composer is driven through the debug remote (TelegramUI `RelayDebugComposer.swift`; output in the result's `state.chat`). `pick` runs the suggestion panel's own selection closure, as a tap on the row does:

```sh
tools/relay-remote.py "$UDID" compose "text=Ping @b"          # set the composer text (focus=0: keep the keyboard as is); suggestions load
tools/relay-remote.py "$UDID" suggestions                       # the visible panel (mentions/commands/emojis) and its entries
tools/relay-remote.py "$UDID" pick index=0                      # select an entry (inserts @bob / ~channel / emoji / the command line)
tools/relay-remote.py "$UDID" send-composer                     # the send button (a slash command runs on the server)
tools/relay-remote.py "$UDID" open-thread post=<root post id>   # the thread view of a root post in the visible chat
tools/relay-remote.py "$UDID" dialog                            # the visible interactive dialog: title, values, errors
tools/relay-remote.py "$UDID" dialog-set name=name value=api    # a field (type=bool|number for those)
tools/relay-remote.py "$UDID" dialog-picker name=reviewer       # open a select's option screen
tools/relay-remote.py "$UDID" dialog-submit                     # the submit button (local checks, then the server)
tools/relay-remote.py "$UDID" dialog-cancel                     # Cancel (notifies the integration if it asked)
```

Interactive dialogs need an integration the server can reach: the dev server only allows `localhost` integration URLs, so run a small responder (Python stdlib, keep it outside `infra/`) in a container that shares the Mattermost container's network namespace (`docker run --network container:mmdev-mattermost-1 …`): it listens on `127.0.0.1:<port>`, answers the slash command registered with `POST /api/v4/commands` (url `http://localhost:<port>/command`), opens dialogs with `POST /api/v4/actions/dialogs/open` (no token needed, the trigger id expires after 3 s) and gets the submissions. Built-in commands (`/away`, `/me`, `/join`, …) need nothing.

#### Phase 3D-2: directory and membership (debug builds only)

The directory screens (MattermostUI `MattermostDirectoryDebug.swift`) and the channel profile (PeerInfoScreen `MattermostPeerInfoDirectory.swift`) register what their taps run; output in the result's `extra`:

```sh
tools/relay-remote.py "$UDID" new-message                                # the chat list's compose button → New Message
tools/relay-remote.py "$UDID" directory                                  # the visible directory screen and its state
tools/relay-remote.py "$UDID" directory-do do=search text=car            # type into its search field
tools/relay-remote.py "$UDID" directory-do do=tap username=carol         # a user row (New Message: opens the DM; selection screens: toggles)
tools/relay-remote.py "$UDID" directory-do do=new-group                  # New Group Message (also: new-channel, browse)
tools/relay-remote.py "$UDID" directory-do do=submit                     # Create / Add / Save
tools/relay-remote.py "$UDID" directory-do do=team team=design           # a team tab (Browse Channels, New Channel)
tools/relay-remote.py "$UDID" directory-do do=archived value=true        # Browse Channels: the Archived switch
tools/relay-remote.py "$UDID" directory-do do=tap name=<channel name>    # Browse Channels: a channel (preview, or the chat when joined)
tools/relay-remote.py "$UDID" directory-do do=join                       # the preview's Join Channel
tools/relay-remote.py "$UDID" directory-do do=set field=name value="Ops" # New Channel / Channel Settings fields: name, url, purpose, header, private
tools/relay-remote.py "$UDID" directory-do do=archive                    # Channel Settings: archive / unarchive / convert (confirmed); confirm-archive shows the alert
tools/relay-remote.py "$UDID" peerinfo                                   # the profile of the chat on top
tools/relay-remote.py "$UDID" info-state                                 # its access bits, members and their actions
tools/relay-remote.py "$UDID" info-edit                                  # the Edit button (Channel Settings)
tools/relay-remote.py "$UDID" info-add-member                            # Add Members
tools/relay-remote.py "$UDID" info-member username=dave do=menu          # a member's context menu (do=promote toggles channel admin, do=remove-confirmed removes)
tools/relay-remote.py "$UDID" info-leave confirm=1                       # Leave: the confirmation, then what its Leave button runs
```

`tools/relay-remote.py "$UDID" alert do=confirm` (or `do=cancel`) presses a button of the confirmation alert these screens show (archive, unarchive, convert: `directory-do do=confirm-archive` etc. show it; Remove from Channel: `info-member … do=remove`). Telegram's own Leave alert can't be pressed: `info-leave confirm=1` runs what its Leave button runs.

#### Phase 3C: search, saved posts, mentions, pinning (debug builds only)

TelegramUI `RelayDebugSearch.swift`; results in the result's `extra`. Search rows are read from the visible search pane (only rows on screen), and `search-tap` calls the row's own `selected(listView:)`, as a tap does:

```sh
tools/relay-remote.py "$UDID" search "query=from:bob deploy"          # chat list search (filter=media|links|files|music); visible rows
tools/relay-remote.py "$UDID" search-tap index=0 kind=message         # open a result (kind=peer for people/channels)
tools/relay-remote.py "$UDID" join-confirm                            # "Join" on the alert a not-joined channel shows
tools/relay-remote.py "$UDID" search-cancel
tools/relay-remote.py "$UDID" peerinfo-search chat=media pane=files query=crash   # profile → Files pane → its search
tools/relay-remote.py "$UDID" engine-search "query=in:firehose before:2014-01-01 nightly" pages=5   # the engine call, all pages, post ids
tools/relay-remote.py "$UDID" engine-search query=deploy chat=firehose from=bob                      # search in one chat
tools/relay-remote.py "$UDID" people query=rel                         # people/channel search (mine / other)
tools/relay-remote.py "$UDID" chat-search query=deploy                 # Search in the visible chat (from=<username>)
tools/relay-remote.py "$UDID" chat-search-step dir=earlier
tools/relay-remote.py "$UDID" post-list kind=saved                     # Settings → Saved Posts (kind=mentions: Recent Mentions)
tools/relay-remote.py "$UDID" post-list-items                          # what the list shows
tools/relay-remote.py "$UDID" post-list-tap index=0
tools/relay-remote.py "$UDID" save post=<id>                           # message menu: Save Post (unsave: Remove from Saved)
tools/relay-remote.py "$UDID" pin post=<id>                            # message menu: Pin / Unpin in the visible chat
tools/relay-remote.py "$UDID" pinned                                   # the visible chat's pinned bar
tools/relay-remote.py "$UDID" pinned-list                              # the bar's list button: all pinned messages
```

#### Phase 3E: link previews, links, Copy Link (debug builds only)

TelegramUI `RelayDebugLinks.swift`; results in the result's `extra`. Link taps go through the chat's own `openUrl`
(what a tap on a link calls), so the in-app link handling and the "Open this link?" prompt are exercised:

```sh
tools/relay-remote.py "$UDID" links                                    # visible messages: link previews, link/heading/code entities
tools/relay-remote.py "$UDID" tap-link url=http://localhost:8065/engineering/pl/<post id>   # tap a link (concealed=1: a [text](url) link)
tools/relay-remote.py "$UDID" tap-preview post=<post id>               # tap the message's link preview card
tools/relay-remote.py "$UDID" copy-link post=<post id>                 # message menu: Copy Link → the pasteboard
tools/relay-remote.py "$UDID" share-link post=<post id>                # message menu: Share Link (system share sheet)
tools/relay-remote.py "$UDID" last-link                                # where the last link led, the chat on top
tools/relay-remote.py "$UDID" open-url url=relay://localhost:8065/engineering/pl/<post id>  # the app delegate's open-URL entry (via=system: UIApplication.open)
xcrun simctl openurl "$UDID" "relay://localhost:8065/engineering/pl/<post id>"   # from the system: SpringBoard asks "Open in Relay?"
```

`simctl openurl` puts up SpringBoard's "Open in "Relay"?" confirmation; Simulator taps don't reach it here, AXe does:
`axe touch -x 275 -y 474 --down --up --delay 0.15 --udid "$UDID"` (iPhone 17 Pro; `axe describe-ui` gives the button's
frame). To test a link of another account's server on one dev server, add the second account with
`http://127.0.0.1:8065` as the server address: it is a different host, so `http://127.0.0.1:8065/…` links belong to it.

Link previews need pages the server can fetch: the dev server only fetches `localhost` URLs, so run a small
OpenGraph responder (Python stdlib, keep it outside `infra/`) in a container sharing the Mattermost container's
network namespace (`docker run --network container:mmdev-mattermost-1 …`, listening on `127.0.0.1:<port>`) and post
`http://localhost:<port>/…` links. Preview images load only from the server itself or through its image proxy
(`ImageProxySettings.Enable`, `PUT /api/v4/config/patch` as sysadmin; it is off on the dev server by default).

#### Phase 3F: own status, profile, notification preferences, sharing (debug builds only)

TelegramUI `RelayDebugProfile.swift`, PeerInfoScreen `RelayDebugProfileSettings.swift`; the screens they open are
MattermostUI list screens, read and driven with `directory` / `directory-do` (their `debugActions`). Remote arguments
are strings (`key=value`); numbers and booleans are parsed by the screens.

```sh
tools/relay-remote.py "$UDID" profile-state                            # own status, custom status, profile fields (compare with REST)
tools/relay-remote.py "$UDID" settings-row row=status                  # Settings rows: status, custom-status, edit, avatar, notifications, username, email (keep=1: don't pop first)
tools/relay-remote.py "$UDID" directory-do do=select status=away       # Status screen: online/away/dnd/offline
tools/relay-remote.py "$UDID" directory-do do=dnd duration=30m         # Do Not Disturb: (none: until turned off) 30m 1h 2h tomorrow, custom minutes=90
tools/relay-remote.py "$UDID" status-menu                              # the Settings tab's long-press status items; status-menu-show presents the menu
tools/relay-remote.py "$UDID" status-menu-pick "title=Do Not Disturb" "sub=For 1 Hour"   # an item's own action
tools/relay-remote.py "$UDID" directory-do do=pick-emoji               # Custom Status: Telegram's emoji picker on the emoji row
tools/relay-remote.py "$UDID" directory-do do=emoji value=palm_tree    # … the emoji a pick turns into (taps don't reach the picker here)
tools/relay-remote.py "$UDID" directory-do do=text "value=On vacation" # … text; duration value=one_hour (dont_clear, thirty_minutes, four_hours, today, this_week, date_and_time minutes=N)
tools/relay-remote.py "$UDID" directory-do do=submit                   # … Set; also recent index=N, suggestion index=N, clear
tools/relay-remote.py "$UDID" edit-profile do=begin                    # Edit Profile: set field=first|last|nickname|position value=…, done, cancel
tools/relay-remote.py "$UDID" directory-do do=set index=0 value=…      # Username / Email screens (email: index=1 is the password); submit
tools/relay-remote.py "$UDID" avatar do=set text=3F                    # a generated picture through the Settings photo handler; do=remove: the removal
tools/relay-remote.py "$UDID" push-mentions                            # Settings → Notifications → Push and Mentions; directory-do do=push value=all, push-status, threads, first-name, channel-wide (value=true|false), keywords
tools/relay-remote.py "$UDID" chat-notifications                       # on a chat's profile (peerinfo first): Customize; directory-do do=push value=default|all|mention|none, threads, ignore-channel-mentions, mute, auto-follow
tools/relay-remote.py "$UDID" share-test chat=relay-3f-share "text=…" url=… images=2 files=1 thread=<root post id>   # the share extension's posting, in the app
tools/relay-remote.py "$UDID" share-extension "text=…" images=1 files=1   # the real share extension, hosted by the app (see below)
tools/relay-remote.py "$UDID" chats-tab                                # back to the Chats tab
```

**The real share extension.** Simulator taps reach neither Relay's windows nor Photos' share sheet on this setup
(AXe's touches only work on SpringBoard alerts), so the extension can't be driven from Photos. Instead the app hosts
its own extension the way `UIActivityViewController` does (`NSExtension` + `instantiateViewControllerWithInputItems:`,
MattermostUI `MattermostShareExtensionDebug.swift`) with generated items (text, URL, JPEGs as the Photos app shares them, an image type over a file URL, and text files as file URLs):
the extension runs in its own process with its own Keychain access, Postbox and uploads. Its picker can't be tapped
either, so a debug file in the app group names the chat: `{"peerId": <PeerId.toInt64()>, "comment": "…", "delay": 6}`
in `<group container>/telegram-data/relay-debug/share-auto.json` (`xcrun simctl get_app_container "$UDID"
org.relaychat.Relay groups`; the peer id from `peerinfo` + `info-state`). After `delay` seconds the extension posts
through what its Send button runs and writes `share-result.json` next to it; the extension logs
`[Relay] share: shared …`. It uses the current account (switch first with `switch username=…`).

#### Phase 4B: runtime hygiene and performance (debug builds only)

TelegramUI `RelayDebugPerf.swift`, MattermostUI `MattermostDebugRemote.swift`; results in the result's `extra`:

```sh
tools/relay-remote.py "$UDID" runtime                     # requests that reached the null network engine per Telegram function (total, live), memory (phys_footprint, resident)
tools/relay-remote.py "$UDID" runtime stacks=1            # … with the call stack of each function's first request (demangle with `xcrun swift-demangle`)
tools/relay-remote.py "$UDID" screen name=data            # a Settings sub-screen as RELAY_DEBUG_OPEN_SCREEN names it (privacy, data, notifications, appearance, …)
RELAY_REMOTE_TIMEOUT=40 tools/relay-remote.py "$UDID" chatlist-scroll "folder=4B Large" seconds=8 speed=7000   # scroll a folder's list down and back, frame intervals and hitches
tools/relay-remote.py "$UDID" storage                     # Telegram's storage usage per chat and category + Mattermost files on disk (mm-file-*, mm-avatar-*, mm-url-*)
tools/relay-remote.py "$UDID" storage do=evict peer=<PeerId.toInt64()> seconds=60   # a per-chat "keep media" exception: automatic eviction of that chat's files unused for 60 s
tools/relay-remote.py "$UDID" storage do=reset            # remove the exceptions; do=clear [peer=…]: what Storage Usage's Clear runs
tools/relay-remote.py "$UDID" background-refresh          # what the BGAppRefreshTask runs (catch-up of every account)
```

- `RELAY_REMOTE_TIMEOUT=<s>` makes `relay-remote.py` wait longer than 15 s for an answer.
- Every launch logs `[Relay] perf: chat list ready <ms> after didFinishLaunching, <ms> after process start` (release builds too, since 4E); the bootstrap logs `bootstrap: newest pages n/N after <ms>` and `bootstrap: done in <ms>`, each catch-up `catch-up since …: N channels, M with new posts …, K stale, in <ms>`, the foreground check `foreground: active after <s> s in the background; websocket alive|…`.
- `tools/relay-session.py "$UDID" --minutes 10 --out session.jsonl`: a scripted session (chats, profiles, thread, search, Settings screens, threads list, background/foreground) with a memory and parked-request sample every minute; the last line lists every parked function.
- **Background refresh** (`BGAppRefreshTask` `org.relaychat.Relay.refresh`): the simulator refuses `BGTaskScheduler.submit` (`BGTaskSchedulerErrorDomain` 1, logged as "could not schedule", although `backgroundRefreshStatus` is available), so `_simulateLaunchForTaskWithIdentifier:` has no pending request to launch there. `tools/relay-remote.py "$UDID" background-refresh` runs what the task runs (also while the app is in the background); the app logs `background refresh: started` and `… N account(s) caught up in … ms`. On a device, after the app was put in the background once: attach lldb (Xcode, or `xcrun lldb -p <pid>`), `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"org.relaychat.Relay.refresh"]`, continue.

**Large-server data** (`tools/mm-large-server.py`, standard library; bulk import through `mmctl --local`): team `relay-4b-large` ("4B Large") with 1,000 channels `l4b-NNNN-<topic>` (~25,000 posts over 60 days, 8 % with replies), 2,000 users `l4bNNNN` (190 active: unlicensed 11.7 servers cap active users at 200/250 — the rest are deactivated but still post and are members; `l4b0001`–`l4b0005` have the shared seed password and post the unread posts):

```sh
tools/mm-large-server.py seed        # ~5 min (bulk import)
tools/mm-large-server.py join        # alice: the team, 500 channels (read), 40 DMs + 5 GMs with load users, then 150 channels with new posts (30 @alice)
tools/mm-large-server.py unread      # more new posts; mark-read: alice reads her load channels
tools/mm-large-server.py status
tools/mm-large-server.py detach      # alice leaves the team (and its channels); her DMs/GMs with load users are hidden (direct/group_channel_show=false)
tools/mm-large-server.py purge       # delete the team and the load users permanently (mmctl)
```

#### Phase 2D hooks (debug builds only)

- `RELAY_DEBUG_OPEN_SCREEN=devices` (Settings → Devices), `openlinks` (Open Links In), `reaction-notifications`, `authorinfo` (profile of the newest message's author in the chat `RELAY_DEBUG_OPEN_CHAT` opened, e.g. a webhook's name override), `settings:add-account` (Settings → Add Account through the Settings handler, account limit included).
- `RELAY_DEBUG_DEVICES_ACTION=terminate-first|terminate-others` (with `RELAY_DEBUG_OPEN_SCREEN=devices`): runs the confirmed "Terminate Session" of the first other session, or "Terminate All Other Sessions", three seconds after the list loaded. Use dave (or sessions you created): it ends real sessions.
- Media tabs: `RELAY_DEBUG_OPEN_CHAT=<channel>` + `RELAY_DEBUG_OPEN_SCREEN=peerinfo`; the file search logs `holes: files of <channel>`. The chat itself pages the history behind the profile, so test with files more than a few pages back.

#### Phase 4C: accessibility, text size, appearance, languages

- **VoiceOver tree from inside the app** (debug builds): `tools/relay-remote.py "$UDID" ax-tree` lists the accessibility
  elements of the screen (label, value, hint, traits, frame, custom actions; `extra.elements`), walked the way UIKit
  exposes them (MattermostUI `MattermostAccessibilityDebug.swift`). It sees elements that AXe misses (Telegram's
  ASDisplayNode-based bars and lists hand out plain objects AXe skips). VoiceOver orders them by position.
- **From outside**: AXe (bundled in XcodeBuildMCP's npm package, `bundled/axe`; `npm pack xcodebuildmcp@2.7.0` and
  unpack it) `axe describe-ui --udid "$UDID"` (whole tree) and `--point x,y` (what touch exploration finds there).
  Its `touch -x … -y … --down --up --delay 0.15` reaches Relay's windows on this setup too (4C).
- **Text size**: `xcrun simctl ui "$UDID" content_size accessibility-extra-extra-extra-large` (then relaunch);
  Telegram follows it while Appearance → Text Size → "Use System Text Size" is on (the default). Back:
  `content_size large`.
- **Dark mode**: `xcrun simctl ui "$UDID" appearance dark` (Telegram's automatic night theme follows the system).
- **Right-to-left**: `xcrun simctl launch "$UDID" org.relaychat.Relay -AppleLanguages "(ar)" -AppleLocale ar_SA`.
- **Pseudo-language** (debug builds bundle `en-XA`, docs/design/localization.md):
  `xcrun simctl launch "$UDID" org.relaychat.Relay -AppleLanguages "(en-XA)"`. Plain English on screen is
  hard-coded or server text.

#### Phase 4F: known-gaps burn-down (debug builds only)

```sh
tools/relay-remote.py "$UDID" dump-chatlist          # chatlist.json now has each row's `top` (sortTimestamp, id, text, isRoot)
tools/relay-remote.py "$UDID" actions post=<post id> # what the message menu offers for a post in the visible chat (deleteGlobally, …)
tools/relay-remote.py "$UDID" chat-search "query=…"  # in-chat search (CRT: replies too); chat-search-step dir=earlier opens a reply's thread
SIMCTL_CHILD_RELAY_DEBUG_SEND_DELAY=25 SIMCTL_CHILD_RELAY_DEBUG_WRITE='image|sandbox|caption' \
  xcrun simctl launch "$UDID" org.relaychat.Relay    # waits 25 s between the upload and POST /posts: end the app meanwhile
```

- **Upload ids across a restart**: with `RELAY_DEBUG_SEND_DELAY`, terminate the app after `send: uploaded …` and the
  `debug delay` line, relaunch without it: the log says `reuses N file(s) uploaded before a restart` and the post's
  `file_ids` are the first upload's.
- **Thread unread separator**: mark a followed thread read at a reply as the user
  (`PUT /users/{me}/teams/{team}/threads/{root}/read/{create_at}`), post more replies as someone else, open the thread
  (`replies post=<root>`): the log says `threads: <root> opens at its first unread reply …`.
- **Notification sender names**: the app logs `push: sender names as <format>` (the `push_name_format` cursor in
  `sync.sqlite`); `simulate-push` (Phase 3A) then titles the notification with that name (`notifications` lists it
  when the app is in the background and notifications are allowed: `tools/sim-allow-notifications.py`).
- **delete_others_posts**: `channel_admin` has none on an unlicensed server; add it for a check as sysadmin
  (`PUT /roles/{id}/patch`, keep the old list to restore it); the app follows `role_updated` live (`actions`).

#### Phase 4G: security and diagnostics

**Managed app configuration on the simulator.** `simctl spawn … defaults write <bundle id>` writes the simulated
user's domain, which the app's `UserDefaults.standard` reads after its own container (checked in 4G: the keys reach
the app). The app reads it at launch and whenever it becomes active; an external `defaults write` posts no
`UserDefaults.didChangeNotification` in the app, so put Relay in the background and back to apply a change:

```sh
xcrun simctl spawn "$UDID" defaults write org.relaychat.Relay com.apple.configuration.managed \
  -dict serverUrl http://localhost:8065 serverName "Relay Dev" username alice allowOtherServers false \
        inAppPinCode true blurApplicationScreen true copyAndPasteProtection true vendor "Example Corp" \
        relayCertificatePins "127.0.0.1=sha256/<base64>"
xcrun simctl launch "$UDID" com.apple.Preferences && xcrun simctl launch "$UDID" org.relaychat.Relay   # re-read
xcrun simctl spawn "$UDID" defaults delete org.relaychat.Relay com.apple.configuration.managed            # unmanaged again
```

Debug remote (MattermostUI `RelaySecurityDebug.swift`, output in `extra`):

```sh
tools/relay-remote.py "$UDID" managed                      # configuration in effect, raw keys seen, extensions' copy, UI policy
tools/relay-remote.py "$UDID" passcode                     # passcode kind, auto-lock, locked?, notification action options
tools/relay-remote.py "$UDID" passcode do=lock             # the chat list's lock button
tools/relay-remote.py "$UDID" passcode do=set code=1234    # as the setup screen completes (do=clear code=…: Turn Passcode Off)
tools/relay-remote.py "$UDID" passcode do=press-set        # "Set Passcode" on the "Passcode Required" alert
tools/relay-remote.py "$UDID" pasteboard                   # the copy/paste guard's view (do=copy text=…: copy as the app does)
tools/relay-remote.py "$UDID" diagnostics                  # stored MetricKit reports, last export
tools/relay-remote.py "$UDID" diagnostics do=add-report kind=diagnostics   # a synthetic report (MetricKit delivers none on a simulator)
RELAY_REMOTE_TIMEOUT=60 tools/relay-remote.py "$UDID" diagnostics do=export   # the export without the share sheet (zip in the app's tmp)
tools/relay-remote.py "$UDID" screen name=passcode         # Privacy and Security → Passcode (also name=diagnostics)
```

- **Real taps** on the passcode keypads work with AXe (`axe touch -x … -y … --down --up --delay 0.08`; iPhone 17 Pro
  points, setup screen keys 1/2/3 at y 622, 4/5/6 at 676, 7/8/9 at 730, 0 at 789, x 69/201/333; lock screen keys at
  y 328/422/513, 0 at 603, x 98/201/302).
- **App-switcher snapshot**: iOS saves it in the data container, `Library/SplashBoard/Snapshots/sceneID:org.relaychat.Relay-default/*.ktx`;
  ImageIO reads KTX (a 10-line Swift script with `CGImageSourceCreateWithURL` writes a PNG).
- **Jailbreak detection** can't trigger on a simulator; `SIMCTL_CHILD_RELAY_DEBUG_JAILBROKEN=1` (debug builds) makes
  the check report a jailbreak.
- **Pasteboard**: `xcrun simctl pbcopy` doesn't reach the simulator here; `pbcopy` on the Mac + `xcrun simctl pbsync
  host "$UDID"` does (it changes the Mac's pasteboard: save and restore it). The simulator also syncs its pasteboard
  with the Mac's on its own, so content Relay copies comes back as a new change (`RelayPasteboardGuard` recognises its
  own content by text/link/images for pasting; the clear when Relay goes to the background only clears an unchanged
  pasteboard).
- **Certificate pinning end to end**: a throwaway TLS proxy in front of the dev server (nginx in a container on the
  `mmdev_default` network, `proxy_pass http://mmdev-mattermost-1:8065` with WebSocket upgrade headers, published on
  `127.0.0.1:8443`), a test CA trusted on the simulator (`xcrun simctl keychain "$UDID" add-root-cert ca.pem`), an
  account on `https://127.0.0.1:8443`, then pins for `127.0.0.1` (compute them with the `openssl` pipeline in
  docs/release/managed-configuration.md). Remove the container afterwards; the CA stays in the simulator's trust store
  (`simctl keychain reset` would remove everything else too).
- **MetricKit** on a device: Xcode → Debug → Simulate MetricKit Payloads delivers a sample of each payload to the
  running app.

#### Phase 4E: release-candidate regression (release builds)

The checklist is [release/REGRESSION.md](release/REGRESSION.md); it is run on the `release_sim_arm64` build with real
taps, and on a debug build only for the items that need the remote.

- **Release builds log in over HTTPS only**: run a TLS proxy in front of the dev server (nginx on `mmdev_default`,
  `proxy_pass http://mmdev-mattermost-1:8065` with the WebSocket upgrade headers, published on `127.0.0.1:8443`, a
  leaf for `localhost`/`127.0.0.1` from a throwaway CA) and `xcrun simctl keychain <udid> add-root-cert ca.pem` on
  every simulator; the server address is then `https://localhost:8443`. The same leaf serves a second server's proxy
  on another port.
- **`tools/relay-axe.py <udid> …`** drives any build with AXe: `tree`, `find`/`tap`/`wait` by accessibility label,
  `tap-text`/`wait-text`/`gone-text`/`ocr` by text on screen (Vision OCR of a screenshot, `tools/relay-ocr.swift`,
  compiled once into `build-input/relay-ocr`), `type` (`--env NAME` keeps a password off the command line), `clear`,
  `key`, `swipe`, `tap-xy`, `shot`. Set `AXE` to XcodeBuildMCP's `bundled/axe`. Telegram's alerts, action sheets,
  tab bar and chat list header are only reachable through `tap-text`. Driving tips are in REGRESSION.md "Setup".
- **Cold start on any build**: every launch logs `[Relay] perf: chat list ready <ms> after didFinishLaunching, <ms>
  after process start` to the unified log (since 4E also in release builds; two numbers, nothing else):
  `xcrun simctl spawn <udid> log stream --style compact --predicate 'eventMessage CONTAINS "[Relay] perf:"'`, then
  `simctl terminate` / `simctl launch` a few times.
- **Release logs**: Settings → About Relay → Diagnostics → Save Diagnostic Logs turns on Telegram's file log in a
  release build; MattermostSync's lines (`bootstrap: done in …`, `catch-up since …`) are then in
  `$(xcrun simctl get_app_container <udid> org.relaychat.Relay groups)/telegram-data/logs/app-logs/*.txt`.
- **A second server version** (D2: the ESR and the newest release) runs as its own compose project from a copy of
  `infra/dev-server/` (outside the repository) with `name:` and the image tag changed and `MM_PORT`/`MM_SITE_URL` set
  in the copy's `.env`; `seed.py` and `mmlib.py` work unchanged on whatever directory they are in (its compose
  project, its `.state/`; 46 s against 12.0.1). The Team Edition image is amd64-only: `docker pull --platform
  linux/amd64`. For pushes, point it at the dev push proxy: `MM_EMAILSETTINGS_SENDPUSHNOTIFICATIONS: "true"`,
  `MM_EMAILSETTINGS_PUSHNOTIFICATIONSERVER: "http://push-proxy:8066"`, then `docker network connect mmdev_default
  <its mattermost container>`. Before connecting, change its datasource host from `postgres` to its own Postgres
  container's name: on two networks the name `postgres` also resolves to the ESR server's database. Remove it all with
  `docker compose … down -v` and `docker rmi` the image.
- **Real pushes on a simulator**: with the push proxy's real APNs key (Phase 4D device signing), a release
  simulator build registers a sandbox token and receives real pushes through APNs, so the notification service
  extension runs as on a device (proxy log "Acknowledged delivery receipt").

If `simctl install` doesn't pick up a rebuilt binary (same build number), replace the installed bundle in place as described in the root `CLAUDE.md` ("Updating the running simulator after a rebuild"). This happened in 2D after a 30-second incremental build: compare the md5 of `Frameworks/TelegramUIFramework.framework/TelegramUIFramework` in the `.ipa` and in the installed app when a change seems missing.

#### Phase 5A: voice messages (debug builds only)

Recording on a simulator uses the Mac's microphone, which can raise a macOS privacy prompt nobody answers. Debug
builds replace the microphone inside Telegram's recorder (`ManagedAudioRecorderContext`) with a **fake microphone**:
a file or a tone fed in 20 ms blocks through the recorder's own encoder, waveform, preview and send path, with no audio
session and no audio unit. Hold-to-record, slide to cancel, lock, pause/resume, preview and send then work with real
taps (AXe) or the remote.

```sh
say -o speech.aiff "This is a Relay voice message test."               # any speech; ffmpeg or afconvert to 48 kHz mono
ffmpeg -i speech.aiff -ar 48000 -ac 1 -c:a pcm_s16le speech48.wav
DATA=$(xcrun simctl get_app_container "$UDID" org.relaychat.Relay data)
mkdir -p "$DATA/Documents/relay-debug" && cp speech48.wav "$DATA/Documents/relay-debug/"
xcrun simctl privacy "$UDID" grant microphone org.relaychat.Relay     # the iOS prompt; no Mac microphone is opened
SIMCTL_CHILD_RELAY_DEBUG_FAKE_MIC=relay-debug/speech48.wav xcrun simctl launch "$UDID" org.relaychat.Relay
                                                                      # or RELAY_DEBUG_FAKE_MIC=tone
```

Debug remote (TelegramUI `RelayDebugVoice.swift`, output in `extra`), each through the code path of the control it
stands for:

```sh
tools/relay-remote.py "$UDID" fake-mic file=relay-debug/speech48.wav   # or tone=20, off=1
tools/relay-remote.py "$UDID" voice do=record     # hold the mic button (beginMediaRecording)
tools/relay-remote.py "$UDID" voice do=lock       # slide up
tools/relay-remote.py "$UDID" voice do=pause      # stop into the preview (resume: do=resume)
tools/relay-remote.py "$UDID" voice do=send       # release / the send button (cancel: do=cancel; state: do=state)
tools/relay-remote.py "$UDID" voice-messages      # the visible chat's voice messages: post, duration, waveform, played
tools/relay-remote.py "$UDID" voice-play index=0  # a tap on the newest one's play button (or post=<id>)
tools/relay-remote.py "$UDID" player rate=2       # the player: state, next message, rate (do=pause|play|next|stop)
tools/relay-remote.py "$UDID" peerinfo-pane chat=sandbox pane=voice   # the profile's Voice tab
tools/relay-remote.py "$UDID" search filter=voice                    # the chat list search's Voice tab
```

- **Real gestures** with AXe on the mic button (`tools/relay-axe.py "$UDID" find "Voice message"` gives its frame):
  `axe touch -x <x> -y <y> --down --up --delay 5` records 5 s and sends on release; `axe swipe` left from the button
  cancels, up from it (`--duration 2 --delta 5`) locks; "Stop and preview" and Send then take ordinary touches. If AXe's
  touches stop reaching the app (taps do nothing, `describe-ui` still answers), reboot the simulator (`simctl shutdown`,
  `boot`): seen once in 5A.
- **Interop**: `GET /posts/{id}` shows `props.relay_voice`; `GET /files/{id}` is the `.m4a` (`ffprobe`: AAC-LC, 48 kHz,
  mono, ~33 kbps). The Mattermost web app's file preview is a plain `<video controls><source src=…>` (11.7 bundle,
  `AUDIO_TYPES` by extension); a page with that markup checks a file in Chrome (`--headless=new --dump-dom
  --virtual-time-budget=8000`), in WebKit (a `WKWebView` in an off-screen window) and in the simulator's Safari.
- **Pushes**: with the push proxy's real APNs key the simulator gets real pushes and the notification service extension
  runs (`nse: post … is a voice message` in the `[Relay]` log); `simulate-push` with a payload whose `post_id` is a voice
  post runs the same code in the app.

#### Phase 4H: daily-use gaps

Nothing new to drive it: real taps (AXe) and REST as the test users. Notes:

- **Name format**: `PUT /users/{me}/preferences` with `{"category": "display_settings", "name": "name_format", "value":
  "full_name" | "nickname_full_name" | "username"}` switches it live (log `names: N user(s) and M group message(s)
  renamed as …`); `POST /users/{me}/preferences/delete` with the same entry goes back to the server's
  `TeammateNameDisplay` (the dev server's is `username`). The rename also runs once per build that bumps
  `userPeersVersion` (cursor `user_names_format` in `sync.sqlite`).
- **`@channel` confirmation** needs a channel with more than 5 members (engineering Town Square and Off-Topic have 7);
  time zones come from the members' `timezone` (`PUT /users/me/patch`, empty on the seeded users). The permission check
  caches roles for 60 s, so wait a minute after changing `channel_user` (`PUT /roles/{id}/patch` as sysadmin).
- **Forwards from another client**: post the permalink (`<SiteURL>/<team>/pl/<post id>`) as bob through REST; that is
  exactly what the web app's Forward posts. `GET /posts/{id}` shows the `permalink` embed (`POST /posts/ids` has none).
- **Catch-up paths**: `simctl terminate`, change things through REST, `simctl launch`: the launch's catch-up logs
  `catch-up: chat-list previews of N quiet chat(s): …` and `threads: … recounted after deleted replies`. Edits move a
  channel's `last_post_at` on 11.7 (the channel is then caught up as an active one); deletions and reactions don't.
- **Two servers**: one server under two addresses (`http://localhost:8065`, `http://127.0.0.1:8065`) gives two
  accounts with different server labels, but not the same user twice (the login refuses a user id it already has).

### Push notifications on the simulator (Phase 3A)

Simulator builds (`--disableProvisioningProfiles`) get `aps-environment: development`, communication notifications and, for the notification service extension, the app group (`TelegramSimulatorEntitlements` / `NotificationServiceSimulatorEntitlements` in `Telegram/BUILD`). On Apple silicon the simulator then gets a real APNs **sandbox** token; the app logs it (`[Relay] push: APNs sandbox token …`) and every account attaches it to its session as `relay_apple_sandbox:<token>` (check with `infra/push-proxy/configure-dev-server.py --sessions alice`).

- **Permission**: Relay asks after login (Telegram's permission flow), never on the login screens. Nothing can answer the system prompt in scripted runs, and `xcrun simctl privacy` has no notifications service, so allow it on the shut-down simulator: `xcrun simctl shutdown $UDID && tools/sim-allow-notifications.py $UDID && xcrun simctl boot $UDID`. Combine with `RELAY_DEBUG_NO_PERMISSION_PROMPTS=1` to skip Telegram's own prompt.
- **`xcrun simctl push` never starts the notification service extension** (CoreSimulatorBridge hands the request straight to SpringBoard; only APNs delivery runs extensions), and a content-available-only payload (`clear`) only triggers a background fetch without its payload. So a `simctl push` shows the server's text as is. To see what the extension makes of a push, debug builds run the same code in the app: `tools/relay-remote.py $UDID simulate-push file=<payload.apns> delay=3` (the result is scheduled as a local notification `delay` seconds later, so it is also delivered after the app was put in the background, locked or terminated). Payloads: `submodules/MattermostPush/Tests/MattermostPushTests/Fixtures/`.
- **Real server pushes**: `infra/push-proxy/sim-bridge.py --udid $UDID --deliver app` with the dev server pointed at it (`infra/push-proxy/README.md`).
- **Taps and actions** (debug remote, the AppDelegate's own handler): `notification-open which=latest` (tap), `notification-reply which=0 "text=…"`, `notification-read which=0`, `notifications` (the delivered list); the result's `state.visibleChat` shows the chat on top. A tap that launches the app: `SIMCTL_CHILD_RELAY_DEBUG_OPEN_NOTIFICATION=latest xcrun simctl launch $UDID org.relaychat.Relay`.
- **Real taps** work with AXe (bundled in XcodeBuildMCP's npm package, `bundled/axe`): `axe touch -x … -y … --down --up --delay 0.15 --udid $UDID` (a plain `tap` doesn't reach SpringBoard's notification platters), `axe button lock`, and `axe swipe … --delta 20` to unlock or open Notification Center from the lock screen. Edge gestures (home, Notification Center from the top) don't work; `xcrun simctl launch $UDID com.apple.Preferences` puts Relay in the background.

## Pure Swift packages

`submodules/MattermostKit`, `submodules/MattermostSyncCore`, `submodules/MattermostPush` and `submodules/MattermostShare` are SwiftPM packages with no Telegram dependencies:

```sh
cd submodules/MattermostKit && swift test
cd submodules/MattermostSyncCore && swift test
cd submodules/MattermostPush && swift test
cd submodules/MattermostShare && swift test            # MM_INTEGRATION=1: also shares as dave into ~relay-3f-share on the dev server
```

## Local Mattermost server

See `infra/dev-server/README.md`; its push proxy: `infra/push-proxy/README.md`.
