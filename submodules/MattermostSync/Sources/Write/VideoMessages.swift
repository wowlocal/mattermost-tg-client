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

    /// What an upload learned about a video file (5B), for the post's marker: the first frame as Telegram's stripped
    /// thumbnail, and the size and duration of the file as uploaded (after Telegram's conversion, when there was one).
    struct UploadedVideo {
        var thumbnail: Data?
        var width: Int
        var height: Int
        var duration: Double
    }

    /// A video file's thumbnail, size and duration as AVFoundation reads the uploaded file; the thumbnail falls back to
    /// the sender's preview image, the size and duration to the local file's `.Video` attribute. Telegram's iOS round
    /// video recorder draws the circle into the video (light corners), which the round bubble clips.
    static func uploadedVideo(file: TelegramMediaFile, videoPath: String, mediaBox: MediaBox) async -> UploadedVideo {
        let started = CFAbsoluteTimeGetCurrent()
        let probe = await PostSender.probeVideo(path: videoPath)
        var image = probe.frame
        var origin = "first frame"
        if image == nil, let representation = file.previewRepresentations.first, let path = mediaBox.completedResourcePath(representation.resource), let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) {
            origin = "preview"
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        var video = UploadedVideo(thumbnail: image.flatMap { PostSender.strippedThumbnail(of: $0) }, width: probe.width, height: probe.height, duration: probe.duration)
        for attribute in file.attributes {
            if case let .Video(duration, size, _, _, _, _) = attribute {
                if video.width <= 0 || video.height <= 0 {
                    video.width = Int(size.width)
                    video.height = Int(size.height)
                }
                if video.duration <= 0 {
                    video.duration = duration
                }
            }
        }
        MMLog.log("video: \(video.width)×\(video.height), \(String(format: "%.1f", video.duration)) s, \(video.thumbnail.map { "\($0.count)-byte thumbnail from the \(origin)" } ?? "no thumbnail") in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
        return video
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

    private struct VideoProbe {
        var frame: CGImage?
        var width = 0
        var height = 0
        var duration = 0.0
    }

    /// The first frame, displayed size (the track's transform applied) and duration of a video file. Media box files
    /// have no extension, which AVFoundation needs to pick the container, so it reads the file through a temporary
    /// `.mp4` link.
    private static func probeVideo(path: String) async -> VideoProbe {
        let directory = NSTemporaryDirectory() + "relay-video-thumbnail"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let linkPath = directory + "/\(UUID().uuidString).mp4"
        guard (try? FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: path)) != nil else {
            return VideoProbe()
        }
        defer {
            try? FileManager.default.removeItem(atPath: linkPath)
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: linkPath))
        var probe = VideoProbe()
        if let track = try? await asset.loadTracks(withMediaType: .video).first, let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let displayed = CGRect(origin: .zero, size: naturalSize).applying(transform)
            probe.width = Int(abs(displayed.width).rounded())
            probe.height = Int(abs(displayed.height).rounded())
        }
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            probe.duration = duration.seconds
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        probe.frame = await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            // Called once for each requested time, also when it fails or is cancelled.
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, _, _ in
                continuation.resume(returning: image)
            }
        }
        return probe
    }

    /// A video an outgoing message sends as a video (5B): Telegram's video attribute, not a round video, a GIF or a
    /// sticker.
    static func videoFile(_ media: Media) -> TelegramMediaFile? {
        guard let file = media as? TelegramMediaFile, !file.isInstantVideo, !file.isAnimated, !file.isSticker else {
            return nil
        }
        for attribute in file.attributes {
            if case .Video = attribute {
                return file
            }
        }
        return nil
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
    /// A round video's marker takes the thumbnail its upload made (`PostSender.uploadedVideo`); after a restart
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

    /// Relay's metadata of the video files of an outgoing post (5B, `VideoFilesMarker`): for every uploaded file that
    /// its message sends as a video, the size, duration and thumbnail the upload found. Nil when the post has none
    /// (uploads restored after a restart have no metadata: those videos show like another client's).
    func videoFilesProps(messages: [Message], uploadedFiles: [MessageId: [PostSender.UploadedFile]]) -> JSONValue? {
        var entries: [String: VideoMessageMarker] = [:]
        for message in messages {
            for uploaded in uploadedFiles[message.id] ?? [] where uploaded.mediaIndex < message.media.count {
                guard PostSender.videoFile(message.media[uploaded.mediaIndex]) != nil, let video = uploaded.video, video.width > 0, video.height > 0 else {
                    continue
                }
                let thumbnail = video.thumbnail.flatMap { VideoMessageMarker.isUsableThumbnail($0) ? $0 : nil }
                entries[uploaded.fileId] = VideoMessageMarker(duration: video.duration, width: video.width, height: video.height, thumbnail: thumbnail)
            }
        }
        return entries.isEmpty ? nil : JSONValue(foundationObject: VideoFilesMarker.propsValue(entries))
    }
}
