import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore

/// Spike A (debug only): creates an authorized account with local fake data, without any login and
/// without Telegram's network, so that the app starts straight into the chat list.
///
/// It uses only public TelegramCore/Postbox API, in the order Telegram's own login uses:
/// 1. write the account postbox (`AuthorizedAccountState`, peers, messages, read states, chat list) with
///    `accountTransaction`, before the account record exists, so nothing else has the postbox open;
/// 2. add the account record and make it current in one account manager transaction (as
///    `switchToAuthorizedAccount` does). `SharedAccountContextImpl` then loads it as an `Account`.
///
/// MattermostSync replaces this with the real bootstrap (Spike D); the postbox writes are the same kind.
public enum MattermostSpikeSeeder {
    private static let started = Atomic<Bool>(value: false)

    /// The own user's peer of the seeded account.
    public static var accountPeerId: PeerId {
        return userPeerId(SpikeFixtures.ownUserId)
    }

    /// Creates and selects the seeded account. Runs once per process; later calls do nothing.
    public static func createSeededAccountIfNeeded(accountManager: AccountManager<TelegramAccountManagerTypes>, rootPath: String, encryptionParameters: ValueBoxEncryptionParameters) {
        if started.swap(true) {
            return
        }
        let id = generateAccountRecordId()
        let now = Int32(Date().timeIntervalSince1970)
        Logger.shared.log("MattermostSpikeSeeder", "seeding account \(id.int64)")

        let _ = (accountTransaction(rootPath: rootPath, id: id, encryptionParameters: encryptionParameters, isReadOnly: false, transaction: { _, transaction -> Void in
            seed(transaction: transaction, now: now)
        })
        |> `catch` { error -> Signal<Void, NoError> in
            Logger.shared.log("MattermostSpikeSeeder", "could not open the account postbox: \(error)")
            return .complete()
        }
        |> mapToSignal { _ -> Signal<Void, NoError> in
            return accountManager.transaction { transaction -> Void in
                let nextSortOrder = (transaction.getRecords().map { record -> Int32 in
                    for attribute in record.attributes {
                        if case let .sortOrder(sortOrder) = attribute {
                            return sortOrder.order
                        }
                    }
                    return 0
                }.max() ?? 0) + 1
                transaction.updateRecord(id, { _ in
                    return AccountRecord(id: id, attributes: [
                        .environment(AccountEnvironmentAttribute(environment: .production)),
                        .sortOrder(AccountSortOrderAttribute(order: nextSortOrder))
                    ], temporarySessionId: nil)
                })
                transaction.setCurrentId(id)
            }
        }).start(completed: {
            Logger.shared.log("MattermostSpikeSeeder", "account \(id.int64) seeded and selected")
        })
    }

    /// Debug hook for screenshots without UI automation: the chat named by the `RELAY_DEBUG_OPEN_CHAT`
    /// environment variable (`SIMCTL_CHILD_RELAY_DEBUG_OPEN_CHAT` on `simctl launch`). `1` opens the
    /// first chat of the list, any other value a chat by its fixture key (`ios-team`, `town-square`,
    /// `dm`, `off-topic`, `saved`).
    public static func debugChatToOpen() -> PeerId? {
        guard let value = ProcessInfo.processInfo.environment["RELAY_DEBUG_OPEN_CHAT"], !value.isEmpty, value != "0" else {
            return nil
        }
        let chat: SpikeChat?
        if value == "1" {
            chat = SpikeFixtures.chats.first
        } else {
            chat = SpikeFixtures.chats.first(where: { $0.key == value })
        }
        return chat.flatMap(chatPeerId)
    }
}

private func userPeerId(_ id: Int64) -> PeerId {
    return PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(id))
}

private func channelPeerId(_ id: Int64) -> PeerId {
    return PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(id))
}

private func chatPeerId(_ chat: SpikeChat) -> PeerId {
    switch chat.kind {
    case let .channel(id, _, _, _):
        return channelPeerId(id)
    case let .directMessage(userId):
        return userPeerId(userId)
    case .savedMessages:
        return userPeerId(SpikeFixtures.ownUserId)
    }
}

