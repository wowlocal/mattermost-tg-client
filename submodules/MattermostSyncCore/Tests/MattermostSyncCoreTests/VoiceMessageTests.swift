import XCTest
@testable import MattermostSyncCore

final class VoiceMessageMarkerTests: XCTestCase {
    private func json(_ text: String) -> Any? {
        return try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    func testRoundTripThroughJSON() throws {
        let waveform = VoiceWaveform.pack((0 ..< 100).map { UInt8($0 % 32) })
        let marker = VoiceMessageMarker(duration: 12, waveform: waveform)
        let props: [String: Any] = [VoiceMessageMarker.propsKey: marker.propsValue]
        let data = try JSONSerialization.data(withJSONObject: props)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(VoiceMessageMarker(propsValue: decoded[VoiceMessageMarker.propsKey]), marker)
        let object = try XCTUnwrap(decoded[VoiceMessageMarker.propsKey] as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["duration"] as? Int, 12)
        XCTAssertEqual(object["waveform"] as? String, waveform.base64EncodedString())
        XCTAssertEqual(waveform.count, 63)
    }

    func testDecodesWhatTheServerReturned() {
        // `props` of a post created through REST on 11.7 (the server reorders keys, keeps the values).
        let value = json(#"{"duration": 5, "v": 1, "waveform": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+"}"#)
        let marker = VoiceMessageMarker(propsValue: value)
        XCTAssertEqual(marker?.duration, 5)
        XCTAssertEqual(marker?.waveform, Data(0 ..< 63))
    }

    func testDurationForms() {
        XCTAssertEqual(VoiceMessageMarker(propsValue: json(#"{"duration": 7.6}"#))?.duration, 8)
        XCTAssertEqual(VoiceMessageMarker(propsValue: json(#"{"duration": "3"}"#))?.duration, 3)
        XCTAssertEqual(VoiceMessageMarker(propsValue: json(#"{"duration": 0, "v": 9}"#))?.duration, 0)
        XCTAssertEqual(VoiceMessageMarker(propsValue: json(#"{"duration": 999999999}"#))?.duration, VoiceMessageMarker.maxDuration)
        XCTAssertNil(VoiceMessageMarker(propsValue: json(#"{"duration": -1}"#)))
        XCTAssertNil(VoiceMessageMarker(propsValue: json(#"{"duration": true}"#)))
        XCTAssertNil(VoiceMessageMarker(propsValue: json(#"{"waveform": "AAAA"}"#)))
        XCTAssertNil(VoiceMessageMarker(propsValue: json(#"{"duration": "soon"}"#)))
        XCTAssertNil(VoiceMessageMarker(propsValue: "relay_voice"))
        XCTAssertNil(VoiceMessageMarker(propsValue: nil))
    }

    func testBadWaveformsAreDropped() {
        XCTAssertNil(VoiceMessageMarker(propsValue: json(#"{"duration": 4, "waveform": "not base64!"}"#))?.waveform)
        XCTAssertNil(VoiceMessageMarker(propsValue: json(#"{"duration": 4, "waveform": ""}"#))?.waveform)
        XCTAssertNil(VoiceMessageMarker(propsValue: json(#"{"duration": 4, "waveform": 12}"#))?.waveform)
        let tooLong = Data(repeating: 0xff, count: VoiceMessageMarker.maxWaveformBytes + 1).base64EncodedString()
        XCTAssertNil(VoiceMessageMarker(propsValue: json("{\"duration\": 4, \"waveform\": \"\(tooLong)\"}"))?.waveform)
        XCTAssertEqual(VoiceMessageMarker(propsValue: json(#"{"duration": 4, "waveform": 12}"#))?.duration, 4)
        XCTAssertNil(VoiceMessageMarker(duration: 3, waveform: nil).propsValue["waveform"])
    }

    func testVoicePostDetection() {
        let marker = VoiceMessageMarker(duration: 3, waveform: nil)
        XCTAssertTrue(VoiceMessageFile.isVoicePost(marker: marker, files: [("Voice message 2026-10-27 14.05.m4a", "audio/mp4")]))
        XCTAssertTrue(VoiceMessageFile.isVoicePost(marker: marker, files: [("clip.ogg", "")]))
        XCTAssertTrue(VoiceMessageFile.isVoicePost(marker: marker, files: [("recording", "audio/x-m4a")]))
        // Without the marker, an audio file is a file (V1).
        XCTAssertFalse(VoiceMessageFile.isVoicePost(marker: nil, files: [("song.m4a", "audio/mp4")]))
        // The marker on anything but a single audio file is ignored.
        XCTAssertFalse(VoiceMessageFile.isVoicePost(marker: marker, files: [("photo.jpg", "image/jpeg")]))
        XCTAssertFalse(VoiceMessageFile.isVoicePost(marker: marker, files: [("a.m4a", "audio/mp4"), ("b.m4a", "audio/mp4")]))
        XCTAssertFalse(VoiceMessageFile.isVoicePost(marker: marker, files: []))
        XCTAssertFalse(VoiceMessageFile.isAudio(name: "movie.mp4", mimeType: "video/mp4"))
    }

    func testFileName() {
        let date = Date(timeIntervalSince1970: 1_793_109_900) // 2026-10-27 14:05 UTC
        XCTAssertEqual(VoiceMessageFile.fileName(prefix: "Voice message", date: date, timeZone: TimeZone(identifier: "UTC")!), "Voice message 2026-10-27 14.05.m4a")
        XCTAssertEqual(VoiceMessageFile.fileName(prefix: "Voice message", date: date, timeZone: TimeZone(identifier: "Europe/Berlin")!), "Voice message 2026-10-27 15.05.m4a")
        XCTAssertEqual(VoiceMessageFile.fileName(prefix: "Sprach/nachricht:", date: date, timeZone: TimeZone(identifier: "UTC")!), "Sprach nachricht 2026-10-27 14.05.m4a")
        XCTAssertEqual(VoiceMessageFile.fileName(prefix: "  ", date: date, timeZone: TimeZone(identifier: "UTC")!), "Voice message 2026-10-27 14.05.m4a")
    }
}

final class VoiceWaveformTests: XCTestCase {
    /// Telegram's `AudioWaveform.makeBitstream` packing (an Int32 OR-ed in at each byte offset), as a reference.
    private func telegramBitstream(_ samples: [UInt8]) -> Data {
        let length = (samples.count * 5) / 8 + ((samples.count * 5) % 8 == 0 ? 0 : 1)
        var bytes = [UInt8](repeating: 0, count: length + 4)
        for (index, sample) in samples.enumerated() {
            let value = Int32(min(31, sample)) << Int32((index * 5) % 8)
            let offset = (index * 5) / 8
            for byte in 0 ..< 4 {
                bytes[offset + byte] |= UInt8(truncatingIfNeeded: value >> Int32(byte * 8))
            }
        }
        return Data(bytes.prefix(length))
    }

    func testPackingMatchesTelegram() {
        var generator = SeededGenerator(seed: 5)
        for _ in 0 ..< 50 {
            let samples = (0 ..< 100).map { _ in UInt8(generator.next() % 32) }
            XCTAssertEqual(VoiceWaveform.pack(samples), telegramBitstream(samples))
        }
        XCTAssertEqual(VoiceWaveform.pack([31, 0, 31]), Data([0x1f, 0x7c]))
    }

    func testRoundTrip() {
        let samples = (0 ..< 100).map { UInt8(($0 * 7) % 32) }
        let packed = VoiceWaveform.pack(samples)
        XCTAssertEqual(packed.count, 63)
        XCTAssertEqual(VoiceWaveform.unpack(packed), samples)
        // Values above 31 are clamped.
        XCTAssertEqual(VoiceWaveform.unpack(VoiceWaveform.pack([200, 3])), [31, 3, 0])
        XCTAssertEqual(VoiceWaveform.unpack(Data()), [])
    }

    func testFromPCM() {
        XCTAssertEqual(VoiceWaveform.fromPCM([]), [UInt8](repeating: 0, count: 100))
        XCTAssertEqual(VoiceWaveform.fromPCM([Int16](repeating: 0, count: 48_000)), [UInt8](repeating: 0, count: 100))
        // Quiet first half, loud second half: low then full bars.
        var pcm: [Int16] = []
        for index in 0 ..< 96_000 {
            let amplitude: Double = index < 48_000 ? 600 : 20_000
            pcm.append(Int16(amplitude * sin(Double(index) * 2 * .pi * 440 / 48_000)))
        }
        let waveform = VoiceWaveform.fromPCM(pcm)
        XCTAssertEqual(waveform.count, 100)
        XCTAssertTrue(waveform[0 ..< 50].allSatisfy { $0 <= 2 })
        XCTAssertTrue(waveform[50 ..< 100].allSatisfy { $0 >= 30 })
        XCTAssertEqual(VoiceWaveform.fromPCM([Int16.min, Int16.max]).first, 31)
        // Short input: every sample lands in some part, the others stay 0.
        XCTAssertEqual(VoiceWaveform.fromPCM([30_000]).filter { $0 > 0 }.count, 1)
    }
}
