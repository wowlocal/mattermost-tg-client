# Relay group calls

Relay uses self-hosted LiveKit for group audio and screen sharing in Mattermost
conversations. Open a conversation and press the phone button to start or join
its room. Other members see a call announcement in the channel and join with
the same phone button. The caller can end the call for everyone; everyone can
mute, share their screen and leave. Leaving preserves the call for others.

The call window can stay open while the macOS client is used. On iOS, **Back
to chat** keeps the session connected; pressing the phone button opens it again.
Only one call is presented per app process. The current feature uses channel
announcements, without incoming CallKit ringing, recordings or a browser client.

## Components

| Component | Location |
| --- | --- |
| Shared API client and native SwiftUI call interface | `submodules/RelayCalls` |
| Mattermost account/channel resolution | `submodules/MattermostSync/Sources/Account/MattermostCalls.swift` |
| iOS presentation | `submodules/TelegramUI/Sources/MattermostCalls.swift` |
| iOS ReplayKit broadcast extension | `Telegram/RelayBroadcast` |
| Server plugin | `infra/relay-calls` |
| macOS presentation | `relay-mac/packages/RelayUI/Sources/RelayUI/RelayCallWindow.swift` |

The `relay-mac` fork consumes this repository through its `telegram-ios`
submodule. Call credentials use the existing Mattermost session and pinned
URLSession. Neither client contains the LiveKit API secret. Channel membership
is checked by the plugin before it issues room-scoped join tokens. Media
permits microphone and screen tracks; camera publishing is not enabled.

WebRTC transport encryption is enabled. Participant end-to-end encryption is
not configured; do not display Telegram encryption fingerprints for these calls.
These are Relay/Mattermost calls, separate from Telegram's call network.

## Apple clients

LiveKit Swift SDK 2.19.0 is vendored in `third-party/livekit-sdk`; its Bazel
BUILD is maintained here. SwiftPM uses the SDK package directly. WebRTC
150.7871.04 and LiveKit FFI 0.13.1 are pinned in both SwiftPM and Bazel.
Bazel downloads the two XCFrameworks from official release archives and checks
their SHA-256 values in `MODULE.bazel`. No manually copied binary directories
are required for a fresh checkout.

On macOS, the sharing button offers displays and windows. System microphone
and screen recording permissions are required. On iOS, the app and the
`.BroadcastUpload` extension must share `group.<bundle-id>`; distribution
profiles must include that app group. The main Info.plist identifies the
ReplayKit extension and its app group. Full-device broadcast needs testing on
a physical device; Simulator compilation does not establish screen capture
or background microphone behavior on a phone.

