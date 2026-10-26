# MattermostKit

Mattermost REST API v4 and WebSocket client for the native iOS Mattermost app (Telegram‑iOS fork). See [Architecture](../../docs/plan/01-architecture.md) and [Sync engine](../../docs/plan/03-sync-engine.md).

- **Foundation only.** No dependencies and no resources in the library target, because Bazel will also build it inside the Telegram‑iOS tree.
- Swift 5 language mode, iOS 15 / macOS 13, async/await. Public types are `Sendable`. The code builds without warnings under `-strict-concurrency=complete` and in Swift 6 language mode.
- No Telegram code. `MattermostSync` maps these types into Postbox.

## Contents

| Path | What |
|---|---|
| `Models/` | Codable models: `User`, `Team`, `TeamMember`, `TeamUnread`, `Channel`/`ChannelType`, `ChannelMember`, `Post`, `PostMetadata` (files, embeds, reactions, emojis, images, priority), `PostList`, `PostSearchResults`, `FileInfo`, `Reaction`, `CustomEmoji`, `UserStatus`, `Preference`, `SidebarCategory`/`OrderedSidebarCategories`, `UserThread`/`ThreadList`, `ClientConfig`, `ClientLicense`, `ServerVersion`, `AppError`, `AutocompleteSuggestion`, `CommandResponse`, `OpenGraph`, plus request bodies (`PostDraft`, `PostPatch`, `ChannelDraft`, search/thread options, …). |
| `Support/JSONValue.swift` | `JSONValue`: free‑form JSON (`Post.props`, event data). Has lenient accessors and `decodeEmbedded(_:)` for JSON‑in‑a‑string fields. |
| `Support/LenientDecoding.swift` | Decoding helpers. Every model uses them. |
| `Client/` | `MattermostClient`: one typed `async` method per endpoint in the v1 API table, `MattermostError`, multipart upload, downloads. |
| `Auth/MobileSSO.swift` | Builds the SSO start URL and parses the callback (**unverified**, see below). |
| `WebSocket/` | `MattermostWebSocket` (actor), the `WebSocketTransport` protocol + `URLSessionWebSocketTransport`, `WebSocketEvent` with typed helpers, `BackoffPolicy`, `WebSocketClock`. |
| `Security/` | Certificate pinning (Phase 4G): `MattermostCertificatePins` (SPKI SHA-256 pins per host, parsed from managed configuration; SPKI read from the certificate's DER), `MattermostServerTrust` (the trust decision; `.shared` is the process-wide policy), `MattermostURLSession.current` (the default session of every client and WebSocket; `renew()` after the pins change). |
| `Managed/` | `MattermostManagedConfiguration` (Phase 4G): the managed app configuration with the Mattermost mobile app's EMM keys, server restriction matching, the extensions' app-group copy. |

### HTTP client

```swift
let client = MattermostClient(serverURL: URL(string: "https://chat.example.com")!, userAgent: "App/1.0")
_ = try await client.ping()                    // server-URL screen
let config = try await client.clientConfig()   // ?format=old; limited until logged in
let login = try await client.login(loginId: "alice", password: pw, mfaToken: code)  // adopts the Token header
let teams = try await client.teams()           // "me" is the default user ID
let page = try await client.posts(channelId: id, perPage: 60, before: oldestPostId)
```

- Requests send `X-Requested-With: XMLHttpRequest`, the configured `User-Agent` and, when a token is set, `Authorization: Bearer <token>`. Login and ping are sent without the token. Cookies are disabled, so the `MMAUTHTOKEN` cookie from login neither triggers CSRF checks nor outlives `logout()`.
- To use a personal access token: `MattermostClient(serverURL:token:)`. The token can be changed at any time with `setToken(_:)`.
- Errors are `MattermostError`: `.unauthorized(AppError?)`, `.forbidden(AppError?)`, `.notFound(AppError?)`, `.rateLimited(retryAfter:)` (`Retry-After` in seconds or as an HTTP date, falling back to `X-RateLimit-Reset`), `.server(AppError)`, `.transport(URLError)`, `.decoding(String)`, `.cancelled`.
  - Helpers: `isTransient` (network, 429, 5xx; the outgoing pipeline's retry rule), `isMFARequired`, `isSessionExpired`, `statusCode`.
  - A non‑JSON error body (e.g. a proxy's HTML page) becomes `.server` with a synthesised `AppError` that carries the status code.
- Uploads: `uploadFiles(_:channelId:progress:)` sends multipart `POST /files`. Parts go in the order `channel_id`, then `client_ids`/`files` per file. File‑backed content is streamed through a temporary file. Cancel the calling task to cancel the upload.
- Downloads: `data(for:)` / `download(_:to:)` for `MattermostResource` (`.file`, `.fileThumbnail`, `.filePreview`, `.userImage`, `.emojiImage`). `urlRequest(for:)` returns an authorised request for a custom fetcher (e.g. `Range` requests).

### WebSocket

```swift
let socket = client.makeWebSocket()            // token, user agent and token check from the client
Task { for await event in socket.events() { … event.posted / .reaction / .channelsViewed … } }
Task { for await state in socket.connectionStates() { if case .connected(let info) = state, !info.resumed { runCatchUp() } } }
await socket.connect()
try await socket.userTyping(channelId: id, parentId: rootId)   // caller throttles
```

- `events()` and `connectionStates()` return a new `AsyncStream` per call, so any number of subscribers is supported. The state stream starts with the current state.
- Frames parse into `WebSocketEvent` (`event`, `data: [String: JSONValue]`, `broadcast`, `seq`). Typed helpers:
  - `hello`, `posted` (decodes the JSON‑string `post`, `mentions`, `followers`), `editedPost`, `deletedPost`, `reaction`
  - `channelViewed` (older servers), `multipleChannelsViewed` (11.x), and `channelsViewed`, which covers both
  - `typing`, `statusChange`, `updatedThread`
  - `decodeEmbedded(_:key:)` for any other event
- Actions: `sendAction(_:data:)` waits for the `seq_reply` (with a timeout). `ping()` sends a ping action; with `pingInterval` set, the socket pings periodically and reconnects if no reply arrives.
- Reconnects use exponential backoff with jitter: `delay(n) = base·(1−jitter) + base·jitter·random`, where `base = min(max, initial·multiplier^(n−1))`. The defaults are 1 s, ×2, 60 s max and 0.5 jitter. The clock and random source are injectable.
  - Call `reconnectNow()` on foreground or when the network changes, and `disconnect()` to stop.
- Resume: reconnects send `connection_id` and `sequence_number` (the next expected `seq`). The socket tracks `seq`: replayed duplicates are dropped, and a gap triggers a reconnect so the server replays the missing events.
- **How a resume is detected (verified on 11.7.14):** on a successful resume the server sends **no `hello`**; it only replays missed events. A new connection always gets `hello` (with a new ID) first. So the socket sends a `ping` (the "handshake probe") right after connecting. If the reply arrives before any `hello`, the connection was resumed: `.connected(info)` with `info.resumed == true`. If `hello` arrives with a new ID, `resumed == false` and the sync layer must catch up.
- **Invalid tokens (verified on 11.7.14):** the server still accepts the upgrade (101), then sends nothing and ignores actions. A connection that never completes its handshake is dropped after `handshakeTimeout`. The optional `tokenVerifier` is then asked; `makeWebSocket()` wires it to `GET /users/me`. Only a 401 stops reconnecting, with `.unauthorized`. A 401 on the upgrade itself (e.g. from a proxy) is detected directly.

### Certificate pinning and managed configuration (Phase 4G)

- Every `MattermostClient` without an injected session and every default `URLSessionWebSocketTransport` go through
  `MattermostURLSession.current`, whose delegate applies `MattermostServerTrust.shared`: a host with pins is accepted
  only when the system trusts the chain **and** a certificate in it has a pinned SPKI digest; hosts without pins are
  left to the system. A refused request fails with `.transport(URLError(.serverCertificateUntrusted))` whose
  `mattermostPinMismatchHost` names the host (URLSession itself reports a refused challenge as a cancellation).
- URLSession checks a certificate when it opens a connection, so after `setPins` call `MattermostURLSession.renew()`
  (and reconnect WebSockets): kept-alive connections and resumable TLS sessions of the old session are not reused.
- `MattermostManagedConfiguration(dictionary:)` reads `UserDefaults.standard`'s `com.apple.configuration.managed`
  (keys and behaviour: [docs/release/managed-configuration.md](../../docs/release/managed-configuration.md)).

## Running the tests

```sh
cd submodules/MattermostKit
swift build && swift test           # needs a toolchain that matches the installed Xcode SDK
xcrun swift test                    # Xcode's toolchain; always works
```

On a machine where `swift` on `PATH` is an open‑source toolchain older than the Xcode SDK (e.g. swiftly 6.3.3 with Xcode 27), the build fails with `error: unknown argument: '-target-arch-variant'` and Foundation types become unresolvable. Use `xcrun swift …` / `/usr/bin/swift …` or a newer toolchain.

The suites:

- **Unit tests** (offline):
  - model decoding against realistic fixtures, including leniency (missing, `null` and mistyped fields; one bad element doesn't fail a page)
  - request building for every endpoint via a `URLProtocol` stub
  - error mapping, login token extraction, SSO URL handling, the multipart body shape, upload progress and cancellation, downloads
  - WebSocket event parsing
  - reconnect, backoff, resume and handshake logic with a fake transport and a manual clock
- **Certificate pinning** (`CertificatePinningTests`): a test CA and leaf certificates are generated for each run
  with `/usr/bin/openssl` (skipped without it; nothing is committed); SPKI digests are compared with openssl's, and
  trust decisions are evaluated on real `SecTrust`s anchored at the test CA. `ManagedConfigurationTests`: the EMM keys.
- **Captured fixtures** (`CapturedFixtureTests`): decodes the real Mattermost 11.7.14 responses in `Tests/MattermostKitTests/Fixtures/Captured`, recorded by `infra/dev-server/capture-fixtures.py`. It also asserts that lenient decoding dropped nothing (element counts match the raw JSON).
  - To refresh, re‑run the capture and copy `infra/dev-server/fixtures/{rest,ws}` there. Set `MM_FIXTURES_DIR=<dir>` to test a capture in place (e.g. from another server version).
- **Integration** (`IntegrationTests`), skipped unless `MM_INTEGRATION=1`:
  - Covers server discovery, login and bootstrap reads, a post lifecycle in the seeded `sandbox` channel (upload, post, reaction, edit, download, delete), WebSocket actions, resume with replay of a missed `posted` event, and rejection of an invalid token.
  - Environment: `MM_URL` (default `http://localhost:8065`), `MM_LOGIN_ID` (default `alice`), `MM_PASSWORD`. Without `MM_PASSWORD`, `SEED_USER_PASSWORD` is read from `infra/dev-server/.env`.

  ```sh
  MM_INTEGRATION=1 xcrun swift test --filter IntegrationTests
  ```

## Verified against a real server (Mattermost 11.7.14 Team Edition)

All models decode the captured responses without dropping elements. Also verified:
- login `Token` header
- `me` in paths
- thread paging parameters (`perPage`, `direction`, …)
- multipart upload, then attaching the file to a post
- `+1` in reaction paths
- the WebSocket `hello`/event/`seq_reply` shapes, the `ping` action, and `get_statuses`
- resume with `connection_id`/`sequence_number`, including replay of missed events and contiguous `seq` across resumes
- 11.x emits `multiple_channels_viewed` instead of `channel_viewed`
- invalid‑token behaviour on the WebSocket

## Assumptions still to verify

- **Mobile SSO** (`MobileSSO`): not checked against a real server. It assumes:
  - start URLs `/oauth/{gitlab|google|office365|openid}/mobile_login?redirect_to=…` and `/login/sso/saml?action=mobile&redirect_to=…`
  - a redirect back to the custom‑scheme `redirect_to` carrying `MMAUTHTOKEN` and `MMCSRF` query parameters
  - the minimum server version that honours a custom‑scheme `redirect_to`

  Older servers may only set the session cookie.
- **MFA:** `isMFARequired` assumes the login error IDs `mfa.validate_token.authenticate.app_error` / `ent.mfa.validate_token.authenticate.app_error`.
- **Push:** the `device_id` platform prefix for our push proxy, and the response shape of `POST /notifications/ack` (returned as raw `JSONValue`).
- **Older servers:** resume and handshake‑probe behaviour on the minimum supported version. It assumes `hello` precedes any action reply on a new connection, and that the server replies to `ping` (a FAIL reply also counts as alive/resumed).
- **Resume window:** how long a server keeps an inactive connection, i.e. after how long a reconnect stops resuming. This was only tested after a sub‑second disconnect. Resume is best‑effort on the server side, so the integration test accepts either outcome as long as the client reports it truthfully.
- **`authentication_challenge`:** auth by challenge was only partially checked. A valid challenge on an unauthenticated socket yields `hello` plus an OK reply; an invalid one makes the server close the connection. Such connections can't be resumed (the server assigns a new ID), so `.header` stays the default.
- **Rate limiting:** `Retry-After` / `X-RateLimit-Reset` handling. The dev server has rate limiting off.
- **`Range` requests** on `GET /files/{id}`.
- **Legacy `format=old`:** the server may drop it from `GET /config/client` / `GET /license/client` in a future release.

## Deviations from the plan

- `MattermostError.unauthorized/.forbidden/.notFound` carry an optional `AppError`, so login errors and MFA can be told apart. Transport errors compare by `URLError.Code`.
- `Post.props` is `[String: JSONValue]` (a JSON object) rather than a bare `JSONValue`.
- The "resumed" signal comes from the handshake probe, not just from a `hello` with the same ID; real servers send no `hello` on resume.
- Additions:
  - Endpoints: `savePreferences`, `deletePreferences`, `channel(id:)`, `channelMember`, `removeChannelMember`, `team(id:)`, `user(id:)`, `fileInfo(id:)`.
  - `MattermostClient.isTokenAccepted()` and `makeWebSocket()`.
  - `ServerVersion`, `UserCustomStatus`, and the `TeammateNameDisplay` display‑name helper.
