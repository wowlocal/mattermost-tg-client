import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Mattermost file attachments → Telegram media.
enum MediaConverter {
    struct Converted {
        var media: Media
        var tags: MessageTags
    }

    /// Mattermost's generated sizes (server defaults): thumbnails fit 120×100, previews 1920×1080.
    private static let thumbnailBox = (width: 120, height: 100)
    private static let previewBox = (width: 1920, height: 1080)

    /// Images Telegram shows as photos (and groups into albums); other files show as documents.
    static func isAlbumImage(_ file: FileInfo) -> Bool {
        return file.isImage && file.width > 0 && file.height > 0 && file.mimeType != "image/svg+xml"
    }

    /// Video files (5B): Telegram's video bubble, in albums with the post's photos.
    static func isVideo(_ file: FileInfo) -> Bool {
        return VideoMessageFile.isVideo(name: file.name, mimeType: file.mimeType)
    }

    /// Photos and videos: one album per post (`PostLayout`).
    static func isAlbumMedia(_ file: FileInfo) -> Bool {
        return isAlbumImage(file) || isVideo(file)
    }

    /// The shape a video without Relay's metadata is shown in (another client's video: Mattermost keeps no size). A
    /// square crops landscape and portrait videos alike; playback shows the whole picture.
    static let unknownVideoSize = PixelDimensions(width: 720, height: 720)

