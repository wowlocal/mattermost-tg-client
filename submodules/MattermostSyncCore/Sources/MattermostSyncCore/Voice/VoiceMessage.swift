import Foundation

/// Relay's voice messages (Phase 5A, decision V1).
///
/// Mattermost has no voice-message post type (11.7 and 12.0), so a voice message is an ordinary post with one
/// audio file (AAC in an `.m4a`, which every Mattermost client can play as a file), marked in the post's `props`
/// so Relay shows it as a voice bubble:
///
/// ```json
/// "props": {"relay_voice": {"v": 1, "duration": 12, "waveform": "<base64>"}}
/// ```
///
/// `duration` is in whole seconds (Telegram's `.Audio(duration:)`); `waveform` is Telegram's packed waveform
/// (`VoiceWaveform`: 100 samples of 5 bits, 63 bytes) in base64. The server keeps custom `props` of a regular
/// user's post (11.7 checked with REST; 12.0's `SanitizeProps` removes only a fixed list of keys).
public struct VoiceMessageMarker: Equatable, Sendable {
    /// The key in `props`.
    public static let propsKey = "relay_voice"
    /// The marker version this build writes. Readers accept any version that has a duration.
    public static let currentVersion = 1
    /// The longest waveform accepted (256 samples): a larger value is ignored rather than drawn.
    public static let maxWaveformBytes = 160
    /// Durations above this are not believed (a day).
    public static let maxDuration = 24 * 60 * 60

    /// Seconds.
    public var duration: Int
    /// Telegram's packed waveform (`VoiceWaveform.pack`); nil when the post has none (it is computed locally).
    public var waveform: Data?

    public init(duration: Int, waveform: Data?) {
        self.duration = max(0, min(duration, VoiceMessageMarker.maxDuration))
        if let waveform = waveform, !waveform.isEmpty, waveform.count <= VoiceMessageMarker.maxWaveformBytes {
            self.waveform = waveform
        } else {
            self.waveform = nil
        }
    }

    /// The marker from the value of `props["relay_voice"]` as JSON (`JSONSerialization` types: a dictionary with
    /// numbers and strings). Nil when there is no marker or it has no usable duration.
    public init?(propsValue: Any?) {
        guard let object = propsValue as? [String: Any] else {
            return nil
        }
        guard let duration = VoiceMessageMarker.number(object["duration"]), duration.isFinite, duration >= 0 else {
            return nil
        }
        var waveform: Data?
        if let string = object["waveform"] as? String, let data = Data(base64Encoded: string) {
            waveform = data
        }
        self.init(duration: Int(min(duration.rounded(), Double(VoiceMessageMarker.maxDuration))), waveform: waveform)
    }

    /// The value to put at `props["relay_voice"]` (`JSONSerialization` types).
    public var propsValue: [String: Any] {
        var value: [String: Any] = [
            "v": VoiceMessageMarker.currentVersion,
            "duration": self.duration,
        ]
        if let waveform = self.waveform {
            value["waveform"] = waveform.base64EncodedString()
        }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            // JSONSerialization gives booleans as NSNumber too; a boolean is not a duration.
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

/// The file of a voice message.
public enum VoiceMessageFile {
    /// What Relay uploads: AAC in an MPEG-4 audio file (V1).
    public static let mimeType = "audio/mp4"
    public static let fileExtension = "m4a"
    /// File extensions the media tabs search for when looking for voice messages (the marker decides).
    public static let searchExtensions = ["m4a", "ogg", "oga", "opus", "mp3", "aac", "wav"]

    private static let audioExtensions: Set<String> = ["m4a", "mp3", "aac", "ogg", "oga", "opus", "wav", "flac", "m4r", "wma", "aif", "aiff", "caf", "amr"]

    /// Whether a file is audio, by its MIME type or (when the server didn't know one) its name.
    public static func isAudio(name: String, mimeType: String) -> Bool {
        if mimeType.lowercased().hasPrefix("audio/") {
            return true
        }
        let ext = (name as NSString).pathExtension.lowercased()
        return audioExtensions.contains(ext)
    }

    /// Whether a post shows as a voice message: it has the marker and exactly one file, which is audio. Every
    /// other audio file stays a file (V1: only Relay's marked posts are voice messages).
    public static func isVoicePost(marker: VoiceMessageMarker?, files: [(name: String, mimeType: String)]) -> Bool {
        guard marker != nil, files.count == 1, let file = files.first else {
            return false
        }
        return isAudio(name: file.name, mimeType: file.mimeType)
    }

    /// A readable file name for a recording: `"<prefix> 2026-10-27 14.05.m4a"` in the sender's time zone. The
    /// prefix ("Voice message", localized by the app) loses characters that file systems or URLs dislike.
    public static func fileName(prefix: String, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        var cleaned = prefix.components(separatedBy: forbidden).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            cleaned = "Voice message"
        }
        return "\(cleaned) \(formatter.string(from: date)).\(fileExtension)"
    }
}

/// Telegram's voice waveform: `sampleCount` values of 0…31, packed 5 bits each, least significant bit first
/// (`AudioWaveform.makeBitstream`; 100 samples are 63 bytes).
public enum VoiceWaveform {
    public static let sampleCount = 100
    public static let bitsPerSample = 5
    public static let maxValue: UInt8 = 31

