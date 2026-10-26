import Foundation
import Postbox
import TelegramCore
import MattermostKit

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

    static func media(for file: FileInfo, mediaId: Int64) -> Converted {
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
