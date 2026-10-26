import Foundation

/// Allocates Telegram-style 32-bit per-chat message ids for Mattermost posts.
///
/// Implements "option 2: sparse allocation with a stored map" from
/// `docs/plan/02-domain-mapping.md`:
///
/// - the first post seen in a channel gets `firstId` (2^30);
/// - a page extending history from an anchor gets ids spaced by `step` (16), moving away from it;
/// - a late post between two neighbours of the same island gets their midpoint;
/// - a run that lands in unloaded history (permalink jump) becomes a new island placed in the
///   gap proportionally to time, leaving holes on both sides;
/// - a page that reaches another island closes the hole between them;
/// - when there is no room left, a minimal window around the insertion point is renumbered and
///   the change is returned as an explicit `RenumberPlan`.
///
/// Invariants (checked by the property tests): ids are unique, within `1...maxId`, and strictly
/// increasing in `(createAt, postId)` order; every pair of neighbouring islands is separated by
/// at least one free id, so each hole can be expressed as a non-empty Int32 range.
///
/// The allocator is a pure value; all state lives in the `MessageIdStore`. Each operation reads
/// through the store's queries and writes exactly one `MessageIdChangeSet`.
public struct MessageIdAllocator: Sendable {
    public struct Configuration: Hashable, Sendable {
        /// Spacing between consecutive posts of a page (`STEP`).
        public var step: Int32
        /// Id of the first post seen in an empty channel.
        public var firstId: Int32
        /// Largest usable id (ids are allocated in `1...maxId`).
        public var maxId: Int32
        /// A renumber window grows until posts inside islands are at least this far apart
        /// (or the whole channel is renumbered).
        public var minimumSpacingAfterRenumber: Int32
        /// Assumed earliest post time (ms) when placing an island below every known post.
        public var historyFloorTime: Int64
        /// Minimum weight (ms) of the open space above the newest island, which must absorb
        /// all future posts.
        public var futureSpan: Int64
        /// Largest island part that is shifted as a whole when a hole runs out; beyond that a
        /// smaller window around the insertion is renumbered instead.
        public var maximumIslandShift: Int

        public init(
            step: Int32 = 16,
            firstId: Int32 = 1 << 30,
            maxId: Int32 = Int32.max,
            minimumSpacingAfterRenumber: Int32 = 4,
            historyFloorTime: Int64 = 1_262_304_000_000, // 2010-01-01T00:00:00Z
            futureSpan: Int64 = 30 * 24 * 60 * 60 * 1000,
            maximumIslandShift: Int = 10_000
        ) {
            precondition(step >= 1 && maxId >= 16 && firstId >= 1 && firstId <= maxId)
            self.step = step
            self.firstId = firstId
            self.maxId = maxId
            self.minimumSpacingAfterRenumber = max(1, minimumSpacingAfterRenumber)
            self.historyFloorTime = historyFloorTime
            self.futureSpan = max(1, futureSpan)
            self.maximumIslandShift = max(1, maximumIslandShift)
        }

        public static let `default` = Configuration()
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Operations

    /// The newest page of a channel (`GET /channels/{id}/posts?page=0`), e.g. when a chat is
    /// opened or after catch-up. The resulting island is marked as reaching the latest post.
    /// - Parameter reachedStart: the server returned fewer posts than requested, so the page
    ///   also contains the oldest post of the channel.
    public func ingestLatestPage<Store: MessageIdStore>(_ posts: [PostOrderKey], reachedStart: Bool, channelId: String, store: inout Store) throws -> IngestResult {
        return try ingestRun(posts, anchors: [], reachesStart: reachedStart, reachesLatest: true, channelId: channelId, store: &store)
    }

    /// A page loaded with `before=anchor` (`.older`) or `after=anchor` (`.newer`). New posts get
    /// ids spaced by `step` moving away from the anchor. When the page reaches posts that are
    /// already mapped (another island), the hole between them is closed.
    /// - Parameter reachedEnd: the server returned fewer posts than requested, so there is
    ///   nothing more in `direction` (the channel start, or the latest post).
    public func ingestPage<Store: MessageIdStore>(_ posts: [PostOrderKey], extending anchorPostId: String, direction: HistoryDirection, reachedEnd: Bool, channelId: String, store: inout Store) throws -> IngestResult {
        return try ingestRun(
            posts,
            anchors: [anchorPostId],
            reachesStart: direction == .older && reachedEnd,
            reachesLatest: direction == .newer && reachedEnd,
            channelId: channelId,
            store: &store
        )
    }

    /// A permalink jump: the target post plus the pages before and after it. If none of them is
    /// mapped yet, they become a new island placed proportionally to time in the gap between
    /// the nearest known posts.
    public func ingestAround<Store: MessageIdStore>(target: PostOrderKey, older: [PostOrderKey], newer: [PostOrderKey], olderReachedStart: Bool, newerReachedLatest: Bool, channelId: String, store: inout Store) throws -> IngestResult {
        return try ingestRun(older + [target] + newer, anchors: [], reachesStart: olderReachedStart, reachesLatest: newerReachedLatest, channelId: channelId, store: &store)
    }