    /// Packs values (clamped to 0…31).
    public static func pack(_ samples: [UInt8]) -> Data {
        let bitCount = samples.count * bitsPerSample
        var bytes = [UInt8](repeating: 0, count: (bitCount + 7) / 8)
        for (index, sample) in samples.enumerated() {
            let value = UInt32(min(sample, maxValue))
            let bitOffset = index * bitsPerSample
            let byteIndex = bitOffset / 8
            let shift = bitOffset % 8
            let shifted = value << UInt32(shift)
            bytes[byteIndex] |= UInt8(truncatingIfNeeded: shifted)
            if byteIndex + 1 < bytes.count {
                bytes[byteIndex + 1] |= UInt8(truncatingIfNeeded: shifted >> 8)
            }
        }
        return Data(bytes)
    }

    /// Unpacks a packed waveform: as many whole samples as the bytes hold (Telegram's
    /// `AudioWaveform(bitstream:bitsPerSample:)`).
    public static func unpack(_ data: Data) -> [UInt8] {
        let bytes = [UInt8](data)
        let count = bytes.count * 8 / bitsPerSample
        var samples: [UInt8] = []
        samples.reserveCapacity(count)
        for index in 0 ..< count {
            let bitOffset = index * bitsPerSample
            let byteIndex = bitOffset / 8
            let shift = bitOffset % 8
            var value = UInt32(bytes[byteIndex])
            if byteIndex + 1 < bytes.count {
                value |= UInt32(bytes[byteIndex + 1]) << 8
            }
            samples.append(UInt8((value >> UInt32(shift)) & UInt32(maxValue)))
        }
        return samples
    }

    /// The waveform of a recording from its PCM samples, as Telegram's recorder makes it
    /// (`ManagedAudioRecorderContext.takeData`): the loudest absolute sample of each of 100 equal parts, scaled
    /// so that 1.8 × the mean of those peaks (at least 2,500) is the top value.
    public static func fromPCM(_ pcm: [Int16]) -> [UInt8] {
        var peaks = [Int64](repeating: 0, count: sampleCount)
        if !pcm.isEmpty {
            for (index, sample) in pcm.enumerated() {
                let magnitude = sample == Int16.min ? Int64(Int16.max) : Int64(abs(sample))
                let bucket = index * sampleCount / pcm.count
                if peaks[bucket] < magnitude {
                    peaks[bucket] = magnitude
                }
            }
        }
        return scaled(peaks: peaks)
    }

    /// Scales 100 peak magnitudes to 0…31 (the recorder's normalisation).
    public static func scaled(peaks: [Int64]) -> [UInt8] {
        let sum = peaks.reduce(0, +)
        var calculatedPeak = Int64(Double(sum) * 1.8 / Double(max(1, peaks.count)))
        if calculatedPeak < 2500 {
            calculatedPeak = 2500
        }
        return peaks.map { peak in
            let value = min(peak, calculatedPeak) * 31 / calculatedPeak
            return UInt8(min(31, max(0, value)))
        }
    }
}
