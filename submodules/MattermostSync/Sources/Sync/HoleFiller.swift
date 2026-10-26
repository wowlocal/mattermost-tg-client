import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Replaces Telegram's `managedMessageHistoryHoles`: observes `postbox.messageHistoryHolesView()` and fills
/// each requested hole from the Mattermost REST API, one fetch at a time per (peer, thread, space).
///
/// An entry that is still requested after its fill completed made no progress (a stall); it is retried
/// with a growing delay and logged, so stalls are visible in the log.
final class HoleFiller {
    private struct Key: Hashable {
        let peerId: PeerId
        let threadId: Int64?
        let space: MessageHistoryHoleOperationSpace
    }

    private let queue = Queue()
    private weak var sync: MattermostAccountSync?
    private let postbox: Postbox
    private let disposable = MetaDisposable()
    private var currentEntries = Set<MessageHistoryHolesViewEntry>()
    private var pending: [Key: MessageHistoryHolesViewEntry] = [:]
    /// Completion time and repeat count of finished entries.
    private var completed: [MessageHistoryHolesViewEntry: (timestamp: Double, repeats: Int)] = [:]
    private var retryTimer: SwiftSignalKit.Timer?

    init(sync: MattermostAccountSync) {
        self.sync = sync
        self.postbox = sync.postbox
    }

    deinit {
        self.disposable.dispose()
        self.retryTimer?.invalidate()
    }

    func start() {
        let queue = self.queue
        self.disposable.set((self.postbox.messageHistoryHolesView()
        |> map { view -> Set<MessageHistoryHolesViewEntry> in
            return view.entries
        }
        |> distinctUntilChanged
        |> deliverOn(queue)).start(next: { [weak self] entries in
            self?.update(entries: entries)
        }))
    }

    private func update(entries: Set<MessageHistoryHolesViewEntry>) {
        assert(self.queue.isCurrent())
        self.currentEntries = entries
        let now = CFAbsoluteTimeGetCurrent()
        var nextRetry: Double?
        for entry in entries {
            let hole: MessageHistoryViewPeerHole
            switch entry.hole {
            case let .peer(value):
                hole = value
            }
            let key = Key(peerId: hole.peerId, threadId: hole.threadId, space: entry.space)
            if self.pending[key] != nil {
                continue
            }
            if let previous = self.completed[entry] {
                let delay = min(20.0, pow(2.0, Double(previous.repeats)))
                if now < previous.timestamp + delay {
                    nextRetry = min(nextRetry ?? .greatestFiniteMagnitude, previous.timestamp + delay - now)
                    continue
                }
                MMLog.log("holes: STALL? \(entry) requested again after its fill (repeat \(previous.repeats + 1))")
            }
            self.pending[key] = entry
            MMLog.log("holes: fill \(entry)")
            let startTime = now
            Task { [weak self] in
                await self?.sync?.fillHole(entry)
                self?.queue.async {
                    guard let self = self else {
                        return
                    }
                    self.pending[key] = nil
                    let repeats = (self.completed[entry]?.repeats).map { $0 + 1 } ?? 0
                    self.completed[entry] = (CFAbsoluteTimeGetCurrent(), repeats)
                    MMLog.log("holes: done \(hole.peerId) \(entry.direction) in \(Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)) ms")
                    self.update(entries: self.currentEntries)
                }
            }
        }
        // Forget finished entries a while after they were last filled.
        self.completed = self.completed.filter { now - $0.value.timestamp < 60.0 }
        if let nextRetry = nextRetry {
            self.retryTimer?.invalidate()
            let timer = SwiftSignalKit.Timer(timeout: max(0.1, nextRetry), repeat: false, completion: { [weak self] in
                guard let self = self else {
                    return
                }
                self.update(entries: self.currentEntries)
            }, queue: self.queue)
            self.retryTimer = timer
            timer.start()
        }
    }
}

