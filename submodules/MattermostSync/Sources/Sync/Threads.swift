import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// One team's followed threads (`GET /users/me/teams/{team}/threads`), kept current by thread events.
struct MattermostTeamThreads {
    /// Root post id → thread.
    var threads: [String: UserThread] = [:]
    var isLoaded = false
}

/// A followed thread for the threads list (MattermostUI), with its peers resolved.
public struct MattermostThreadListItem {
    public let rootPostId: String
    public let channelId: String
    public let channelTitle: String
    /// The chat of the thread and the thread (local id of the root) to open, once the root is stored.
    public let peerId: PeerId
    public let threadId: Int64?
    public let author: Peer?
    public let rootText: String
    public let replyCount: Int
    /// The latest participants first.
    public let participants: [Peer]
    public let lastReplyAt: Int64
    public let unreadReplies: Int
    public let unreadMentions: Int
    public let isUrgent: Bool
}

public struct MattermostThreadList {
    public let teamId: String
    public let teamName: String
    public let isLoaded: Bool
    /// Newest reply first.
    public let items: [MattermostThreadListItem]

    public var unreadThreadCount: Int {
        return self.items.filter { $0.unreadReplies > 0 }.count
    }

    public var unreadMentionCount: Int {
        return self.items.reduce(0, { $0 + $1.unreadMentions })
    }
}

/// Unread followed threads of a team: the threads button's badge.
public struct MattermostThreadsBadge: Equatable {
    public let unreadThreads: Int
    public let unreadMentions: Int

    public init(unreadThreads: Int, unreadMentions: Int) {
        self.unreadThreads = unreadThreads
        self.unreadMentions = unreadMentions
    }
}

extension MattermostAccountSync {
    // MARK: Loading

    /// Every team's followed threads, e.g. after the bootstrap or switching collapsed threads on.
    func reloadAllThreads() async {
        for team in self.state.with({ $0.teams }) {
            await self.reloadThreads(teamId: team.id)
        }
    }

    /// A team's followed threads, newest reply first (at most 500). Users and roots that aren't stored yet are
    /// written, so every row can open its thread view.
    func reloadThreads(teamId: String) async {
        do {
            var threads: [UserThread] = []
            var before: String?
            for _ in 0 ..< 5 {
                let list = try await self.client.userThreads(teamId: teamId, options: UserThreadsOptions(before: before, perPage: 100, extended: true))
                threads.append(contentsOf: list.threads)
                if list.threads.count < 100 {
                    break
                }
                before = list.threads.last?.id
            }
            threads = threads.filter { $0.deleteAt == 0 }
            await self.prepareThreads(threads)
            await self.postbox.mmTransaction { transaction in
                for thread in threads {
                    if let post = thread.post {
                        self.updateThreadRootSummary(channelId: post.channelId, rootPostId: post.id, replyCount: thread.replyCount, latestUserIds: thread.participants.reversed().map { $0.id }, transaction: transaction)
                    }
                }
            }
            self.state.with { state in
                var teamThreads = MattermostTeamThreads()
                for thread in threads {
                    teamThreads.threads[thread.id] = thread
                }
                teamThreads.isLoaded = true
                state.threads[teamId] = teamThreads
            }
            self.threadsChanged()
            MMLog.log("threads: \(threads.count) followed in team \(teamId), \(threads.filter { $0.unreadReplies > 0 }.count) unread")
        } catch {
            MMLog.log("threads: team \(teamId) not loaded: \(error)")
        }
    }

    func clearThreads() {
        self.state.with { $0.threads = [:] }
        self.threadsChanged()
    }

