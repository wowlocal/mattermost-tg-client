import Foundation
import UIKit
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore
import WebPBinding

/// Static reaction images, generated on the device (nothing is downloaded for Unicode emoji).
///
/// Telegram's reaction UI draws `TelegramMediaFile`s. Each reaction value gets one static WebP "custom emoji"
/// file (`.CustomEmoji` attribute, `image/webp`), which the reaction buttons (`InlineStickerItemLayer`, still
/// type) and the picker (`AnimatedStickerNode` with a static source) both render. The file's resource is a
/// `LocalFileMediaResource` (the only resource kind `AvailableReactions` can serialize) whose id is a hash of
/// the value in a range of its own; `mattermostFetchResource` renders it on demand:
/// - a Unicode emoji: the glyph drawn with Apple Color Emoji;
/// - `:name:`: the server's custom emoji image (`GET /emoji/{id}/image`), or the name as text if missing.
enum MattermostReactionImages {
    static let pixelSize = 160
    private static let rangeTag: Int64 = 0x4D5252 // "MRR"; with 39 hash bits the ids stay positive
    private static let hashBits: Int64 = 39

    private static let registry: MMLocked<[Int64: String]> = {
        var values: [Int64: String] = [:]
        for (_, emoji) in EmojiTable.allEmoji {
            values[fileId(for: emoji)] = emoji
        }
        return MMLocked(values)
    }()

    static func fileId(for value: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let mask = (UInt64(1) << UInt64(hashBits)) - 1
        return (rangeTag << hashBits) | Int64(bitPattern: hash & mask)
    }

    static func isReactionImageFileId(_ fileId: Int64) -> Bool {
        return fileId >> hashBits == rangeTag
    }

