import Foundation

/// What kind of chat a push is about, from the recipient account's sync store when it knows the channel.
public enum MattermostPushChannelKind: Equatable, Sendable {
    case direct
    case group
    case channel
    case unknown
}

/// The text of one notification.
public struct MattermostPushText: Equatable, Sendable {
    /// The conversation: the sender for a DM, the channel ("Reply in …" for a thread reply) otherwise.
    public var title: String
    /// Shown only when the notification is not drawn as a communication notification (iOS hides it then).
    public var subtitle: String?
    public var body: String
    /// The person shown with the notification (communication notification, avatar).
    public var senderName: String?
    /// Channels and group messages: the group the intent names, so iOS draws the channel as the title.
    public var groupName: String?
    /// `threadIdentifier`: one notification group per channel.
    public var threadIdentifier: String
    /// Whether to send it as a communication notification (`INSendMessageIntent`) with the sender.
    public var isCommunication: Bool

    public init(title: String, subtitle: String? = nil, body: String, senderName: String?, groupName: String?, threadIdentifier: String, isCommunication: Bool) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.senderName = senderName
        self.groupName = groupName
        self.threadIdentifier = threadIdentifier
        self.isCommunication = isCommunication
    }
}

/// Builds the notification text from a push.
///
/// Mattermost already writes the text for the recipient (in their language) according to the server's push
/// contents setting:
/// - **full**: `message` is `"sender: text"` in channels and the text alone in DMs; `channel_name` is the
///   channel, or the other user's name for a DM, or "Reply in <channel>" / "Reply in Direct Message" for
///   collapsed-thread replies;
/// - **generic**: `message` is "sender posted in channel" or similar, without the text;
/// - **ID-only** (licensed servers): a placeholder until the extension fetches the post.
///
/// This keeps the server's wording and only arranges it: DMs are titled by the sender and lose the sender
/// prefix, channels are titled by the channel with the sender in the body, thread replies say so in the
/// title.
public enum MattermostPushTextBuilder {
    public static func text(for payload: MattermostPushPayload, kind: MattermostPushChannelKind, siteName: String?) -> MattermostPushText {
        let threadIdentifier = payload.channelId ?? payload.threadIdentifier ?? "mattermost"
        let sender = nonEmpty(payload.overrideUsername) ?? nonEmpty(payload.senderName)
        let site = nonEmpty(siteName) ?? "Mattermost"

        switch payload.type {
        case .session:
            return MattermostPushText(
                title: "Session Expired",
                body: "Your session on \(site) has ended. Open Relay to log in again.",
                senderName: nil,
                groupName: nil,
                threadIdentifier: "mattermost-session",
                isCommunication: false
            )
        case .test:
            return MattermostPushText(
                title: site,
                body: nonEmpty(payload.message) ?? "Test notification",
                senderName: nil,
                groupName: nil,
                threadIdentifier: "mattermost-test",
                isCommunication: false
            )
        case .clear, .updateBadge:
            return MattermostPushText(title: "", body: "", senderName: nil, groupName: nil, threadIdentifier: threadIdentifier, isCommunication: false)
        case .message, .other:
            break
        }

        let channelName = nonEmpty(payload.channelName) ?? nonEmpty(payload.alertTitle)
        var resolvedKind = kind
        if resolvedKind == .unknown {
            // A DM's `channel_name` is the sender's name (the server names a DM after the other user).
            if let channelName = channelName, let sender = sender, channelName == sender {
                resolvedKind = .direct
            } else {
                resolvedKind = .channel
            }
        }
        var body = nonEmpty(payload.message) ?? "New message"
        let isReply = payload.isThreadReply

        switch resolvedKind {
        case .direct:
            if let sender = sender {
                body = stripSenderPrefix(body, sender: sender)
            }
            let title = sender ?? channelName ?? site
            return MattermostPushText(
                title: title,
                subtitle: isReply ? "Reply in thread" : nil,
                body: body,
                senderName: sender ?? title,
                groupName: nil,
                threadIdentifier: threadIdentifier,
                isCommunication: true
            )
        case .group, .channel, .unknown:
            var title = channelName ?? site
            // Collapsed threads: the server already titles replies "Reply in <channel>"; without collapsed
            // threads it sends the plain channel name.
            if isReply && !payload.isCRTEnabled {
                title = "Reply in \(title)"
            }
            if let sender = sender {
                // The group intent shows the sender with its avatar; the body keeps the server's
                // "sender: text" only when there is no sender to show.
                body = stripSenderPrefix(body, sender: sender)
            }
            return MattermostPushText(
                title: title,
                body: body,
                senderName: sender,
                groupName: title,
                threadIdentifier: threadIdentifier,
                isCommunication: sender != nil
            )
        }
    }

    /// Text for a notification whose content must stay hidden (passcode lock): no sender, no text.
    public static func lockedText(for payload: MattermostPushPayload, placeholder: String) -> MattermostPushText {
        return MattermostPushText(title: "", body: placeholder, senderName: nil, groupName: nil, threadIdentifier: payload.channelId ?? "mattermost", isCommunication: false)
    }

    /// `"bob: hello"` → `"hello"` when the prefix is the sender.
    static func stripSenderPrefix(_ text: String, sender: String) -> String {
        let prefix = sender + ": "
        if text.hasPrefix(prefix) && text.count > prefix.count {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return value
}