    /// A single post that wasn't loaded through paging: a WebSocket `posted` event, the HTTP
    /// response of our own `POST /posts`, or `GET /posts/{id}`.
    ///
    /// - Between two posts of the same island: joins that island at their midpoint (late insert).
    /// - Newer than everything while the newest island reaches the latest post: appended to it.
    /// - Older than everything while the oldest island reaches the start: prepended to it.
    /// - Otherwise: becomes a single-post island inside the hole.
    ///
    /// `partCount` > 1 maps the post's parts too (`PostParts`, one message per file). For a post that is
    /// already mapped, missing parts are added right after its last mapped part (an edit that added
    /// files); fewer parts are not removed here (`removeParts`).
    ///
    /// Idempotent: an already mapped post returns `.existing`, a tombstoned one `.deleted`.
    public func insertPost<Store: MessageIdStore>(_ post: PostOrderKey, channelId: String, store: inout Store) throws -> IngestResult {
        // An overload rather than a default argument: Swift 6.4 crashes compiling a defaulted argument next
        // to an opened existential `inout` store.
        return try insertPost(post, partCount: 1, channelId: channelId, store: &store)
    }

    public func insertPost<Store: MessageIdStore>(_ post: PostOrderKey, partCount: Int, channelId: String, store: inout Store) throws -> IngestResult {
        let keys = post.parts(count: partCount)
        let known = store.entries(channelId: channelId, postIds: keys.map { $0.postId })
        let postDeleted = known[post.postId]?.isDeleted ?? !store.unmappedTombstones(channelId: channelId, among: [post.postId]).isEmpty
        let missing = postDeleted ? [] : keys.filter { known[$0.postId] == nil }
        if missing.isEmpty {
            return IngestResult(
                allocations: keys.map { key in
                    let entry = known[key.postId]
                    return PostAllocation(postId: key.postId, localId: entry?.localId, status: postDeleted || (entry?.isDeleted ?? true) ? .deleted : .existing)
                },
                holes: holes(channelId: channelId, store: store)
            )
        }
        let lower = store.entries(channelId: channelId, olderThan: missing[0], limit: 1).first
        let upper = store.entries(channelId: channelId, newerThan: missing[missing.count - 1], limit: 1).first
        let islands = store.islands(channelId: channelId)
        let index = IslandIndex(islands: islands)
        var anchors: [String] = []
        if let lower = lower, lower.serverPostId == post.postId {
            // New parts of a mapped post: nothing else lies between the post and its parts.
            anchors = [lower.postId]
            if let upper = upper, let lowerIsland = index.index(of: lower.key), lowerIsland == index.index(of: upper.key) {
                anchors.append(upper.postId)
            }
        } else if let lower = lower, let upper = upper {
            if let lowerIsland = index.index(of: lower.key), lowerIsland == index.index(of: upper.key) {
                anchors = [lower.postId, upper.postId]
            }
        } else if let lower = lower {
            if let top = islands.last, top.reachesLatest, top.contains(lower.key) {
                anchors = [lower.postId]
            }
        } else if let upper = upper {
            if let bottom = islands.first, bottom.reachesStart, bottom.contains(upper.key) {
                anchors = [upper.postId]
            }
        }
        var result = try ingestRun(missing, anchors: anchors, reachesStart: false, reachesLatest: false, channelId: channelId, store: &store)
        if keys.count > missing.count {
            // Report every part, with the current ids of the parts that were mapped already.
            let inserted = Set(result.allocations.filter { $0.status == .inserted }.map { $0.postId })
            let current = store.entries(channelId: channelId, postIds: keys.map { $0.postId })
            result.allocations = keys.map { key in
                let entry = current[key.postId]
                if inserted.contains(key.postId) {
                    return PostAllocation(postId: key.postId, localId: entry?.localId, status: .inserted)
                }
                return PostAllocation(postId: key.postId, localId: entry?.localId, status: (entry?.isDeleted ?? true) ? .deleted : .existing)
            }
        }
        return result
    }

    /// The mapped entries of a post and its parts (`PostParts`), in key order; empty when the post is
    /// unknown.
    public func partEntries<Store: MessageIdStore>(postId: String, channelId: String, store: Store) -> [MessageIdEntry] {
        guard let entry = store.entries(channelId: channelId, postIds: [postId])[postId] else {
            return []
        }
        return store.entries(channelId: channelId, keyRange: entry.key.partsRange)
    }

    /// Tombstones the parts of a post from `keeping` on (an edit removed files). Returns the entries that
    /// were newly tombstoned.
    @discardableResult
    public func removeParts<Store: MessageIdStore>(postId: String, keeping: Int, channelId: String, store: inout Store) -> [MessageIdEntry] {
        let extra = partEntries(postId: postId, channelId: channelId, store: store).filter { $0.partIndex >= max(1, keeping) && !$0.isDeleted }
        if extra.isEmpty {
            return []
        }
        return markDeleted(extra.map { $0.postId }, channelId: channelId, store: &store)
    }

