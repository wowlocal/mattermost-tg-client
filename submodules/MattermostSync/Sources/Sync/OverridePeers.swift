import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Webhook and bot posts can show another name and icon than their poster's (`props.override_username`,
/// `override_icon_url`, set by the server when `EnablePostUsernameOverride` / `EnablePostIconOverride` allow
/// it). Telegram shows a message's author from `Message.author`, so each distinct override (name + icon)
/// becomes a bot user of its own, written like any user peer and used as the author of those posts.
///
/// This is the least invasive mechanism: no upstream change, and the name, the avatar (an image on the
/// server, `MattermostURLImageResource`), the bot label and the grouping of consecutive messages all follow
/// from the peer. Telegram's alternatives were weaker: an author signature attribute shows only in channel
/// posts, and "via @bot" or forward headers would keep the poster's name and avatar. The synthetic peer has no
/// chat: it is never included in the chat list, and its profile shows the override name and the poster.
extension MattermostAccountSync {
    struct AuthorOverride: Hashable {
        var username: String
        var iconURL: String
    }

    static func authorOverride(_ post: Post) -> AuthorOverride? {
        let props = post.props
        guard props["from_webhook"]?.scalarString == "true" || props["from_bot"]?.scalarString == "true" else {
            return nil
        }
        let username = props["override_username"]?.scalarString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let iconURL = props["override_icon_url"]?.scalarString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if username.isEmpty && iconURL.isEmpty {
            return nil
        }
        return AuthorOverride(username: username, iconURL: iconURL)
    }

    /// Writes the override peers the posts need (once per distinct override and call) and returns post id →
    /// override peer.
    func writeOverridePeers(_ posts: [Post], transaction: Transaction) -> [String: PeerId] {
        var result: [String: PeerId] = [:]
        var written: [AuthorOverride: PeerId] = [:]
        for post in posts {
            guard let override = MattermostAccountSync.authorOverride(post) else {
                continue
            }
            if let peerId = written[override] {
                result[post.id] = peerId
                continue
            }
            // Without a name the poster's name stays (only the icon changes).
            let poster = self.state.with { $0.users[post.userId] }
            let name = override.username.isEmpty ? (poster.map(PeerConverter.displayName) ?? "Webhook") : override.username
            let key = "override:\(name)\n\(override.iconURL)"
            guard let peer = self.store.allocatePeer(mattermostId: key, kind: .user, teamId: nil) else {
                continue
            }
            let peerId = MattermostPeerIds.userPeerId(peer.peerId)
            var photo: [TelegramMediaImageRepresentation] = []
            if !override.iconURL.isEmpty, let serverURL = URL(string: self.server.url), MattermostURLImageResource.sameOriginURL(override.iconURL, serverURL: serverURL) != nil {
                photo.append(TelegramMediaImageRepresentation(
                    dimensions: PixelDimensions(width: 128, height: 128),
                    resource: MattermostURLImageResource(url: override.iconURL),
                    progressiveSizes: [],
                    immediateThumbnailData: nil
                ))
            } else if override.iconURL.isEmpty, let poster = poster {
                // A name override keeps the poster's picture.
                photo = PeerConverter.user(poster, peerId: peerId).photo
            }
            let user = TelegramUser(
                id: peerId,
                accessHash: .personal(0),
                firstName: name,
                lastName: nil,
                username: nil,
                phone: nil,
                photo: photo,
                botInfo: BotUserInfo(flags: [], inlinePlaceholder: nil),
                restrictionInfo: nil,
                flags: [],
                emojiStatus: nil,
                usernames: [],
                storiesHidden: nil,
                nameColor: nil,
                backgroundEmojiId: nil,
                profileColor: nil,
                profileBackgroundEmojiId: nil,
                subscriberCount: nil,
                verificationIconFileId: nil
            )
            if transaction.getPeer(peerId).map({ !$0.isEqual(user) }) ?? true {
                updatePeersCustom(transaction: transaction, peers: [user], update: { _, updated in
                    return updated
                })
                let about = poster.map { "Posted by \(PeerConverter.displayName($0)) (@\($0.username))" }
                transaction.updatePeerCachedData(peerIds: [peerId], update: { _, current in
                    return (current as? CachedUserData ?? CachedUserData())
                        .withUpdatedAbout(about)
                        .withUpdatedBusinessIntro(nil)
                        .withUpdatedPeerStatusSettings(PeerStatusSettings())
                })
            }
            written[override] = peerId
            result[post.id] = peerId
        }
        return result
    }
}
