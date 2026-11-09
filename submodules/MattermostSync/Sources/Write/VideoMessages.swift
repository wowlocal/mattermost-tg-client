import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Relay's video messages (Telegram's round videos, Phase 5B, design: mattermost-sync.md "Video messages (5B)").
///
/// Mattermost has no video-message post type, so Telegram's round video recording (H.264 and AAC in an `.mp4`,
/// `.Video(flags: [.instantRoundVideo])`) goes out as an ordinary post with one video file, named
/// "Video message 2026-11-09 14.05.mp4", and marked in the post's props (`VideoMessageMarker`: duration and size) so
/// Relay shows it as a round video (`PostConverter.videoMessageMarker`). Every other Mattermost client plays it as a
/// video file. Other video files stay files.
public enum MattermostVideoMessages {
    /// The start of an uploaded recording's file name, before its date ("Video message"): MattermostUI sets the
    /// localized text at launch; the sync has no strings of its own.
    public static var fileNamePrefix: () -> String = { "Video message" }
}

extension PostSender {
    /// The file of a round video message (Telegram's recorder, or a forwarded video message) and what its marker says.
    struct VideoMessageRecording {
        var file: TelegramMediaFile
        var marker: VideoMessageMarker

        /// A recording made here (not yet the server's file): uploaded under a readable name. A forwarded video
        /// message is already the server's file and keeps its name.
        var isLocalRecording: Bool {
            return !(self.file.resource is MattermostFileResource)
        }

        init?(media: Media) {
            guard let file = media as? TelegramMediaFile else {
                return nil
            }
            for attribute in file.attributes {
                if case let .Video(duration, size, flags, _, _, _) = attribute, flags.contains(.instantRoundVideo) {
                    self.file = file
                    self.marker = VideoMessageMarker(duration: duration, width: Int(size.width), height: Int(size.height))
                    return
                }
            }
            return nil
        }
    }

    /// Telegram's stripped thumbnail of a recording's first frame, for its marker (`VideoMessageMarker.thumbnail`): from
    /// the video itself (what playback replaces it with), else from the recorder's preview image (on iOS a snapshot
    /// already masked to a circle). Nil when neither can be read.
    static func videoMessageThumbnail(recording: VideoMessageRecording, videoPath: String, mediaBox: MediaBox) async -> Data? {
        let started = CFAbsoluteTimeGetCurrent()
        var origin = "first frame"
        var image = await PostSender.firstVideoFrame(path: videoPath)
        if image == nil, let representation = recording.file.previewRepresentations.first, let path = mediaBox.completedResourcePath(representation.resource), let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) {
            origin = "preview"
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image = image, let thumbnail = PostSender.strippedThumbnail(of: image) else {
            MMLog.log("video message: no thumbnail for \(recording.file.fileId)")
            return nil
        }
        MMLog.log("video message: \(thumbnail.count)-byte thumbnail from the \(origin) in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
        return thumbnail
    }

    /// An image scaled to fit `TinyThumbnailEncoder.defaultSide` and encoded as Telegram's stripped thumbnail.
    static func strippedThumbnail(of image: CGImage) -> Data? {
        guard image.width > 0, image.height > 0 else {
            return nil
        }
        let side = Double(TinyThumbnailEncoder.defaultSide)
        let scale = min(side / Double(image.width), side / Double(image.height), 1.0)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            return nil
        }
        return TinyThumbnailEncoder.encode(rgba: rgba, width: width, height: height)
    }

    /// The first frame of a video file. Media box files have no extension, which AVFoundation needs to pick the
    /// container, so it reads the file through a temporary `.mp4` link.
    private static func firstVideoFrame(path: String) async -> CGImage? {
        let directory = NSTemporaryDirectory() + "relay-video-thumbnail"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let linkPath = directory + "/\(UUID().uuidString).mp4"
        guard (try? FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: path)) != nil else {
            return nil
        }
        defer {
            try? FileManager.default.removeItem(atPath: linkPath)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: linkPath)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            // Called once for each requested time, also when it fails or is cancelled.
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, _, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// The single round video of an outgoing message, if it is one.
    static func videoMessageRecording(of message: Message) -> VideoMessageRecording? {
        let files = message.media.filter { $0 is TelegramMediaFile || $0 is TelegramMediaImage }
        guard files.count == 1, let recording = VideoMessageRecording(media: files[0]) else {
            return nil
        }
        return recording
    }
}

extension MattermostAccountSync {
    /// The props marker of an outgoing message that is a voice recording (5A) or a round video (5B), for
    /// `outgoingDraft`.
    ///
    /// A round video's marker takes the thumbnail its upload made (`PostSender.videoMessageThumbnail`); after a restart
    /// between the upload and the post there is none, and the marker goes without it.
    func recordingProps(of message: Message, videoThumbnail: Data?) -> [String: JSONValue] {
        let voice = self.voiceProps(of: message)
        if !voice.isEmpty {
            return voice
        }
        guard let recording = PostSender.videoMessageRecording(of: message) else {
            return [:]
        }
        var marker = recording.marker
        marker.thumbnail = videoThumbnail.flatMap { VideoMessageMarker.isUsableThumbnail($0) ? $0 : nil }
        guard let value = JSONValue(foundationObject: marker.propsValue) else {
            return [:]
        }
        return [VideoMessageMarker.propsKey: value]
    }
}