    /// The general operation behind all the others: `posts` (in any order, duplicates ignored)
    /// together with the mapped `anchors` form one contiguous stretch of the channel's history,
    /// i.e. the server has no other posts between the oldest and the newest of them.
    public func ingestRun<Store: MessageIdStore>(_ posts: [PostOrderKey], anchors: [String], reachesStart: Bool, reachesLatest: Bool, channelId: String, store: inout Store) throws -> IngestResult {
        var seen = Set<String>()
        var unique: [PostOrderKey] = []
        unique.reserveCapacity(posts.count)
        for post in posts where seen.insert(post.postId).inserted {
            unique.append(post)
        }

        let known = store.entries(channelId: channelId, postIds: unique.map { $0.postId } + anchors)
        for anchor in anchors where known[anchor] == nil {
            throw MessageIdAllocationError.unknownAnchor(postId: anchor)
        }
        let unknownIds = unique.compactMap { known[$0.postId] == nil ? $0.postId : nil }
        var tombstoned = unknownIds.isEmpty ? Set<String>() : store.unmappedTombstones(channelId: channelId, among: unknownIds)
        // Parts of a deleted post are deleted too, even when they were never mapped.
        let partOwners = Set(unknownIds.filter { PostParts.isPartId($0) }.map { PostParts.postId(ofPartId: $0) })
        if !partOwners.isEmpty {
            let owners = Array(partOwners)
            let ownerEntries = store.entries(channelId: channelId, postIds: owners)
            let deletedOwners = store.unmappedTombstones(channelId: channelId, among: owners).union(ownerEntries.values.filter { $0.isDeleted }.map { $0.postId })
            for id in unknownIds where PostParts.isPartId(id) && deletedOwners.contains(PostParts.postId(ofPartId: id)) {
                tombstoned.insert(id)
            }
        }
        let newPosts = unique.filter { known[$0.postId] == nil && !tombstoned.contains($0.postId) }.sorted()

        // The key span covered by this run; islands overlapping it merge into one.
        let runKeys = newPosts + known.values.map { $0.key }
        var spanLow = runKeys.min()
        var spanHigh = runKeys.max()
        // Nothing older (newer) exists on the server, so every mapped post below (above) the run
        // belongs to it. Only that end of the span moves.
        if reachesStart, let lowest = store.entries(channelId: channelId, newerThan: nil, limit: 1).first {
            spanLow = min(spanLow ?? lowest.key, lowest.key)
            spanHigh = spanHigh ?? lowest.key
        }
        if reachesLatest, let highest = store.entries(channelId: channelId, olderThan: nil, limit: 1).first {
            spanHigh = max(spanHigh ?? highest.key, highest.key)
            spanLow = spanLow ?? highest.key
        }

        guard let low = spanLow, let high = spanHigh else {
            // Nothing to record (empty page of an empty channel, or only tombstoned posts).
            return IngestResult(
                allocations: unique.sorted().map { PostAllocation(postId: $0.postId, localId: nil, status: .deleted) },
                holes: holes(channelId: channelId, store: store)
            )
        }

        // Merge overlapping islands.
        let oldIslands = store.islands(channelId: channelId)
        var merged = HistoryIsland(lower: low, upper: high, reachesStart: reachesStart, reachesLatest: reachesLatest)
        var newIslands: [HistoryIsland] = []
        var joinedIslandCount = 0
        for island in oldIslands {
            if island.upper < low || high < island.lower {
                newIslands.append(island)
            } else {
                joinedIslandCount += 1
                if island.lower < merged.lower {
                    merged.lower = island.lower
                }
                if merged.upper < island.upper {
                    merged.upper = island.upper
                }
                merged.reachesStart = merged.reachesStart || island.reachesStart
                merged.reachesLatest = merged.reachesLatest || island.reachesLatest
            }
        }
        newIslands.append(merged)
        newIslands.sort { $0.lower < $1.lower }
        for i in newIslands.indices {
            if i != 0 {
                newIslands[i].reachesStart = false
            }
            if i != newIslands.count - 1 {
                newIslands[i].reachesLatest = false
            }
        }

        // Place the new posts.
        var inserted: [MessageIdEntry] = []
        var renumberPlan: RenumberPlan?
        if !newPosts.isEmpty {
            let placement = try place(newPosts, islands: IslandIndex(islands: newIslands), channelId: channelId, store: store)
            inserted = placement.inserted
            renumberPlan = placement.renumberPlan
        }

        store.apply(MessageIdChangeSet(
            channelId: channelId,
            renumbered: renumberPlan?.moves ?? [],
            inserted: inserted,
            islands: newIslands
        ))

        // Report.
        var currentIds: [String: Int32] = [:]
        for entry in known.values {
            currentIds[entry.postId] = entry.localId
        }
        for move in renumberPlan?.moves ?? [] {
            currentIds[move.postId] = move.to
        }
        var insertedIds: [String: Int32] = [:]
        for entry in inserted {
            insertedIds[entry.postId] = entry.localId
        }
        let allocations: [PostAllocation] = unique.map { post -> (PostOrderKey, PostAllocation) in
            if let id = insertedIds[post.postId] {
                return (post, PostAllocation(postId: post.postId, localId: id, status: .inserted))
            } else if let entry = known[post.postId] {
                return (entry.key, PostAllocation(postId: post.postId, localId: currentIds[post.postId], status: entry.isDeleted ? .deleted : .existing))
            } else {
                return (post, PostAllocation(postId: post.postId, localId: nil, status: .deleted))
            }
        }.sorted { $0.0 < $1.0 }.map { $0.1 }

        let boundaries = store.entries(channelId: channelId, postIds: [merged.lower.postId, merged.upper.postId])
        var islandRange: ClosedRange<Int32>?
        if let lowerEntry = boundaries[merged.lower.postId], let upperEntry = boundaries[merged.upper.postId] {
            islandRange = lowerEntry.localId ... upperEntry.localId
        }

        return IngestResult(
            allocations: allocations,
            renumberPlan: renumberPlan,
            islandRange: islandRange,
            joinedIslandCount: joinedIslandCount,
            holes: holes(channelId: channelId, store: store)
        )
    }

