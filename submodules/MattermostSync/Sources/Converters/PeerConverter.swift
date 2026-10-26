import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Mattermost users and channels → Telegram peers.
enum PeerConverter {
    static func user(_ user: User, peerId: PeerId) -> TelegramUser {
        var firstName = user.firstName.trimmingCharacters(in: .whitespaces)
        var lastName = user.lastName.trimmingCharacters(in: .whitespaces)
        if firstName.isEmpty && lastName.isEmpty {
            firstName = user.username
            lastName = ""
        }
        var photo: [TelegramMediaImageRepresentation] = []
        // Without a custom picture Mattermost serves a generated default; Telegram's own initials look better.
        let pictureUpdate = user.isBot ? user.botLastIconUpdate : user.lastPictureUpdate
        if pictureUpdate > 0 {
            photo.append(TelegramMediaImageRepresentation(
                dimensions: PixelDimensions(width: 128, height: 128),
                resource: MattermostAvatarResource(userId: user.id, lastPictureUpdate: pictureUpdate),
                progressiveSizes: [],
                immediateThumbnailData: nil
            ))
        }
        return TelegramUser(
            id: peerId,
            accessHash: .personal(0),
            firstName: firstName,
            lastName: lastName.isEmpty ? nil : lastName,
            username: user.username,
            phone: nil,
            photo: photo,
            // Mattermost bots read their channels: member lists say "has access to messages" (Phase 3D).
            botInfo: user.isBot ? BotUserInfo(flags: [.hasAccessToChatHistory], inlinePlaceholder: nil) : nil,
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
    }

    /// Public/private channels and group messages are all supergroups (`TelegramChannel` with `.group`
    /// info): basic groups never get a `threadId` on replies.
    /// `username` is only set on the composer's `~` suggestions (the channel name to insert); stored channel
    /// peers have none.
    static func channel(_ channel: Channel, title: String, peerId: PeerId, username: String? = nil) -> TelegramChannel {
        return TelegramChannel(
            id: peerId,
            accessHash: .personal(0),
            title: title,
            username: username,
            photo: [],
            creationDate: mmSeconds(channel.createAt),
            version: 0,
            participationStatus: .member,
            info: .group(TelegramChannelGroupInfo(flags: [])),
            flags: [],
            restrictionInfo: nil,
            adminRights: nil,
            bannedRights: nil,
            defaultBannedRights: nil,
            usernames: [],
            storiesHidden: nil,
            nameColor: nil,
            backgroundEmojiId: nil,
            profileColor: nil,
            profileBackgroundEmojiId: nil,
            emojiStatus: nil,
            approximateBoostLevel: nil,
            subscriptionUntilDate: nil,
            verificationIconFileId: nil,
            sendPaidMessageStars: nil,
            linkedMonoforumId: nil
        )
    }

    static func presence(status: UserStatus.Status, lastActivityAt: Int64, dndEndTime: Int64?, now: Date) -> TelegramUserPresence {
        let mapped = PresenceMapper.presence(
            status: MattermostUserStatus(apiValue: status.rawValue),
            lastActivityAt: lastActivityAt,
            dndEndTime: dndEndTime,
            now: now
        )
        // Mattermost refreshes statuses by events; keep an online user online until told otherwise.
        let onlineValidity: Int32 = 24 * 60 * 60
        switch mapped.state {
        case .online:
            return TelegramUserPresence(status: .present(until: Int32(clamping: Int64(now.timeIntervalSince1970) + Int64(onlineValidity))), lastActivity: 0)
        case .recently:
            return TelegramUserPresence(status: .recently(isHidden: false), lastActivity: 0)
        case let .lastSeen(at):
            return TelegramUserPresence(status: .present(until: at), lastActivity: at)
        case .unknown:
            return TelegramUserPresence(status: .none, lastActivity: 0)
        }
    }

    static func displayName(_ user: User) -> String {
        let full = user.fullName.trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? user.username : full
    }
}