private func seed(transaction: Transaction, now: Int32) {
    let accountPeerId = userPeerId(SpikeFixtures.ownUserId)
    // Channels "exist" since 90 days ago; the chat list uses this as the minimum timestamp of a channel row.
    let channelCreationDate = now - 90 * 24 * 60 * 60

    transaction.setState(AuthorizedAccountState(isTestingEnvironment: false, masterDatacenterId: 2, peerId: accountPeerId, state: nil, invalidatedChannels: []))

    // Peers. `.personal` access hashes: `TelegramUser.merge` replaces stored users only for those, and
    // `updatePeersCustom` gives member channels their chat-list inclusion only for those.
    var peers: [Peer] = []
    for user in SpikeFixtures.users {
        peers.append(TelegramUser(
            id: userPeerId(user.id),
            accessHash: .personal(0),
            firstName: user.firstName,
            lastName: user.lastName,
            username: user.username,
            phone: nil,
            photo: [],
            botInfo: nil,
            restrictionInfo: nil,
            flags: [],
            emojiStatus: nil,
            usernames: [],
            storiesHidden: nil,
            nameColor: nil,
            backgroundEmojiId: nil,
            profileColor: nil,
            profileBackgroundEmojiId: nil,
            subscriberCount: nil,
            verificationIconFileId: nil
        ))
    }
    var channelPeerIds = Set<PeerId>()
    var channelData: [PeerId: (purpose: String, memberCount: Int32)] = [:]
    for chat in SpikeFixtures.chats {
        guard case let .channel(id, title, purpose, memberCount) = chat.kind else {
            continue
        }
        let peerId = channelPeerId(id)
        channelPeerIds.insert(peerId)
        channelData[peerId] = (purpose, memberCount)
        peers.append(TelegramChannel(
            id: peerId,
            accessHash: .personal(0),
            title: title,
            username: nil,
            photo: [],
            creationDate: channelCreationDate,
            version: 0,
            participationStatus: .member,
            info: .group(TelegramChannelGroupInfo(flags: [])),
            flags: [],
            restrictionInfo: nil,
            adminRights: nil,
            bannedRights: nil,
            defaultBannedRights: nil,
            usernames: [],
            storiesHidden: nil,
            nameColor: nil,
            backgroundEmojiId: nil,
            profileColor: nil,
            profileBackgroundEmojiId: nil,
            emojiStatus: nil,
            approximateBoostLevel: nil,
            subscriptionUntilDate: nil,
            verificationIconFileId: nil,
            sendPaidMessageStars: nil,
            linkedMonoforumId: nil
        ))
    }
    updatePeersCustom(transaction: transaction, peers: peers, update: { _, updated in
        return updated
    })

    var presences: [PeerId: PeerPresence] = [:]
    for user in SpikeFixtures.users where user.id != SpikeFixtures.ownUserId {
        let status: UserPresenceStatus
        var lastActivity: Int32 = 0
        switch user.presence {
        case .online:
            status = .present(until: now + 24 * 60 * 60)
        case let .lastSeen(minutesAgo):
            status = .present(until: now - minutesAgo * 60)
            lastActivity = now - minutesAgo * 60
        case .recently:
            status = .recently(isHidden: false)
        case .lastWeek:
            status = .lastWeek(isHidden: false)
        }
        presences[userPeerId(user.id)] = TelegramUserPresence(status: status, lastActivity: lastActivity)
    }
    transaction.updatePeerPresencesInternal(presences: presences, merge: { _, updated in
        return updated
    })
    transaction.replaceContactPeerIds(Set(SpikeFixtures.users.filter({ $0.id != SpikeFixtures.ownUserId }).map({ userPeerId($0.id) })))

    // Channel info shown by the chat header and peer info ("5 members"), which would otherwise wait for
    // `channels.getFullChannel` forever.
    transaction.updatePeerCachedData(peerIds: channelPeerIds, update: { peerId, _ in
        guard let data = channelData[peerId] else {
            return nil
        }
        return CachedChannelData()
            .withUpdatedAbout(data.purpose)
            .withUpdatedParticipantsSummary(CachedChannelParticipantsSummary(memberCount: data.memberCount, adminCount: 1, bannedCount: 0, kickedCount: 0))
    })

    // Users: a known (empty) business intro and no action bar. A user chat's history waits until the
    // intro is known (`chatHistoryViewForLocation`), which `users.getFullUser` would otherwise decide.
    let userPeerIds = Set(SpikeFixtures.users.map { userPeerId($0.id) })
    transaction.updatePeerCachedData(peerIds: userPeerIds, update: { _, current in
        return (current as? CachedUserData ?? CachedUserData())
            .withUpdatedBusinessIntro(nil)
            .withUpdatedPeerStatusSettings(PeerStatusSettings())
    })

    // What Telegram's login writes (`initializedAppSettingsAfterLogin`): no device-contact sync. With sync
    // on, every chat waits for the device contacts, which never load while the Contacts permission is
    // undetermined (`DeviceContactDataManager`), so no chat would ever open.
    transaction.updatePreferencesEntry(key: PreferencesKeys.contactsSettings, { _ in
        return PreferencesEntry(ContactsSettings(synchronizeContacts: false))
    })

    // The root and archive chat lists start with a hole that `managedChatListHoles` fills from
    // `messages.getDialogs`; with it the list stays "loading". The list is complete locally.
    let seededHoles = telegramPostboxSeedConfiguration.initializeChatListWithHole
    for (groupId, seededHole) in [(PeerGroupId.root, seededHoles.topLevel), (Namespaces.PeerGroup.archive, seededHoles.groups)] {
        // Replacing initializes the list first (adding its seeded hole) and then removes that hole.
        if let seededHole = seededHole {
            transaction.replaceChatListHole(groupId: groupId, index: seededHole.index, hole: nil)
        }
        for hole in transaction.allChatListHoles(groupId: groupId) {
            transaction.replaceChatListHole(groupId: groupId, index: hole.index, hole: nil)
        }
    }

    var chatIndex: Int32 = 0
    for chat in SpikeFixtures.chats {
        chatIndex += 1
        seedChat(transaction: transaction, chat: chat, accountPeerId: accountPeerId, now: now, channelCreationDate: channelCreationDate, firstMessageId: chatIndex * 1000 + 1)
    }
}

