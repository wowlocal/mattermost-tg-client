# Local Mattermost dev server

A Mattermost server with realistic seed data for developing and testing the
iOS client. **Development only.** Everything here runs as the Docker Compose
project `mmdev` (containers `mmdev-*`, volumes `mmdev_*`, network
`mmdev_default`), so it never touches other containers on the machine.

| | |
|---|---|
| Web app / API | <http://localhost:8065> (API base `http://localhost:8065/api/v4`) |
| WebSocket | `ws://localhost:8065/api/v4/websocket` |
| Server | `mattermost/mattermost-team-edition:11.7.14`, the current **v11.7 ESR** (supported until 2027-05-15) |
| Database | `postgres:18.6-alpine`, reachable only inside the compose network |
| Data | named volumes `mmdev_postgres-data`, `mmdev_mm-config`, `mmdev_mm-data`, `mmdev_mm-logs`, `mmdev_mm-plugins`, `mmdev_mm-client-plugins` |

**Why Team Edition:** without a license, the Enterprise image runs as
"Mattermost Entry", which hides history beyond the most recent 10,000
messages. That would break the firehose channel (11k+ posts back to 2013).
The image is amd64-only. On Apple silicon, OrbStack/Docker runs it through
Rosetta (`platform: linux/amd64`), which works fine for development.

## Quick start

```sh
cd infra/dev-server
./up.sh                      # start; creates .env with random passwords on first run
./seed.py                    # seed test data (idempotent, about 40 s on a fresh server)
./capture-fixtures.py        # optional: refresh fixtures/ for MattermostKit tests
```

