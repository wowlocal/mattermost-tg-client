import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Collapsed reply threads (CRT, Phase 3B; design: mattermost-sync.md "Collapsed reply threads").
///
/// On when the server's `CollapsedThreads` setting allows it and the user's `display_settings` /
/// `collapsed_reply_threads` preference (or the server default) says so. While on:
/// - a chat's main history shows root posts only: every root post carries `MessageTags.mattermostRootPost`
///   (always, CRT on or off) and `AccountViewTracker` opens main histories as that tag's view
///   (`MattermostBackend.setCollapsedThreads`);
/// - replies are `.NotCountedAsUnread` and never mention-tagged in their chat, which counts root posts only
///   (the server's `_root` counters); thread unreads live in the threads list (`Threads.swift`);
/// - roots with replies show an "N replies" button (`ReplyThreadMessageAttribute.commentsPeerId` = the chat).
/// Switching (a preference change from another client, or the server setting) re-renders every stored message
/// of the account (`reapplyCollapsedThreads`), which is also the one-time upgrade of data written before 3B.
extension MattermostAccountSync {
    static let collapsedThreadsCursor = "collapsed_threads"
    /// Version of the stored message layout that `reapplyCollapsedThreads` brings messages to (root tags, DM
    /// reply threads). Data written by older builds is upgraded once.
    static let threadLayoutCursor = "thread_layout"
    static let threadLayoutVersion = "1"

    var isCollapsedThreads: Bool {
        return self.state.with { $0.collapsedThreads }
    }

    /// Whether the user has collapsed reply threads (mattermost-webapp `isCollapsedThreadsEnabled`).
    static func collapsedThreadsEnabled(setting: CollapsedThreadsSetting, preferences: [Preference]) -> Bool {
        switch setting {
        case .alwaysOn:
            return true
        case .defaultOn, .defaultOff:
            if let preference = preferences.last(where: { $0.category == PreferenceCategory.displaySettings && $0.name == "collapsed_reply_threads" }) {
                return preference.value == "on"
            }
            return setting == .defaultOn
        case .disabled, .unknown:
            return false
        }
    }

    /// The mention badge count from member counters: `mention_count_root` with collapsed reply threads. Takes the
    /// state lock: never call it inside `state.with`.
    func memberMentionCount(_ member: ChannelMember) -> Int32 {
        return Int32(clamping: self.isCollapsedThreads ? member.mentionCountRoot : member.mentionCount)
    }

    /// The last known state, before the bootstrap asks the server (so chats open with the right history).
    func restoreCollapsedThreads() {
        let isOn = self.store.cursor(MattermostAccountSync.collapsedThreadsCursor) == "1"
        self.state.with { $0.collapsedThreads = isOn }
        MattermostBackend.setCollapsedThreads(isOn, accountPeerId: self.ownPeerId)
        MMLog.log("crt: \(isOn ? "on" : "off") (last known)")
    }

    /// Sets the state from the server's setting and the user's preferences. Returns true when it changed (the
    /// caller then re-renders the stored messages).
    @discardableResult
    func updateCollapsedThreads(setting: CollapsedThreadsSetting, preferences: [Preference]) -> Bool {
        let isOn = MattermostAccountSync.collapsedThreadsEnabled(setting: setting, preferences: preferences)
        let changed = self.state.with { state -> Bool in
            state.collapsedThreadsSetting = setting
            let changed = state.collapsedThreads != isOn
            state.collapsedThreads = isOn
            return changed
        }
        self.store.setCursor(MattermostAccountSync.collapsedThreadsCursor, isOn ? "1" : "0")
        MMLog.log("crt: server \(setting.rawValue) → \(isOn ? "on" : "off")\(changed ? " (changed)" : "")")
        return changed
    }

    /// Publishes the state to the UI (after the stored messages match it).
    func publishCollapsedThreads() {
        MattermostBackend.setCollapsedThreads(self.isCollapsedThreads, accountPeerId: self.ownPeerId)
    }

    /// A preference changed (WebSocket `preferences_changed`): switches when `collapsed_reply_threads` did.
    func applyPreferencesChanged(_ preferences: [Preference]) async {
        guard preferences.contains(where: { $0.category == PreferenceCategory.displaySettings && $0.name == "collapsed_reply_threads" }) else {
            return
        }
        let setting = self.state.with { $0.collapsedThreadsSetting }
        // The event carries the changed preferences only; the collapsed-threads one is among them.
        if self.updateCollapsedThreads(setting: setting, preferences: preferences) {
            await self.switchCollapsedThreads()
        }
    }

