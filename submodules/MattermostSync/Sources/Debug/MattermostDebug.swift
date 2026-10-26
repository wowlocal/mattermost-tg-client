import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Where a debug hook wants the app to navigate.
public struct MattermostDebugTarget {
    public let peerId: PeerId
    public let messageId: MessageId?
}

/// Debug-only hooks for verification without UI automation (Spike D). All read the launch environment
/// (`SIMCTL_CHILD_<NAME>` on `xcrun simctl launch`):
///
/// - `RELAY_DEBUG_OPEN_CHAT=<chat>` opens a chat once the bootstrap has written it: a channel name
///   (`firehose`, `engineering/town-square`), a display name, `dm:<username>` or `saved`.
/// - `RELAY_DEBUG_OPEN_POST=<post id>` opens the post's chat at that post (permalink). Only the post's id
///   is mapped up front; the chat's `.aroundId` hole request loads the post and its neighbours.
/// - `RELAY_DEBUG_PAGE=<chat>` pages through the chat's whole history with Postbox history views (what the
///   chat screen does while scrolling): down to the first post, then up to the newest one, starting at
///   `RELAY_DEBUG_OPEN_POST` when set. Then it checks the result and writes
///   `Documents/relay-debug/<channel id>.json` (local ids, post ids, holes) for comparison with the server.
/// - `RELAY_DEBUG_WRITE=<actions>` drives the write path through the engine (see `MattermostDebugWriter`).
public enum MattermostDebug {
    public static func chatToOpen(account: Account) -> Signal<MattermostDebugTarget?, NoError> {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let chat = environment["RELAY_DEBUG_OPEN_CHAT"].flatMap { $0.isEmpty ? nil : $0 }
        let postId = environment["RELAY_DEBUG_OPEN_POST"].flatMap { $0.isEmpty ? nil : $0 }
        let pageChat = environment["RELAY_DEBUG_PAGE"].flatMap { $0.isEmpty ? nil : $0 }
        let dumpChatList = environment["RELAY_DEBUG_DUMP_CHATLIST"] == "1"
        let writeScript = environment["RELAY_DEBUG_WRITE"].flatMap { $0.isEmpty ? nil : $0 }
        if chat == nil && postId == nil && pageChat == nil && !dumpChatList && writeScript == nil {
            return .single(nil)
        }
        return Signal { subscriber in
            let task = Task {
                guard let sync = await waitForSync(accountId: account.id) else {
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return
                }
                var target: MattermostDebugTarget?
                var startMessageId: MessageId?
                if let postId = postId {
                    target = await sync.debugPrepareJump(postId: postId)
                    startMessageId = target?.messageId
                } else if let chat = chat, let channelId = sync.debugFindChannel(chat), let channelState = sync.channelState(channelId) {
                    target = MattermostDebugTarget(peerId: channelState.peerId, messageId: nil)
                } else if let chat = chat {
                    MMLog.log("debug: no chat matches \(chat)")
                }
                subscriber.putNext(target)
                subscriber.putCompletion()
                if dumpChatList {
                    // Give the newest pages a moment to resolve read states, then dump.
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await sync.debugDumpChatList()
                }
                if let startMessageId = startMessageId {
                    // The chat screen opens at the reserved id; its `.aroundId` request loads the post.
                    let started = CFAbsoluteTimeGetCurrent()
                    var loaded = false
                    for _ in 0 ..< 300 {
                        loaded = await sync.postbox.mmTransaction { transaction in
                            return transaction.messageExists(id: startMessageId)
                        }
                        if loaded {
                            break
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    MMLog.log("debug: permalink target \(loaded ? "loaded" : "NOT loaded") \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms after navigating")
                }
                if let pageChat = pageChat, let channelId = sync.debugFindChannel(pageChat) {
                    await sync.debugPageThroughHistory(channelId: channelId, startMessageId: startMessageId)
                }
                if let writeScript = writeScript {
                    // After the chat (if any) has opened.
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    await MattermostDebugWriter.run(script: writeScript, sync: sync)
                }
            }
            return ActionDisposable {
                let _ = task
            }
        }
        #else
        return .single(nil)
        #endif
    }

    /// Debug: the message of a loaded post in a chat (the thread root for the debug remote's `open-thread`).
    public static func messageId(accountId: AccountRecordId, peerId: PeerId, postId: String) -> MessageId? {
        #if DEBUG
        guard let sync = MattermostSync.sync(accountId: accountId), let channelId = sync.channelId(forPeerId: peerId), let entry = sync.store.entries(channelId: channelId, postIds: [postId])[postId], !entry.isDeleted else {
            return nil
        }
        return MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: entry.localId)
        #else
        return nil
        #endif
    }

    private static func waitForSync(accountId: AccountRecordId) async -> MattermostAccountSync? {
        for _ in 0 ..< 600 {
            if let sync = MattermostSync.sync(accountId: accountId), sync.state.with({ $0.newestPagesLoaded }) {
                return sync
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        MMLog.log("debug: MattermostSync did not bootstrap within 60 s")
        return nil
    }
}

extension MattermostAccountSync {
    func debugFindChannel(_ query: String) -> String? {
        let lowered = query.lowercased()
        return self.state.with { state -> String? in
            var teamName: String?
            var name = lowered
            if let slash = lowered.firstIndex(of: "/") {
                teamName = String(lowered[..<slash])
                name = String(lowered[lowered.index(after: slash)...])
            }
            let teamId = teamName.flatMap { teamName in state.teams.first(where: { $0.name.lowercased() == teamName })?.id }
            if name == "saved" {
                return state.channels.values.first(where: { $0.kind == .saved })?.channel.id
            }
            if name.hasPrefix("dm:") {
                let username = String(name.dropFirst(3))
                guard let userId = state.userIdByUsername[username] else {
                    return nil
                }
                return state.channels.values.first(where: { $0.kind == .direct && $0.channel.directMessagePartnerId(myUserId: self.ownUserId) == userId })?.channel.id
            }
            let candidates = state.channels.values.filter { channelState in
                if let teamId = teamId, channelState.teamId != teamId {
                    return false
                }
                return channelState.channel.name.lowercased() == name || channelState.channel.displayName.lowercased() == name || channelState.channel.id == query
            }
            return candidates.sorted(by: { $0.channel.lastPostAt > $1.channel.lastPostAt }).first?.channel.id
        }
    }

    /// Maps the post's id (a single-post island in the ID map, nothing in Postbox yet) and returns where to
    /// navigate: the chat view then asks for `.aroundId` and the hole filler loads the neighbourhood.
    func debugPrepareJump(postId: String) async -> MattermostDebugTarget? {
        do {
            let post = try await self.client.post(id: postId)
            guard let channelState = self.channelState(post.channelId) else {
                MMLog.log("debug: post \(postId) is in unknown channel \(post.channelId)")
                return nil
            }
            let localId: Int32? = await self.postbox.mmTransaction { _ in
                var store = self.storeRef()
                var ingest: IngestResult?
                let _ = self.store.idMapTransaction {
                    ingest = try self.allocator.insertPost(PostOrderKey(createAt: post.createAt, postId: post.id), channelId: post.channelId, store: &store)
                }
                guard let localId = ingest?.localId(for: post.id) else {
                    return nil
                }
                self.state.with { $0.reservedJumpIds[post.channelId, default: []].insert(localId) }
                return localId
            }
            guard let localId = localId else {
                return nil
            }
            MMLog.log("debug: permalink \(postId) (\(Date(timeIntervalSince1970: Double(post.createAt) / 1000))) → local id \(localId) in \(post.channelId)")
            return MattermostDebugTarget(peerId: channelState.peerId, messageId: MessageId(peerId: channelState.peerId, namespace: Namespaces.Message.Cloud, id: localId))
        } catch {
            MMLog.log("debug: permalink \(postId) failed: \(error)")
            return nil
        }
    }

    /// Scrolls through the whole history like the chat screen does: a Postbox history view anchored at the
    /// message next to the nearest hole (older holes first, then newer ones), kept open until that hole
    /// changes, until Postbox has no holes left for the chat. Then checks and dumps the result.
    /// `tag`: page the view of that tag instead (the root-post history of collapsed reply threads); `dump`: write
    /// the result (else the caller checks it).
    func debugPageThroughHistory(channelId: String, startMessageId: MessageId?, tag: MessageTags? = nil, dump: Bool = true) async {
        guard let channelState = self.channelState(channelId) else {
            return
        }
        let peerId = channelState.peerId
        let started = CFAbsoluteTimeGetCurrent()
        let startId = startMessageId?.id ?? self.maxLocalId
        MMLog.log("pager: start \(channelId) from local id \(startId)")
        var stalls = 0
        var steps = 0
        var slowestStep = 0.0
        while steps < 5000 {
            let next: (holes: IndexSet, anchor: HistoryViewInputAnchor) = await self.postbox.mmTransaction { transaction in
                let holes = transaction.getHoles(peerId: peerId, namespace: Namespaces.Message.Cloud)
                // Older holes (below the start) from the top down, then newer ones from the bottom up.
                let ranges = Array(holes.rangeView)
                var anchorId: Int32?
                if let below = ranges.last(where: { $0.lowerBound <= Int(startId) }) {
                    anchorId = self.store.entries(channelId: channelId, fromLocalId: Int32(below.upperBound), ascending: true, limit: 16).first(where: { !$0.isDeleted })?.localId
                } else if let above = ranges.first {
                    anchorId = self.store.entries(channelId: channelId, fromLocalId: Int32(above.lowerBound - 1), ascending: false, limit: 16).first(where: { !$0.isDeleted })?.localId
                }
                // A reserved (not yet written) id anchors by id: the view then asks for `.aroundId`.
                let anchor: HistoryViewInputAnchor
                if let anchorId = anchorId {
                    let messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: anchorId)
                    anchor = transaction.getMessage(messageId).map { .index($0.index) } ?? .message(messageId)
                } else {
                    anchor = .upperBound
                }
                return (holes, anchor)
            }
            if next.holes.isEmpty {
                break
            }
            steps += 1
            let stepStarted = CFAbsoluteTimeGetCurrent()
            let progressed = await self.debugWaitForHoleChange(peerId: peerId, anchor: next.anchor, holes: next.holes, tag: tag)
            slowestStep = max(slowestStep, CFAbsoluteTimeGetCurrent() - stepStarted)
            if !progressed {
                stalls += 1
                MMLog.log("pager: STALL at \(next.anchor), holes \(Array(next.holes.rangeView))")
                if stalls > 3 {
                    break
                }
            }
            if steps % 25 == 0 {
                MMLog.log("pager: \(steps) steps, \(Int(CFAbsoluteTimeGetCurrent() - started)) s, holes \(Array(next.holes.rangeView).map { "\($0.lowerBound)...\($0.upperBound - 1)" })")
            }
        }
        MMLog.log("pager: done after \(steps) steps in \(Int(CFAbsoluteTimeGetCurrent() - started)) s (slowest step \(Int(slowestStep * 1000)) ms, \(stalls) stalls)")
        if dump {
            await self.debugDump(channelId: channelId, peerId: peerId, stalls: stalls, seconds: CFAbsoluteTimeGetCurrent() - started)
        }
    }

    /// Opens a history view at `anchor` (which makes Postbox request the nearest hole) and waits until the
    /// chat's holes differ from `holes`; false after 30 s without change.
    private func debugWaitForHoleChange(peerId: PeerId, anchor: HistoryViewInputAnchor, holes: IndexSet, tag: MessageTags? = nil) async -> Bool {
        let disposable = self.postbox.aroundMessageHistoryViewForLocation(
            .peer(peerId: peerId, threadId: nil),
            anchor: anchor,
            ignoreMessagesInTimestampRange: nil,
            ignoreMessageIds: Set(),
            count: 60,
            fixedCombinedReadStates: nil,
            topTaggedMessageIdNamespaces: [],
            tag: tag.flatMap { .tag($0) },
            appendMessagesFromTheSameGroup: false,
            namespaces: .not(Namespaces.Message.allNonRegular),
            orderStatistics: []
        ).start()
        defer {
            disposable.dispose()
        }
        let deadline = CFAbsoluteTimeGetCurrent() + 30.0
        while CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            let current = await self.postbox.mmTransaction { transaction in
                return transaction.getHoles(peerId: peerId, namespace: Namespaces.Message.Cloud)
            }
            if current != holes {
                return true
            }
        }
        return false
    }

    /// Every chat with its Postbox unread count, mention count, mute state and chat-list group, for
    /// comparison with the server's counters (`Documents/relay-debug/chatlist.json`).
    func debugDumpChatList() async {
        let channels = self.state.with { Array($0.channels.values) }
        let report: [String: Any] = await self.postbox.mmTransaction { transaction in
            var chats: [[String: Any]] = []
            let pinned = transaction.getPinnedItemIds(groupId: .root)
            for channelState in channels {
                let readState = transaction.getCombinedPeerReadState(channelState.peerId)
                let mentions = transaction.getMessageTagSummary(peerId: channelState.peerId, threadId: nil, tagMask: .unseenPersonalMessage, namespace: Namespaces.Message.Cloud, customTag: nil)?.count ?? 0
                let muted: Bool
                if let settings = transaction.getPeerNotificationSettings(id: channelState.peerId) as? TelegramPeerNotificationSettings, case .muted = settings.muteState {
                    muted = true
                } else {
                    muted = false
                }
                let group = transaction.getPeerChatListIndex(channelState.peerId).map { $0.0 == .root ? "root" : "archive" } ?? "none"
                chats.append([
                    "channelId": channelState.channel.id,
                    "name": channelState.channel.displayName.isEmpty ? channelState.channel.name : channelState.channel.displayName,
                    "type": channelState.channel.type.rawValue,
                    "teamId": channelState.teamId,
                    "peerId": "\(channelState.peerId)",
                    "unread": Int(readState?.count ?? -1),
                    "mentions": Int(mentions),
                    "muted": muted,
                    "group": group,
                    "pinned": pinned.contains(.peer(channelState.peerId))
                ])
            }
            let total = transaction.getTotalUnreadState(groupId: .root)
            return [
                "chats": chats.sorted(by: { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }),
                "totalUnreadMessages": Int(total.absoluteCounters.values.reduce(0, { $0 + $1.messageCount })),
                "collapsedThreads": self.isCollapsedThreads,
                "folders": self.state.with { $0.teams.map { $0.displayName } }
            ]
        }
        self.debugWrite(report, name: "chatlist.json")
    }

    private func debugWrite(_ report: [String: Any], name: String) {
        do {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("relay-debug")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            MMLog.log("debug: wrote \(url.path)")
        } catch {
            MMLog.log("debug: could not write \(name): \(error)")
        }
    }

    /// Checks the loaded history against the ID map and writes it to `Documents/relay-debug/`.
    func debugDump(channelId: String, peerId: PeerId, stalls: Int, seconds: Double) async {
        let report: [String: Any] = await self.postbox.mmTransaction { transaction in
            let entries = self.store.allEntries(channelId: channelId)
            var messageIds: [Int32] = []
            var timestamps: [Int32: Int32] = [:]
            var replyTargets: [Int32: Int32] = [:]
            var threadIds: [Int32: Int64] = [:]
            transaction.withAllMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, { message in
                messageIds.append(message.id.id)
                timestamps[message.id.id] = message.timestamp
                for attribute in message.attributes {
                    if let reply = attribute as? ReplyMessageAttribute {
                        replyTargets[message.id.id] = reply.messageId.id
                    }
                }
                if let threadId = message.threadId {
                    threadIds[message.id.id] = threadId
                }
                return true
            })
            let liveEntries = entries.filter { !$0.isDeleted }
            let entryIds = Set(liveEntries.map { $0.localId })
            let messageIdSet = Set(messageIds)
            let holes = transaction.getHoles(peerId: peerId, namespace: Namespaces.Message.Cloud)
            let problems = self.store.validate(channelId: channelId)
            var outOfOrder = 0
            let sortedIds = messageIds.sorted()
            for i in 1 ..< max(1, sortedIds.count) where (timestamps[sortedIds[i]] ?? 0) < (timestamps[sortedIds[i - 1]] ?? 0) {
                outOfOrder += 1
            }
            return [
                "channelId": channelId,
                "entries": entries.count,
                "liveEntries": liveEntries.count,
                "messages": messageIds.count,
                "duplicateMessageIds": messageIds.count - messageIdSet.count,
                "entriesWithoutMessage": entryIds.subtracting(messageIdSet).count,
                "messagesWithoutEntry": messageIdSet.subtracting(entryIds).count,
                "messagesOutOfTimestampOrder": outOfOrder,
                "postboxHoleRanges": holes.rangeView.map { "\($0.lowerBound)...\($0.upperBound - 1)" },
                "islands": self.store.islands(channelId: channelId).map { $0.description },
                "storeProblems": problems,
                "stalls": stalls,
                "seconds": Int(seconds),
                "posts": liveEntries.map { entry -> [String: Any] in
                    var item: [String: Any] = ["id": entry.postId, "localId": Int(entry.localId), "createAt": entry.createAt]
                    if let target = replyTargets[entry.localId] {
                        item["replyTo"] = Int(target)
                    }
                    if let threadId = threadIds[entry.localId] {
                        item["threadId"] = threadId
                    }
                    return item
                }
            ]
        }
        var summary = report
        summary["posts"] = nil
        MMLog.log("pager: result \(summary)")
        self.debugWrite(report, name: "\(channelId).json")
    }
}
