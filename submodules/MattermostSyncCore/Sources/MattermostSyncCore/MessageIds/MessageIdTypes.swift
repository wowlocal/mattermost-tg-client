import Foundation

/// The ordering key of a Mattermost post inside one channel: `(create_at ms, post id)`.
///
/// Local message ids are strictly increasing in this order within a channel. Post ids are
/// compared byte-wise (UTF-8), which matches SQLite's `BINARY` collation, so a SQL-backed
/// store can use `ORDER BY create_at, post_id` and agree with this type.
public struct PostOrderKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var createAt: Int64
    public var postId: String

    public init(createAt: Int64, postId: String) {
        self.createAt = createAt
        self.postId = postId
    }

    public static func < (lhs: PostOrderKey, rhs: PostOrderKey) -> Bool {
        if lhs.createAt != rhs.createAt {
            return lhs.createAt < rhs.createAt
        }
        return lhs.postId.utf8.lexicographicallyPrecedes(rhs.postId.utf8)
    }

    /// A key that sorts after every real post created at `createAt` (useful for "created at or before" queries).
    public static func upperBound(createAt: Int64) -> PostOrderKey {
        return PostOrderKey(createAt: createAt, postId: "\u{10FFFF}")
    }

    /// A key that sorts before every real post created at `createAt`.
    public static func lowerBound(createAt: Int64) -> PostOrderKey {
        return PostOrderKey(createAt: createAt, postId: "")
    }

    public var description: String {
        return "\(createAt)/\(postId)"
    }
}

/// One row of the persistent ID map: a Mattermost post and its local Telegram message id.
public struct MessageIdEntry: Hashable, Sendable, CustomStringConvertible {
    public var key: PostOrderKey
    public var localId: Int32
    /// Tombstone flag. A deleted post keeps its id (so the slot is never reused and a late
    /// `posted` event can't resurrect it).
    public var isDeleted: Bool

    public init(key: PostOrderKey, localId: Int32, isDeleted: Bool = false) {
        self.key = key
        self.localId = localId
        self.isDeleted = isDeleted
    }

    public var postId: String { return key.postId }
    public var createAt: Int64 { return key.createAt }

    public var description: String {
        return "\(localId)=\(key)\(isDeleted ? "(deleted)" : "")"
    }
}

/// A contiguous loaded stretch of a channel's history: every post whose key lies in
/// `lower...upper` is known to the ID map. Islands are stored by post keys (not local ids),
/// so renumbering never invalidates them.
public struct HistoryIsland: Hashable, Sendable, CustomStringConvertible {
    public var lower: PostOrderKey
    public var upper: PostOrderKey
    /// Nothing older than `lower` exists on the server (only meaningful for the lowest island).
    public var reachesStart: Bool
    /// Nothing newer than `upper` exists on the server and the island is kept live
    /// (only meaningful for the highest island).
    public var reachesLatest: Bool

    public init(lower: PostOrderKey, upper: PostOrderKey, reachesStart: Bool = false, reachesLatest: Bool = false) {
        self.lower = lower
        self.upper = upper
        self.reachesStart = reachesStart
        self.reachesLatest = reachesLatest
    }

    public func contains(_ key: PostOrderKey) -> Bool {
        return !(key < lower) && !(upper < key)
    }

    public var description: String {
        return "[\(lower) … \(upper)\(reachesStart ? " start" : "")\(reachesLatest ? " latest" : "")]"
    }
}

/// An island with the local ids of its boundary posts resolved.
public struct HistoryIslandSummary: Hashable, Sendable {
    public var island: HistoryIsland
    public var range: ClosedRange<Int32>
}

/// A gap in the local id space where posts may exist on the server but are not loaded.
/// `range` is suitable for Postbox's hole index (Int32 id ranges per peer and namespace).
public struct HistoryHole: Hashable, Sendable, CustomStringConvertible {
    public var range: ClosedRange<Int32>
    /// The loaded post just below the hole (nil: the hole reaches the start of the id space).
    public var lowerBoundary: PostOrderKey?
    /// The loaded post just above the hole (nil: the hole reaches the top of the id space).
    public var upperBoundary: PostOrderKey?

    public init(range: ClosedRange<Int32>, lowerBoundary: PostOrderKey?, upperBoundary: PostOrderKey?) {
        self.range = range
        self.lowerBoundary = lowerBoundary
        self.upperBoundary = upperBoundary
    }