    /// The server's config changed (`config_changed`): the `CollapsedThreads` setting may have.
    func refreshCollapsedThreadsConfig() async {
        do {
            let config = try await self.client.clientConfig()
            let preferences = try await self.client.preferences()
            if self.updateCollapsedThreads(setting: config.collapsedThreads, preferences: preferences) {
                await self.switchCollapsedThreads()
            }
        } catch {
            MMLog.log("crt: config not reloaded: \(error)")
        }
    }

    /// Re-renders everything for the new state: messages, the member counters (`_root` or not), the threads list.
    func switchCollapsedThreads() async {
        let started = CFAbsoluteTimeGetCurrent()
        let isOn = self.isCollapsedThreads
        // The counters of both kinds come with every member; reload them so the badges are current.
        do {
            let teams = self.state.with { $0.teams }
            let snapshot = try await self.loadChannels(teams: teams, categories: false)
            self.state.with { state in
                for (channelId, member) in snapshot.members where state.channels[channelId] != nil {
                    state.channels[channelId]?.member = member
                    if let channel = snapshot.channels[channelId]?.channel {
                        state.channels[channelId]?.channel = channel
                    }
                }
            }
        } catch {
            MMLog.log("crt: members not reloaded: \(error)")
        }
        self.state.with { state in
            for channelId in Array(state.channels.keys) {
                if let member = state.channels[channelId]?.member {
                    state.channels[channelId]?.mentionCount = Int32(clamping: isOn ? member.mentionCountRoot : member.mentionCount)
                }
            }
        }
        await self.reapplyCollapsedThreads()
        self.publishCollapsedThreads()
        if isOn {
            await self.reloadAllThreads()
        } else {
            self.clearThreads()
        }
        MMLog.log("crt: switched \(isOn ? "on" : "off") in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
    }

    /// Brings every stored message of the account in line with the state (one chat per transaction):
    /// - root posts carry `.mattermostRootPost`;
    /// - replies in DMs are in their root's thread (upgrade of data written before 3B);
    /// - incoming replies are `.NotCountedAsUnread` while CRT is on (album parts other than the first always are)
    ///   and lose their chat mention tag;
    /// - reply counts of roots carry the CRT marker (`commentsPeerId`) while CRT is on.
    /// Then resets every chat's read state from the server counters.
    func reapplyCollapsedThreads() async {
        let isOn = self.isCollapsedThreads
        let chats = self.state.with { state in
            return state.channels.values.filter { $0.kind != .saved }.map { ($0.channel.id, $0.peerId, $0.kind) }
        }
        var updatedCount = 0
        for (channelId, peerId, kind) in chats {
            updatedCount += await self.postbox.mmTransaction { transaction -> Int in
                // Parts after the first of a multi-file post (`<post id>#NN`) never count as unread.
                var laterPartIds = Set<Int32>()
                for entry in self.store.allEntries(channelId: channelId) where entry.postId.contains("#") {
                    laterPartIds.insert(entry.localId)
                }
                var updates: [(MessageId, Int64?, [MessageAttribute], StoreMessageFlags, MessageTags)] = []
                transaction.withAllMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, { message in
                    let reply = message.attributes.first(where: { $0 is ReplyMessageAttribute }) as? ReplyMessageAttribute
                    var rootId: MessageId?
                    if let reply = reply, reply.messageId.peerId == peerId, reply.messageId.namespace == Namespaces.Message.Cloud {
                        rootId = reply.messageId
                    }
                    var threadId = message.threadId
                    var attributes = message.attributes
                    var flags = StoreMessageFlags(message.flags)
                    var tags = message.tags
                    if let rootId = rootId {
                        if kind == .direct && threadId == nil {
                            threadId = Int64(rootId.id)
                            if let index = attributes.firstIndex(where: { $0 is ReplyMessageAttribute }), let reply = reply {
                                attributes[index] = ReplyMessageAttribute(messageId: reply.messageId, threadMessageId: rootId, quote: reply.quote, isQuote: reply.isQuote, innerSubject: reply.innerSubject)
                            }
                        }
                        tags.remove(.mattermostRootPost)
                        if message.flags.contains(.Incoming) {
                            if isOn {
                                flags.insert(.NotCountedAsUnread)
                                tags.remove(.unseenPersonalMessage)
                            } else if !laterPartIds.contains(message.id.id) {
                                flags.remove(.NotCountedAsUnread)
                            }
                        }
                    } else {
                        tags.insert(.mattermostRootPost)
                        if let index = attributes.firstIndex(where: { $0 is ReplyThreadMessageAttribute }), let thread = attributes[index] as? ReplyThreadMessageAttribute {
                            let marker: PeerId? = isOn ? peerId : nil
                            if thread.commentsPeerId != marker {
                                attributes[index] = ReplyThreadMessageAttribute(count: thread.count, latestUsers: thread.latestUsers, commentsPeerId: marker, maxMessageId: thread.maxMessageId, maxReadMessageId: thread.maxReadMessageId)
                            }
                        }
                    }
                    let attributesChanged = attributes.count != message.attributes.count || zip(attributes, message.attributes).contains(where: { !($0.0 === $0.1) })
                    if threadId != message.threadId || flags != StoreMessageFlags(message.flags) || tags != message.tags || attributesChanged {
                        updates.append((message.id, threadId, attributes, flags, tags))
                    }
                    return true
                })
                for (id, threadId, attributes, flags, tags) in updates {
                    transaction.updateMessage(id, update: { current in
                        return .update(StoreMessage.mmCopy(of: current, id: current.id, threadId: threadId, attributes: attributes, flags: flags, tags: tags))
                    })
                }
                self.applyServerReadState(channelId: channelId, transaction: transaction)
                return updates.count
            }
        }
        await self.postbox.mmTransaction { transaction in
            self.store.setCursor(MattermostAccountSync.threadLayoutCursor, MattermostAccountSync.threadLayoutVersion)
            self.applyChatListOrder(transaction: transaction)
            self.refreshChatListTimestamps(transaction: transaction)
        }
        MMLog.log("crt: re-rendered \(updatedCount) message(s) in \(chats.count) chat(s) for collapsed threads \(isOn ? "on" : "off")")
    }

