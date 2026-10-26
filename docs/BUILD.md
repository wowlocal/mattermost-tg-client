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
```

Launch with `SIMCTL_CHILD_RELAY_DEBUG_NO_PERMISSION_PROMPTS=1` from the first launch on: an unanswered notifications prompt is SpringBoard's and survives app restarts and reinstalls until the simulator reboots. Passwords filled by the remote are cleared once they are submitted, so iOS doesn't cover the screen with "Save Password?".

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

```sh
SIMCTL_CHILD_RELAY_DEBUG_OPEN_CHAT=sandbox \
SIMCTL_CHILD_RELAY_DEBUG_WRITE='send|sandbox|Hello **world**;reply|sandbox|last|in a thread;react|sandbox|last|👍' \
  xcrun simctl launch "$UDID" org.relaychat.Relay
```

Failed writes the UI can't show (a refused delete, an unsendable message) appear as toasts (`MattermostSync.notices`).

If `simctl install` doesn't pick up a rebuilt binary (same build number), replace the installed bundle in place as described in the root `CLAUDE.md` ("Updating the running simulator after a rebuild").

## Pure Swift packages

`submodules/MattermostKit` and `submodules/MattermostSyncCore` are SwiftPM packages with no Telegram dependencies:

```sh
cd submodules/MattermostKit && swift test
cd submodules/MattermostSyncCore && swift test
```

## Local Mattermost server

See `infra/dev-server/README.md`.