private func seedChat(transaction: Transaction, chat: SpikeChat, accountPeerId: PeerId, now: Int32, channelCreationDate: Int32, firstMessageId: Int32) {
    let peerId = chatPeerId(chat)
    let isChannel = peerId.namespace == Namespaces.Peer.CloudChannel
    let isSavedMessages = peerId == accountPeerId

    // Every peer gets a chat-list inclusion. For channels this is also what lets `AccountViewTracker`
    // show history at once instead of waiting for `getChannelDifference` (and re-adding a full hole).
    transaction.updatePeerChatListInclusion(peerId, inclusion: .ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: isChannel ? channelCreationDate : nil))

    // Ids follow (timestamp, id) order within the peer, which Postbox's hole sampler requires.
    let ids: [MessageId] = chat.messages.indices.map { index in
        return MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: firstMessageId + Int32(index))
    }
    let maxId = ids.last?.id ?? 0
    let firstUnreadIndex = chat.messages.count - chat.unreadCount
    let maxIncomingReadId: Int32 = firstUnreadIndex > 0 ? ids[firstUnreadIndex - 1].id : 0
    for index in firstUnreadIndex ..< chat.messages.count {
        assert(chat.messages[index].authorId != SpikeFixtures.ownUserId, "unread messages must be incoming")
    }

    // Authoritative read state before the messages, so adding them does not count them again.
    // Outgoing messages count as read by the other side (double check marks).
    transaction.resetIncomingReadStates([peerId: [Namespaces.Message.Cloud: .idBased(maxIncomingReadId: maxIncomingReadId, maxOutgoingReadId: maxId, maxKnownId: maxId, count: Int32(chat.unreadCount), markedUnread: false)]])

    var threadIds = Set<Int64>()
    var storeMessages: [StoreMessage] = []
    var previousTimestamp: Int32 = 0
    for (index, message) in chat.messages.enumerated() {
        let timestamp = now - message.minutesAgo * 60
        assert(timestamp > previousTimestamp, "messages must be listed oldest first")
        previousTimestamp = timestamp

        let isIncoming = message.authorId != SpikeFixtures.ownUserId
        var attributes: [MessageAttribute] = []
        var threadId: Int64?
        if isSavedMessages {
            // Telegram files Saved Messages under the peer they were saved from; notes to self use the own id.
            threadId = accountPeerId.toInt64()
        } else if isChannel {
            // As Telegram stores supergroup messages: replies belong to the thread of the message they
            // answer, everything else to thread 1.
            threadId = 1
        }
        if let replyTo = message.replyTo {
            let replyToId = ids[replyTo]
            let threadMessageId: MessageId? = isChannel ? replyToId : nil
            if isChannel {
                threadId = Int64(replyToId.id)
            }
            attributes.append(ReplyMessageAttribute(messageId: replyToId, threadMessageId: threadMessageId, quote: nil, isQuote: false, innerSubject: nil))
        }
        if let threadId = threadId {
            threadIds.insert(threadId)
        }

        storeMessages.append(StoreMessage(
            id: ids[index],
            customStableId: nil,
            globallyUniqueId: nil,
            groupingKey: nil,
            threadId: threadId,
            timestamp: timestamp,
            flags: isIncoming ? [.Incoming] : [],
            tags: [],
            globalTags: [],
            localTags: [],
            forwardInfo: nil,
            authorId: userPeerId(message.authorId),
            text: message.text,
            attributes: attributes,
            media: []
        ))
    }
    let _ = transaction.addMessages(storeMessages, location: .Random)

    // The seeded history is complete: no hole anywhere, so nothing asks for a fill (Telegram's hole
    // management is off; MattermostSync fills holes from Spike D on). Removing the `.everywhere` range
    // also clears every tag space.
    let fullRange: ClosedRange<MessageId.Id> = 1 ... (Int32.max - 1)
    transaction.removeHole(peerId: peerId, threadId: nil, namespace: Namespaces.Message.Cloud, space: .everywhere, range: fullRange)
    for threadId in threadIds {
        transaction.removeHole(peerId: peerId, threadId: threadId, namespace: Namespaces.Message.Cloud, space: .everywhere, range: fullRange)
    }
}
