import Foundation

/// A batch of mutations produced by one allocator operation. A persistent store should apply
/// it atomically (one SQLite / Postbox transaction), in this order: `renumbered`, `inserted`,
/// `deletedPostIds`, `unmappedTombstones`, `islands`.
public struct MessageIdChangeSet: Hashable, Sendable {
    public var channelId: String
    /// Existing entries whose local id changes.
    public var renumbered: [RenumberMove]
    /// New entries (with their final local ids).
    public var inserted: [MessageIdEntry]
    /// Mapped posts to flag as deleted.
    public var deletedPostIds: [String]
    /// Posts deleted before they were ever mapped; remembered so they're never inserted later.
    public var unmappedTombstones: [String]
    /// When non-nil, replaces the channel's island list.
    public var islands: [HistoryIsland]?

    public init(channelId: String, renumbered: [RenumberMove] = [], inserted: [MessageIdEntry] = [], deletedPostIds: [String] = [], unmappedTombstones: [String] = [], islands: [HistoryIsland]? = nil) {
        self.channelId = channelId
        self.renumbered = renumbered
        self.inserted = inserted
        self.deletedPostIds = deletedPostIds
        self.unmappedTombstones = unmappedTombstones
        self.islands = islands
    }

    public var isEmpty: Bool {
        return renumbered.isEmpty && inserted.isEmpty && deletedPostIds.isEmpty && unmappedTombstones.isEmpty && islands == nil
    }
}

/// Persistence for the post ↔ local message id map of every channel.
///
/// The allocator only reads through these queries and writes through `apply(_:)`, once per
/// operation, so a SQLite/Postbox implementation can run each operation inside a single
/// transaction. Required indexes: `(channel, post_id)`, `(channel, create_at, post_id)` and
/// `(channel, local_id)`. Within a channel the `(create_at, post_id)` order and the `local_id`
/// order are always the same.
public protocol MessageIdStore {
    /// Mapped entries (including tombstoned ones) for the given post ids. Unknown ids are absent.
    func entries(channelId: String, postIds: [String]) -> [String: MessageIdEntry]

    /// Entries with `keyRange.lowerBound <= key <= keyRange.upperBound`, ascending.
    func entries(channelId: String, keyRange: ClosedRange<PostOrderKey>) -> [MessageIdEntry]

    /// Up to `limit` entries strictly older than `key` (all entries when `key` is nil),
    /// nearest first (descending order).
    func entries(channelId: String, olderThan key: PostOrderKey?, limit: Int) -> [MessageIdEntry]

    /// Up to `limit` entries strictly newer than `key` (all entries when `key` is nil),
    /// nearest first (ascending order).
    func entries(channelId: String, newerThan key: PostOrderKey?, limit: Int) -> [MessageIdEntry]

    /// Up to `limit` entries starting at `localId` (inclusive), ascending or descending by id.
    func entries(channelId: String, fromLocalId localId: Int32, ascending: Bool, limit: Int) -> [MessageIdEntry]

    /// The channel's islands, sorted ascending. Usually a handful.
    func islands(channelId: String) -> [HistoryIsland]

    /// The subset of `postIds` that were deleted before ever being mapped.
    func unmappedTombstones(channelId: String, among postIds: [String]) -> Set<String>

    /// Applies one operation's changes atomically.
    mutating func apply(_ changes: MessageIdChangeSet)
}

/// A value-type `MessageIdStore` kept in memory. Used by tests and as a reference
/// implementation for the persistent store.
public struct InMemoryMessageIdStore: MessageIdStore, Sendable {
    struct Channel: Sendable {
        /// Sorted by key (and therefore by local id).
        var entries: [MessageIdEntry] = []
        var keyByPostId: [String: PostOrderKey] = [:]
        var islands: [HistoryIsland] = []
        var tombstones: Set<String> = []

