import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// A team, as the threads screen offers it.
public struct MattermostTeamInfo: Equatable {
    public let id: String
    public let name: String
}

/// Collapsed reply threads for TelegramUI and MattermostUI (Phase 3B): thread views, the threads list,
/// follow/unfollow, thread read state.
public extension MattermostSync {
    static func isCollapsedThreads(accountId: AccountRecordId) -> Bool {
        return self.sync(accountId: accountId)?.isCollapsedThreads ?? false
    }

    /// The thread root of a reply that collapsed reply threads hide from its chat (nil for a root post, for a
    /// chat without threads, or while CRT is off): navigating to the reply opens its thread instead.
    static func collapsedThreadRoot(accountId: AccountRecordId, messageId: MessageId) -> MessageId? {
        guard let sync = self.sync(accountId: accountId), sync.isCollapsedThreads, messageId.namespace == Namespaces.Message.Cloud else {
            return nil
        }
        guard let channelId = sync.channelId(forPeerId: messageId.peerId), let channelState = sync.channelState(channelId), channelState.kind != .saved else {
            return nil
        }
        guard let entry = sync.store.entries(channelId: channelId, fromLocalId: messageId.id, ascending: true, limit: 1).first, entry.localId == messageId.id, !entry.isDeleted else {
            return nil
        }
        guard let rootPostId = sync.store.threadRootId(postId: entry.postId, channelId: channelId), let root = sync.store.entries(channelId: channelId, postIds: [rootPostId])[rootPostId], !root.isDeleted else {
            return nil
        }
        return MessageId(peerId: messageId.peerId, namespace: Namespaces.Message.Cloud, id: root.localId)
    }

    /// The account's teams, in the server's order.
    static func teams(accountId: AccountRecordId) -> [MattermostTeamInfo] {
        return self.sync(accountId: accountId)?.state.with { $0.teams.map { MattermostTeamInfo(id: $0.id, name: $0.displayName) } } ?? []
    }

    /// The account's teams once its bootstrap has finished: the Threads tab is made at launch, before the account
    /// syncs, so `teams(accountId:)` can still be empty then.
    static func teamsWhenReady(accountId: AccountRecordId) -> Signal<[MattermostTeamInfo], NoError> {
        return self.runningSync(accountId: accountId)
        |> mapToSignal { sync -> Signal<[MattermostTeamInfo], NoError> in
            guard let sync = sync else {
                return .complete()
            }
            return sync.bootstrapped.get()
            |> filter { $0 }
            |> take(1)
            |> map { _ -> [MattermostTeamInfo] in
                return self.teams(accountId: accountId)
            }
        }
    }

    /// The team of a team folder (chat list filter), see `writeTeamFolders`.
    static func teamId(accountId: AccountRecordId, chatListFilterId: Int32) -> String? {
        guard let sync = self.sync(accountId: accountId) else {
            return nil
        }
        for team in sync.state.with({ $0.teams }) {
            if sync.store.cursor(MattermostCursorKey.folderId(teamId: team.id)) == String(chatListFilterId) {
                return team.id
            }
        }
        return nil
    }

    /// The team's followed threads, updated live; nil while collapsed reply threads are off.
    static func threadList(accountId: AccountRecordId, teamId: String) -> Signal<MattermostThreadList?, NoError> {
        return self.runningSync(accountId: accountId)
        |> mapToSignal { sync -> Signal<MattermostThreadList?, NoError> in
            guard let sync = sync else {
                return .single(nil)
            }
            return combineLatest(sync.threadsVersionPromise.get(), MattermostBackend.collapsedThreadsUpdates(accountPeerId: sync.ownPeerId))
            |> mapToSignal { _, isOn -> Signal<MattermostThreadList?, NoError> in
                if !isOn {
                    return .single(nil)
                }
                return MattermostSync.signal {
                    return await sync.threadList(teamId: teamId)
                }
                |> map(Optional.init)
            }
        }
    }

