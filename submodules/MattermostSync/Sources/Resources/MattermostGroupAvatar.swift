import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit

/// The picture of a group message (Mattermost has none for channels and group messages): its other members' pictures
/// side by side, composed on the device. Two members share the circle in halves, three as a half and two quarters,
/// four or more as quarters (the first four, in the title's order), with a white line between them. A member without a picture gets the letter tile
/// Telegram draws for them elsewhere (same gradient, by the member's peer id).
///
/// Everything the image shows is in the resource (each member's `last_picture_update`, letter and colour), so its id
/// changes, and the picture is composed again, exactly when one of them changes. The class name is part of the
/// storage format (see `MattermostResources.swift`): never rename it.
public final class MattermostGroupAvatarResource: TelegramMediaResource {
    public struct Member: Equatable {
        public let userId: String
        /// 0 when the member has no picture of their own (the letter tile).
        public let pictureUpdate: Int64
        public let letter: String
        /// Index into Telegram's avatar gradients (`AvatarNode.gradientColors`).
        public let colorIndex: Int32

        public init(userId: String, pictureUpdate: Int64, letter: String, colorIndex: Int32) {
            self.userId = userId
            self.pictureUpdate = pictureUpdate
            self.letter = letter
            self.colorIndex = colorIndex
        }
    }

    public let members: [Member]

    public init(members: [Member]) {
        self.members = members
    }

    public required init(decoder: PostboxDecoder) {
        let userIds = decoder.decodeStringArrayForKey("u")
        let pictureUpdates = decoder.decodeInt64ArrayForKey("t")
        let letters = decoder.decodeStringArrayForKey("l")
        let colors = decoder.decodeInt32ArrayForKey("c")
        var members: [Member] = []
        for index in 0 ..< min(userIds.count, pictureUpdates.count, letters.count, colors.count) {
            members.append(Member(userId: userIds[index], pictureUpdate: pictureUpdates[index], letter: letters[index], colorIndex: colors[index]))
        }
        self.members = members
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeStringArray(self.members.map(\.userId), forKey: "u")
        encoder.encodeInt64Array(self.members.map(\.pictureUpdate), forKey: "t")
        encoder.encodeStringArray(self.members.map(\.letter), forKey: "l")
        encoder.encodeInt32Array(self.members.map(\.colorIndex), forKey: "c")
    }

    public var size: Int64? {
        return nil
    }

    public var id: MediaResourceId {
        let key = self.members.map { "\($0.userId):\($0.pictureUpdate):\($0.letter):\($0.colorIndex)" }.joined(separator: "|")
        return MediaResourceId("mm-group-avatar-2-\(key.persistentHashString)")
    }

    public func isEqual(to: MediaResource) -> Bool {
        guard let to = to as? MattermostGroupAvatarResource else {
            return false
        }
        return self.members == to.members
    }
}

enum MattermostGroupAvatar {
    static let pixelSize = 160

    /// The photo of a group message's peer, or none without members to show.
    static func photo(members: [MattermostGroupAvatarResource.Member]) -> [TelegramMediaImageRepresentation] {
        if members.isEmpty {
            return []
        }
        return [TelegramMediaImageRepresentation(
            dimensions: PixelDimensions(width: Int32(pixelSize), height: Int32(pixelSize)),
            resource: MattermostGroupAvatarResource(members: Array(members.prefix(4))),
            progressiveSizes: [],
            immediateThumbnailData: nil
        )]
    }

    /// The fetch: each member's picture from the media box (where their own avatar is stored once shown) or the
    /// server, then the composed PNG. A network failure fails the fetch, so it is tried again later instead of keeping
    /// a letter tile for good; a picture the server refuses (404, 403) or that can't be decoded is a letter tile.
    static func fetch(postbox: Postbox, resource: MattermostGroupAvatarResource) -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError> {
        let resourceId = resource.id.stringRepresentation
        return MattermostResourceClients.shared.client(postbox: postbox)
        |> castError(MediaResourceDataFetchError.self)
        |> mapToSignal { client -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError> in
            return Signal { subscriber in
                let task = Task {
                    do {
                        var images: [MMImage?] = []
                        for member in resource.members {
                            guard member.pictureUpdate > 0 else {
                                images.append(nil)
                                continue
                            }
                            let avatar = MattermostAvatarResource(userId: member.userId, lastPictureUpdate: member.pictureUpdate)
                            if let path = postbox.mediaBox.completedResourcePath(avatar), let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let image = MMImage(data: data) {
                                images.append(image)
                                continue
                            }
                            let data: Data
                            do {
                                data = try await client.data(for: .userImage(userId: member.userId, lastPictureUpdate: member.pictureUpdate))
                            } catch let error as MattermostError {
                                switch error {
                                case .notFound, .forbidden:
                                    // The server won't give this picture (a deleted user, no access): the letter tile,
                                    // not a picture that never loads.
                                    images.append(nil)
                                    continue
                                default:
                                    throw error
                                }
                            }
                            guard let image = MMImage(data: data) else {
                                images.append(nil)
                                continue
                            }
                            // Kept as the member's own avatar too (their chats and profile).
                            postbox.mediaBox.storeResourceData(avatar.id, data: data)
                            images.append(image)
                        }
                        guard let data = self.render(members: resource.members, images: images) else {
                            throw URLError(.cannotDecodeContentData)
                        }
                        subscriber.putNext(.reset)
                        subscriber.putNext(.dataPart(resourceOffset: 0, data: data, range: 0 ..< Int64(data.count), complete: true))
                        subscriber.putCompletion()
                    } catch {
                        if !Task.isCancelled {
                            MMLog.log("fetch \(resourceId) failed: \(error)")
                        }
                        subscriber.putError(.generic)
                    }
                }
                return ActionDisposable {
                    task.cancel()
                }
            }
        }
    }

