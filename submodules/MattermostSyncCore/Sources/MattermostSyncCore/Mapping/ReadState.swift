import Foundation

/// The channel and channel-member counters Mattermost exposes for unread state.
public struct ChannelReadCounters: Hashable, Sendable {
    /// `member.last_viewed_at` (ms).
    public var lastViewedAt: Int64
    /// `channel.total_msg_count` / `channel.total_msg_count_root`.
    public var totalMessageCount: Int64
    public var totalMessageCountRoot: Int64
    /// `member.msg_count` / `member.msg_count_root`.
    public var memberMessageCount: Int64
    public var memberMessageCountRoot: Int64
    /// `member.mention_count` / `member.mention_count_root`.
    public var mentionCount: Int64
    public var mentionCountRoot: Int64
    /// Collapsed reply threads on for this user: use the `_root` counters.
    public var collapsedThreads: Bool

    public init(
        lastViewedAt: Int64,
        totalMessageCount: Int64,
        totalMessageCountRoot: Int64 = 0,
        memberMessageCount: Int64,
        memberMessageCountRoot: Int64 = 0,
        mentionCount: Int64,
        mentionCountRoot: Int64 = 0,
        collapsedThreads: Bool = false
    ) {
        self.lastViewedAt = lastViewedAt
        self.totalMessageCount = totalMessageCount
        self.totalMessageCountRoot = totalMessageCountRoot
        self.memberMessageCount = memberMessageCount
        self.memberMessageCountRoot = memberMessageCountRoot
        self.mentionCount = mentionCount
        self.mentionCountRoot = mentionCountRoot
        self.collapsedThreads = collapsedThreads
    }
}

/// Values for Telegram's id-based peer read state (`PeerReadState.idBased`) plus the mention badge.
public struct ChannelReadState: Hashable, Sendable {
    /// Local id of the newest known post with `create_at <= last_viewed_at`, or 0 when none is known.
    public var maxIncomingReadId: Int32
    /// Always 0: Mattermost has no per-message receipts (single "sent" check).
    public var maxOutgoingReadId: Int32
    /// Newest known local id, or 0 for an empty channel.
    public var maxKnownId: Int32
    /// `total_msg_count - msg_count` (root variants with CRT), never negative.
    public var unreadCount: Int32
    /// `mention_count` (root variant with CRT).
    public var mentionCount: Int32

    public init(maxIncomingReadId: Int32, maxOutgoingReadId: Int32 = 0, maxKnownId: Int32, unreadCount: Int32, mentionCount: Int32) {
        self.maxIncomingReadId = maxIncomingReadId
        self.maxOutgoingReadId = maxOutgoingReadId
        self.maxKnownId = maxKnownId
        self.unreadCount = unreadCount
        self.mentionCount = mentionCount
    }

    public var isUnread: Bool {
        return unreadCount > 0
    }
}

public enum ReadStateMapper {
    /// A known post of the channel, as stored in the ID map.
    public struct KnownPost: Hashable, Sendable {
        public var localId: Int32
        public var createAt: Int64

        public init(localId: Int32, createAt: Int64) {
            self.localId = localId
            self.createAt = createAt
        }
    }

    /// Computes the read state from a list of known posts (any order).
    public static func readState(knownPosts: [KnownPost], counters: ChannelReadCounters) -> ChannelReadState {
        var maxRead: Int32 = 0
        var maxKnown: Int32 = 0
        for post in knownPosts {
            maxKnown = max(maxKnown, post.localId)
            if post.createAt <= counters.lastViewedAt {
                maxRead = max(maxRead, post.localId)
            }
        }
        return makeState(maxIncomingReadId: maxRead, maxKnownId: maxKnown, counters: counters)
    }

    /// Computes the read state with two indexed store lookups instead of a full scan.
    public static func readState<Store: MessageIdStore>(channelId: String, store: Store, counters: ChannelReadCounters) -> ChannelReadState {
        let newest = store.entries(channelId: channelId, olderThan: nil, limit: 1).first
        let newestRead = store.entries(channelId: channelId, olderThan: PostOrderKey.upperBound(createAt: counters.lastViewedAt), limit: 1).first
        return makeState(maxIncomingReadId: newestRead?.localId ?? 0, maxKnownId: newest?.localId ?? 0, counters: counters)
    }

    private static func makeState(maxIncomingReadId: Int32, maxKnownId: Int32, counters: ChannelReadCounters) -> ChannelReadState {
        let total = counters.collapsedThreads ? counters.totalMessageCountRoot : counters.totalMessageCount
        let read = counters.collapsedThreads ? counters.memberMessageCountRoot : counters.memberMessageCount
        let mentions = counters.collapsedThreads ? counters.mentionCountRoot : counters.mentionCount
        return ChannelReadState(
            maxIncomingReadId: maxIncomingReadId,
            maxKnownId: maxKnownId,
            unreadCount: clampToInt32(total - read),
            mentionCount: clampToInt32(mentions)
        )
    }

    private static func clampToInt32(_ value: Int64) -> Int32 {
        return Int32(max(0, min(Int64(Int32.max), value)))
    }
}
