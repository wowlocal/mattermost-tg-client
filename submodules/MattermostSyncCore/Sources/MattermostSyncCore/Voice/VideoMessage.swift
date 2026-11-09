import Foundation

/// Relay's video messages (Telegram's round videos, Phase 5B).
///
/// Mattermost has no video-message post type, so a video message is an ordinary post with one video file (H.264 and
/// AAC in an `.mp4`, which every Mattermost client plays as a video file), marked in the post's `props` so Relay shows
/// it as Telegram's round video bubble:
///
/// ```json
/// "props": {"relay_round_video": {"v": 1, "duration": 9.4, "width": 480, "height": 480, "thumb": "<base64>"}}
/// ```
///
/// `duration` is in seconds (Telegram's `.Video(duration:)`, fractional); `width` and `height` are the video's pixel
/// size (Telegram's iOS recorder makes 400 × 400 or 480 × 480 depending on the camera). `thumb` is the first frame as
/// Telegram's stripped thumbnail (`TinyThumbnailEncoder`, about 40 × 40 pixels and 100–300 bytes), which Telegram
/// shows blurred until the video is downloaded. Readers accept any version that has a duration; a marker without a
/// usable size gets the recorder's, and an unusable thumbnail is dropped.
public struct VideoMessageMarker: Equatable, Sendable {
    /// The key in `props`.
    public static let propsKey = "relay_round_video"
    /// The marker version this build writes.
    public static let currentVersion = 1
    /// Durations above this are not believed (an hour; Telegram's recorder stops at one minute).
    public static let maxDuration: Double = 60 * 60
    /// The size of Telegram's round videos, for a marker without one.
    public static let defaultSide = 400
    /// The largest side believed.
    public static let maxSide = 4096
    /// The largest thumbnail accepted; a larger one is dropped rather than decoded.
    public static let maxThumbnailBytes = 4096

    /// Seconds.
    public var duration: Double
    public var width: Int
    public var height: Int
    /// Telegram's stripped thumbnail of the first frame (`immediateThumbnailData`), when the sender made one.
    public var thumbnail: Data?

    public init(duration: Double, width: Int, height: Int, thumbnail: Data? = nil) {
        self.duration = duration.isFinite ? max(0, min(duration, VideoMessageMarker.maxDuration)) : 0
        if width > 0 && height > 0 && width <= VideoMessageMarker.maxSide && height <= VideoMessageMarker.maxSide {
            self.width = width
            self.height = height
        } else {
            self.width = VideoMessageMarker.defaultSide
            self.height = VideoMessageMarker.defaultSide
        }
        self.thumbnail = thumbnail.flatMap { VideoMessageMarker.isUsableThumbnail($0) ? $0 : nil }
    }

    /// A stripped thumbnail Telegram can decode: version 1, a size, some scan data, not oversized.
    public static func isUsableThumbnail(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(3))
        return data.count > 3 && data.count <= VideoMessageMarker.maxThumbnailBytes && bytes[0] == 1 && bytes[1] > 0 && bytes[2] > 0
    }

    /// The marker from the value of `props["relay_round_video"]` as JSON (`JSONSerialization` types: a dictionary with
    /// numbers and strings). Nil when there is no marker or it has no usable duration.
    public init?(propsValue: Any?) {
        guard let object = propsValue as? [String: Any] else {
            return nil
        }
        guard let duration = MarkerNumber.value(object["duration"]), duration.isFinite, duration >= 0 else {
            return nil
        }
        let width = MarkerNumber.value(object["width"]).flatMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil } ?? 0
        let height = MarkerNumber.value(object["height"]).flatMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil } ?? 0
        let thumbnail = (object["thumb"] as? String).flatMap { Data(base64Encoded: $0) }
        self.init(duration: duration, width: width, height: height, thumbnail: thumbnail)
    }

    /// The value to put at `props["relay_round_video"]` (`JSONSerialization` types). The duration keeps tenths.
    public var propsValue: [String: Any] {
        var value: [String: Any] = [
            "v": VideoMessageMarker.currentVersion,
            "duration": (self.duration * 10).rounded() / 10,
            "width": self.width,
            "height": self.height,
        ]
        if let thumbnail = self.thumbnail {
            value["thumb"] = thumbnail.base64EncodedString()
        }
        return value
    }
}

/// The file of a video message.
public enum VideoMessageFile {
    /// What Relay uploads: Telegram's recording, H.264 and AAC in an MPEG-4 file.
    public static let mimeType = "video/mp4"
    public static let fileExtension = "mp4"
    /// File extensions the media tabs search for when looking for video messages (the marker decides).
    public static let searchExtensions = ["mp4", "mov", "m4v"]

    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm"]

    /// Whether a file is a video, by its MIME type or (when the server didn't know one) its name.
    public static func isVideo(name: String, mimeType: String) -> Bool {
        if mimeType.lowercased().hasPrefix("video/") {
            return true
        }
        let ext = (name as NSString).pathExtension.lowercased()
        return videoExtensions.contains(ext)
    }

    /// Whether a post shows as a video message: it has the marker and exactly one file, which is a video. Every other
    /// video file stays a file.
    public static func isVideoMessagePost(marker: VideoMessageMarker?, files: [(name: String, mimeType: String)]) -> Bool {
        guard marker != nil, files.count == 1, let file = files.first else {
            return false
        }
        return isVideo(name: file.name, mimeType: file.mimeType)
    }

    /// A readable file name for a recording: `"<prefix> 2026-11-09 14.05.mp4"` in the sender's time zone (the prefix,
    /// "Video message", is localized by the app).
    public static func fileName(prefix: String, date: Date, timeZone: TimeZone = .current) -> String {
        return MediaMessageFileName.make(prefix: prefix, fallback: "Video message", date: date, timeZone: timeZone, fileExtension: fileExtension)
    }
}

/// File names of recordings (voice and video messages).
enum MediaMessageFileName {
    /// `"<prefix> 2026-10-27 14.05.<ext>"`; the prefix loses characters that file systems or URLs dislike.
    static func make(prefix: String, fallback: String, date: Date, timeZone: TimeZone, fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        var cleaned = prefix.components(separatedBy: forbidden).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            cleaned = fallback
        }
        return "\(cleaned) \(formatter.string(from: date)).\(fileExtension)"
    }
}

/// Numbers in a marker: JSON numbers or numeric strings, never booleans.
enum MarkerNumber {
    static func value(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            // JSONSerialization gives booleans as NSNumber too; a boolean is not a number here.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            return number.doubleValue
        case let int as Int:
            return Double(int)
        case let double as Double:
            return double
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }
}