    /// The Mattermost cursor that loads posts into this hole, moving in `direction`.
    /// `.older` fills from the hole's upper edge (`before=` the post above it, or the latest page
    /// when nothing is above); `.newer` fills from the lower edge (`after=` the post below it, or
    /// nil when nothing is below, because Mattermost can't page forward from the channel start).
    public func cursor(direction: HistoryDirection) -> HistoryCursor? {
        switch direction {
        case .older:
            if let upper = upperBoundary {
                return .before(postId: upper.postId)
            }
            return .latest
        case .newer:
            if let lower = lowerBoundary {
                return .after(postId: lower.postId)
            }
            return nil
        }
    }

    public var description: String {
        return "hole(\(range.lowerBound)...\(range.upperBound))"
    }
}

/// Paging direction relative to a boundary post.
public enum HistoryDirection: Sendable, Hashable {
    /// Towards older posts (`before=`), i.e. towards lower local ids.
    case older
    /// Towards newer posts (`after=`), i.e. towards higher local ids.
    case newer
}

/// A Mattermost `GET /channels/{id}/posts` cursor.
public enum HistoryCursor: Hashable, Sendable {
    /// No cursor: the newest page (`page=0`).
    case latest
    case before(postId: String)
    case after(postId: String)
    /// `GET /posts/{id}` + `before=id` + `after=id`.
    case around(postId: String)
}

/// One id change in a renumber plan.
public struct RenumberMove: Hashable, Sendable, CustomStringConvertible {
    public var postId: String
    public var from: Int32
    public var to: Int32

    public init(postId: String, from: Int32, to: Int32) {
        self.postId = postId
        self.from = from
        self.to = to
    }

    public var description: String {
        return "\(postId): \(from)→\(to)"
    }
}

/// Existing posts whose local ids change. Apply in one Postbox transaction: delete every
/// message at a `from` id first, then re-insert each at its `to` id (ids may be swapped
/// between moved posts, so interleaving delete/insert per move is not safe). Every other
/// stored local id (read state, thread ids, reply references) must be remapped too.
/// Holes inside `affectedRange` should be recomputed from `IngestResult.holes`.
public struct RenumberPlan: Hashable, Sendable {
    public var moves: [RenumberMove]
    /// The id range that contains every `from` and `to` id of the plan.
    public var affectedRange: ClosedRange<Int32>

    public init(moves: [RenumberMove], affectedRange: ClosedRange<Int32>) {
        self.moves = moves
        self.affectedRange = affectedRange
    }

    public func newId(for oldId: Int32) -> Int32? {
        return moves.first(where: { $0.from == oldId })?.to
    }
}

/// What happened to one post of an ingested batch.
public struct PostAllocation: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        /// The post was new and got `localId`.
        case inserted
        /// The post was already mapped (idempotent replay); `localId` is its current id.
        case existing
        /// The post is tombstoned; don't (re)insert the message. `localId` is nil when the
        /// post was deleted before it was ever mapped.
        case deleted
    }

    public var postId: String
    public var localId: Int32?
    public var status: Status

    public init(postId: String, localId: Int32?, status: Status) {
        self.postId = postId
        self.localId = localId
        self.status = status
    }
}

/// The outcome of one allocator operation.
public struct IngestResult: Hashable, Sendable {
    /// One entry per distinct input post, sorted by `PostOrderKey`.
    public var allocations: [PostAllocation]
    /// Non-nil when existing posts had to move. Apply it before inserting the new messages.
    public var renumberPlan: RenumberPlan?
    /// Local id range of the island that now contains the batch. Everything in it is loaded,
    /// so the caller can remove this whole range from Postbox's hole index.
    public var islandRange: ClosedRange<Int32>?
    /// How many previously separate islands the batch touched. `>= 2` means a hole was closed.
    public var joinedIslandCount: Int
    /// All holes of the channel after the operation.
    public var holes: [HistoryHole]

    public init(allocations: [PostAllocation] = [], renumberPlan: RenumberPlan? = nil, islandRange: ClosedRange<Int32>? = nil, joinedIslandCount: Int = 0, holes: [HistoryHole] = []) {
        self.allocations = allocations
        self.renumberPlan = renumberPlan
        self.islandRange = islandRange
        self.joinedIslandCount = joinedIslandCount
        self.holes = holes
    }

    /// True when the batch reached an existing island (the hole between them is closed).
    public var didCloseHole: Bool {
        return joinedIslandCount >= 2
    }

    public var insertedCount: Int {
        return allocations.reduce(0) { $0 + ($1.status == .inserted ? 1 : 0) }
    }

    public func localId(for postId: String) -> Int32? {
        return allocations.first(where: { $0.postId == postId })?.localId
    }
}

public enum MessageIdAllocationError: Error, Hashable, Sendable {
    /// `ingestPage(extending:)` was called with an anchor that isn't mapped.
    case unknownAnchor(postId: String)
    /// The channel has more posts than the id space can hold.
    case capacityExhausted(channelId: String)
}