    /// Tombstones posts (WebSocket `post_deleted`, or deletions found during catch-up), with their
    /// parts. Mapped posts keep their id and are flagged; unmapped ones are remembered so they're
    /// never inserted later. Returns the mapped entries that were newly tombstoned (parts included).
    @discardableResult
    public func markDeleted<Store: MessageIdStore>(_ postIds: [String], channelId: String, store: inout Store) -> [MessageIdEntry] {
        var postIds = postIds
        var known = store.entries(channelId: channelId, postIds: postIds)
        // A deleted post takes its parts (`PostParts`) with it.
        for postId in postIds where !PostParts.isPartId(postId) {
            guard let entry = known[postId] else {
                continue
            }
            for part in store.entries(channelId: channelId, keyRange: entry.key.partsRange) where part.postId != postId && known[part.postId] == nil {
                known[part.postId] = part
                postIds.append(part.postId)
            }
        }
        var newlyDeleted: [MessageIdEntry] = []
        var unmapped: [String] = []
        var seen = Set<String>()
        for postId in postIds where seen.insert(postId).inserted {
            if var entry = known[postId] {
                if !entry.isDeleted {
                    entry.isDeleted = true
                    newlyDeleted.append(entry)
                }
            } else {
                unmapped.append(postId)
            }
        }
        store.apply(MessageIdChangeSet(channelId: channelId, deletedPostIds: newlyDeleted.map { $0.postId }, unmappedTombstones: unmapped))
        return newlyDeleted.sorted { $0.key < $1.key }
    }

    /// Marks the newest island as no longer live (e.g. after a non-resumed WebSocket reconnect or
    /// a catch-up that was too large to apply). A hole opens above it.
    public func invalidateLatest<Store: MessageIdStore>(channelId: String, store: inout Store) {
        var islands = store.islands(channelId: channelId)
        guard let last = islands.indices.last, islands[last].reachesLatest else {
            return
        }
        islands[last].reachesLatest = false
        store.apply(MessageIdChangeSet(channelId: channelId, islands: islands))
    }

    // MARK: - Queries

    /// The channel's islands with resolved id ranges, ascending.
    public func islandSummaries<Store: MessageIdStore>(channelId: String, store: Store) -> [HistoryIslandSummary] {
        let islands = store.islands(channelId: channelId)
        if islands.isEmpty {
            return []
        }
        let boundaries = store.entries(channelId: channelId, postIds: islands.flatMap { [$0.lower.postId, $0.upper.postId] })
        return islands.compactMap { island in
            guard let lower = boundaries[island.lower.postId], let upper = boundaries[island.upper.postId] else {
                return nil
            }
            return HistoryIslandSummary(island: island, range: lower.localId ... upper.localId)
        }
    }

    /// The gaps between islands as local id ranges, plus the open space below the oldest island
    /// (unless it reaches the channel start) and above the newest one (unless it is live).
    /// An empty channel is one hole covering the whole id space.
    public func holes<Store: MessageIdStore>(channelId: String, store: Store) -> [HistoryHole] {
        let summaries = islandSummaries(channelId: channelId, store: store)
        let maxId = configuration.maxId
        if summaries.isEmpty {
            return [HistoryHole(range: 1 ... maxId, lowerBoundary: nil, upperBoundary: nil)]
        }
        var result: [HistoryHole] = []
        var previous: HistoryIslandSummary?
        for summary in summaries {
            let low: Int32 = previous.map { $0.range.upperBound + 1 } ?? 1
            if previous != nil || !summary.island.reachesStart {
                if summary.range.lowerBound > low {
                    result.append(HistoryHole(range: low ... (summary.range.lowerBound - 1), lowerBoundary: previous?.island.upper, upperBoundary: summary.island.lower))
                }
            }
            previous = summary
        }
        if let last = previous, !last.island.reachesLatest, last.range.upperBound < maxId {
            result.append(HistoryHole(range: (last.range.upperBound + 1) ... maxId, lowerBoundary: last.island.upper, upperBoundary: nil))
        }
        return result
    }

