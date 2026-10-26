import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Where a channel's messages live in Postbox.
enum ChatKind: Equatable {
    /// Public/private channel or group message (`CloudChannel`, group).
    case channel
    /// DM with another user (that user's `CloudUser` peer).
    case direct
    /// Self-DM (the own user's peer: Saved Messages).
    case saved
}

/// Everything `PostConverter` needs to know besides the post. Built inside a Postbox transaction.
struct PostConversionContext {
    var ownUserId: String
    var ownUsername: String
    var accountPeerId: PeerId
    var chatPeerId: PeerId
    var kind: ChatKind
    var serverURL: String
    /// `last_viewed_at` of the channel (ms): newer incoming mentions get the unseen-mention tag.
    var lastViewedAt: Int64
    var userPeerId: (String) -> PeerId?
    var usernamePeerId: (String) -> PeerId?
    var userDisplayName: (String) -> String?
    /// Post id → current local id in this channel.
    var localId: (String) -> Int32?
    var mediaId: (String) -> Int64
    /// The author shown instead of the poster (webhook and bot `override_username`), see `OverridePeers`.
    var authorOverride: (Post) -> PeerId? = { _ in nil }
}

/// The messages of one post (one per mapped part, in part order) and the custom emoji files their text
/// references (stored in Postbox's media table, so `Message.associatedMedia` resolves them offline).
struct ConvertedPost {
    var messages: [StoreMessage] = []
    var customEmojiFiles: [TelegramMediaFile] = []
}

/// Mattermost posts → Postbox `StoreMessage`s (design: "Writing a page of posts", step 3).
enum PostConverter {
    /// A post as its messages (`PostLayout`). `localIds` maps part index → local id; parts without an id
    /// (tombstoned) are skipped.
    static func storeMessages(post: Post, localIds: [Int: Int32], context: PostConversionContext) -> ConvertedPost {
        var result = ConvertedPost()
        let layout = PostLayout(post: post)
        let isIncoming = post.userId != context.ownUserId
        let flags: StoreMessageFlags = isIncoming ? [.Incoming] : []
        let authorId = context.authorOverride(post) ?? context.userPeerId(post.userId)

        // Threads: channel messages use thread 1 like Telegram's supergroups, replies the local id of their
        // root; Saved Messages use the own peer id as thread; DMs have no threads.
        var threadId: Int64?
        switch context.kind {
        case .channel:
            threadId = 1
        case .saved:
            threadId = context.accountPeerId.toInt64()
        case .direct:
            threadId = nil
        }
        var commonAttributes: [MessageAttribute] = []
        if !post.rootId.isEmpty, let rootLocalId = context.localId(post.rootId) {
            let rootMessageId = MessageId(peerId: context.chatPeerId, namespace: Namespaces.Message.Cloud, id: rootLocalId)
            if context.kind == .channel {
                threadId = Int64(rootLocalId)
            }
            commonAttributes.append(ReplyMessageAttribute(messageId: rootMessageId, threadMessageId: context.kind == .channel ? rootMessageId : nil, quote: nil, isQuote: false, innerSubject: nil))
        }
        if post.editAt > 0 {
            commonAttributes.append(EditedMessageAttribute(date: mmSeconds(post.editAt), isHidden: false))
        }

        // The primary message's extras: reply count, reactions, pinned flag.
        var primaryAttributes: [MessageAttribute] = []
        var primaryTags: MessageTags = []
        if post.rootId.isEmpty && post.replyCount > 0 {
            let latestUsers = (post.participants ?? []).prefix(3).compactMap { context.userPeerId($0.id) }
            primaryAttributes.append(ReplyThreadMessageAttribute(count: Int32(clamping: post.replyCount), latestUsers: Array(latestUsers), commentsPeerId: nil, maxMessageId: nil, maxReadMessageId: nil))
        }
        if let reactions = reactionsAttribute(post.metadata?.reactions ?? [], context: context) {
            primaryAttributes.append(reactions)
        }
        if post.isPinned {
            primaryTags.insert(.pinned)
        }

        // Text and the media of each part.
        var text = ""
        var textAttributes: [MessageAttribute] = []
        var textTags: MessageTags = []
        var media: [[Media]] = Array(repeating: [], count: layout.count)
        var partTags: [MessageTags] = Array(repeating: [], count: layout.count)
        if post.type.hasPrefix("system_") {
            media[0].append(self.serviceAction(post: post, context: context))
        } else {
            var builder = FormattedTextBuilder()
            builder.appendMarkdown(post.message)
            let attachments = AttachmentConverter.convert(props: post.props, images: post.metadata?.images ?? [:], serverURL: context.serverURL, builder: &builder)
            if let markup = attachments.replyMarkup {
                primaryAttributes.append(markup)
            }
            let formatted = builder.formatted
            text = formatted.text
            let customEmojiNames = Set((post.metadata?.emojis ?? []).map { $0.name.lowercased() })
            var entities: [MessageTextEntity] = []
            for entity in formatted.entities {
                if case let .customEmoji(name) = entity.type {
                    // Only the server's custom emoji become images; other `:name:` stays text, as on Mattermost.
                    guard customEmojiNames.contains(name) else {
                        continue
                    }
                    let file = MattermostReactionImages.file(for: ":\(name):")
                    result.customEmojiFiles.append(file)
                    entities.append(MessageTextEntity(range: entity.range, type: .CustomEmoji(stickerPack: nil, fileId: file.fileId.id)))
                    continue
                }
                if let converted = textEntity(entity, context: context) {
                    entities.append(converted)
                }
            }
            if post.type == "me", !text.isEmpty {
                entities.insert(MessageTextEntity(range: 0 ..< (text as NSString).length, type: .Italic), at: 0)
            }
            if !entities.isEmpty {
                textAttributes.append(TextEntitiesMessageAttribute(entities: entities))
            }
            if isIncoming && post.createAt > context.lastViewedAt && mentionsMe(formatted, kind: context.kind, ownUsername: context.ownUsername) {
                textTags.insert(.unseenPersonalMessage)
            }

            for (index, part) in layout.parts.enumerated() {
                guard let file = part.file else {
                    continue
                }
                let converted = MediaConverter.media(for: file, mediaId: context.mediaId(file.id))
                media[index].append(converted.media)
                partTags[index].formUnion(converted.tags)
            }
            if layout.parts[0].file == nil, let image = attachments.image {
                // An attachment image (no files): the photo under the attachment text, as Mattermost shows it.
                media[0].append(MediaConverter.urlImage(url: image.url, width: image.width, height: image.height, mediaId: context.mediaId("url:" + image.url)))
                partTags[0].formUnion([.photoOrVideo, .photo])
                if !text.isEmpty {
                    textAttributes.append(InvertMediaMessageAttribute())
                }
            }
        }

        for (index, part) in layout.parts.enumerated() {
            guard let localId = localIds[index] else {
                continue
            }
            var attributes = commonAttributes
            var tags = partTags[index]
            var partText = ""
            if index == layout.textPartIndex {
                partText = text
                attributes.append(contentsOf: textAttributes)
                tags.formUnion(textTags)
            }
            if index == 0 {
                attributes.append(contentsOf: primaryAttributes)
                tags.formUnion(primaryTags)
            }
            result.messages.append(StoreMessage(
                id: MessageId(peerId: context.chatPeerId, namespace: Namespaces.Message.Cloud, id: localId),
                customStableId: nil,
                globallyUniqueId: nil,
                groupingKey: part.groupingKey,
                threadId: threadId,
                timestamp: mmSeconds(post.createAt),
                flags: flags,
                tags: tags,
                globalTags: [],
                localTags: [],
                forwardInfo: nil,
                authorId: authorId,
                text: partText,
                attributes: attributes,
                media: media[index]
            ))
        }
        return result
    }