    /// Unread followed threads of all the account's teams (the Threads tab's badge); nil while collapsed reply
    /// threads are off.
    static func totalThreadsBadge(accountId: AccountRecordId) -> Signal<MattermostThreadsBadge?, NoError> {
        return self.runningSync(accountId: accountId)
        |> mapToSignal { sync -> Signal<MattermostThreadsBadge?, NoError> in
            guard let sync = sync else {
                return .single(nil)
            }
            return combineLatest(sync.threadsVersionPromise.get(), MattermostBackend.collapsedThreadsUpdates(accountPeerId: sync.ownPeerId))
            |> map { _, isOn -> MattermostThreadsBadge? in
                guard isOn else {
                    return nil
                }
                var unreadThreads = 0
                var unreadMentions = 0
                for teamId in sync.state.with({ $0.teams.map { $0.id } }) {
                    let badge = sync.threadsBadge(teamId: teamId)
                    unreadThreads += badge.unreadThreads
                    unreadMentions += badge.unreadMentions
                }
                return MattermostThreadsBadge(unreadThreads: unreadThreads, unreadMentions: unreadMentions)
            }
            |> distinctUntilChanged
        }
    }

    static func reloadThreads(accountId: AccountRecordId, teamId: String) {
        guard let sync = self.sync(accountId: accountId) else {
            return
        }
        sync.addTask(Task {
            await sync.reloadThreads(teamId: teamId)
        })
    }

    /// Whether the user follows the thread (`threadId` = local id of the root in the chat `peerId`); nil when
    /// unknown (collapsed threads off, or the list isn't loaded).
    static func isFollowingThread(accountId: AccountRecordId, peerId: PeerId, threadId: Int64) -> Bool? {
        guard let sync = self.sync(accountId: accountId), sync.isCollapsedThreads else {
            return nil
        }
        return sync.isFollowingThread(peerId: peerId, threadId: threadId)
    }

    static func setFollowingThread(accountId: AccountRecordId, peerId: PeerId, threadId: Int64, following: Bool) -> Signal<Bool, NoError> {
        return self.signal {
            guard let sync = self.sync(accountId: accountId) else {
                return false
            }
            return await sync.setFollowingThread(peerId: peerId, threadId: threadId, following: following)
        }
    }

    /// A thread view showed its messages up to `messageIndex` (`AccountContext.applyMaxReadIndex`).
    static func markThreadViewed(accountId: AccountRecordId, peerId: PeerId, threadId: Int64, messageIndex: MessageIndex) {
        guard let sync = self.sync(accountId: accountId), sync.isCollapsedThreads else {
            return
        }
        sync.addTask(Task {
            await sync.markThreadViewed(peerId: peerId, threadId: threadId, messageIndex: messageIndex)
        })
    }

    /// Where a post opens (a permalink): its thread when it is a reply and collapsed reply threads are on, else
    /// its chat at the post. The post (and its root) are mapped first, so the view's hole request loads them.
    static func postDestination(accountId: AccountRecordId, postId: String) -> Signal<MattermostNotificationDestination?, NoError> {
        return self.signal {
            guard let sync = await self.waitForRunningSync(accountId: accountId) else {
                return nil
            }
            guard let post = try? await sync.client.post(id: postId), let channelState = sync.channelState(post.channelId) else {
                MMLog.log("permalink: post \(postId) not found or in an unknown channel")
                return nil
            }
            var threadId: Int64?
            if channelState.kind != .saved, sync.isCollapsedThreads, !post.rootId.isEmpty, let rootLocalId = await sync.notificationLocalId(postId: post.rootId, channelId: post.channelId) {
                threadId = Int64(rootLocalId)
            }
            guard let localId = await sync.notificationLocalId(postId: post.id, channelId: post.channelId) else {
                return nil
            }
            let messageId = MessageId(peerId: channelState.peerId, namespace: Namespaces.Message.Cloud, id: localId)
            MMLog.log("permalink: \(postId) → peer \(channelState.peerId), thread \(threadId.map { "\($0)" } ?? "-"), message \(localId)")
            return MattermostNotificationDestination(accountId: accountId, peerId: channelState.peerId, threadId: threadId, messageId: messageId)
        }
    }

    /// The thread of a threads-list row whose root isn't stored yet: maps and loads the root.
    static func threadDestination(accountId: AccountRecordId, rootPostId: String) -> Signal<(peerId: PeerId, threadId: Int64)?, NoError> {
        return self.postDestination(accountId: accountId, postId: rootPostId)
        |> map { destination -> (peerId: PeerId, threadId: Int64)? in
            guard let destination = destination, let messageId = destination.messageId else {
                return nil
            }
            return (destination.peerId, Int64(messageId.id))
        }
    }

    private static func runningSync(accountId: AccountRecordId) -> Signal<MattermostAccountSync?, NoError> {
        if let sync = self.sync(accountId: accountId) {
            return .single(sync)
        }
        return self.signal {
            return await self.waitForRunningSync(accountId: accountId)
        }
    }
}