    /// Translates a Postbox hole fill request into a Mattermost cursor.
    ///
    /// - `.older`: `boundaryLocalId` is the upper edge of the region to fill (Postbox
    ///   `.range(start:end:)` with `start > end`). Returns `before=` the nearest mapped post at or
    ///   above it, or `.latest` when nothing is mapped above.
    /// - `.newer`: `boundaryLocalId` is the lower edge. Returns `after=` the nearest mapped post at
    ///   or below it, or nil when nothing is mapped below (Mattermost can't page forward from the
    ///   channel start; fill that hole with `.older` instead).
    ///
    /// Tombstoned boundary posts are skipped in favour of a live post of the same island. A part
    /// (`PostParts`) gives the cursor of its post.
    /// Ingest the response with `ingestPage(_:extending:direction:reachedEnd:)` using the
    /// cursor's post as the anchor (or `ingestLatestPage` for `.latest`).
    public func fillCursor<Store: MessageIdStore>(direction: HistoryDirection, boundaryLocalId: Int32, channelId: String, store: Store) -> HistoryCursor? {
        let candidates = store.entries(channelId: channelId, fromLocalId: boundaryLocalId, ascending: direction == .older, limit: 16)
        guard let first = candidates.first else {
            return direction == .older ? .latest : nil
        }
        var chosen = first
        if first.isDeleted {
            let index = IslandIndex(islands: store.islands(channelId: channelId))
            let island = index.index(of: first.key)
            if let live = candidates.first(where: { !$0.isDeleted && index.index(of: $0.key) == island }) {
                chosen = live
            }
        }
        // Cursors name server posts: a part pages like its post (nothing lies between them).
        switch direction {
        case .older:
            return .before(postId: chosen.serverPostId)
        case .newer:
            return .after(postId: chosen.serverPostId)
        }
    }

    /// The cursor for Postbox's `.aroundId` request, when the id is mapped.
    public func aroundCursor<Store: MessageIdStore>(localId: Int32, channelId: String, store: Store) -> HistoryCursor? {
        guard let entry = store.entries(channelId: channelId, fromLocalId: localId, ascending: true, limit: 1).first, entry.localId == localId else {
            return nil
        }
        return .around(postId: entry.serverPostId)
    }

    // MARK: - Placement

    private enum Slot {
        case existing(MessageIdEntry)
        case new(PostOrderKey)

        var key: PostOrderKey {
            switch self {
            case let .existing(entry):
                return entry.key
            case let .new(key):
                return key
            }
        }
    }

    private struct Group {
        var lower: MessageIdEntry?
        var upper: MessageIdEntry?
        var keys: [PostOrderKey]
    }

    private struct Placement {
        var inserted: [MessageIdEntry]
        var renumberPlan: RenumberPlan?
    }

    private var upperSentinel: Int64 {
        return Int64(configuration.maxId) + 1
    }

    private func place<Store: MessageIdStore>(_ newPosts: [PostOrderKey], islands: IslandIndex, channelId: String, store: Store) throws -> Placement {
        let first = newPosts[0]
        let last = newPosts[newPosts.count - 1]
        let inside = newPosts.count > 1 ? store.entries(channelId: channelId, keyRange: first ... last) : []
        let lowerNeighbour = store.entries(channelId: channelId, olderThan: first, limit: 1).first
        let upperNeighbour = store.entries(channelId: channelId, newerThan: last, limit: 1).first

        // Empty channel: the newest post of the run gets `firstId`.
        if lowerNeighbour == nil && upperNeighbour == nil && inside.isEmpty {
            let step = Int64(configuration.step)
            let count = Int64(newPosts.count)
            if (count - 1) * step < Int64(configuration.firstId) {
                let top = Int64(configuration.firstId)
                let inserted = newPosts.enumerated().map { index, key in
                    MessageIdEntry(key: key, localId: Int32(top - (count - 1 - Int64(index)) * step))
                }
                return Placement(inserted: inserted, renumberPlan: nil)
            }
        }

        // Interleave the new posts with the mapped posts between them.
        var slots: [Slot] = []
        slots.reserveCapacity(newPosts.count + inside.count)
        var i = 0
        var j = 0
        while i < inside.count || j < newPosts.count {
            if j >= newPosts.count || (i < inside.count && inside[i].key < newPosts[j]) {
                slots.append(.existing(inside[i]))
                i += 1
            } else {
                slots.append(.new(newPosts[j]))
                j += 1
            }
        }

        var groups: [Group] = []
        var currentLower = lowerNeighbour
        var currentKeys: [PostOrderKey] = []
        for slot in slots {
            switch slot {
            case let .existing(entry):
                if !currentKeys.isEmpty {
                    groups.append(Group(lower: currentLower, upper: entry, keys: currentKeys))
                    currentKeys = []
                }
                currentLower = entry
            case let .new(key):
                currentKeys.append(key)
            }
        }
        if !currentKeys.isEmpty {
            groups.append(Group(lower: currentLower, upper: upperNeighbour, keys: currentKeys))
        }

        // Fast path: every group fits into its own gap and nothing existing moves. A page next to a
        // hole may be compressed down to `minimumSpacingAfterRenumber`; a late post between two
        // posts of the same island takes their midpoint as long as a free id is left.
        let minimumSpacing = Int64(configuration.minimumSpacingAfterRenumber)
        var inserted: [MessageIdEntry] = []
        inserted.reserveCapacity(newPosts.count)
        var exhaustedHole: Bool?
        for group in groups {
            let keys: [PostOrderKey?] = [group.lower?.key] + group.keys.map { Optional($0) } + [group.upper?.key]
            let gaps = layoutGaps(for: keys, islands: islands)
            let touchesHole = gaps.contains { $0 != .island }
            let lowerBound = Int64(group.lower?.localId ?? 0)
            let upperBound = group.upper.map { Int64($0.localId) } ?? upperSentinel
            guard let outcome = IdLayout.layout(lower: lowerBound, upper: upperBound, gaps: gaps, step: Int64(configuration.step)),
                  !touchesHole || outcome.minimumIslandSpacing >= minimumSpacing else {
                exhaustedHole = touchesHole
                break
            }
            for (key, position) in zip(group.keys, outcome.positions) {
                inserted.append(MessageIdEntry(key: key, localId: Int32(position)))
            }
        }
        guard let holeExhausted = exhaustedHole else {
            return Placement(inserted: inserted, renumberPlan: nil)
        }

        // No room: renumber.
        let lower = groups[0].lower
        let upper = groups[groups.count - 1].upper
        if holeExhausted {
            // A hole ran out (the plan's "renumber the smaller island"): shift the smaller of the
            // island parts next to the insertion into the hole beyond it. This restores STEP
            // spacing and gives the hole being filled at least half of the freed space.
            var best: WindowLayout?
            for candidate in islandShiftCandidates(items: slots, lower: lower, upper: upper, islands: islands, moveLimit: configuration.maximumIslandShift, channelId: channelId, store: store) {
                if let layout = layoutWindow(items: candidate.items, lower: candidate.lower, upper: candidate.upper, islands: islands), best == nil || layout.moveCount < best!.moveCount {
                    best = layout
                }
            }
            if let best = best {
                return best.placement
            }
        }
        // A gap inside an island ran out (late inserts), or no island could be shifted: renumber
        // the smallest window around the insertion that has room.
        return try growingWindowLayout(items: slots, lower: lower, upper: upper, islands: islands, channelId: channelId, store: store).placement
    }