| Script | What it does |
|---|---|
| `./up.sh` | Generates `.env` if missing, refuses to start if the port belongs to someone else, then runs `docker compose up -d --wait` and waits for `/api/v4/system/ping`. |
| `./down.sh` | Stops and removes the containers. **Data is kept** in the volumes. |
| `./reset.sh [--yes]` | Removes this project's containers **and volumes** (only `mmdev_*`) and `.state/`, then runs `up.sh` and `seed.py`. About 1 min end to end (56 s measured: ~13 s startup, ~43 s seed). |
| `./seed.py` | Seeds everything in [SEED.md](SEED.md). Safe to re-run: nothing is duplicated. Ends with a verification summary. |
| `./seed.py --verify` | Prints only the verification summary (counts, firehose range, alice's unread state). |
| `./capture-fixtures.py` | Logs in as alice and records REST responses and WebSocket events into `fixtures/`. See below. |

The scripts need only Docker (Compose v2) and the system `python3` (3.9+,
standard library only).

## Credentials

- **Passwords live in `.env`** (git-ignored, mode 600). `up.sh` generates it
  from `.env.example` with random values. Keys:
  - `SEED_ADMIN_USERNAME` / `SEED_ADMIN_PASSWORD`: the system admin (`sysadmin`)
  - `SEED_USER_PASSWORD`: the shared password of `alice`, `bob`, `carol` and `dave`
  - `POSTGRES_*`: the database
- **Runtime secrets live in `.state/credentials.json`** (git-ignored, mode 600),
  written by `seed.py`:
  - `bot_token`: personal access token of the `buildbot` bot account
  - `incoming_webhook_url`: the seeded "CI notifications" incoming webhook in ~integrations
- Log in with a username or an email (`alice@example.com`). Email
  verification is off.

If you change a password in `.env`, re-run `./seed.py`; it resets the
accounts to match.

## Server configuration

All settings come from `MM_*` environment variables in `docker-compose.yml`.
Settings set this way show as read-only in the System Console. Highlights:

- SiteURL `http://localhost:8065` (`MM_SITE_URL` in `.env`)
- Open server, user creation and sign-in by email or username, no email verification
- Personal access tokens, bot accounts and custom emoji on
- Collapsed reply threads `default_on`, thread auto-follow on
- File attachments on, max file size 100 MiB, public file links on, mobile upload/download on
- Link previews, permalink previews, SVG and LaTeX rendering on
- Incoming/outgoing webhooks, slash commands, username/icon overrides on
- Post priority and synced (server-side) drafts on
- No rate limiting, so seeding runs at full speed
- Local mode on: `mmctl --local` inside the container needs no login
- Telemetry, Sentry, security-update checks, admin notices and the plugin marketplace off
- Push notifications **off** (no push proxy yet). Enable `MM_EMAILSETTINGS_SENDPUSHNOTIFICATIONS` and set the push server once the dev push proxy exists.

### Useful commands

```sh
docker compose -p mmdev ps
docker compose -p mmdev logs -f mattermost
docker compose -p mmdev exec mattermost mmctl --local system status
docker compose -p mmdev exec mattermost mmctl --local config get ServiceSettings.CollapsedThreads
docker compose -p mmdev exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

The Mattermost image is distroless: it has no shell, `curl` or `cat`. Use
`mmctl` for anything inside it, and `docker compose cp` to move files in.

## Testing on a device (LAN)

1. In `.env` set `MM_BIND_ADDRESS=0.0.0.0` and `MM_SITE_URL=http://<your-mac-ip>:8065`, then run `./up.sh`.
2. App Transport Security blocks plain HTTP to non-localhost hosts. Either put a
   local TLS proxy in front of the server, or use a **debug-only** ATS exception
   that never ships (see `docs/plan/07-dev-environment.md`).

Binding to `0.0.0.0` exposes a server with known dev passwords to your network.
Switch back when you are done.

If port 8065 is taken, set `MM_PORT` and `MM_SITE_URL` in `.env`. `up.sh`
checks the port before starting.

## Fixtures (`fixtures/`)

`./capture-fixtures.py` writes:

- `fixtures/rest/*.json`: response bodies as alice: login, `users/me`, users by ID, statuses, teams, team members, unread counts, channels (one team and all teams), channel members, sidebar categories, channel and stats, post pages (`code-review`, `firehose`, a `before=` page, posts around the first unread, `integrations`, the DM with bob), a thread (plain and paged), a post with 5 files and reactions, file infos, reactions, pinned and flagged posts, user threads, a single user thread, custom emoji, preferences, client config and license (`format=old`), and a 404 error body.
- `fixtures/ws/events.json`: an ordered WebSocket recording, plus one file per event type: `hello`, `typing`, `posted`, `posted_reply`, `reaction_added`, `reaction_removed`, `post_edited`, `thread_updated`, `post_deleted`, `multiple_channels_viewed`, and `response_seq_1` (the reply to a client `get_statuses` action). The script triggers these itself as bob in ~sandbox and then deletes its post.
- `fixtures/manifest.json`: method, path, query, status and safe headers for each file.

Sanitizing: response headers (the `Token` header, cookies) are never stored,
both session tokens are replaced with `REDACTED` if they appear anywhere, and
token-like keys are dropped. IDs, emails and timestamps are kept, because tests
need consistent IDs. Re-run the script after `./reset.sh`, since all IDs change.

> **Note:** Mattermost 11.x no longer emits `channel_viewed`. Viewing a channel
> (`POST /channels/members/{user_id}/view`) publishes
> **`multiple_channels_viewed`** with `data.channel_times: {channel_id: last_viewed_at}`.

## Other server versions

The plan calls for testing against the oldest supported version, the ESR
(this setup) and the latest release (12.0.x when this was written). To run
another version side by side, copy this directory, change `name:` (for
example `mmdev-latest`), the image tag and `MM_PORT`/`MM_SITE_URL`. The seed
and fixture scripts work against any server via `MM_URL=http://localhost:<port>`.
Note that `seed.py` calls `mmctl` through the compose file next to it.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | Mattermost + Postgres, healthchecks, named volumes, all config |
| `.env.example` / `.env` | Template / real dev passwords and port (`.env` is git-ignored) |
| `up.sh`, `down.sh`, `reset.sh` | Lifecycle |
| `seed.py` | Seeder (REST v4 + bulk import for backdated history) |
| `capture-fixtures.py` | Fixture recorder |
| `mmlib.py`, `mmassets.py` | Shared helpers: REST/WebSocket client, `mmctl` wrapper; PNG/JPEG/PDF/WAV/SVG generators |
| `SEED.md` | What was seeded where |
| `.state/` | git-ignored runtime state: bot token, webhook URL, the generated import zip |
