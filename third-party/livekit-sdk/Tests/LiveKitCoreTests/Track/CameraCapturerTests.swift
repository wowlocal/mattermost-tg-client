/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.tags(.media))
struct CameraCapturerTests {
    /// New options for a stopped camera (a muted camera track) apply at its next start. Starting it here left the
    /// capturer running after its track stopped, and WebRTC asserted when the capturer was deallocated.
    @Test func setOptionsOnStoppedCapturerKeepsItStopped() async throws {
        let track = await LocalVideoTrack.createCameraTrack(options: CameraCaptureOptions(dimensions: .h360_169))
        let capturer = try #require(track.capturer as? CameraCapturer)

        let didStart = try await capturer.set(options: CameraCaptureOptions(dimensions: .h720_169, fps: 15))

        #expect(!didStart)
        #expect(capturer.captureState == .stopped)
        #expect(track.trackState == .stopped)
        #expect(capturer.options.dimensions == .h720_169)
        #expect(capturer.options.fps == 15)
    }
}
