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
        case .ephemeralMessage:
            if let post = event.decodeEmbedded(Post.self, key: "post") {
                await self.applyEphemeral(post)
            }
        case .openDialog:
            if let request = event.openDialog {
                self.applyOpenDialog(request)
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
        case .channelMemberUpdated:
            // Mute and other member changes: the member arrives as a JSON string, without a channel in the
            // broadcast.
            var channelId = event.data["channel_id"]?.stringValue ?? event.broadcast.channelId
            if channelId.isEmpty, let raw = event.data["channelMember"]?.stringValue, let data = raw.data(using: .utf8), let member = try? JSONDecoder().decode(ChannelMember.self, from: data) {
                channelId = member.channelId
            }
            if !channelId.isEmpty {
                await self.refreshChannel(channelId)
            }
        case .directAdded, .groupAdded, .channelUpdated, .channelDeleted, .channelRestored, .channelConverted:
            let channelId = event.data["channel_id"]?.stringValue ?? event.broadcast.channelId
            if !channelId.isEmpty {
                await self.refreshChannel(channelId)
            }
        case .userAdded:
            if event.data["user_id"]?.stringValue == self.ownUserId, !event.broadcast.channelId.isEmpty {
                await self.refreshChannel(event.broadcast.channelId)
            } else if !event.broadcast.channelId.isEmpty {
                await self.refreshMemberCounts([event.broadcast.channelId])
                if let userId = event.data["user_id"]?.stringValue {
                    await self.announceMemberAdded(channelId: event.broadcast.channelId, userId: userId)
                }
            }
        case .leaveTeam, .addedToTeam:
            // Phase 4B: the user's teams changed (removal from a team sends no `user_removed` per channel); the
            // catch-up reloads the teams, writes the new channels and removes what the user left.
            if (event.data["user_id"]?.stringValue ?? event.broadcast.userId) == self.ownUserId {
                await self.catchUp()
            }
        case .userRemoved:
            let channelId = event.data["channel_id"]?.stringValue ?? event.broadcast.channelId
            let userId = event.data["user_id"]?.stringValue ?? event.broadcast.userId
            if !channelId.isEmpty, userId != self.ownUserId {
                await self.refreshMemberCounts([channelId])
                self.announceMemberRemoved(channelId: channelId, userId: userId)
            } else if !channelId.isEmpty {
                await self.applyOwnRemoval(channelId: channelId)
            }
        case .sidebarCategoryCreated, .sidebarCategoryUpdated, .sidebarCategoryDeleted, .sidebarCategoryOrderUpdated:
            await self.refreshFavorites()
        case .preferencesChanged, .preferenceChanged, .preferencesDeleted:
            // Saved posts (3C): `flagged_post` preferences.
            self.applySavedPostsEvent(event)
            if event.data["preferences"]?.stringValue?.contains(PreferenceCategory.favoriteChannel) == true || event.data["preference"]?.stringValue?.contains(PreferenceCategory.favoriteChannel) == true {
                await self.refreshFavorites()
            }
            // Collapsed reply threads switched on another client (3B). A deleted preference falls back to the
            // server default, so reload them all then.
            if event.type == .preferencesDeleted {
                if event.data["preferences"]?.stringValue?.contains("collapsed_reply_threads") == true {
                    await self.refreshCollapsedThreadsConfig()
                }
                // Link previews / emoticons back to their defaults (3E).
                let deleted = event.data["preferences"]?.stringValue ?? ""
                if deleted.contains(DisplaySettingName.linkPreviews) || deleted.contains(DisplaySettingName.renderEmoticonsAsEmoji) {
                    await self.reloadRichContentPreferences()
                }
            } else {
                var changed = event.decodeEmbedded([Preference].self, key: "preferences") ?? []
                if let single = event.decodeEmbedded(Preference.self, key: "preference") {
                    changed.append(single)
                }
                await self.applyPreferencesChanged(changed)
                await self.applyRichContentPreferences(changed)
            }
        case .configChanged:
            await self.refreshCollapsedThreadsConfig()
            await self.refreshRichContentConfig()
        case .threadUpdated, .threadReadChanged, .threadFollowChanged:
            await self.applyThreadEvent(event)
        case .userUpdated:
            if let user = event.data["user"].flatMap({ try? $0.decode(User.self) }) {
                await self.postbox.mmTransaction { transaction in
                    self.writeUsers([user], transaction: transaction)
                }
                // The own system roles may have changed (3D-2: channel access).
                if user.id == self.ownUserId, user.roles != self.state.with({ $0.me?.roles }) {
                    await self.refreshChannelAccess(reason: "own roles changed")
                }
                // Phase 3F: own profile, custom status, picture or notify props changed (here or elsewhere).
                if user.id == self.ownUserId {
                    await self.applyOwnUserUpdated()
                }
            }
        case .roleUpdated, .memberRoleUpdated:
            await self.refreshChannelAccess(reason: event.type.rawValue)
        case .channelSchemeUpdated:
            let channelId = event.data["channel_id"]?.stringValue ?? event.broadcast.channelId
            if !channelId.isEmpty {
                await self.refreshChannel(channelId)
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
            await self.applyOwnPost(post, pendingPostId: post.pendingPostId, uploadedFiles: [:], onRewritten: nil)
            MMLog.log("live: own post \(post.id) (pending \(post.pendingPostId)) applied from its echo")
            return
        }
        if self.channelState(post.channelId) == nil {
            await self.refreshChannel(post.channelId)
            // A new or closed DM/GM (3D-2): shown again, also on the user's other clients.
            await self.showDirectChat(channelId: post.channelId)
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
        // With collapsed reply threads a reply counts in its thread (threads list), not in its chat.
        let countsInChat = post.rootId.isEmpty || !self.isCollapsedThreads
        let mentionsMe = !isOwn && countsInChat && (posted.mentions.contains(self.ownUserId) || self.channelState(post.channelId)?.kind == .direct)
        let marksRead = isOwn && countsInChat
        let result: PageWriteResult = await self.postbox.mmTransaction { transaction in
            self.state.with { state in
                guard var channelState = state.channels[post.channelId] else {
                    return
                }
                channelState.channel.totalMsgCount += 1
                channelState.channel.lastPostAt = max(channelState.channel.lastPostAt, post.createAt)
                if post.rootId.isEmpty {
                    channelState.channel.totalMsgCountRoot += 1
                    channelState.channel.lastRootPostAt = max(channelState.channel.lastRootPostAt, post.createAt)
                }
                if marksRead {
                    // Posting marks the channel read in Mattermost.
                    channelState.member.msgCount = channelState.channel.totalMsgCount
                    channelState.member.msgCountRoot = channelState.channel.totalMsgCountRoot
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
                if marksRead {
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
            // Not loaded: paging will bring the edited version. A post pinned elsewhere is stored now (3C): the
            // pinned bar reads the `.pinned` tag space, which is complete once loaded.
            if post.isPinned && post.deleteAt == 0 {
                await self.storeFoundPosts([post])
            }
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
            if added {
                self.noteReactionEmoji(names: [reaction.emojiName], transaction: transaction)
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
                let mentionCount = self.memberMentionCount(member)
                await self.postbox.mmTransaction { transaction in
                    self.state.with { state in
                        guard var channelState = state.channels[channelId] else {
                            return
                        }
                        channelState.member = member
                        channelState.channel.totalMsgCount = max(channelState.channel.totalMsgCount, member.msgCount)
                        channelState.mentionCount = mentionCount
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
        if !typing.parentId.isEmpty, channelState.kind != .saved, let root = self.store.entries(channelId: typing.channelId, postIds: [typing.parentId])[typing.parentId], !root.isDeleted {
            category = .thread(Int64(root.localId))
        }
        self.account.mattermostAddRemoteInputActivity(chatPeerId: PeerActivitySpace(peerId: channelState.peerId, category: category), peerId: userPeerId, activity: .typingText)
    }

    func applyStatus(_ change: StatusChangeEvent) async {
        if change.userId == self.ownUserId {
            // Phase 3F: Settings shows the own status.
            await self.applyOwnStatusChange(change)
            return
        }
        guard let peerId = self.userPeerId(change.userId) else {
            return
        }
        // Phase 3F: the event has no DND end; the status request has it.
        var dndEndTime: Int64?
        if change.status == .dnd, let status = try? await self.client.userStatuses(ids: [change.userId]).first {
            dndEndTime = status.dndEndTime
        }
        let presence = PeerConverter.presence(status: change.status, lastActivityAt: Int64(Date().timeIntervalSince1970 * 1000), dndEndTime: dndEndTime, now: Date())
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
            let previous = self.channelState(channelId)
            let isNew = previous == nil
            // Roles of a channel scheme the user hasn't met yet (3D-2: channel access).
            await self.ensureRoles([member.roles])
            await self.postbox.mmTransaction { transaction in
                let teamId = channel.teamId
                self.writeChannel(channel, member: member, teamId: teamId, transaction: transaction)
            }
            await self.refreshMemberCounts([channelId])
            // Archived channels leave the team folders (and come back when restored).
            if (isNew || previous?.channel.isArchived != channel.isArchived) && channel.type != .directMessage {
                await self.writeTeamFolders(teams: self.state.with { $0.teams })
            }
            MMLog.log("live: channel \(channelId) \(isNew ? "added" : "updated")")
        } catch {
            MMLog.log("live: could not load channel \(channelId): \(error)")
        }
    }
}