    /// Telegram's avatar gradients (`AvatarNode.gradientColors`, bottom then top), so a member's letter tile matches
    /// their own avatar.
    private static let gradients: [(bottom: UInt32, top: UInt32)] = [
        (0xff516a, 0xff885e),
        (0xffa85c, 0xffcd6a),
        (0x665fff, 0x82b1ff),
        (0x54cb68, 0xa0de7e),
        (0x4acccd, 0x00fcfd),
        (0x2a9ef1, 0x72d5fd),
        (0xd669ed, 0xe0a2f3)
    ]

    /// The tiles of `count` members in a square of `side`: halves, a half and two quarters, or quarters, with a gap
    /// between them (the avatar is clipped to a circle by the views that draw it).
    static func tiles(count: Int, side: CGFloat) -> [CGRect] {
        let gap = side * 0.025
        let half = (side - gap) / 2.0
        let left = CGRect(x: 0.0, y: 0.0, width: half, height: side)
        let right = CGRect(x: half + gap, y: 0.0, width: half, height: side)
        let topRight = CGRect(x: half + gap, y: 0.0, width: half, height: half)
        let bottomRight = CGRect(x: half + gap, y: half + gap, width: half, height: half)
        switch count {
        case 0:
            return []
        case 1:
            return [CGRect(x: 0.0, y: 0.0, width: side, height: side)]
        case 2:
            return [left, right]
        case 3:
            return [left, topRight, bottomRight]
        default:
            return [CGRect(x: 0.0, y: 0.0, width: half, height: half), topRight, CGRect(x: 0.0, y: half + gap, width: half, height: half), bottomRight]
        }
    }

    private static func color(_ rgb: UInt32) -> MMColor {
        return MMColor(red: CGFloat((rgb >> 16) & 0xff) / 255.0, green: CGFloat((rgb >> 8) & 0xff) / 255.0, blue: CGFloat(rgb & 0xff) / 255.0, alpha: 1.0)
    }

    static func render(members: [MattermostGroupAvatarResource.Member], images: [MMImage?]) -> Data? {
        let side = CGFloat(self.pixelSize)
        let tiles = self.tiles(count: min(members.count, 4), side: side)
        if tiles.isEmpty {
            return nil
        }
        let rendered = MMImageRenderer.image(size: CGSize(width: side, height: side), opaque: true) { cgContext in
            // Opaque, with white between the tiles: a transparent gap showed the letter placeholder that avatar views
            // draw under the image.
            MMColor.white.setFill()
            cgContext.fill(CGRect(x: 0.0, y: 0.0, width: side, height: side))
            for (index, tile) in tiles.enumerated() {
                cgContext.saveGState()
                cgContext.clip(to: tile)
                if index < images.count, let image = images[index], image.size.width > 0, image.size.height > 0 {
                    // Aspect fill, centred.
                    let scale = max(tile.width / image.size.width, tile.height / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.mmDraw(in: CGRect(x: tile.midX - size.width / 2.0, y: tile.midY - size.height / 2.0, width: size.width, height: size.height))
                } else {
                    let member = members[index]
                    let gradient = self.gradients[Int(abs(member.colorIndex)) % self.gradients.count]
                    let colors = [self.color(gradient.top).cgColor, self.color(gradient.bottom).cgColor] as CFArray
                    if let cgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) {
                        cgContext.drawLinearGradient(cgGradient, start: CGPoint(x: tile.midX, y: tile.minY), end: CGPoint(x: tile.midX, y: tile.maxY), options: [])
                    }
                    let font = MMFont.systemFont(ofSize: min(tile.width, tile.height) * 0.42, weight: .semibold)
                    let text = NSAttributedString(string: member.letter, attributes: [.font: font, .foregroundColor: MMColor.white])
                    let bounds = text.boundingRect(with: CGSize(width: 1000.0, height: 1000.0), options: [.usesLineFragmentOrigin], context: nil)
                    // Halves and quarters reach the circle's edge: the letter moves a little toward the centre so
                    // the round clip doesn't cut it.
                    let center = CGPoint(x: tile.midX + (side / 2.0 - tile.midX) * 0.2, y: tile.midY + (side / 2.0 - tile.midY) * 0.2)
                    text.draw(at: CGPoint(x: center.x - bounds.width / 2.0, y: center.y - bounds.height / 2.0))
                }
                cgContext.restoreGState()
            }
        }
        return rendered.mmPNGData()
    }
}