    static func file(for value: String) -> TelegramMediaFile {
        let id = self.fileId(for: value)
        self.registry.with { $0[id] = value }
        return TelegramMediaFile(
            fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: id),
            partialReference: nil,
            resource: LocalFileMediaResource(fileId: id),
            previewRepresentations: [],
            videoThumbnails: [],
            immediateThumbnailData: nil,
            mimeType: "image/webp",
            size: nil,
            attributes: [
                .FileName(fileName: "reaction.webp"),
                .CustomEmoji(isPremium: false, isSingleColor: false, alt: value, packReference: nil),
                .ImageSize(size: PixelDimensions(width: Int32(pixelSize), height: Int32(pixelSize)))
            ],
            alternativeRepresentations: []
        )
    }

    // MARK: Inline icons (4F)

    private static let iconRangeTag: Int64 = 0x4D4943 // "MIC"

    /// The custom-emoji file of an inline picture (an attachment's `author_icon`, `footer_icon`, `thumb_url`): the
    /// image itself is in the resource (`MattermostIconResource`), so no registry is needed after a relaunch.
    static func iconFile(url: String, round: Bool) -> TelegramMediaFile {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (url + (round ? "#round" : "")).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let mask = (UInt64(1) << UInt64(hashBits)) - 1
        let id = (iconRangeTag << hashBits) | Int64(bitPattern: hash & mask)
        return TelegramMediaFile(
            fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: id),
            partialReference: nil,
            resource: MattermostIconResource(url: url, round: round),
            previewRepresentations: [],
            videoThumbnails: [],
            immediateThumbnailData: nil,
            mimeType: "image/webp",
            size: nil,
            attributes: [
                .FileName(fileName: "icon.webp"),
                .CustomEmoji(isPremium: false, isSingleColor: false, alt: round ? "👤" : "🖼", packReference: nil),
                .ImageSize(size: PixelDimensions(width: Int32(pixelSize), height: Int32(pixelSize)))
            ],
            alternativeRepresentations: []
        )
    }

    /// An icon's image as a transparent square WebP (aspect fit; clipped to a circle when `round`).
    static func iconWebPData(_ data: Data, round: Bool) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        let side = CGFloat(self.pixelSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let box = CGRect(x: 0.0, y: 0.0, width: side, height: side)
            if round {
                context.cgContext.addEllipse(in: box)
                context.cgContext.clip()
                // A round icon fills its circle.
                let scale = max(box.width / image.size.width, box.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: box.midX - size.width / 2.0, y: box.midY - size.height / 2.0, width: size.width, height: size.height))
            } else {
                let scale = min(box.width / image.size.width, box.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: box.midX - size.width / 2.0, y: box.midY - size.height / 2.0, width: size.width, height: size.height))
            }
        }
        return try? WebP.convert(toWebP: rendered, quality: 0.9)
    }

    static func value(forFileId fileId: Int64) -> String? {
        return self.registry.with { $0[fileId] }
    }

    // MARK: Rendering

    /// The fetch for a reaction image resource, or nil for any other resource.
    static func fetch(postbox: Postbox, resource: MediaResource) -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError>? {
        guard let resource = resource as? LocalFileMediaResource, self.isReactionImageFileId(resource.fileId) else {
            return nil
        }
        let fileId = resource.fileId
        return Signal { subscriber in
            let task = Task {
                // The registry fills when MattermostSync writes the reaction list; wait for it briefly.
                var value = self.value(forFileId: fileId)
                var attempts = 0
                while value == nil && attempts < 30 && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    value = self.value(forFileId: fileId)
                    attempts += 1
                }
                guard let value = value else {
                    subscriber.putError(.generic)
                    return
                }
                var sourceImage: UIImage?
                if value.count > 2, value.hasPrefix(":"), value.hasSuffix(":") {
                    sourceImage = await self.customEmojiImage(name: String(value.dropFirst().dropLast()), postbox: postbox)
                }
                guard let data = self.webpData(value: value, image: sourceImage) else {
                    subscriber.putError(.generic)
                    return
                }
                subscriber.putNext(.reset)
                subscriber.putNext(.dataPart(resourceOffset: 0, data: data, range: 0 ..< Int64(data.count), complete: true))
                subscriber.putCompletion()
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    private static func customEmojiImage(name: String, postbox: Postbox) async -> UIImage? {
        let client: MattermostClient? = await withCheckedContinuation { continuation in
            let resumed = Atomic<Bool>(value: false)
            let _ = (MattermostResourceClients.shared.client(postbox: postbox)
            |> timeout(20.0, queue: Queue.concurrentDefaultQueue(), alternate: .complete())).start(next: { client in
                if !resumed.swap(true) {
                    continuation.resume(returning: client)
                }
            }, completed: {
                if !resumed.swap(true) {
                    continuation.resume(returning: nil)
                }
            })
        }
        guard let client = client, let emoji = try? await client.customEmoji(name: name), let data = try? await client.data(for: .emojiImage(emojiId: emoji.id)) else {
            return nil
        }
        return UIImage(data: data)
    }

    /// A square transparent WebP with the image (or the emoji glyph / text) centered.
    static func webpData(value: String, image: UIImage?) -> Data? {
        let side = CGFloat(self.pixelSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let box = CGRect(x: 0.0, y: 0.0, width: side, height: side).insetBy(dx: side * 0.04, dy: side * 0.04)
            if let image = image, image.size.width > 0, image.size.height > 0 {
                let scale = min(box.width / image.size.width, box.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: box.midX - size.width / 2.0, y: box.midY - size.height / 2.0, width: size.width, height: size.height))
                return
            }
            let isText = value.hasPrefix(":")
            let font: UIFont = isText ? UIFont.boldSystemFont(ofSize: side * 0.3) : (UIFont(name: "AppleColorEmoji", size: side * 0.78) ?? UIFont.systemFont(ofSize: side * 0.78))
            let text = NSAttributedString(string: isText ? String(value.dropFirst().dropLast()) : value, attributes: [
                .font: font,
                .foregroundColor: UIColor.gray
            ])
            var bounds = text.boundingRect(with: CGSize(width: 10000.0, height: 10000.0), options: [.usesLineFragmentOrigin], context: nil)
            var scale: CGFloat = 1.0
            if bounds.width > box.width || bounds.height > box.height {
                scale = min(box.width / bounds.width, box.height / bounds.height)
            }
            bounds.size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            if let context = UIGraphicsGetCurrentContext() {
                context.saveGState()
                context.translateBy(x: box.midX - bounds.width / 2.0, y: box.midY - bounds.height / 2.0)
                context.scaleBy(x: scale, y: scale)
                text.draw(at: .zero)
                context.restoreGState()
            }
        }
        return try? WebP.convert(toWebP: rendered, quality: 0.9)
    }
}
