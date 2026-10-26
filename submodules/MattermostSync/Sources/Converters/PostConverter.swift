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
}

/// Mattermost posts → Postbox `StoreMessage`s (design: "Writing a page of posts", step 3).
enum PostConverter {
    static func storeMessage(post: Post, localId: Int32, context: PostConversionContext) -> StoreMessage {
        let messageId = MessageId(peerId: context.chatPeerId, namespace: Namespaces.Message.Cloud, id: localId)
        let isIncoming = post.userId != context.ownUserId
        let flags: StoreMessageFlags = isIncoming ? [.Incoming] : []
        var tags: MessageTags = []
        var attributes: [MessageAttribute] = []
        var media: [Media] = []
        var text = ""

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
        if !post.rootId.isEmpty, let rootLocalId = context.localId(post.rootId) {
            let rootMessageId = MessageId(peerId: context.chatPeerId, namespace: Namespaces.Message.Cloud, id: rootLocalId)
            if context.kind == .channel {
                threadId = Int64(rootLocalId)
            }
            attributes.append(ReplyMessageAttribute(messageId: rootMessageId, threadMessageId: context.kind == .channel ? rootMessageId : nil, quote: nil, isQuote: false, innerSubject: nil))
        }

        if post.type.hasPrefix("system_") {
            let action = ServiceAction.from(type: post.type, userId: post.userId, message: post.message, props: stringProps(post.props))
            let actionText = action?.fallbackText(name: { reference in
                if let userId = reference.userId, let name = context.userDisplayName(userId) {
                    return name
                }
                if let username = reference.username {
                    return "@\(username)"
                }
                return "Someone"
            }) ?? post.message
            media.append(TelegramMediaAction(action: .customText(text: actionText, entities: [], additionalAttributes: nil)))
        } else {
            var markdown = post.message
            let attachmentText = attachmentsText(post.props)
            if !attachmentText.isEmpty {
                markdown = markdown.isEmpty ? attachmentText : markdown + "\n\n" + attachmentText
            }
            let formatted = MattermostMarkdown.parse(markdown)
            text = formatted.text
            var entities = formatted.entities.compactMap { entity in
                return textEntity(entity, context: context)
            }
            if post.type == "me", !text.isEmpty {
                entities.insert(MessageTextEntity(range: 0 ..< (text as NSString).length, type: .Italic), at: 0)
            }
            if !entities.isEmpty {
                attributes.append(TextEntitiesMessageAttribute(entities: entities))
            }
            if isIncoming && post.createAt > context.lastViewedAt && mentionsMe(formatted, kind: context.kind, ownUsername: context.ownUsername) {
                tags.insert(.unseenPersonalMessage)
            }

            for file in post.metadata?.files ?? [] where file.deleteAt == 0 {
                let converted = MediaConverter.media(for: file, mediaId: context.mediaId(file.id))
                media.append(converted.media)
                tags.formUnion(converted.tags)
            }
        }

        if post.rootId.isEmpty && post.replyCount > 0 {
            let latestUsers = (post.participants ?? []).prefix(3).compactMap { context.userPeerId($0.id) }
            attributes.append(ReplyThreadMessageAttribute(count: Int32(clamping: post.replyCount), latestUsers: Array(latestUsers), commentsPeerId: nil, maxMessageId: nil, maxReadMessageId: nil))
        }
        if post.editAt > 0 {
            attributes.append(EditedMessageAttribute(date: mmSeconds(post.editAt), isHidden: false))
        }
        if let reactions = reactionsAttribute(post.metadata?.reactions ?? [], context: context) {
            attributes.append(reactions)
        }
        if post.isPinned {
            tags.insert(.pinned)
        }

        return StoreMessage(
            id: messageId,
            customStableId: nil,
            globallyUniqueId: nil,
            groupingKey: nil,
            threadId: threadId,
            timestamp: mmSeconds(post.createAt),
            flags: flags,
            tags: tags,
            globalTags: [],
            localTags: [],
            forwardInfo: nil,
            authorId: context.userPeerId(post.userId),
            text: text,
            attributes: attributes,
            media: media
        )
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

    /// Slack-style attachments (bots, webhooks) as markdown text until they get their own rendering.
    private static func attachmentsText(_ props: [String: JSONValue]) -> String {
        guard let attachments = props["attachments"]?.arrayValue else {
            return ""
        }
        var blocks: [String] = []
        for attachment in attachments {
            guard let object = attachment.objectValue else {
                continue
            }
            var lines: [String] = []
            for key in ["pretext", "author_name"] {
                if let value = object[key]?.stringValue, !value.isEmpty {
                    lines.append(value)
                }
            }
            if let title = object["title"]?.stringValue, !title.isEmpty {
                if let link = object["title_link"]?.stringValue, !link.isEmpty {
                    lines.append("**[\(title)](\(link))**")
                } else {
                    lines.append("**\(title)**")
                }
            }
            if let value = object["text"]?.stringValue, !value.isEmpty {
                lines.append(value)
            }
            for field in object["fields"]?.arrayValue ?? [] {
                guard let field = field.objectValue else {
                    continue
                }
                let title = field["title"]?.stringValue ?? ""
                let value = field["value"]?.scalarString ?? ""
                if !title.isEmpty || !value.isEmpty {
                    lines.append(title.isEmpty ? value : "**\(title):** \(value)")
                }
            }
            let actions = (object["actions"]?.arrayValue ?? []).compactMap { $0.objectValue?["name"]?.stringValue }
            if !actions.isEmpty {
                lines.append(actions.map { "[\($0)]" }.joined(separator: " "))
            }
            if let footer = object["footer"]?.stringValue, !footer.isEmpty {
                lines.append("_\(footer)_")
            }
            if !lines.isEmpty {
                blocks.append(lines.map { "> " + $0 }.joined(separator: "\n"))
            }
        }
        return blocks.joined(separator: "\n\n")
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