extension MattermostAccountSync {
    /// Fills one Postbox hole request (design: "Hole filling").
    func fillHole(_ entry: MessageHistoryHolesViewEntry) async {
        let hole: MessageHistoryViewPeerHole
        switch entry.hole {
        case let .peer(value):
            hole = value
        }
        let peerId = hole.peerId
        // Wait for the bootstrap: it creates the channels this request may belong to.
        if !(self.state.with { $0.isBootstrapped }) {
            let _ = await self.bootstrappedSignalValue()
        }
        guard hole.namespace == Namespaces.Message.Cloud, let channelId = self.channelId(forPeerId: peerId), let channelState = self.channelState(channelId) else {
            // Not a Mattermost chat (or another namespace): nothing will ever fill it.
            await self.postbox.mmTransaction { transaction in
                transaction.removeHole(peerId: peerId, threadId: hole.threadId, namespace: hole.namespace, space: entry.space, range: 1 ... (Int32.max - 1))
            }
            MMLog.log("holes: dropped \(entry) (not a Mattermost chat)")
            return
        }
        if let threadId = hole.threadId, !(channelState.kind == .saved && threadId == self.ownPeerId.toInt64()) {
            await self.fillThreadHole(channelId: channelId, channelState: channelState, threadId: threadId)
            return
        }

        do {
            switch entry.direction {
            case let .range(start, end):
                let requested = min(start.id, end.id) ... max(start.id, end.id)
                let olderFirst = start.id >= end.id
                if case let .tag(tag) = entry.space {
                    if tag == .pinned {
                        // The pinned-message bar: Mattermost lists a channel's pinned posts in one call.
                        try await self.loadPinned(channelId: channelId, channelState: channelState)
                    } else {
                        // Media tabs (photos, files, links, …). Paging the whole history for them would load
                        // every post of the channel as soon as a chat opens; Spike D shows the media of the
                        // loaded history instead (Phase 2: Mattermost's file search per channel).
                        self.state.with { $0.completeTagSpaces[channelId, default: []].insert(tag) }
                        await self.postbox.mmTransaction { transaction in
                            transaction.removeHole(peerId: peerId, threadId: nil, namespace: Namespaces.Message.Cloud, space: .tag(tag), range: 1 ... self.maxLocalId)
                        }
                    }
                    return
                }
                // Fill the ID-map hole nearest to `start` inside the requested range. For the main history
                // that is the hole right next to the loaded messages; tag spaces (media tabs) only have their
                // holes cleared by main-history fills, so they page the main history too.
                let target = await self.postbox.mmTransaction { _ -> (cursor: HistoryCursor, range: ClosedRange<Int32>)?? in
                    let storeRef = self.storeRef()
                    let holes: [HistoryHole]
                    if storeRef.islands(channelId: channelId).isEmpty {
                        holes = self.state.with { $0.emptyChannels.contains(channelId) } ? [] : [HistoryHole(range: 1 ... self.maxLocalId, lowerBoundary: nil, upperBoundary: nil)]
                    } else {
                        holes = self.allocator.holes(channelId: channelId, store: storeRef)
                    }
                    let overlapping = holes.filter { $0.range.overlaps(requested) }
                    guard let hole = olderFirst ? overlapping.last : overlapping.first else {
                        return .some(nil)
                    }
                    // Mattermost can't page forward from the channel start: such holes fill downwards.
                    let cursor = (olderFirst ? nil : hole.cursor(direction: .newer)) ?? hole.cursor(direction: .older) ?? .latest
                    return (cursor, hole.range)
                }
                guard let resolved = target, let found = resolved else {
                    // The ID map has no hole here. Posts mapped without a stored message (the app stopped
                    // between the ID-map commit and the Postbox commit, or a reserved jump id) are loaded
                    // again with their neighbours; otherwise the Postbox hole is stale and just cleared.
                    let unwritten = await self.postbox.mmTransaction { transaction -> String? in
                        let edge = olderFirst ? requested.upperBound : requested.lowerBound
                        let nearby = self.store.entries(channelId: channelId, fromLocalId: edge, ascending: !olderFirst, limit: self.perPage)
                        return nearby.first(where: { entry in
                            return !entry.isDeleted && requested.contains(entry.localId) && !transaction.messageExists(id: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: entry.localId))
                        })?.postId
                    }
                    if let unwritten = unwritten {
                        MMLog.log("holes: \(unwritten) is mapped but not stored; reloading around it")
                        try await self.loadAround(channelId: channelId, postId: unwritten, requestedRange: requested)
                        return
                    }
                    await self.postbox.mmTransaction { transaction in
                        self.syncHoles(channelId: channelId, channelState: channelState, ranges: [requested], transaction: transaction)
                    }
                    MMLog.log("holes: \(requested) of \(channelId) is loaded already; cleared")
                    return
                }
                try await self.loadPage(channelId: channelId, cursor: found.cursor, requestedRange: requested)
            case let .aroundId(messageId):
                let cursor = await self.postbox.mmTransaction { _ -> HistoryCursor? in
                    return self.allocator.aroundCursor(localId: messageId.id, channelId: channelId, store: self.storeRef())
                }
                if case let .around(postId)? = cursor {
                    try await self.loadAround(channelId: channelId, postId: postId, requestedRange: messageId.id ... messageId.id)
                } else {
                    // An anchor that maps to no post: the id is known to hold nothing; fill towards it from above.
                    let fallback = await self.postbox.mmTransaction { transaction -> HistoryCursor? in
                        transaction.removeHole(peerId: peerId, threadId: hole.threadId, namespace: Namespaces.Message.Cloud, space: .everywhere, range: messageId.id ... messageId.id)
                        return self.allocator.fillCursor(direction: .older, boundaryLocalId: messageId.id, channelId: channelId, store: self.storeRef())
                    }
                    try await self.loadPage(channelId: channelId, cursor: fallback ?? .latest, requestedRange: messageId.id ... messageId.id)
                }
            }
        } catch {
            MMLog.log("holes: \(entry) failed: \(error)")
        }
    }

    private func bootstrappedSignalValue() async -> Bool {
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let _ = (self.bootstrapped.get()
            |> filter { $0 }
            |> take(1)).start(next: { value in
                continuation.resume(returning: value)
            })
        }
    }

    /// Loads one page at `cursor` and writes it (bootstrap's newest pages, hole fills, catch-up gaps).
    @discardableResult
    func loadPage(channelId: String, cursor: HistoryCursor, requestedRange: ClosedRange<Int32>?, resetReadState: Bool = false) async throws -> PageWriteResult {
        if case let .around(postId) = cursor {
            return try await self.loadAround(channelId: channelId, postId: postId, requestedRange: requestedRange)
        }
        let list: PostList
        switch cursor {
        case .latest, .around:
            list = try await self.client.posts(channelId: channelId, page: 0, perPage: self.perPage)
        case let .before(postId):
            list = try await self.client.posts(channelId: channelId, perPage: self.perPage, before: postId)
        case let .after(postId):
            list = try await self.client.posts(channelId: channelId, perPage: self.perPage, after: postId)
        }
        let ordered = list.orderedPosts
        let isFull = ordered.count >= self.perPage
        let run: [Post]
        let kind: PageWrite.Kind
        switch cursor {
        case .latest, .around:
            run = isFull ? trimCutGroup(ordered, oldest: true) : ordered
            kind = .latest(reachedStart: !isFull)
        case let .before(postId):
            run = isFull ? trimCutGroup(ordered, oldest: true) : ordered
            kind = .older(anchor: postId, reachedStart: !isFull)
        case let .after(postId):
            run = isFull ? trimCutGroup(ordered, oldest: false) : ordered
            kind = .newer(anchor: postId, reachedLatest: !isFull)
        }
        let extra = extraPosts(list, run: run)
        await self.ensureUsers(referencedUserIds(run + extra))
        let page = PageWrite(channelId: channelId, kind: kind, run: run, extra: extra, requestedRange: requestedRange, resetReadState: resetReadState)
        let result = await self.postbox.mmTransaction { transaction in
            return self.write(page, transaction: transaction)
        }
        MMLog.log("page \(channelId) \(cursor): \(ordered.count) posts (\(run.count) in run, \(extra.count) extra), inserted \(result.insertedCount), island \(result.islandRange.map { "\($0)" } ?? "-"), renumbered \(result.renumberedCount)")
        return result
    }

    /// A permalink: the target, the posts before it and the posts after it, as one new island.
    @discardableResult
    func loadAround(channelId: String, postId: String, requestedRange: ClosedRange<Int32>?) async throws -> PageWriteResult {
        let target = try await self.client.post(id: postId)
        let half = self.perPage / 2
        let before = try await self.client.posts(channelId: channelId, perPage: half, before: postId)
        let olderOrdered = before.orderedPosts
        let olderReachedStart = olderOrdered.count < half
        let olderRun = olderReachedStart ? olderOrdered : trimCutGroup(olderOrdered, oldest: true)
        // `before=`/`after=` compare `create_at` strictly, so posts sharing the target's millisecond are in
        // neither page. Paging forward from the newest older post includes them.
        let afterAnchor = olderOrdered.first?.id ?? postId
        let after = try await self.client.posts(channelId: channelId, perPage: self.perPage, after: afterAnchor)
        let newerOrdered = after.orderedPosts
        let newerReachedLatest = newerOrdered.count < self.perPage
        var newerRun = newerReachedLatest ? newerOrdered : trimCutGroup(newerOrdered, oldest: false)
        if !newerRun.contains(where: { $0.id == postId }) && !olderRun.contains(where: { $0.id == postId }) {
            newerRun.append(target)
        }
        let run = olderRun + newerRun
        var extra = extraPosts(before, run: run) + extraPosts(after, run: run)
        var seen = Set(run.map { $0.id })
        extra = extra.filter { seen.insert($0.id).inserted }
        await self.ensureUsers(referencedUserIds(run + extra))
        let page = PageWrite(channelId: channelId, kind: .around(target: postId, olderReachedStart: olderReachedStart, newerReachedLatest: newerReachedLatest), run: run, extra: extra, requestedRange: requestedRange)
        let result = await self.postbox.mmTransaction { transaction in
            return self.write(page, transaction: transaction)
        }
        MMLog.log("around \(postId) in \(channelId): \(run.count) posts, island \(result.islandRange.map { "\($0)" } ?? "-"), renumbered \(result.renumberedCount)")
        return result
    }

    /// The channel's pinned posts (`GET /channels/{id}/pinned`), so the `.pinned` tag space is complete
    /// without loading the whole history.
    func loadPinned(channelId: String, channelState: ChannelState) async throws {
        let list = try await self.client.pinnedPosts(channelId: channelId)
        let posts = list.orderedPosts
        await self.ensureUsers(referencedUserIds(posts))
        self.state.with { $0.completeTagSpaces[channelId, default: []].insert(.pinned) }
        await self.postbox.mmTransaction { transaction in
            if !posts.isEmpty {
                self.write(PageWrite(channelId: channelId, kind: .singles, run: posts), transaction: transaction)
            }
            transaction.removeHole(peerId: channelState.peerId, threadId: nil, namespace: Namespaces.Message.Cloud, space: .tag(.pinned), range: 1 ... self.maxLocalId)
        }
        MMLog.log("holes: \(posts.count) pinned posts of \(channelId)")
    }

    /// Thread views (`threadId` = local id of the root): `GET /posts/{root}/thread`.
    private func fillThreadHole(channelId: String, channelState: ChannelState, threadId: Int64) async {
        let rootPostId: String? = await self.postbox.mmTransaction { _ in
            guard let localId = Int32(exactly: threadId), let entry = self.store.entries(channelId: channelId, fromLocalId: localId, ascending: true, limit: 1).first, entry.localId == localId else {
                return nil
            }
            return entry.postId
        }
        var posts: [Post] = []
        if let rootPostId = rootPostId {
            do {
                posts = try await self.client.postThread(postId: rootPostId).orderedPosts
            } catch {
                MMLog.log("holes: thread \(rootPostId) failed: \(error)")
                return
            }
            await self.ensureUsers(referencedUserIds(posts))
        }
        let peerId = channelState.peerId
        await self.postbox.mmTransaction { transaction in
            if !posts.isEmpty {
                self.write(PageWrite(channelId: channelId, kind: .singles, run: posts), transaction: transaction)
            }
            // The whole thread is loaded (or the thread is unknown): nothing else to fill in its view.
            transaction.removeHole(peerId: peerId, threadId: threadId, namespace: Namespaces.Message.Cloud, space: .everywhere, range: 1 ... (Int32.max - 1))
        }
        MMLog.log("holes: thread \(threadId) of \(channelId): \(posts.count) posts")
    }
}

