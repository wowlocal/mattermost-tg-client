# LiveKit binary dependencies

`MODULE.bazel` fetches official release archives with pinned SHA-256 checksums:

| Dependency | Release | Import |
| --- | --- | --- |
| LiveKitWebRTC | [150.7871.04](https://github.com/livekit/webrtc-xcframework/releases/tag/150.7871.04) | Dynamic XCFramework |
| RustLiveKitFFI | [0.13.1](https://github.com/livekit/livekit-uniffi-xcframework/releases/tag/0.13.1) | Static XCFramework |

SwiftPM uses the same versions through `third-party/livekit-sdk/Package.swift`.
LiveKit's Objective-C WebRTC symbols use the `LK` prefix and its Swift module
is `LiveKitWebRTC`, allowing it to coexist with Telegram's existing WebRTC.

`third-party/livekit-sdk` is the source snapshot of
[client-sdk-swift 2.19.0](https://github.com/livekit/client-sdk-swift/releases/tag/2.19.0),
with a local Bazel BUILD and exact binary package pins. Its LICENSE and source
notices are retained. `third-party/livekit-ffi/Sources` and its LICENSE come
from [livekit-ffi-xcframework 0.13.1](https://github.com/livekit/livekit-ffi-xcframework/tree/0.13.1).
Keep generated Swift bindings and their matching Rust binary version together.