    /// `voice` (5A): the post is a Relay voice message (`VoiceMessageFile.isVoicePost`), shown as Telegram's voice
    /// bubble; `waveform` replaces a missing one of the marker (computed on the device, `MattermostAccountSync.computedVoiceWaveform`).
    ///
    /// `roundVideo` (5B): the post is a Relay video message (`VideoMessageFile.isVideoMessagePost`), shown as Telegram's
    /// round video bubble. `video` (5B): Relay's size, duration and first frame of a video file (`VideoFilesMarker`).
    static func media(for file: FileInfo, mediaId: Int64, voice: VoiceMessageMarker? = nil, waveform: Data? = nil, roundVideo: VideoMessageMarker? = nil, video: VideoMessageMarker? = nil) -> Converted {
        if let roundVideo = roundVideo {
            let telegramFile = TelegramMediaFile(
                fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: mediaId),
                partialReference: nil,
                resource: MattermostFileResource(fileId: file.id, variant: .file, size: file.size),
                previewRepresentations: [],
                videoThumbnails: [],
                // The sender's blurred first frame, until the video is downloaded.
                immediateThumbnailData: roundVideo.thumbnail,
                mimeType: file.mimeType.isEmpty ? VideoMessageFile.mimeType : file.mimeType,
                size: file.size,
                attributes: [
                    .Video(duration: roundVideo.duration, size: PixelDimensions(width: Int32(roundVideo.width), height: Int32(roundVideo.height)), flags: [.instantRoundVideo], preloadSize: nil, coverTime: nil, videoCodec: nil),
                    .FileName(fileName: file.name),
                ],
                alternativeRepresentations: []
            )
            // Telegram files round videos with voice messages: the Voice tab, the playlist that plays the next one.
            return Converted(media: telegramFile, tags: [.voiceOrInstantVideo])
        }
        if isVideo(file) {
            // A video file (5B): Telegram's video bubble and gallery player. Without Relay's metadata (another client)
            // the bubble is square, the duration shows once it plays, and the first frame once it is downloaded.
            let size = video.map { PixelDimensions(width: Int32($0.width), height: Int32($0.height)) } ?? MediaConverter.unknownVideoSize
            let telegramFile = TelegramMediaFile(
                fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: mediaId),
                partialReference: nil,
                resource: MattermostFileResource(fileId: file.id, variant: .file, size: file.size),
                previewRepresentations: [],
                videoThumbnails: [],
                immediateThumbnailData: video?.thumbnail,
                mimeType: file.mimeType.isEmpty ? VideoMessageFile.mimeType : file.mimeType,
                size: file.size,
                attributes: [
                    .Video(duration: video?.duration ?? 0, size: size, flags: [], preloadSize: nil, coverTime: nil, videoCodec: nil),
                    .FileName(fileName: file.name),
                ],
                alternativeRepresentations: []
            )
            return Converted(media: telegramFile, tags: [.photoOrVideo, .video])
        }
        if let voice = voice {
            let telegramFile = TelegramMediaFile(
                fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: mediaId),
                partialReference: nil,
                resource: MattermostFileResource(fileId: file.id, variant: .file, size: file.size),
                previewRepresentations: [],
                videoThumbnails: [],
                immediateThumbnailData: nil,
                mimeType: file.mimeType.isEmpty ? VoiceMessageFile.mimeType : file.mimeType,
                size: file.size,
                attributes: [
                    .Audio(isVoice: true, duration: voice.duration, title: nil, performer: nil, waveform: voice.waveform ?? waveform),
                    .FileName(fileName: file.name),
                ],
                alternativeRepresentations: []
            )
            // Telegram's tag for voice messages: the Voice tab, the playlist that plays the next one.
            return Converted(media: telegramFile, tags: [.voiceOrInstantVideo])
        }
        if isAlbumImage(file) {
            var representations: [TelegramMediaImageRepresentation] = []
            if file.hasPreviewImage {
                representations.append(TelegramMediaImageRepresentation(
                    dimensions: fit(width: file.width, height: file.height, in: thumbnailBox),
                    resource: MattermostFileResource(fileId: file.id, variant: .thumbnail, size: nil),
                    progressiveSizes: [],
                    immediateThumbnailData: nil
                ))
                let previewDimensions = fit(width: file.width, height: file.height, in: previewBox)
                if previewDimensions.width < file.width || previewDimensions.height < file.height {
                    representations.append(TelegramMediaImageRepresentation(
                        dimensions: previewDimensions,
                        resource: MattermostFileResource(fileId: file.id, variant: .preview, size: nil),
                        progressiveSizes: [],
                        immediateThumbnailData: nil
                    ))
                }
            }
            representations.append(TelegramMediaImageRepresentation(
                dimensions: PixelDimensions(width: Int32(clamping: file.width), height: Int32(clamping: file.height)),
                resource: MattermostFileResource(fileId: file.id, variant: .file, size: file.size),
                progressiveSizes: [],
                immediateThumbnailData: nil
            ))
            let image = TelegramMediaImage(
                imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: mediaId),
                representations: representations,
                immediateThumbnailData: nil,
                reference: nil,
                partialReference: nil,
                flags: []
            )
            return Converted(media: image, tags: [.photoOrVideo, .photo])
        }

        var attributes: [TelegramMediaFileAttribute] = [.FileName(fileName: file.name)]
        if file.isImage && file.width > 0 && file.height > 0 {
            attributes.append(.ImageSize(size: PixelDimensions(width: Int32(clamping: file.width), height: Int32(clamping: file.height))))
        }
        let telegramFile = TelegramMediaFile(
            fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: mediaId),
            partialReference: nil,
            resource: MattermostFileResource(fileId: file.id, variant: .file, size: file.size),
            previewRepresentations: [],
            videoThumbnails: [],
            immediateThumbnailData: nil,
            mimeType: file.mimeType.isEmpty ? "application/octet-stream" : file.mimeType,
            size: file.size,
            attributes: attributes,
            alternativeRepresentations: []
        )
        return Converted(media: telegramFile, tags: [.file])
    }

    /// An image from a URL on the Mattermost server (message attachment images, `image_url` / `thumb_url`).
    static func urlImage(url: String, width: Int, height: Int, mediaId: Int64) -> TelegramMediaImage {
        return TelegramMediaImage(
            imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: mediaId),
            representations: [TelegramMediaImageRepresentation(
                dimensions: PixelDimensions(width: Int32(clamping: width), height: Int32(clamping: height)),
                resource: MattermostURLImageResource(url: url),
                progressiveSizes: [],
                immediateThumbnailData: nil
            )],
            immediateThumbnailData: nil,
            reference: nil,
            partialReference: nil,
            flags: []
        )
    }

    static func fit(width: Int, height: Int, in box: (width: Int, height: Int)) -> PixelDimensions {
        if width <= box.width && height <= box.height {
            return PixelDimensions(width: Int32(clamping: width), height: Int32(clamping: height))
        }
        let scale = min(Double(box.width) / Double(width), Double(box.height) / Double(height))
        return PixelDimensions(width: Int32(max(1, (Double(width) * scale).rounded())), height: Int32(max(1, (Double(height) * scale).rounded())))
    }
}