    /// Chat list rows (4F): with collapsed reply threads a row previews and sorts by its newest root post, as
    /// Mattermost sorts by `last_root_post_at` (Postbox's chat list follows the root-post tag; Saved Messages, which
    /// has no collapsed view, keeps its newest message). Without CRT, the newest message.
    func applyChatListOrder(transaction: Transaction) {
        transaction.setChatListTopMessageTag(self.isCollapsedThreads ? .mattermostRootPost : nil, exceptPeerId: self.ownPeerId)
    }

    /// The time a chat sorts by until its messages are loaded: the last (root) post. Takes the state lock.
    func chatListMinTimestamp(_ channel: Channel) -> Int32 {
        let lastPostAt = self.isCollapsedThreads && channel.lastRootPostAt > 0 ? channel.lastRootPostAt : channel.lastPostAt
        return mmSeconds(max(lastPostAt, channel.createAt))
    }

    /// After a switch: every included chat sorts by the matching last post time (pinning and folder kept).
    func refreshChatListTimestamps(transaction: Transaction) {
        let channels = self.state.with { state in
            return state.channels.values.map { ($0.peerId, $0.channel) }
        }
        for (peerId, channel) in channels {
            if case let .ifHasMessagesOrOneOf(groupId, pinningIndex, _) = transaction.getPeerChatListInclusion(peerId) {
                transaction.updatePeerChatListInclusion(peerId, inclusion: .ifHasMessagesOrOneOf(groupId: groupId, pinningIndex: pinningIndex, minTimestamp: self.chatListMinTimestamp(channel)))
            }
        }
    }

    /// Data written before 3B (no root tags, DM replies outside threads) is brought up to date once.
    func upgradeThreadLayoutIfNeeded() async {
        let current = await self.postbox.mmTransaction { _ in
            return self.store.cursor(MattermostAccountSync.threadLayoutCursor)
        }
        if current == MattermostAccountSync.threadLayoutVersion {
            return
        }
        MMLog.log("crt: upgrading the stored thread layout (\(current ?? "none") → \(MattermostAccountSync.threadLayoutVersion))")
        await self.reapplyCollapsedThreads()
    }
}