/// Drops the posts that share the page's outermost `create_at` when the page was cut by `per_page`.
/// Mattermost's `before=`/`after=` compare `create_at` strictly, so if a group of posts with the same
/// millisecond straddles the page boundary, paging on from this page would skip the rest of the group.
/// Leaving the whole group to the next page avoids that (unless the entire page is one millisecond).
func trimCutGroup(_ ordered: [Post], oldest: Bool) -> [Post] {
    guard let boundary = oldest ? ordered.map({ $0.createAt }).min() : ordered.map({ $0.createAt }).max() else {
        return ordered
    }
    let trimmed = ordered.filter { $0.createAt != boundary }
    if trimmed.isEmpty {
        MMLog.log("page: all \(ordered.count) posts share create_at \(boundary); posts of that millisecond beyond the page may be missed")
        return ordered
    }
    return trimmed
}

/// Thread roots of the run's replies that are not part of the run (Mattermost adds them to `posts`; a root
/// can also be in a trimmed millisecond group).
func extraPosts(_ list: PostList, run: [Post]) -> [Post] {
    let runIds = Set(run.map { $0.id })
    let roots = Set(run.compactMap { $0.rootId.isEmpty ? nil : $0.rootId })
    return list.posts.values.filter { !runIds.contains($0.id) && roots.contains($0.id) }.sorted(by: { $0.createAt < $1.createAt })
}

func referencedUserIds(_ posts: [Post]) -> Set<String> {
    var result = Set<String>()
    for post in posts {
        result.insert(post.userId)
        for reaction in post.metadata?.reactions ?? [] {
            result.insert(reaction.userId)
        }
        for participant in post.participants ?? [] {
            result.insert(participant.id)
        }
    }
    return result
}