iOS explicitly uses ReplayKit Broadcast Capture on every supported version,
including iOS 27. The SDK otherwise switches to in-process ScreenCaptureKit on
iOS 27, which has different entitlement and background-mode requirements.
This keeps Relay's capture path consistent with its embedded broadcast
extension and app-group profiles; see the SDK's
[capture configuration guide](../third-party/livekit-sdk/Docs/ios-screen-sharing.md#opting-out).

## Server

Build and test the Mattermost plugin:

```sh
cd infra/relay-calls
go test -race ./server
./build.sh
```

The build produces an installable Mattermost tarball with Linux amd64/arm64
executables. Deployment, media ports, generated secret locations, TLS renewal
and rollback are documented in the infrastructure repository at
`services/relay-calls/README.md`.

Plugin routes below are relative to `/plugins/org.relaychat.calls`:

| Method and route | Behavior |
| --- | --- |
| `GET /config` | Authenticated feature availability and room limit |
| `GET /channels/<id>` | Current call or `null` |
| `POST /channels/<id>/join` | Create/reuse room and issue a device token |
| `POST /channels/<id>/end` | End the specified call for authorized users |
| `POST /webhook` | Verify LiveKit signature and update room state |

Join/end accept optional `call_id`; a stale value returns `409`. Join tokens
use unique device identities so a second device does not evict the first.
The pilot server limits a room to 25 devices. Empty rooms expire; channel
departure disconnects that member's devices. Room state lives in Mattermost
plugin KV. The plugin serializes room operations for the current single-server
deployment; a multi-node Mattermost deployment requires distributed locking.

## Validation

After each build, check the freshly packaged IPA before installing it:

```sh
python3 tools/relay-calls-bundle-check.py bazel-bin/Telegram/Telegram.ipa
```

Then install and launch that IPA on a dedicated simulator. Compilation alone
does not validate extension metadata or embedded dynamic libraries. Integration
testing found that a missing broadcast display name prevented installation,
and importing RustLiveKitFFI as a static framework omitted its runtime binary
and caused a dyld launch failure. Both dependencies are dynamic frameworks.

`swift test` in `submodules/RelayCalls` checks account authorization, URL path
prefixes, invalid server responses, channel traversal and stale call errors.
The Go tests check member access, room reuse, token grants, end permissions,
webhook signatures, RPC-safe events and revocation across devices.

`infra/relay-calls/test-media.py` sends generated PCM audio and screen frames
between three SDK participants. Run it inside Docker so the native Python
interpreter does not open WebRTC sockets on the operator's Mac. Pin Python
dependencies to `livekit==1.2.1 livekit-api==1.2.2` for the tested environment.
For local LiveKit dev mode, set `RELAY_TEST_URL`; the public dev key is used.
For an authenticated deployment, set `RELAY_TEST_CREDENTIALS_STDIN=1` and pass
one JSON line with `url` and three `tokens` through stdin. Tokens must never
be put in command-line arguments, logs or committed files. Setting
`RELAY_TEST_RELAY_ONLY=1` requires TURN rather than direct ICE transport.

### Native integration run on 2026-11-07

VMPal controlled a real Mac mini, with a native macOS client plus dedicated
iPhone 17 Pro and iPad Pro 11-inch simulators running iOS 26.5. The first
scenario used `relaytester` on all three clients with separate device identities.
The final source-built IPA used three distinct members: `relaytester` on macOS,
`alex.rivera` on iPhone and `sam.lee` on iPad, in a separate private channel.
The gaming Mac ran no client builds or simulators during this run. Builds on
the mini used limited concurrency and low CPU priority.

- Joined all three clients through the phone controls; the UI and server both
  showed three participants with unmuted microphone publications.
- Thirteen XCTest checks passed: seven in the same-account scenario (mute/unmute
  on each simulator, screen presentation on each simulator, iPhone leave, and
  remote end-of-call on both receivers), then six against the freshly built
  IPA (distinct member names/end permissions, mute/unmute and remote end-of-call
  on each simulator).
- Shared a macOS browser window containing the test clock and animated bar.
  Both receivers rendered the changing content. The server reported an
  unmuted 1920×1148 screen-video track in addition to the three microphones.
- Leaving the iPhone reduced the room to two participants; rejoining restored
  three. Stopping sharing removed the video publication while audio stayed
  connected. Ending from the creator's macOS UI disconnected both receivers
  and cleared the room. The test channel was archived.

The initial iOS bundle needed the missing broadcast display name and matching
Simulator FFI framework repaired after installation and launch exposed those
defects. Both fixes were then applied to Bazel packaging. A fresh Simulator IPA
from `a0ea749c9b` passed the bundle checker, installed and launched on both
simulators, and passed the four distinct-member checks without bundle repairs.
A physical-device IPA from the same revision also built, passed the bundle
checker and passed strict recursive signature verification. The required
broadcast app ID, app group and development provisioning profile were created.
Physical iPad installation and testing were deferred at the user's request.

The final macOS rebuild passed Xcode compilation and strict recursive signature
verification. Disabling automatic `NSHostingController` sizing keeps its
720×620 call content size stable when participants and shared screens update;
all controls remain visible. Microphone mute/unmute, source selection, sharing
and end-for-everyone were exercised in that build. Screen capture succeeded
without a stale error message. The iPhone rendered that final Mac's shared
window; both freshly built iOS receivers had also rendered the window during
the earlier multiuser run. Ending from macOS passed the final two receiver
checks and cleared the server call state.

A receive-only SDK probe joined that final native call for 15 seconds and
decoded 1,500 audio frames / 720,000 samples from each of the three clients,
with nonzero signal levels. It also decoded 217 screen frames at 1920×1148;
15 sampled frame checksums differed. The probe published nothing and retained
only counts, dimensions and signal statistics, then disconnected and logged
out. This verifies media delivery; it is not a listening-quality assessment.
Both private test channels were archived. The test Mac app and dedicated
simulators were stopped, the six simulator sessions paused for testing were
booted again, and VMPal input ownership was released.

The reusable test project and fixture are in
[`tools/relay-calls-ui-tests`](../tools/relay-calls-ui-tests/README.md).
Tests retain screenshots in their `.xcresult` bundles on the mini. These
checks do not establish audible quality, hardware audio routing, physical
ReplayKit broadcasting or background microphone behavior.

### Direct installations and GitHub drafts on 2026-11-07

An optimized iOS Release build, **1.0.0 (31900)** from `10ba1db2e1`, passed
the complete release audit, bundle checks and strict signature verification.
All five embedded development profiles cover the three intended devices.
The build was installed in place on two physical iPhones and one iPad. One
iPhone launch was verified; the other was locked, and the iPad's launch was
deferred during an active call. These installations do not establish physical
ReplayKit or hardware audio quality.

The macOS Release build, **1.0.3 (38)** from `8c8b689`, is Developer ID signed,
notarized, stapled and accepted by Gatekeeper. It was installed on the MacBook
and Mac mini, with launch verified on the mini. Relay was left closed on the
gaming MacBook. Existing application bundles were retained as local backups.
All client compilation ran on the mini.

GitHub drafts contain the installable archives and SHA-256 checksums:
`relay-1.0.0-31900` in
[mattermost-tg-client releases](https://github.com/wowlocal/mattermost-tg-client/releases)
and `relay-mac-1.0.3-38` in
[relay-mac releases](https://github.com/wowlocal/relay-mac/releases).
The iOS IPA uses development signing for registered devices. Both releases
remain drafts; the macOS automatic-update feed and TestFlight were not changed.