    /// Writes the users of the threads and their roots that aren't stored (a root of an old thread may be far
    /// back in its channel's history).
    private func prepareThreads(_ threads: [UserThread]) async {
        var userIds = Set<String>()
        for thread in threads {
            for participant in thread.participants {
                userIds.insert(participant.id)
            }
            if let post = thread.post {
                userIds.insert(post.userId)
            }
        }
        await self.ensureUsers(userIds)
        var rootsByChannel: [String: [Post]] = [:]
        for thread in threads {
            if let post = thread.post, post.deleteAt == 0, self.channelState(post.channelId) != nil {
                rootsByChannel[post.channelId, default: []].append(post)
            }
        }
        for (channelId, roots) in rootsByChannel {
            guard let peerId = self.channelState(channelId)?.peerId else {
                continue
            }
            await self.postbox.mmTransaction { transaction in
                let known = self.store.entries(channelId: channelId, postIds: roots.map { $0.id })
                let missing = roots.filter { root in
                    guard let entry = known[root.id] else {
                        return true
                    }
                    return !entry.isDeleted && !transaction.messageExists(id: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: entry.localId))
                }
                if !missing.isEmpty {
                    self.write(PageWrite(channelId: channelId, kind: .singles, run: missing.sorted(by: { $0.createAt < $1.createAt })), transaction: transaction)
                }
            }
        }
    }

    // MARK: Live updates

    /// `thread_updated`, `thread_read_changed`, `thread_follow_changed`.
    func applyThreadEvent(_ event: WebSocketEvent) async {
        guard self.isCollapsedThreads else {
            return
        }
        // DM and GM threads belong to no team: the server sends them without one.
        let eventTeamId = event.broadcast.teamId
        let teamIds: [String] = eventTeamId.isEmpty ? self.state.with { Array($0.threads.keys) } : [eventTeamId]
        switch event.type {
        case .threadUpdated:
            guard let thread = event.updatedThread else {
                return
            }
            await self.prepareThreads([thread])
            self.state.with { state in
                for teamId in teamIds {
                    state.threads[teamId, default: MattermostTeamThreads()].threads[thread.id] = thread
                }
            }
            await self.updateThreadRoot(thread)
            MMLog.log("live: thread \(thread.id) updated (\(thread.replyCount) replies, \(thread.unreadReplies) unread, \(thread.unreadMentions) mentions)")
        case .threadReadChanged:
            guard let threadId = event.data["thread_id"]?.stringValue, !threadId.isEmpty else {
                // A whole channel or team was marked read.
                for teamId in teamIds {
                    await self.reloadThreads(teamId: teamId)
                }
                return
            }
            let unreadReplies = event.data["unread_replies"]?.int64Value ?? 0
            let unreadMentions = event.data["unread_mentions"]?.int64Value ?? 0
            let lastViewedAt = event.data["timestamp"]?.int64Value
            self.state.with { state in
                for teamId in Array(state.threads.keys) where teamIds.contains(teamId) || eventTeamId.isEmpty {
                    if var thread = state.threads[teamId]?.threads[threadId] {
                        thread.unreadReplies = unreadReplies
                        thread.unreadMentions = unreadMentions
                        if let lastViewedAt = lastViewedAt {
                            thread.lastViewedAt = max(thread.lastViewedAt, lastViewedAt)
                        }
                        state.threads[teamId]?.threads[threadId] = thread
                    }
                }
            }
            MMLog.log("live: thread \(threadId) read changed (\(unreadReplies) unread, \(unreadMentions) mentions)")
        case .threadFollowChanged:
            guard let threadId = event.data["thread_id"]?.stringValue, !threadId.isEmpty else {
                return
            }
            let following = event.data["state"]?.boolValue ?? false
            if following {
                let teamId = teamIds.first ?? self.state.with { $0.teams.first?.id } ?? ""
                if let thread = try? await self.client.userThread(teamId: teamId, threadId: threadId, extended: true) {
                    await self.prepareThreads([thread])
                    self.state.with { state in
                        for teamId in teamIds {
                            state.threads[teamId, default: MattermostTeamThreads()].threads[thread.id] = thread
                        }
                    }
                }
            } else {
                self.state.with { state in
                    for teamId in Array(state.threads.keys) {
                        state.threads[teamId]?.threads[threadId] = nil
                    }
                }
            }
            MMLog.log("live: thread \(threadId) \(following ? "followed" : "unfollowed")")
        default:
            return
        }
        self.threadsChanged()
    }

    /// The root's reply count and latest repliers from the server's thread (`thread_updated`, the threads list).
    func updateThreadRoot(_ thread: UserThread) async {
        guard let post = thread.post else {
            return
        }
        await self.postbox.mmTransaction { transaction in
            self.updateThreadRootSummary(channelId: post.channelId, rootPostId: post.id, replyCount: thread.replyCount, latestUserIds: thread.participants.reversed().map { $0.id }, transaction: transaction)
        }
    }

    /// The roots of the replies among `posts` get their reply count from `POST /posts/ids` (channel pages and
    /// `since=` lists say 0 for every root), with the replies' authors in front of their latest repliers.
    func refreshThreadRoots(channelId: String, posts: [Post]) async {
        var repliesByRoot: [String: [Post]] = [:]
        for post in posts where !post.rootId.isEmpty && post.deleteAt == 0 {
            repliesByRoot[post.rootId, default: []].append(post)
        }
        if repliesByRoot.isEmpty {
            return
        }
        var roots: [Post] = []
        let rootIds = Array(repliesByRoot.keys)
        for start in stride(from: 0, to: rootIds.count, by: 100) {
            guard let chunk = try? await self.client.posts(ids: Array(rootIds[start ..< min(rootIds.count, start + 100)])) else {
                return
            }
            roots.append(contentsOf: chunk)
        }
        await self.postbox.mmTransaction { transaction in
            for root in roots where root.channelId == channelId && root.deleteAt == 0 {
                let authors = (repliesByRoot[root.id] ?? []).sorted(by: { $0.createAt > $1.createAt }).map { $0.userId }
                self.updateThreadRootSummary(channelId: channelId, rootPostId: root.id, replyCount: root.replyCount, latestUserIds: authors, mergingStoredUsers: true, transaction: transaction)
            }
        }
    }

    /// Sets a root's "N replies" (count and the latest repliers' avatars, newest first). Channel pages carry no
    /// participants, so these come from loaded threads and the threads list. `mergingStoredUsers`: the given
    /// users go in front of the stored latest repliers (they are only some of the thread's).
    func updateThreadRootSummary(channelId: String, rootPostId: String, replyCount: Int64, latestUserIds: [String], mergingStoredUsers: Bool = false, transaction: Transaction) {
        guard let channelState = self.channelState(channelId), let entry = self.store.entries(channelId: channelId, postIds: [rootPostId])[rootPostId], !entry.isDeleted else {
            return
        }
        var latestUsers: [PeerId] = []
        for userId in latestUserIds {
            if let peerId = self.userPeerId(userId), !latestUsers.contains(peerId) {
                latestUsers.append(peerId)
            }
            if latestUsers.count == 3 {
                break
            }
        }
        let marker: PeerId? = self.isCollapsedThreads ? channelState.peerId : nil
        transaction.updateMessage(MessageId(peerId: channelState.peerId, namespace: Namespaces.Message.Cloud, id: entry.localId), update: { current in
            let existing = current.attributes.first(where: { $0 is ReplyThreadMessageAttribute }) as? ReplyThreadMessageAttribute
            var latestUsers = latestUsers
            if mergingStoredUsers, let existing = existing {
                for peerId in existing.latestUsers where latestUsers.count < 3 && !latestUsers.contains(peerId) {
                    latestUsers.append(peerId)
                }
            }
            if let existing = existing, Int64(existing.count) == replyCount, existing.latestUsers == latestUsers, existing.commentsPeerId == marker {
                return .skip
            }
            var attributes = current.attributes.filter { !($0 is ReplyThreadMessageAttribute) }
            if replyCount > 0 {
                attributes.append(ReplyThreadMessageAttribute(count: Int32(clamping: replyCount), latestUsers: latestUsers, commentsPeerId: marker, maxMessageId: nil, maxReadMessageId: nil))
            }
            return .update(StoreMessage.mmCopy(of: current, id: current.id, threadId: current.threadId, attributes: attributes))
        })
    }

    // MARK: Actions

    /// The root post and team of a thread view (`threadId` = local id of the root in the chat `peerId`).
    func threadReference(peerId: PeerId, threadId: Int64) -> (channelId: String, rootPostId: String, teamId: String)? {
        guard let channelId = self.channelId(forPeerId: peerId), let channelState = self.channelState(channelId), let localId = Int32(exactly: threadId) else {
            return nil
        }
        guard let entry = self.store.entries(channelId: channelId, fromLocalId: localId, ascending: true, limit: 1).first, entry.localId == localId, !entry.isDeleted else {
            return nil
        }
        // DMs and GMs: any team serves the thread APIs.
        let teamId = channelState.teamId.isEmpty ? (self.state.with { $0.teams.first?.id } ?? "") : channelState.teamId
        return (channelId, entry.serverPostId, teamId)
    }

    /// The followed thread with this root, from any team's list.
    func followedThread(rootPostId: String) -> UserThread? {
        return self.state.with { state in
            for teamThreads in state.threads.values {
                if let thread = teamThreads.threads[rootPostId] {
                    return thread
                }
            }
            return nil
        }
    }

    /// Whether the user follows the thread: nil while the lists aren't loaded.
    func isFollowingThread(peerId: PeerId, threadId: Int64) -> Bool? {
        guard let reference = self.threadReference(peerId: peerId, threadId: threadId) else {
            return nil
        }
        if self.followedThread(rootPostId: reference.rootPostId) != nil {
            return true
        }
        let isLoaded = self.state.with { $0.threads[reference.teamId]?.isLoaded ?? false }
        return isLoaded ? false : nil
    }

    func setFollowingThread(peerId: PeerId, threadId: Int64, following: Bool) async -> Bool {
        guard let reference = self.threadReference(peerId: peerId, threadId: threadId) else {
            return false
        }
        do {
            if following {
                try await self.client.followThread(teamId: reference.teamId, threadId: reference.rootPostId)
                if let thread = try? await self.client.userThread(teamId: reference.teamId, threadId: reference.rootPostId, extended: true) {
                    await self.prepareThreads([thread])
                    self.state.with { state in
                        state.threads[reference.teamId, default: MattermostTeamThreads()].threads[thread.id] = thread
                    }
                }
            } else {
                try await self.client.unfollowThread(teamId: reference.teamId, threadId: reference.rootPostId)
                self.state.with { state in
                    for teamId in Array(state.threads.keys) {
                        state.threads[teamId]?.threads[reference.rootPostId] = nil
                    }
                }
            }
            self.threadsChanged()
            MMLog.log("threads: \(following ? "followed" : "unfollowed") \(reference.rootPostId)")
            return true
        } catch {
            MMLog.log("threads: \(following ? "follow" : "unfollow") of \(reference.rootPostId) failed: \(error)")
            self.notice("Couldn't \(following ? "follow" : "unfollow") the thread: \(describeError(error))")
            return false
        }
    }

    /// The thread view showed messages up to `messageIndex`: marks the thread read on the server when it has
    /// unread replies (`PUT …/threads/{id}/read/{timestamp}`), up to now when the newest reply was seen.
    func markThreadViewed(peerId: PeerId, threadId: Int64, messageIndex: MessageIndex) async {
        guard self.isCollapsedThreads, let reference = self.threadReference(peerId: peerId, threadId: threadId), let thread = self.followedThread(rootPostId: reference.rootPostId) else {
            return
        }
        if thread.unreadReplies == 0 && thread.unreadMentions == 0 {
            return
        }
        let seenCreateAt: Int64? = await self.postbox.mmTransaction { transaction in
            let messageId = messageIndex.id
            guard messageId.namespace == Namespaces.Message.Cloud, let entry = self.store.entries(channelId: reference.channelId, fromLocalId: messageId.id, ascending: true, limit: 1).first, entry.localId == messageId.id else {
                return nil
            }
            return entry.createAt
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var timestamp = now
        if let seenCreateAt = seenCreateAt, seenCreateAt < thread.lastReplyAt {
            timestamp = seenCreateAt
        }
        if timestamp <= thread.lastViewedAt {
            return
        }
        let inFlightKey = "\(reference.rootPostId)"
        let started = self.threadReadsInFlight.with { inFlight -> Bool in
            if inFlight.contains(inFlightKey) {
                return false
            }
            inFlight.insert(inFlightKey)
            return true
        }
        if !started {
            return
        }
        defer {
            self.threadReadsInFlight.with { _ = $0.remove(inFlightKey) }
        }
        do {
            try await self.client.markThreadRead(teamId: reference.teamId, threadId: reference.rootPostId, timestamp: timestamp)
            // The server answers with `thread_read_changed`; until then, assume everything seen is read.
            if timestamp >= thread.lastReplyAt {
                self.state.with { state in
                    for teamId in Array(state.threads.keys) {
                        if var item = state.threads[teamId]?.threads[reference.rootPostId] {
                            item.unreadReplies = 0
                            item.unreadMentions = 0
                            item.lastViewedAt = max(item.lastViewedAt, timestamp)
                            state.threads[teamId]?.threads[reference.rootPostId] = item
                        }
                    }
                }
                self.threadsChanged()
                MattermostSync.removeDeliveredNotifications(channelId: reference.channelId, rootId: reference.rootPostId, isCRTEnabled: true, serverId: self.server.diagnosticId, accountId: self.account.id.int64)
            }
            MMLog.log("threads: marked \(reference.rootPostId) read up to \(timestamp)")
        } catch {
            MMLog.log("threads: marking \(reference.rootPostId) read failed: \(error)")
        }
    }

    // MARK: Observing

    func threadsChanged() {
        self.threadsVersion.with { $0 += 1 }
        self.threadsVersionPromise.set(self.threadsVersion.current)
    }

    func threadsBadge(teamId: String) -> MattermostThreadsBadge {
        return self.state.with { state in
            let threads = state.threads[teamId]?.threads.values.map { $0 } ?? []
            return MattermostThreadsBadge(unreadThreads: threads.filter { $0.unreadReplies > 0 }.count, unreadMentions: threads.reduce(0, { $0 + Int($1.unreadMentions) }))
        }
    }

    func threadList(teamId: String) async -> MattermostThreadList {
        let (team, teamThreads) = self.state.with { state in
            return (state.teams.first(where: { $0.id == teamId }), state.threads[teamId] ?? MattermostTeamThreads())
        }
        let threads = teamThreads.threads.values.sorted(by: { lhs, rhs in
            if lhs.lastReplyAt != rhs.lastReplyAt {
                return lhs.lastReplyAt > rhs.lastReplyAt
            }
            return lhs.id > rhs.id
        })
        let items: [MattermostThreadListItem] = await self.postbox.mmTransaction { transaction in
            return threads.compactMap { thread -> MattermostThreadListItem? in
                guard let post = thread.post, let channelState = self.channelState(post.channelId) else {
                    return nil
                }
                var threadId: Int64?
                if let entry = self.store.entries(channelId: post.channelId, postIds: [post.id])[post.id], !entry.isDeleted {
                    threadId = Int64(entry.localId)
                }
                var builder = FormattedTextBuilder()
                builder.appendMarkdown(post.message)
                var rootText = builder.formatted.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if rootText.isEmpty, let files = post.metadata?.files, !files.isEmpty {
                    rootText = files.map { $0.name }.joined(separator: ", ")
                }
                let channelTitle = channelState.channel.displayName.isEmpty ? channelState.channel.name : channelState.channel.displayName
                return MattermostThreadListItem(
                    rootPostId: thread.id,
                    channelId: post.channelId,
                    channelTitle: channelState.kind == .direct ? (channelState.channel.directMessagePartnerId(myUserId: self.ownUserId).flatMap { partnerId in self.state.with { $0.users[partnerId] } }.map(PeerConverter.displayName) ?? channelTitle) : channelTitle,
                    peerId: channelState.peerId,
                    threadId: threadId,
                    author: self.userPeerId(post.userId).flatMap { transaction.getPeer($0) },
                    rootText: rootText,
                    replyCount: Int(thread.replyCount),
                    participants: thread.participants.reversed().prefix(5).compactMap { participant in
                        return self.userPeerId(participant.id).flatMap { transaction.getPeer($0) }
                    },
                    lastReplyAt: thread.lastReplyAt,
                    unreadReplies: Int(thread.unreadReplies),
                    unreadMentions: Int(thread.unreadMentions),
                    isUrgent: thread.isUrgent
                )
            }
        }
        return MattermostThreadList(teamId: teamId, teamName: team?.displayName ?? "", isLoaded: teamThreads.isLoaded, items: items)
    }
}
