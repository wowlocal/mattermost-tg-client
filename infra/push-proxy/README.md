# Push proxy (mattermost-push-proxy) for Relay

Mattermost servers don't talk to APNs. They send each push to a **push proxy**, which signs it with the app's
APNs key and forwards it to Apple. Mattermost's hosted proxy only serves the official apps' bundle ids, so
Relay (`org.relaychat.Relay`) needs its own: [`mattermost-push-proxy`](https://github.com/mattermost/mattermost-push-proxy)
(Apache-2.0), here **6.6.0** pinned by digest.

```
Mattermost server ──POST /api/v1/send_push──▶ push proxy ──HTTP/2──▶ APNs ──▶ device ──▶ notification service extension
        ▲                                            │                                        │
        └──── POST /api/v4/notifications/ack ◀───────┴──────── POST /api/v1/ack ◀─────────────┘
```

**No secrets in this directory.** The APNs auth key (`.p8`) stays outside the repository and is mounted
read-only; `.env` (key id, team id) and the rendered config (`.state/`) are git-ignored.

## Platforms

The device id a Relay session registers (`PUT /api/v4/users/sessions/device`) is `<platform>:<APNs token>`.
The server hands the platform to the proxy, which picks the `ApplePushSettings` entry with that `Type`:

| Platform (`Type`) | APNs | Used by |
|---|---|---|
| `relay_apple` | production (`ApplePushUseDevelopment: false`) | App Store, TestFlight and ad-hoc builds |
| `relay_apple_sandbox` | sandbox (`ApplePushUseDevelopment: true`) | development builds and the simulator |

Both use topic `org.relaychat.Relay` and the same key (an APNs auth key works for both environments). The
app picks the platform from its `aps-environment` (`MattermostPushDevice`, submodules/MattermostPush). No
`-v<N>` suffix: the proxy reads one as an app version and changes how `clear` badges are sent.

## Quick start (local, with the dev server)

```sh
infra/dev-server/up.sh                       # the proxy joins its network, mmdev_default
cp infra/push-proxy/.env.example infra/push-proxy/.env   # fill in the key (below), or:
infra/push-proxy/make-dev-key.sh             # throwaway key: tests the wiring, APNs answers 403
infra/push-proxy/up.sh                       # renders .state/mattermost-push-proxy.json, starts the proxy
infra/push-proxy/configure-dev-server.py --enable   # dev server → http://push-proxy:8066, contents "full"
docker logs -f relaypush-push-proxy-1        # one "Sending apple push notification" per push
```

From a git worktree, set `RELAY_DEV_SERVER_DIR=<checkout>/infra/dev-server` for `configure-dev-server.py`
(the `.env` with the admin password lives in the checkout that started the dev server).

- `configure-dev-server.py` sets `EmailSettings.PushNotificationServer` and `PushNotificationContents` through
  `PUT /api/v4/config/patch` as `sysadmin`. `--status` shows them, `--sessions alice,bob` shows the users'
  sessions with their device ids.
- **`SendPushNotifications`**: the dev server's `docker-compose.yml` pins it to `false` with
  `MM_EMAILSETTINGS_SENDPUSHNOTIFICATIONS`, and settings fixed by environment variables can't be changed
  through the API. `--enable` therefore recreates the dev server's `mattermost` container with
  `dev-server-push.override.yml` (data stays in the volumes; ~20 s downtime). Running `infra/dev-server/up.sh`
  again turns pushes off again.
- **Push contents**: `full` (sender and text in the push) on the unlicensed Team Edition dev server.
  `id_loaded` (the device fetches the text with `POST /notifications/ack`) needs a licensed server: unlicensed
  servers silently send `generic` instead (`BuildPushNotificationMessage`). The app handles `id_loaded`
  pushes (it merges the acknowledgement's answer), unverified for that reason.
- `server_id` in every push is the server's `DiagnosticId` (client config), which Relay stores at login to
  route pushes to the right account.

## Production / a real APNs key

What the person who owns the Apple Developer account does once:

1. **App ID**: developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → the App ID
   `org.relaychat.Relay` (create it if missing) with the capabilities **Push Notifications**, **App Groups**
   (`group.org.relaychat.Relay`) and **Communication Notifications**. Also an App ID
   `org.relaychat.Relay.NotificationService` with **App Groups** (same group) and **Communication
   Notifications**. Regenerate the provisioning profiles of both (the build takes the extension's entitlements
   from its profile).
2. **Key**: Keys → **+** → name it (e.g. "Relay APNs"), tick **Apple Push Notifications service (APNs)**
   (environment "Sandbox & Production"), Continue → Register → **Download** the `AuthKey_<KEYID>.p8` (only
   downloadable once). Note the **Key ID** (10 characters) and the **Team ID** (top right, 10 characters).
3. **Store the key outside the repository**, e.g. `~/.relay-secrets/AuthKey_<KEYID>.p8`, `chmod 640`, readable
   by the proxy container (it runs as `nobody`; on Docker Desktop/OrbStack bind mounts the file must be
   readable through the VM's file sharing — `chmod 644` on a local development machine only).
4. In `infra/push-proxy/.env`: `APNS_KEY_FILE=<absolute path>`, `APNS_KEY_ID=<Key ID>`,
   `APNS_TEAM_ID=<Team ID>`; then `infra/push-proxy/up.sh`. The log must show "Initializing apple notification
   server with AuthKey" for `relay_apple` and `relay_apple_sandbox`, and no "Failed to initialize".
5. **Team id in the app build**: `build-config/development-configuration.json` still has Telegram's
   `team_id` (`C67CF9S4VU`); set it to your Team ID so device builds are signed by the team that owns the
   App ID and the key (APNs only accepts a token for a topic of the key's team).
6. Check end to end: run a **development** build on a device or the simulator (Apple silicon; the simulator
   gets real sandbox tokens), log in, send the account a DM from another user, and expect in the proxy log
   "Sending apple push notification … target_type=relay_apple_sandbox" without a following "Failed to send
   apple push". Only real APNs delivery starts the notification service extension (`xcrun simctl push` does
   not), so this is also the first run of the extension itself.

For a production deployment the proxy needs a public HTTPS endpoint the Mattermost servers reach (put it
behind a TLS reverse proxy; it listens on plain HTTP :8066), the key mounted from a secret store, and
monitoring of its log (APNs errors such as `BadDeviceToken`, `Unregistered`, `InvalidProviderToken`;
"Notification throughput" every minute) or of its Prometheus metrics (`EnableMetrics`).

## Simulator without a real key: `sim-bridge.py`

**Development only.** `sim-bridge.py` stands in for the push proxy URL on the dev server: it forwards every
request to the real proxy (so its log still shows the server → proxy leg) and delivers Relay's pushes to a
simulator, with the APNs payload built exactly as push-proxy 6.6.0 builds it:

```sh
infra/push-proxy/sim-bridge.py --udid <simulator> --deliver app --app-delay 3 [--save-dir DIR]
infra/push-proxy/configure-dev-server.py --push-server http://host.docker.internal:8166
```

- `--deliver simctl` uses `xcrun simctl push`. The simulator then shows the server's text as is: **simulated
  pushes never start a notification service extension** (CoreSimulatorBridge adds the notification request
  directly), and a background push (`clear`) only triggers a background fetch, without its payload.
- `--deliver app` hands the payload to a running debug build (debug remote `simulate-push`), which runs the
  extension's code (`MattermostPushService`) in the app and schedules the result as a local notification
  `--app-delay` seconds later, so it is delivered while the app is in the background, locked or killed;
  `clear` and `update_badge` go to the app's background-push handler. The app must be in the foreground
  when the push arrives.
- `--save-dir` keeps every payload (signature replaced) for fixtures:
  `submodules/MattermostPush/Tests/MattermostPushTests/Fixtures/captured-*.apns`.

Point the server back at the proxy afterwards: `configure-dev-server.py` (default `http://push-proxy:8066`).

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | The proxy (project `relaypush`), on `mmdev_default` as `push-proxy`, port 127.0.0.1:8066 |
| `mattermost-push-proxy.template.json` | Config with placeholders (`__APNS_KEY_ID__`, `__APNS_TEAM_ID__`, `__APNS_TOPIC__`, `__LOG_LEVEL__`) |
| `.env.example` / `.env` | Key path, key id, team id, topic (`.env` is git-ignored) |
| `up.sh`, `down.sh` | Render the config and start; stop |
| `make-dev-key.sh` | Throwaway P-256 key (not an Apple key) in `.state/dev-key/` for wiring tests |
| `configure-dev-server.py` | Dev server push settings through the REST API; `--enable`, `--status`, `--sessions` |
| `dev-server-push.override.yml` | Compose override that turns `SendPushNotifications` on for the dev server |
| `sim-bridge.py` | Development only: deliver the dev server's pushes to a simulator |
