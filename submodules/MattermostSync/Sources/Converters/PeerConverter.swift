import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Mattermost users and channels → Telegram peers.
enum PeerConverter {
    /// `names`: the peer's first and last name (4H: the user's display setting, `DisplayNames.swift`); without
    /// them the full name, else the username.
    static func user(_ user: User, peerId: PeerId, names: (first: String, last: String?)? = nil) -> TelegramUser {
        let names = names ?? UserDisplayName.peerNames(username: user.username, firstName: user.firstName, lastName: user.lastName, nickname: "", format: UserDisplayName.fullNameFormat)
        let firstName = names.first
        let lastName = names.last ?? ""
        var photo: [TelegramMediaImageRepresentation] = []
        // Without a custom picture Mattermost serves a generated default; Telegram's own initials look better.
        // Bots too: a bot's picture is its profile image (plugins and `POST /users/{id}/image` set
        // `last_picture_update`), as Mattermost's own apps draw it; `bot_last_icon_update` stays 0 on 11.x.
        if user.hasCustomPicture {
            photo.append(TelegramMediaImageRepresentation(
                dimensions: PixelDimensions(width: 128, height: 128),
                resource: MattermostAvatarResource(userId: user.id, lastPictureUpdate: user.lastPictureUpdate),
                progressiveSizes: [],
                immediateThumbnailData: nil
            ))
        }
        return TelegramUser(
            id: peerId,
            accessHash: PeerConverter.userAccessHash,
            firstName: firstName,
            lastName: lastName.isEmpty ? nil : lastName,
            username: user.username,
            phone: nil,
            photo: photo,
            // Mattermost bots read their channels: member lists say "has access to messages" (Phase 3D).
            botInfo: user.isBot ? BotUserInfo(flags: [.hasAccessToChatHistory], inlinePlaceholder: nil) : nil,
            restrictionInfo: nil,
            flags: [],
            emojiStatus: PeerConverter.customStatusEmoji(user),
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

    /// 4H: the access hash of user peers. Any non-zero value: Postbox stores 0 as "no access hash", and a user read
    /// back without one has no `PeerReference`, which the chat list's avatar loader (`AvatarNode.setPeerV2`,
    /// `DirectMediaImageCache`) needs, so DM rows of users with a picture stayed blank (4G gap: bob's DM row). The
    /// value is never sent anywhere.
    static let userAccessHash: TelegramPeerAccessHash = .personal(1)

    /// Public/private channels and group messages are all supergroups (`TelegramChannel` with `.group`
    /// info): basic groups never get a `threadId` on replies.
    /// `username` is only set on the composer's `~` suggestions (the channel name to insert); stored channel
    /// peers have none. `access` (`MattermostChannelAccess`, Phase 3D-2) is what the user may do with the channel;
    /// it goes into `version`, which Telegram's UI doesn't read for these peers. `participationStatus` is `.left` for
    /// a public channel the user hasn't joined (a search result, Phase 3C).
    static func channel(_ channel: Channel, title: String, peerId: PeerId, username: String? = nil, access: MattermostChannelAccess = [], participationStatus: TelegramChannelParticipationStatus = .member) -> TelegramChannel {
        return TelegramChannel(
            id: peerId,
            accessHash: .personal(0),
            title: title,
            username: username,
            photo: [],
            creationDate: mmSeconds(channel.createAt),
            version: access.rawValue,
            participationStatus: participationStatus,
            info: .group(TelegramChannelGroupInfo(flags: [])),
            flags: [],
            restrictionInfo: nil,
            adminRights: nil,
            bannedRights: nil,
            // An archived channel is read-only (3D-2): Telegram's composer shows its "writing isn't allowed" panel
            // (`Conversation.DefaultRestrictedText`, worded for archived channels in Relay.strings).
            defaultBannedRights: channel.isArchived && participationStatus == .member ? PeerConverter.archivedChannelRights : nil,
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

    static let archivedChannelRights = TelegramChatBannedRights(flags: [.banSendText, .banSendMedia, .banSendStickers, .banSendGifs, .banSendInline, .banSendPolls, .banSendPhotos, .banSendVideos, .banSendInstantVideos, .banSendMusic, .banSendVoice, .banSendFiles, .banSendReactions, .banPinMessages, .banChangeInfo, .banAddMembers], untilDate: Int32.max)

    /// Phase 3F: the custom status's emoji in Telegram's emoji status slot (next to the name in the chat list, chat
    /// title and profile). The emoji is the locally rendered static image of the reaction list (`MattermostReactionImages`;
    /// a text-only status shows Mattermost's default 💬); its file must be stored (`customStatusEmojiFile`). Expired
    /// statuses are left out (Mattermost doesn't announce the expiry; `scheduleCustomStatusExpiry` rewrites the user).
    static func customStatusEmoji(_ user: User, now: Date = Date()) -> PeerEmojiStatus? {
        guard let file = self.customStatusEmojiFile(user, now: now), let custom = user.customStatus else {
            return nil
        }
        let expiration = custom.expiryDate.map { Int32(clamping: Int64($0.timeIntervalSince1970)) }
        return PeerEmojiStatus(content: .emoji(fileId: file.fileId.id), expirationDate: expiration)
    }

    static func customStatusEmojiFile(_ user: User, now: Date = Date()) -> TelegramMediaFile? {
        guard let custom = user.customStatus, !custom.isEmpty, !custom.isExpired(at: now) else {
            return nil
        }
        let name = custom.emoji.isEmpty ? CustomStatusRules.defaultEmoji : custom.emoji
        return MattermostReactionImages.file(for: MattermostCustomStatus.displayEmoji(name: name))
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
        // Phase 3F: away and do not disturb are marked, so the presence texts say so.
        let mark: MattermostPresenceStatus? = mapped.isDoNotDisturb ? .doNotDisturb : (mapped.isAway ? .away : nil)
        let until = mapped.isDoNotDisturb ? mapped.doNotDisturbUntil : nil
        switch mapped.state {
        case .online:
            return TelegramUserPresence(status: .present(until: Int32(clamping: Int64(now.timeIntervalSince1970) + Int64(onlineValidity))), lastActivity: 0, mattermostStatus: mark, mattermostStatusUntil: until)
        case .recently:
            return TelegramUserPresence(status: .recently(isHidden: false), lastActivity: 0, mattermostStatus: mark, mattermostStatusUntil: until)
        case let .lastSeen(at):
            return TelegramUserPresence(status: .present(until: at), lastActivity: at, mattermostStatus: mark, mattermostStatusUntil: until)
        case .unknown:
            return TelegramUserPresence(status: .none, lastActivity: 0, mattermostStatus: mark, mattermostStatusUntil: until)
        }
    }

    static func displayName(_ user: User) -> String {
        let full = user.fullName.trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? user.username : full
    }
}