    private struct WindowLayout {
        var placement: Placement
        var moveCount: Int
    }

    private struct WindowCandidate {
        var items: [Slot]
        var lower: MessageIdEntry?
        var upper: MessageIdEntry?
    }

    /// Lays out `items` strictly between `lower` and `upper` (nil: the edge of the id space).
    /// Returns nil unless posts inside islands end up at least `minimumSpacingAfterRenumber`
    /// apart; for the whole channel any layout that fits is accepted.
    private func layoutWindow(items: [Slot], lower: MessageIdEntry?, upper: MessageIdEntry?, islands: IslandIndex) -> WindowLayout? {
        let keys: [PostOrderKey?] = [lower?.key] + items.map { Optional($0.key) } + [upper?.key]
        // Holes next to the new posts are the ones being filled: give them at least half of the
        // free space so repeated pages into a dense stretch don't renumber every time.
        var hot = [Bool](repeating: false, count: keys.count - 1)
        for (index, item) in items.enumerated() {
            if case .new = item {
                hot[index] = true
                hot[index + 1] = true
            }
        }
        let gaps = layoutGaps(for: keys, islands: islands, hot: hot)
        let lowerBound = Int64(lower?.localId ?? 0)
        let upperBound = upper.map { Int64($0.localId) } ?? upperSentinel
        guard let outcome = IdLayout.layout(lower: lowerBound, upper: upperBound, gaps: gaps, step: Int64(configuration.step)) else {
            return nil
        }
        let isWholeChannel = lower == nil && upper == nil
        guard isWholeChannel || outcome.minimumIslandSpacing >= Int64(configuration.minimumSpacingAfterRenumber) else {
            return nil
        }
        var inserted: [MessageIdEntry] = []
        var moves: [RenumberMove] = []
        for (item, position) in zip(items, outcome.positions) {
            let id = Int32(position)
            switch item {
            case let .new(key):
                inserted.append(MessageIdEntry(key: key, localId: id))
            case let .existing(entry):
                if entry.localId != id {
                    moves.append(RenumberMove(postId: entry.postId, from: entry.localId, to: id))
                }
            }
        }
        let affected = Int32(lowerBound + 1) ... Int32(upperBound - 1)
        let plan = moves.isEmpty ? nil : RenumberPlan(moves: moves, affectedRange: affected)
        return WindowLayout(placement: Placement(inserted: inserted, renumberPlan: plan), moveCount: moves.count)
    }

