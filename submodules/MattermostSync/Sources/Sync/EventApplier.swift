import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// WebSocket events → Postbox (design: "Live events and catch-up").
extension MattermostAccountSync {
    func handleEvent(_ event: WebSocketEvent) async {
        guard self.state.with({ $0.isBootstrapped }) else {
            return
        }
        switch event.type {
        case .posted:
            if let posted = event.posted {
                await self.applyPosted(posted)
            }
        case .postEdited:
            if let post = event.editedPost {
                await self.applyEdited(post)
            }
        case .postDeleted:
            if let post = event.deletedPost {
                await self.applyDeleted(post)
            }
        case .reactionAdded, .reactionRemoved:
            if let reaction = event.reaction {
                await self.applyReaction(reaction, added: event.type == .reactionAdded)
            }
        case .channelViewed, .multipleChannelsViewed:
            if let viewed = event.channelsViewed {
                await self.applyViewed(viewed)
            }
        case .typing:
            if let typing = event.typing {
                self.applyTyping(typing)
            }
        case .statusChange:
            if let change = event.statusChange {
                await self.applyStatus(change)
            }
        case .directAdded, .groupAdded, .channelUpdated, .channelDeleted, .channelRestored, .channelConverted, .channelMemberUpdated:
            let channelId = event.data["channel_id"]?.stringValue ?? event.broadcast.channelId
            if !channelId.isEmpty {
                await self.refreshChannel(channelId)
            }
        case .userAdded:
            if event.data["user_id"]?.stringValue == self.ownUserId, !event.broadcast.channelId.isEmpty {
                await self.refreshChannel(event.broadcast.channelId)
            }
        case .sidebarCategoryCreated, .sidebarCategoryUpdated, .sidebarCategoryDeleted, .sidebarCategoryOrderUpdated:
            await self.refreshFavorites()
        case .preferencesChanged, .preferenceChanged, .preferencesDeleted:
            if event.data["preferences"]?.stringValue?.contains(PreferenceCategory.favoriteChannel) == true || event.data["preference"]?.stringValue?.contains(PreferenceCategory.favoriteChannel) == true {
                await self.refreshFavorites()
            }
        case .userUpdated:
            if let user = event.data["user"].flatMap({ try? $0.decode(User.self) }) {
                await self.postbox.mmTransaction { transaction in
                    self.writeUsers([user], transaction: transaction)
                }
            }
        default:
            break
        }
    }

    // MARK: Posts

    private func isMapped(_ postId: String, channelId: String) -> Bool {
        if let entry = self.store.entries(channelId: channelId, postIds: [postId])[postId] {
            return !entry.isDeleted
        }
        return false
    }

    func applyPosted(_ posted: PostedEvent) async {
        let received = CFAbsoluteTimeGetCurrent()
        let post = posted.post
        if post.type == "system_ephemeral" {
            return
        }
        // Our own post (`pending_post_id`): the response of the request in flight rewrites the local message;
        // without one (the app restarted meanwhile) the echo does it.
        if post.userId == self.ownUserId, !post.pendingPostId.isEmpty, self.store.pendingPost(pendingPostId: post.pendingPostId) != nil {
            if self.sender?.isInFlight(pendingPostId: post.pendingPostId) == true {
                MMLog.log("live: echo of own post \(post.id) (pending \(post.pendingPostId)) left to its request")
                return
            }
            await self.applyOwnPost(post, pendingPostId: post.pendingPostId, uploadedFiles: [], onRewritten: nil)
            MMLog.log("live: own post \(post.id) (pending \(post.pendingPostId)) applied from its echo")
            return
        }
        if self.channelState(post.channelId) == nil {
            await self.refreshChannel(post.channelId)
        }
        guard self.channelState(post.channelId) != nil else {
            MMLog.log("live: post \(post.id) in unknown channel \(post.channelId)")
            return
        }
        // A reply to a root that isn't loaded: load the root too, so the reply can point at it.
        var extra: [Post] = []
        if !post.rootId.isEmpty, !self.isMapped(post.rootId, channelId: post.channelId), let root = try? await self.client.post(id: post.rootId) {
            extra.append(root)
        }
        await self.ensureUsers(referencedUserIds([post] + extra))
        let isOwn = post.userId == self.ownUserId
        let mentionsMe = !isOwn && (posted.mentions.contains(self.ownUserId) || self.channelState(post.channelId)?.kind == .direct)
        let result: PageWriteResult = await self.postbox.mmTransaction { transaction in
            self.state.with { state in
                guard var channelState = state.channels[post.channelId] else {
                    return
                }
                channelState.channel.totalMsgCount += 1
                channelState.channel.lastPostAt = max(channelState.channel.lastPostAt, post.createAt)
                if isOwn {
                    // Posting marks the channel read in Mattermost.
                    channelState.member.msgCount = channelState.channel.totalMsgCount
                    channelState.member.lastViewedAt = max(channelState.member.lastViewedAt, post.createAt)
                    channelState.mentionCount = 0
                } else if mentionsMe {
                    channelState.mentionCount += 1
                }
                state.channels[post.channelId] = channelState
            }
            let result = self.write(PageWrite(channelId: post.channelId, kind: .singles, run: [post], extra: extra), transaction: transaction)
            if result.insertedCount > 0 && extra.isEmpty {
                // A fetched root already counts the reply.
                self.bumpThreadRoot(of: post, transaction: transaction)
            }
            if let channelState = self.channelState(post.channelId) {
                if isOwn {
                    self.applyServerReadState(channelId: post.channelId, transaction: transaction)
                } else if mentionsMe {
                    self.applyMentionCount(channelState.mentionCount, peerId: channelState.peerId, transaction: transaction)
                }
            }
            return result
        }
        MMLog.log("live: posted \(post.id) in \(post.channelId) → \(result.writtenCount) message(s) written \(Int((CFAbsoluteTimeGetCurrent() - received) * 1000)) ms after the event (create_at \(post.createAt))")
    }