        func index(ofFirstKeyNotLessThan key: PostOrderKey) -> Int {
            var low = 0
            var high = entries.count
            while low < high {
                let mid = (low + high) / 2
                if entries[mid].key < key {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return low
        }

        func index(ofFirstKeyGreaterThan key: PostOrderKey) -> Int {
            var low = 0
            var high = entries.count
            while low < high {
                let mid = (low + high) / 2
                if key < entries[mid].key {
                    high = mid
                } else {
                    low = mid + 1
                }
            }
            return low
        }

        func index(ofFirstLocalIdNotLessThan localId: Int32) -> Int {
            var low = 0
            var high = entries.count
            while low < high {
                let mid = (low + high) / 2
                if entries[mid].localId < localId {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return low
        }

        func index(of key: PostOrderKey) -> Int? {
            let index = index(ofFirstKeyNotLessThan: key)
            if index < entries.count && entries[index].key == key {
                return index
            }
            return nil
        }
    }

    private var channels: [String: Channel] = [:]

    public init() {
    }

    // MARK: MessageIdStore

    public func entries(channelId: String, postIds: [String]) -> [String: MessageIdEntry] {
        guard let channel = channels[channelId] else {
            return [:]
        }
        var result: [String: MessageIdEntry] = [:]
        for postId in postIds {
            if let key = channel.keyByPostId[postId], let index = channel.index(of: key) {
                result[postId] = channel.entries[index]
            }
        }
        return result
    }

    public func entries(channelId: String, keyRange: ClosedRange<PostOrderKey>) -> [MessageIdEntry] {
        guard let channel = channels[channelId] else {
            return []
        }
        let start = channel.index(ofFirstKeyNotLessThan: keyRange.lowerBound)
        let end = channel.index(ofFirstKeyGreaterThan: keyRange.upperBound)
        if start >= end {
            return []
        }
        return Array(channel.entries[start ..< end])
    }

    public func entries(channelId: String, olderThan key: PostOrderKey?, limit: Int) -> [MessageIdEntry] {
        guard let channel = channels[channelId], limit > 0 else {
            return []
        }
        let end = key.map { channel.index(ofFirstKeyNotLessThan: $0) } ?? channel.entries.count
        let start = max(0, end - limit)
        return channel.entries[start ..< end].reversed()
    }

    public func entries(channelId: String, newerThan key: PostOrderKey?, limit: Int) -> [MessageIdEntry] {
        guard let channel = channels[channelId], limit > 0 else {
            return []
        }
        let start = key.map { channel.index(ofFirstKeyGreaterThan: $0) } ?? 0
        // `start + limit` would overflow for limits near Int.max.
        let end = start + min(limit, channel.entries.count - start)
        if start >= end {
            return []
        }
        return Array(channel.entries[start ..< end])
    }

    public func entries(channelId: String, fromLocalId localId: Int32, ascending: Bool, limit: Int) -> [MessageIdEntry] {
        guard let channel = channels[channelId], limit > 0 else {
            return []
        }
        if ascending {
            let start = channel.index(ofFirstLocalIdNotLessThan: localId)
            let end = start + min(limit, channel.entries.count - start)
            if start >= end {
                return []
            }
            return Array(channel.entries[start ..< end])
        } else {
            var end = channel.index(ofFirstLocalIdNotLessThan: localId)
            if end < channel.entries.count && channel.entries[end].localId == localId {
                end += 1
            }
            let start = max(0, end - limit)
            return channel.entries[start ..< end].reversed()
        }
    }

    public func islands(channelId: String) -> [HistoryIsland] {
        return channels[channelId]?.islands ?? []
    }

    public func unmappedTombstones(channelId: String, among postIds: [String]) -> Set<String> {
        guard let channel = channels[channelId], !channel.tombstones.isEmpty else {
            return []
        }
        return Set(postIds.filter { channel.tombstones.contains($0) })
    }

    public mutating func apply(_ changes: MessageIdChangeSet) {
        if changes.isEmpty {
            return
        }
        var channel = channels.removeValue(forKey: changes.channelId) ?? Channel()

        // Renumbering never changes key order, so entries are updated in place.
        for move in changes.renumbered {
            if let key = channel.keyByPostId[move.postId], let index = channel.index(of: key) {
                channel.entries[index].localId = move.to
            }
        }

        if !changes.inserted.isEmpty {
            var inserted = changes.inserted.filter { channel.keyByPostId[$0.postId] == nil }
            inserted.sort { $0.key < $1.key }
            var merged: [MessageIdEntry] = []
            merged.reserveCapacity(channel.entries.count + inserted.count)
            var i = 0
            var j = 0
            while i < channel.entries.count || j < inserted.count {
                if j >= inserted.count || (i < channel.entries.count && channel.entries[i].key < inserted[j].key) {
                    merged.append(channel.entries[i])
                    i += 1
                } else {
                    merged.append(inserted[j])
                    j += 1
                }
            }
            channel.entries = merged
            for entry in inserted {
                channel.keyByPostId[entry.postId] = entry.key
            }
        }

        for postId in changes.deletedPostIds {
            if let key = channel.keyByPostId[postId], let index = channel.index(of: key) {
                channel.entries[index].isDeleted = true
            }
        }
        for postId in changes.unmappedTombstones where channel.keyByPostId[postId] == nil {
            channel.tombstones.insert(postId)
        }
        if let islands = changes.islands {
            channel.islands = islands
        }
        channels[changes.channelId] = channel
    }

    // MARK: Inspection (tests, debugging)

    /// All entries of a channel in key order.
    public func allEntries(channelId: String) -> [MessageIdEntry] {
        return channels[channelId]?.entries ?? []
    }

    /// Removes everything known about a channel (full resync).
    public mutating func removeChannel(_ channelId: String) {
        channels.removeValue(forKey: channelId)
    }

    /// Checks the store invariants and returns a description of every violation found.
    public func validate(channelId: String, maxId: Int32 = Int32.max) -> [String] {
        guard let channel = channels[channelId] else {
            return []
        }
        var problems: [String] = []
        for entry in channel.entries where channel.keyByPostId[entry.postId] != entry.key {
            problems.append("post id index out of sync: \(entry)")
        }
        if channel.keyByPostId.count != channel.entries.count {
            problems.append("post id index has \(channel.keyByPostId.count) rows for \(channel.entries.count) entries")
        }
        return Self.invariantProblems(entries: channel.entries, islands: channel.islands, maxId: maxId) + problems
    }

    /// The id map invariants of one channel, given its entries in key order and its islands
    /// (shared with persistent stores).
    static func invariantProblems(entries: [MessageIdEntry], islands: [HistoryIsland], maxId: Int32) -> [String] {
        var channel = Channel()
        channel.entries = entries
        channel.islands = islands
        var problems: [String] = []
        var previous: MessageIdEntry?
        var seenIds = Set<Int32>()
        for entry in channel.entries {
            if entry.localId < 1 || entry.localId > maxId {
                problems.append("id out of range: \(entry)")
            }
            if !seenIds.insert(entry.localId).inserted {
                problems.append("duplicate id: \(entry)")
            }
            if let previous = previous {
                if !(previous.key < entry.key) {
                    problems.append("keys not strictly increasing: \(previous) then \(entry)")
                }
                if !(previous.localId < entry.localId) {
                    problems.append("ids not strictly increasing: \(previous) then \(entry)")
                }
            }
            previous = entry
        }
        var previousIsland: HistoryIsland?
        var boundaryIds: [(Int32, Int32)] = []
        for island in channel.islands {
            if island.upper < island.lower {
                problems.append("inverted island \(island)")
            }
            if let previousIsland = previousIsland, !(previousIsland.upper < island.lower) {
                problems.append("overlapping or unsorted islands \(previousIsland) \(island)")
            }
            let lowerIndex = channel.index(of: island.lower)
            let upperIndex = channel.index(of: island.upper)
            if lowerIndex == nil || upperIndex == nil {
                problems.append("island boundary is not an entry: \(island)")
            } else {
                boundaryIds.append((channel.entries[lowerIndex!].localId, channel.entries[upperIndex!].localId))
            }
            previousIsland = island
        }
        for i in 1 ..< max(1, boundaryIds.count) {
            if boundaryIds[i - 1].1 + 1 > boundaryIds[i].0 - 1 {
                problems.append("no free id between islands \(i - 1) and \(i)")
            }
        }
        var islandIndex = 0
        for entry in channel.entries {
            while islandIndex < channel.islands.count && channel.islands[islandIndex].upper < entry.key {
                islandIndex += 1
            }
            if islandIndex >= channel.islands.count || !channel.islands[islandIndex].contains(entry.key) {
                problems.append("entry outside every island: \(entry)")
            }
        }
        for (index, island) in channel.islands.enumerated() {
            if island.reachesStart && index != 0 {
                problems.append("reachesStart on a non-lowest island \(island)")
            }
            if island.reachesLatest && index != channel.islands.count - 1 {
                problems.append("reachesLatest on a non-highest island \(island)")
            }
        }
        return problems
    }
}