    /// Grows a window around the insertion until it has enough room. Each step extends the side
    /// that yields more free ids per renumbered post, doubling the step on that side.
    private func growingWindowLayout<Store: MessageIdStore>(items initialItems: [Slot], lower: MessageIdEntry?, upper: MessageIdEntry?, islands: IslandIndex, channelId: String, store: Store) throws -> WindowLayout {
        var items = initialItems
        var windowLower = lower
        var windowUpper = upper
        var lowerStep = 1
        var upperStep = 1

        while true {
            if let layout = layoutWindow(items: items, lower: windowLower, upper: windowUpper, islands: islands) {
                return layout
            }

            var lowerCandidate: (bound: MessageIdEntry?, added: [MessageIdEntry], gain: Int64)?
            if let current = windowLower {
                let fetched = store.entries(channelId: channelId, olderThan: current.key, limit: lowerStep)
                let bound = fetched.count == lowerStep ? fetched.last : nil
                let added = [current] + (bound != nil ? Array(fetched.dropLast()) : fetched)
                lowerCandidate = (bound, added.reversed(), Int64(current.localId) - Int64(bound?.localId ?? 0))
            }
            var upperCandidate: (bound: MessageIdEntry?, added: [MessageIdEntry], gain: Int64)?
            if let current = windowUpper {
                let fetched = store.entries(channelId: channelId, newerThan: current.key, limit: upperStep)
                let bound = fetched.count == upperStep ? fetched.last : nil
                let added = [current] + (bound != nil ? Array(fetched.dropLast()) : fetched)
                upperCandidate = (bound, added, (bound.map { Int64($0.localId) } ?? upperSentinel) - Int64(current.localId))
            }

            let growLower: Bool
            switch (lowerCandidate, upperCandidate) {
            case (nil, nil):
                throw MessageIdAllocationError.capacityExhausted(channelId: channelId)
            case (.some, nil):
                growLower = true
            case (nil, .some):
                growLower = false
            case let (.some(lowerValue), .some(upperValue)):
                let lowerRatio = Double(lowerValue.gain) / Double(lowerValue.added.count)
                let upperRatio = Double(upperValue.gain) / Double(upperValue.added.count)
                growLower = lowerRatio != upperRatio ? lowerRatio > upperRatio : lowerStep <= upperStep
            }
            if growLower, let candidate = lowerCandidate {
                items = candidate.added.map { Slot.existing($0) } + items
                windowLower = candidate.bound
                lowerStep *= 2
            } else if let candidate = upperCandidate {
                items = items + candidate.added.map { Slot.existing($0) }
                windowUpper = candidate.bound
                upperStep *= 2
            }
        }
    }

    /// Windows that move the rest of the island below `lower` down into the hole under it, or the
    /// rest of the island above `upper` up into the hole over it. Only islands parts with at most
    /// `moveLimit` posts are considered, so the store reads stay bounded.
    private func islandShiftCandidates<Store: MessageIdStore>(items: [Slot], lower: MessageIdEntry?, upper: MessageIdEntry?, islands: IslandIndex, moveLimit: Int, channelId: String, store: Store) -> [WindowCandidate] {
        var candidates: [WindowCandidate] = []
        if let lower = lower, let index = islands.index(of: lower.key) {
            let island = islands.islands[index]
            let fetched = store.entries(channelId: channelId, olderThan: lower.key, limit: moveLimit)
            var part: [MessageIdEntry] = [lower]
            var bound: MessageIdEntry?
            var complete = fetched.count < moveLimit
            for entry in fetched {
                if entry.key < island.lower {
                    bound = entry
                    complete = true
                    break
                }
                part.append(entry)
            }
            if complete && part.count <= moveLimit {
                candidates.append(WindowCandidate(items: part.reversed().map { Slot.existing($0) } + items, lower: bound, upper: upper))
            }
        }
        if let upper = upper, let index = islands.index(of: upper.key) {
            let island = islands.islands[index]
            let fetched = store.entries(channelId: channelId, newerThan: upper.key, limit: moveLimit)
            var part: [MessageIdEntry] = [upper]
            var bound: MessageIdEntry?
            var complete = fetched.count < moveLimit
            for entry in fetched {
                if island.upper < entry.key {
                    bound = entry
                    complete = true
                    break
                }
                part.append(entry)
            }
            if complete && part.count <= moveLimit {
                candidates.append(WindowCandidate(items: items + part.map { Slot.existing($0) }, lower: lower, upper: bound))
            }
        }
        return candidates
    }

    /// Classifies each gap of `keys` (nil = the edge of the id space) as inside an island or a
    /// hole weighted by the time it spans.
    private func layoutGaps(for keys: [PostOrderKey?], islands: IslandIndex, hot: [Bool]? = nil) -> [IdLayout.Gap] {
        var raw: [Double?] = []
        raw.reserveCapacity(keys.count - 1)
        var topSentinelIndex: Int?
        var otherHoleWeight: Double = 0
        var previousIsland: Int? = keys[0].flatMap { islands.index(of: $0) }
        for index in 1 ..< keys.count {
            let lower = keys[index - 1]
            let upper = keys[index]
            let upperIsland = upper.flatMap { islands.index(of: $0) }
            if lower != nil, upper != nil, let a = previousIsland, a == upperIsland {
                raw.append(nil)
            } else if let lower = lower, let upper = upper {
                let weight = Double(max(0, upper.createAt - lower.createAt))
                raw.append(weight)
                otherHoleWeight += weight
            } else if let upper = upper {
                let weight = Double(max(0, upper.createAt - configuration.historyFloorTime))
                raw.append(weight)
                otherHoleWeight += weight
            } else {
                topSentinelIndex = raw.count
                raw.append(0)
            }
            previousIsland = upperIsland
        }
        if let index = topSentinelIndex {
            raw[index] = max(otherHoleWeight, Double(configuration.futureSpan))
        }
        let holeWeights = raw.compactMap { $0 }
        let total = holeWeights.reduce(0, +)
        // Every hole gets a floor share so a time-adjacent hole still has room to grow.
        let floor = max(1, total / Double(8 * max(1, holeWeights.count)))
        var weights: [Double?] = raw.map { $0.map { $0 + floor } }
        if let hot = hot {
            var hotCount = 0
            var coldWeight: Double = 0
            for (index, weight) in weights.enumerated() {
                if let weight = weight {
                    if hot[index] {
                        hotCount += 1
                    } else {
                        coldWeight += weight
                    }
                }
            }
            if hotCount > 0 && coldWeight > 0 {
                for index in weights.indices where hot[index] {
                    if let weight = weights[index] {
                        weights[index] = max(weight, coldWeight / Double(hotCount))
                    }
                }
            }
        }
        return weights.map { value in
            if let value = value {
                return .hole(weight: value)
            }
            return .island
        }
    }
}

/// Binary search over a sorted island list.
struct IslandIndex {
    let islands: [HistoryIsland]