    func applyEdited(_ post: Post) async {
        let received = CFAbsoluteTimeGetCurrent()
        guard self.channelState(post.channelId) != nil else {
            return
        }
        let mapped = await self.postbox.mmTransaction { _ in
            return self.isMapped(post.id, channelId: post.channelId)
        }
        if !mapped {
            // Not loaded: paging will bring the edited version.
            return
        }
        var post = post
        if post.hasReactions && (post.metadata?.reactions.isEmpty ?? true), let full = try? await self.client.post(id: post.id) {
            post = full
        }
        await self.ensureUsers(referencedUserIds([post]))
        let written: Int = await self.postbox.mmTransaction { transaction in
            return self.writeMessages(channelId: post.channelId, posts: [post], transaction: transaction)
        }
        MMLog.log("live: edited \(post.id) → \(written) message(s) updated \(Int((CFAbsoluteTimeGetCurrent() - received) * 1000)) ms after the event")
    }

    func applyDeleted(_ post: Post) async {
        let received = CFAbsoluteTimeGetCurrent()
        guard let channelState = self.channelState(post.channelId) else {
            return
        }
        let _ = channelState
        let deletedCount: Int = await self.postbox.mmTransaction { transaction in
            return self.removePostsLocally([post.id], channelId: post.channelId, transaction: transaction)
        }
        MMLog.log("live: deleted \(post.id) → \(deletedCount) message(s) removed \(Int((CFAbsoluteTimeGetCurrent() - received) * 1000)) ms after the event")
    }

    func applyReaction(_ reaction: Reaction, added: Bool) async {
        let received = CFAbsoluteTimeGetCurrent()
        let channelId: String
        if let value = reaction.channelId, !value.isEmpty {
            channelId = value
        } else if let post = try? await self.client.post(id: reaction.postId) {
            channelId = post.channelId
        } else {
            return
        }
        guard let channelState = self.channelState(channelId) else {
            return
        }
        await self.ensureUsers([reaction.userId])
        guard let userPeerId = self.userPeerId(reaction.userId) else {
            return
        }
        let value = PostConverter.reactionValue(reaction.emojiName)
        let isMy = reaction.userId == self.ownUserId
        let updated: Bool = await self.postbox.mmTransaction { transaction in
            guard let entry = self.store.entries(channelId: channelId, postIds: [reaction.postId])[reaction.postId], !entry.isDeleted else {
                return false
            }
            let messageId = MessageId(peerId: channelState.peerId, namespace: Namespaces.Message.Cloud, id: entry.localId)
            var found = false
            transaction.updateMessage(messageId, update: { current in
                found = true
                var attributes = current.attributes
                var recentPeers: [ReactionsMessageAttribute.RecentPeer] = []
                if let index = attributes.firstIndex(where: { $0 is ReactionsMessageAttribute }) {
                    recentPeers = (attributes[index] as! ReactionsMessageAttribute).recentPeers
                    attributes.remove(at: index)
                }
                recentPeers.removeAll(where: { $0.peerId == userPeerId && $0.value == value })
                if added {
                    recentPeers.append(ReactionsMessageAttribute.RecentPeer(value: value, isLarge: false, isUnseen: false, isMy: isMy, peerId: userPeerId, timestamp: mmSeconds(reaction.createAt)))
                }
                if let attribute = PostConverter.reactionsAttribute(recentPeers: recentPeers) {
                    attributes.append(attribute)
                }
                return .update(StoreMessage.mmCopy(of: current, id: current.id, threadId: current.threadId, attributes: attributes))
            })
            return found
        }
        MMLog.log("live: reaction \(added ? "+" : "-")\(reaction.emojiName) by \(reaction.userId) on \(reaction.postId) → \(updated ? "updated" : "not loaded") \(Int((CFAbsoluteTimeGetCurrent() - received) * 1000)) ms after the event")
    }

