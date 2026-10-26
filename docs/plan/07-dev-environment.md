# 7 · Dev environment

## Prerequisites

- Apple‑silicon Mac with 32 GB RAM or more (64 GB recommended) and ~150 GB free disk for the Bazel cache and Xcode.
- The **exact Xcode version** listed in Telegram‑iOS's `versions.json` for the pinned tag. Other versions usually fail to build.
- An Apple Developer account with:
  - team ID
  - App IDs for the app and each extension
  - app group and keychain access group
  - an APNs auth key (for the push proxy)
- A container runtime (Docker or a compatible one) for the local Mattermost server and push proxy.

## Building Telegram‑iOS

Follow the upstream README **at the pinned tag**; flags change between releases. The general shape:

1. Clone with submodules: `git clone --recursive -j8 https://github.com/TelegramMessenger/Telegram-iOS.git`, then check out the pinned tag and update submodules.
2. Copy the development configuration template from `build-system/`. Set our bundle ID, team ID and app group. The Telegram `api_id`/`api_hash` fields get placeholders; they become unused once MTProto is disconnected.
3. Generate the Xcode project with `build-system/Make.py … generateProject`, or build directly with `Make.py … build`. Use the Bazel cache directory option.
4. Simulator builds first; device builds once signing is set up.

Record the exact working commands in `docs/BUILD.md` during Phase 0.

## Local Mattermost server

- Quick start: the `mattermost/mattermost-preview` container image (all‑in‑one, **development only**), exposed on port 8065.
- For realistic testing, use the official Docker Compose setup with Postgres. Keep the compose file in `infra/dev-server/`.
- Seed data:
  - Use the server's sample‑data generator for bulk content.
  - Add a scripted seed (`infra/dev-server/seed`) for the specific cases from Phase 0: a 10,000‑post channel, threads, custom emoji, a bot with interactive attachments, imported old posts.
- **Server versions:** test against the oldest supported version, the current Extended Support Release (ESR), and the latest release. Run them as separate containers.
- **Testing on a device:** the server must be reachable over the LAN. App Transport Security blocks plain HTTP to non‑localhost hosts, so either:
  - put a local TLS proxy in front of the server, or
  - add a debug‑only ATS exception.

  Never ship the exception.

## Testing strategy

| Layer | How |
|---|---|
| `MattermostKit` | Unit tests with recorded JSON fixtures for REST responses and WebSocket events. Runs with SwiftPM in seconds. |
| `MattermostSync` | Tests against a temporary Postbox: event application, catch‑up, outgoing pipeline. Property tests for the ID allocator (random interleavings keep IDs unique and ordered). |
| Integration | Scripted scenarios against the containerized server: a second "user" posts, edits, reacts and deletes through the API while the test checks Postbox state. |
| UI | XCUITest smoke flows: add server, login, send, receive, reply in thread, upload, search. |
| Push | `simctl push` fixtures; end‑to‑end on a device against the sandbox push proxy. |
| Manual | Device matrix (oldest supported iOS, current iOS; small and large iPhone; iPad), poor networks (Network Link Conditioner). |

## CI

- Self‑hosted macOS runner with a persistent Bazel disk cache (or a remote cache). Hosted runners are usually too small and too slow for Telegram‑iOS builds.
- On every push:
  - `MattermostKit` and `MattermostSync` unit tests
  - a simulator build of the app
- Nightly:
  - integration tests against the three server versions
  - a device build uploaded to TestFlight (internal)
- Signing assets are stored in the CI secret store, never in the repository.