    func index(of key: PostOrderKey) -> Int? {
        var low = 0
        var high = islands.count
        while low < high {
            let mid = (low + high) / 2
            if islands[mid].upper < key {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low < islands.count && islands[low].contains(key) {
            return low
        }
        return nil
    }
}

/// Distributes positions inside an exclusive id interval.
enum IdLayout {
    enum Gap: Equatable {
        /// Between two posts of the same island: wants `step` spacing.
        case island
        /// A hole: shares the remaining space proportionally to `weight`, at least 1 free id.
        case hole(weight: Double)
    }

    struct Outcome {
        var positions: [Int64]
        var minimumIslandSpacing: Int64
    }

    static let minimumHoleDistance: Int64 = 2

    /// Places `gaps.count - 1` positions strictly between `lower` and `upper` (both exclusive).
    ///
    /// - Only island gaps: spread evenly (a single post lands on the midpoint).
    /// - With holes: island gaps get `step`, reduced so the holes keep at least half the space;
    ///   holes split the rest by weight, each keeping at least one free id.
    static func layout(lower: Int64, upper: Int64, gaps: [Gap], step: Int64) -> Outcome? {
        let capacity = upper - lower
        let gapCount = gaps.count
        guard gapCount >= 1, capacity >= Int64(gapCount) else {
            return nil
        }
        var islandGapCount: Int64 = 0
        var holeIndices: [Int] = []
        var holeWeights: [Double] = []
        for (index, gap) in gaps.enumerated() {
            switch gap {
            case .island:
                islandGapCount += 1
            case let .hole(weight):
                holeIndices.append(index)
                holeWeights.append(weight)
            }
        }

        var distances = [Int64](repeating: 0, count: gapCount)
        var minimumIslandSpacing = Int64.max
        if holeIndices.isEmpty {
            let base = capacity / Int64(gapCount)
            var remainder = capacity - base * Int64(gapCount)
            for index in 0 ..< gapCount {
                distances[index] = base + (remainder > 0 ? 1 : 0)
                if remainder > 0 {
                    remainder -= 1
                }
            }
            minimumIslandSpacing = base
        } else {
            var spacing: Int64 = 0
            if islandGapCount > 0 {
                spacing = min(step, capacity / (2 * islandGapCount))
                if spacing < 1 {
                    spacing = (capacity - minimumHoleDistance * Int64(holeIndices.count)) / islandGapCount
                    if spacing < 1 {
                        return nil
                    }
                }
                minimumIslandSpacing = spacing
            }
            guard let holeDistances = distribute(total: capacity - spacing * islandGapCount, weights: holeWeights, minimum: minimumHoleDistance) else {
                return nil
            }
            for index in 0 ..< gapCount {
                distances[index] = spacing
            }
            for (k, index) in holeIndices.enumerated() {
                distances[index] = holeDistances[k]
            }
        }

        var positions: [Int64] = []
        positions.reserveCapacity(gapCount - 1)
        var current = lower
        for index in 0 ..< gapCount - 1 {
            current += distances[index]
            positions.append(current)
        }
        return Outcome(positions: positions, minimumIslandSpacing: minimumIslandSpacing)
    }

    static func distribute(total: Int64, weights: [Double], minimum: Int64) -> [Int64]? {
        let count = Int64(weights.count)
        guard count > 0, total >= minimum * count else {
            return nil
        }
        let spare = total - minimum * count
        let sum = weights.reduce(0, +)
        var result = [Int64](repeating: minimum, count: weights.count)
        var used: Int64 = 0
        if sum > 0 {
            for index in weights.indices {
                let share = Int64((Double(spare) * weights[index] / sum).rounded(.down))
                let clamped = max(0, min(share, spare - used))
                result[index] += clamped
                used += clamped
            }
        }
        if used < spare {
            var largest = 0
            for index in weights.indices where weights[index] > weights[largest] {
                largest = index
            }
            result[largest] += spare - used
        }
        return result
    }
}