    // MARK: Read state, typing, presence

    /// Read on another device (`multiple_channels_viewed` / `channel_viewed`): reload the member counters.
    func applyViewed(_ viewed: ChannelsViewedEvent) async {
        for channelId in viewed.channelIds {
            guard self.channelState(channelId) != nil else {
                continue
            }
            do {
                let member = try await self.client.channelMember(channelId: channelId)
                await self.postbox.mmTransaction { transaction in
                    self.state.with { state in
                        guard var channelState = state.channels[channelId] else {
                            return
                        }
                        channelState.member = member
                        channelState.channel.totalMsgCount = max(channelState.channel.totalMsgCount, member.msgCount)
                        channelState.mentionCount = Int32(clamping: member.mentionCount)
                        state.channels[channelId] = channelState
                    }
                    self.applyServerReadState(channelId: channelId, transaction: transaction)
                }
                MMLog.log("live: \(channelId) viewed elsewhere (last_viewed_at \(member.lastViewedAt))")
            } catch {
                MMLog.log("live: could not reload the member of \(channelId): \(error)")
            }
        }
    }

    func applyTyping(_ typing: TypingEvent) {
        guard typing.userId != self.ownUserId, let channelState = self.channelState(typing.channelId), let userPeerId = self.userPeerId(typing.userId) else {
            return
        }
        // Typing in a thread shows in that thread (Telegram's `.thread` activity space), like Mattermost's own
        // clients show it in the thread view only.
        var category: PeerActivitySpace.Category = .global
        if !typing.parentId.isEmpty, channelState.kind == .channel, let root = self.store.entries(channelId: typing.channelId, postIds: [typing.parentId])[typing.parentId], !root.isDeleted {
            category = .thread(Int64(root.localId))
        }
        self.account.mattermostAddRemoteInputActivity(chatPeerId: PeerActivitySpace(peerId: channelState.peerId, category: category), peerId: userPeerId, activity: .typingText)
    }

    func applyStatus(_ change: StatusChangeEvent) async {
        guard change.userId != self.ownUserId, let peerId = self.userPeerId(change.userId) else {
            return
        }
        let presence = PeerConverter.presence(status: change.status, lastActivityAt: Int64(Date().timeIntervalSince1970 * 1000), dndEndTime: nil, now: Date())
        await self.postbox.mmTransaction { transaction in
            transaction.updatePeerPresencesInternal(presences: [peerId: presence], merge: { _, updated in
                return updated
            })
        }
    }

    // MARK: Channels

    /// Loads a channel and its membership and (re)writes it; used for new chats and channel updates.
    func refreshChannel(_ channelId: String) async {
        do {
            let channel = try await self.client.channel(id: channelId)
            let member = try await self.client.channelMember(channelId: channelId)
            if let partnerId = channel.directMessagePartnerId(myUserId: self.ownUserId) {
                await self.ensureUsers([partnerId])
            }
            let isNew = self.channelState(channelId) == nil
            await self.postbox.mmTransaction { transaction in
                let teamId = channel.teamId
                self.writeChannel(channel, member: member, teamId: teamId, transaction: transaction)
            }
            if isNew && channel.type != .directMessage {
                await self.writeTeamFolders(teams: self.state.with { $0.teams })
            }
            MMLog.log("live: channel \(channelId) \(isNew ? "added" : "updated")")
        } catch {
            MMLog.log("live: could not load channel \(channelId): \(error)")
        }
    }
}