    /// A system post as a service message (centered bubble): Telegram's custom-text action, with the users
    /// as mention entities (tapping one opens the profile) and quoted values (a new header) in bold.
    static func serviceAction(post: Post, context: PostConversionContext) -> TelegramMediaAction {
        guard let action = ServiceAction.from(type: post.type, userId: post.userId, message: post.message, props: stringProps(post.props)) else {
            return TelegramMediaAction(action: .customText(text: post.message, entities: [], additionalAttributes: nil))
        }
        let formatted = action.formattedText(name: { reference in
            if let userId = reference.userId, let name = context.userDisplayName(userId) {
                return name
            }
            if let username = reference.username {
                return "@\(username)"
            }
            return "Someone"
        })
        var entities: [MessageTextEntity] = []
        for mention in formatted.mentions {
            var peerId: PeerId?
            if let userId = mention.user.userId {
                peerId = context.userPeerId(userId)
            }
            if peerId == nil, let username = mention.user.username {
                peerId = context.usernamePeerId(username)
            }
            if let peerId = peerId {
                entities.append(MessageTextEntity(range: mention.range, type: .TextMention(peerId: peerId)))
            }
            // Names in bold, like Telegram's own service messages (a mention alone keeps the regular font there).
            entities.append(MessageTextEntity(range: mention.range, type: .Bold))
        }
        for range in formatted.emphasized {
            entities.append(MessageTextEntity(range: range, type: .Bold))
        }
        return TelegramMediaAction(action: .customText(text: formatted.text, entities: entities, additionalAttributes: nil))
    }

