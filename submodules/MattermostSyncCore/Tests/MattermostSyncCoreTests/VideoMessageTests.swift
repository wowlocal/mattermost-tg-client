import XCTest
@testable import MattermostSyncCore

final class VideoMessageMarkerTests: XCTestCase {
    private func json(_ text: String) -> Any? {
        return try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    func testRoundTripThroughJSON() throws {
        let marker = VideoMessageMarker(duration: 9.43, width: 400, height: 400)
        let props: [String: Any] = [VideoMessageMarker.propsKey: marker.propsValue]
        let data = try JSONSerialization.data(withJSONObject: props)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let object = try XCTUnwrap(decoded[VideoMessageMarker.propsKey] as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["duration"] as? Double, 9.4)
        XCTAssertEqual(object["width"] as? Int, 400)
        XCTAssertEqual(object["height"] as? Int, 400)
        let read = try XCTUnwrap(VideoMessageMarker(propsValue: decoded[VideoMessageMarker.propsKey]))
        XCTAssertEqual(read.duration, 9.4, accuracy: 0.0001)
        XCTAssertEqual(read.width, 400)
        XCTAssertEqual(read.height, 400)
        XCTAssertEqual(VideoMessageMarker.propsKey, "relay_round_video")
    }

    func testDecodesWhatTheServerReturned() {
        // The server reorders keys and may turn whole numbers into floats.
        let marker = VideoMessageMarker(propsValue: json(#"{"height": 400.0, "duration": 5, "v": 1, "width": 400.0}"#))
        XCTAssertEqual(marker?.duration, 5)
        XCTAssertEqual(marker?.width, 400)
        XCTAssertEqual(marker?.height, 400)
    }

    func testDurationForms() {
        XCTAssertEqual(VideoMessageMarker(propsValue: json(#"{"duration": 7.6}"#))?.duration, 7.6)
        XCTAssertEqual(VideoMessageMarker(propsValue: json(#"{"duration": "3"}"#))?.duration, 3)
        XCTAssertEqual(VideoMessageMarker(propsValue: json(#"{"duration": 0, "v": 9}"#))?.duration, 0)
        XCTAssertEqual(VideoMessageMarker(propsValue: json(#"{"duration": 999999999}"#))?.duration, VideoMessageMarker.maxDuration)
        XCTAssertNil(VideoMessageMarker(propsValue: json(#"{"duration": -1}"#)))
        XCTAssertNil(VideoMessageMarker(propsValue: json(#"{"duration": true}"#)))
        XCTAssertNil(VideoMessageMarker(propsValue: json(#"{"width": 400, "height": 400}"#)))
        XCTAssertNil(VideoMessageMarker(propsValue: json(#"{"duration": "soon"}"#)))
        XCTAssertNil(VideoMessageMarker(propsValue: "relay_round_video"))
        XCTAssertNil(VideoMessageMarker(propsValue: nil))
        XCTAssertEqual(VideoMessageMarker(duration: .nan, width: 400, height: 400).duration, 0)
    }

    func testMissingOrBadSizeGetsTheRecordersSize() {
        for text in [#"{"duration": 4}"#, #"{"duration": 4, "width": 0, "height": 400}"#, #"{"duration": 4, "width": 400}"#,
                     #"{"duration": 4, "width": -5, "height": -5}"#, #"{"duration": 4, "width": 99999, "height": 400}"#,
                     #"{"duration": 4, "width": true, "height": true}"#, #"{"duration": 4, "width": "wide", "height": 400}"#] {
            let marker = VideoMessageMarker(propsValue: json(text))
            XCTAssertEqual(marker?.width, VideoMessageMarker.defaultSide, text)
            XCTAssertEqual(marker?.height, VideoMessageMarker.defaultSide, text)
        }
        let marker = VideoMessageMarker(propsValue: json(#"{"duration": 4, "width": "240", "height": 239.6}"#))
        XCTAssertEqual(marker?.width, 240)
        XCTAssertEqual(marker?.height, 240)
    }

    func testThumbnail() throws {
        let rgba = [UInt8](repeating: 90, count: 40 * 40 * 4)
        let thumbnail = try XCTUnwrap(TinyThumbnailEncoder.encode(rgba: rgba, width: 40, height: 40))
        let marker = VideoMessageMarker(duration: 3, width: 480, height: 480, thumbnail: thumbnail)
        let data = try JSONSerialization.data(withJSONObject: marker.propsValue)
        let read = try XCTUnwrap(VideoMessageMarker(propsValue: try JSONSerialization.jsonObject(with: data)))
        XCTAssertEqual(read.thumbnail, thumbnail)
        XCTAssertEqual(read, marker)
        // Not Telegram's format, oversized, not base64, or absent: no thumbnail, the marker still counts.
        let notStripped = Data([0xff, 0xd8, 0xff, 0xe0]).base64EncodedString()
        let oversized = (Data([1, 40, 40]) + Data(repeating: 7, count: VideoMessageMarker.maxThumbnailBytes)).base64EncodedString()
        for thumb in [notStripped, oversized, "not base64!", Data([1, 0, 40, 9]).base64EncodedString(), Data([1, 40, 40]).base64EncodedString()] {
            let marker = VideoMessageMarker(propsValue: ["duration": 3, "thumb": thumb])
            XCTAssertNotNil(marker)
            XCTAssertNil(marker?.thumbnail, thumb)
        }
        XCTAssertNil(VideoMessageMarker(propsValue: ["duration": 3, "thumb": 12])?.thumbnail)
        XCTAssertNil(VideoMessageMarker(duration: 3, width: 400, height: 400).propsValue["thumb"])
    }

    func testVideoMessagePostDetection() {
        let marker = VideoMessageMarker(duration: 3, width: 400, height: 400)
        XCTAssertTrue(VideoMessageFile.isVideoMessagePost(marker: marker, files: [("Video message 2026-11-09 14.05.mp4", "video/mp4")]))
        XCTAssertTrue(VideoMessageFile.isVideoMessagePost(marker: marker, files: [("clip.mov", "")]))
        XCTAssertTrue(VideoMessageFile.isVideoMessagePost(marker: marker, files: [("recording", "video/quicktime")]))
        // Without the marker, a video file is a file.
        XCTAssertFalse(VideoMessageFile.isVideoMessagePost(marker: nil, files: [("movie.mp4", "video/mp4")]))
        // The marker on anything but a single video file is ignored.
        XCTAssertFalse(VideoMessageFile.isVideoMessagePost(marker: marker, files: [("photo.jpg", "image/jpeg")]))
        XCTAssertFalse(VideoMessageFile.isVideoMessagePost(marker: marker, files: [("voice.m4a", "audio/mp4")]))
        XCTAssertFalse(VideoMessageFile.isVideoMessagePost(marker: marker, files: [("a.mp4", "video/mp4"), ("b.mp4", "video/mp4")]))
        XCTAssertFalse(VideoMessageFile.isVideoMessagePost(marker: marker, files: []))
        XCTAssertFalse(VideoMessageFile.isVideo(name: "voice.m4a", mimeType: "audio/mp4"))
    }

    func testFileName() {
        let date = Date(timeIntervalSince1970: 1_794_233_100) // 2026-11-09 14:05 UTC
        XCTAssertEqual(VideoMessageFile.fileName(prefix: "Video message", date: date, timeZone: TimeZone(identifier: "UTC")!), "Video message 2026-11-09 14.05.mp4")
        XCTAssertEqual(VideoMessageFile.fileName(prefix: "Video message", date: date, timeZone: TimeZone(identifier: "Europe/Berlin")!), "Video message 2026-11-09 15.05.mp4")
        XCTAssertEqual(VideoMessageFile.fileName(prefix: "Video/nachricht:", date: date, timeZone: TimeZone(identifier: "UTC")!), "Video nachricht 2026-11-09 14.05.mp4")
        XCTAssertEqual(VideoMessageFile.fileName(prefix: "  ", date: date, timeZone: TimeZone(identifier: "UTC")!), "Video message 2026-11-09 14.05.mp4")
    }
}