    /// Reactions grouped by emoji, in order of their first use. Every reacting user is listed in
    /// `recentPeers`, which is also the source of truth for live `reaction_added/removed` updates.
    static func reactionsAttribute(_ reactions: [Reaction], context: PostConversionContext) -> ReactionsMessageAttribute? {
        let live = reactions.filter { $0.deleteAt == 0 }.sorted(by: { $0.createAt < $1.createAt })
        if live.isEmpty {
            return nil
        }
        var recentPeers: [ReactionsMessageAttribute.RecentPeer] = []
        for reaction in live {
            guard let peerId = context.userPeerId(reaction.userId) else {
                continue
            }
            recentPeers.append(ReactionsMessageAttribute.RecentPeer(
                value: reactionValue(reaction.emojiName),
                isLarge: false,
                isUnseen: false,
                isMy: reaction.userId == context.ownUserId,
                peerId: peerId,
                timestamp: mmSeconds(reaction.createAt)
            ))
        }
        return reactionsAttribute(recentPeers: recentPeers)
    }

    static func reactionsAttribute(recentPeers: [ReactionsMessageAttribute.RecentPeer]) -> ReactionsMessageAttribute? {
        if recentPeers.isEmpty {
            return nil
        }
        var order: [MessageReaction.Reaction] = []
        var counts: [MessageReaction.Reaction: Int32] = [:]
        var mine: [MessageReaction.Reaction] = []
        for peer in recentPeers {
            if counts[peer.value] == nil {
                order.append(peer.value)
            }
            counts[peer.value, default: 0] += 1
            if peer.isMy && !mine.contains(peer.value) {
                mine.append(peer.value)
            }
        }
        let messageReactions = order.map { value in
            return MessageReaction(value: value, count: counts[value] ?? 0, chosenOrder: mine.firstIndex(of: value))
        }
        return ReactionsMessageAttribute(canViewList: true, isTags: false, reactions: messageReactions, recentPeers: recentPeers, topPeers: [])
    }

    /// Built-in emoji become their Unicode value; custom emoji keep `:name:` until they get files (Phase 2).
    static func reactionValue(_ emojiName: String) -> MessageReaction.Reaction {
        return .builtin(EmojiTable.unicode(forName: emojiName) ?? ":\(emojiName):")
    }

    private static func mentionsMe(_ formatted: FormattedText, kind: ChatKind, ownUsername: String) -> Bool {
        if kind == .direct {
            return true
        }
        for entity in formatted.entities {
            switch entity.type {
            case let .mention(username):
                if username == ownUsername {
                    return true
                }
            case .specialMention:
                if kind == .channel {
                    return true
                }
            default:
                break
            }
        }
        return false
    }

    private static func textEntity(_ entity: TextEntity, context: PostConversionContext) -> MessageTextEntity? {
        let type: MessageTextEntityType
        switch entity.type {
        case .bold:
            type = .Bold
        case .italic:
            type = .Italic
        case .strikethrough:
            type = .Strikethrough
        case .underline:
            type = .Underline
        case .code:
            type = .Code
        case let .pre(language):
            type = .Pre(language: language)
        case let .textUrl(url):
            type = .TextUrl(url: url)
        case .url:
            type = .Url
        case .email:
            type = .Email
        case let .mention(username):
            // A known user opens their profile locally; Telegram's `.Mention` would resolve the name online.
            if let peerId = context.usernamePeerId(username) {
                type = .TextMention(peerId: peerId)
            } else {
                type = .Bold
            }
        case let .channelMention(name):
            type = .TextUrl(url: "\(context.serverURL)/_redirect/channels/\(name)")
        case .specialMention:
            type = .Bold
        case .blockQuote:
            type = .BlockQuote(isCollapsed: false)
        case .hashtag:
            type = .Hashtag
        case .customEmoji:
            return nil
        }
        return MessageTextEntity(range: entity.range, type: type)
    }

    static func stringProps(_ props: [String: JSONValue]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in props {
            if let string = value.scalarString {
                result[key] = string
            }
        }
        return result
    }
}

extension StoreMessage {
    /// Rebuilds a stored message under a new id (renumbering) or with changed thread references.
    static func mmCopy(of message: Message, id: MessageId, threadId: Int64?, attributes: [MessageAttribute]) -> StoreMessage {
        return StoreMessage(
            id: id,
            customStableId: nil,
            globallyUniqueId: message.globallyUniqueId,
            groupingKey: message.groupingKey,
            threadId: threadId,
            timestamp: message.timestamp,
            flags: StoreMessageFlags(message.flags),
            tags: message.tags,
            globalTags: message.globalTags,
            localTags: message.localTags,
            forwardInfo: message.forwardInfo.flatMap(StoreMessageForwardInfo.init),
            authorId: message.author?.id,
            text: message.text,
            attributes: attributes,
            media: message.media
        )
    }
}
