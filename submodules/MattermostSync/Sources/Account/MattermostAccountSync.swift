import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// MattermostSync for one account: the replacement for Telegram's sync (`docs/design/mattermost-sync.md`).
///
/// Concurrency: network work runs in Swift tasks; every unit of work that touches the ID map or Postbox runs
/// inside one Postbox transaction (`Postbox.mmTransaction`), which does its ID-map changes first and then
/// writes Postbox. Postbox runs transactions one at a time, so these units never interleave. In-memory state
/// (`SyncState`) is behind a lock because it is read from tasks as well.
public final class MattermostAccountSync: @unchecked Sendable {
    let account: Account
    let client: MattermostClient
    let store: MattermostSyncStore
    let server: MattermostServerInfo
    let ownPeerId: PeerId
    /// `maxId` stays below `Int32.max`, the end of Postbox's hole range.
    let allocator: MessageIdAllocator
    let perPage = 60

    var postbox: Postbox {
        return self.account.postbox
    }

    struct ChannelState {
        var channel: Channel
        var member: ChannelMember
        var kind: ChatKind
        var peerId: PeerId
        var teamId: String
        /// Mention badge count, kept from the member counters plus live mentions.
        var mentionCount: Int32

        /// The "@" mention badge: channels only. Mattermost counts every DM and GM message as a mention, so
        /// DMs and GMs show the unread count alone (product decision, docs/PROGRESS.md 2D).
        var showsMentionBadge: Bool {
            return self.kind == .channel && self.channel.type != .groupMessage
        }

        var counters: ChannelReadCounters {
            return ChannelReadCounters(
                lastViewedAt: self.member.lastViewedAt,
                totalMessageCount: self.channel.totalMsgCount,
                memberMessageCount: self.member.msgCount,
                mentionCount: Int64(self.mentionCount)
            )
        }
    }

    struct SyncState {
        var me: User?
        var teams: [Team] = []
        var channels: [String: ChannelState] = [:]
        var channelIdByPeerId: [PeerId: String] = [:]
        var users: [String: User] = [:]
        var userIdByUsername: [String: String] = [:]
        /// Channels whose newest page came back empty (no posts at all).
        var emptyChannels: Set<String> = []
        /// Tag spaces without holes per channel: `.pinned` once the pinned posts are loaded, media tags once
        /// requested (they show the loaded history only, see `fillHole`).
        var completeTagSpaces: [String: MessageTags] = [:]
        var isBootstrapped = false
        /// The first bootstrap also loaded every channel's newest page.
        var newestPagesLoaded = false
        /// Local ids reserved for a jump (permalink) before their post is written: they stay holes, so the
        /// chat's `.aroundId` request loads them with their neighbours.
        var reservedJumpIds: [String: Set<Int32>] = [:]
        /// Each team's Favorites category (channel ids, in order): the pinned chats of the team's folder.
        var favoritesByTeam: [String: [String]] = [:]
        /// The pinned peers last written to (or pushed from) each team folder, to tell the user's pin changes
        /// in a folder from our own writes.
        var folderPins: [String: [PeerId]] = [:]
    }

    let state = MMLocked(SyncState())
    private let updatingCount = MMLocked<Int>(0)
    private let disposables = DisposableSet()
    private let tasks = MMLocked<[Task<Void, Never>]>([])
    private(set) var socket: MattermostWebSocket?
    private var holeFiller: HoleFiller?
    private var readStatePusher: ReadStatePusher?
    let bootstrapped = ValuePromise<Bool>(false, ignoreRepeated: true)

    // Write path (Phase 2A).
    private(set) var sender: PostSender!
    var operationRunners: [AnyObject] = []
    /// Counts WebSocket connections; retries of offline requests wake up when it changes.
    let connectionGeneration = MMLocked<Int>(0)
    let isConnected = MMLocked<Bool>(false)
    /// Set by `stop()` (logout, session expiry); a stopped sync is never restarted.
    private let stoppedFlag = MMLocked<Bool>(false)
    var isStopped: Bool {
        return self.stoppedFlag.current
    }
    /// `user_typing` throttle per chat (the server's `TimeBetweenUserTypingUpdatesMilliseconds`).
    let typingInterval = MMLocked<Double>(5.0)
    let typingSent = MMLocked<[PeerActivitySpace: (time: Double, updateId: Int32)]>([:])
    /// File searches for the media tabs, per channel (`loadChannelFiles`); kept once done.
    let fileSearches = MMLocked<[String: Task<Void, Error>]>([:])
    /// What the `AvailableReactions` list holds (`SyntheticConfiguration`).
    let reactionList = MMLocked<(customNames: [String], usedEmoji: [String], listed: Set<String>)>(([], [], []))

    init(account: Account, client: MattermostClient, store: MattermostSyncStore, server: MattermostServerInfo) {
        self.account = account
        self.client = client
        self.store = store
        self.server = server
        self.ownPeerId = account.peerId
        var configuration = MessageIdAllocator.Configuration(maxId: Int32.max - 1)
        #if DEBUG
        // Debug only: a small id space (`RELAY_DEBUG_ID_SPACE=300000`) forces renumbering, to exercise
        // `applyRenumber` against real history.
        if let value = ProcessInfo.processInfo.environment["RELAY_DEBUG_ID_SPACE"].flatMap({ Int32($0) }), value >= 1024 {
            configuration = MessageIdAllocator.Configuration(firstId: value / 2, maxId: value)
            MMLog.log("debug: id space limited to 1...\(value)")
        }
        #endif
        self.allocator = MessageIdAllocator(configuration: configuration)
    }

    deinit {
        self.disposables.dispose()
        for task in self.tasks.current {
            task.cancel()
        }
    }

    func start() {
        MMLog.log("account \(self.account.id.int64): starting sync for \(self.server.url) as \(self.server.userId)")
        MattermostResourceClients.shared.register(postbox: self.postbox, client: self.client)
        self.account.network.mattermostSetConnectionState(isConnected: false, isNetworkAvailable: true)

        // Write path: sending/editing through PendingMessageManager, then the operation consumers.
        let sender = PostSender(sync: self)
        self.sender = sender
        self.account.mattermostSetMessageSender(sender)

        let holeFiller = HoleFiller(sync: self)
        self.holeFiller = holeFiller
        holeFiller.start()
        let readStatePusher = ReadStatePusher(sync: self)
        self.readStatePusher = readStatePusher
        readStatePusher.start()

        self.addTask(Task { [weak self] in
            guard let self = self else {
                return
            }
            await self.run()
        })
    }

    private func run() async {
        await self.writeSyntheticConfiguration()
        // Bootstrap until it succeeds (the server may be unreachable at launch).
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await self.bootstrap()
                break
            } catch {
                attempt += 1
                let delay = min(30.0, pow(2.0, Double(min(attempt, 5))))
                MMLog.log("bootstrap failed (\(error)); retrying in \(Int(delay)) s")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        if Task.isCancelled {
            return
        }
        self.bootstrapped.set(true)
        // The consumers need the channel map that the bootstrap wrote.
        self.startOperationConsumers()
        self.startSocket()
        await self.refreshSyntheticConfiguration()
    }

    func addTask(_ task: Task<Void, Never>) {
        self.tasks.with { $0.append(task) }
    }

    /// Waits until the bootstrap has written the chats (the sender needs the channel map).
    func waitUntilBootstrapped() async {
        while !self.state.with({ $0.isBootstrapped }) && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    func addDisposable(_ disposable: Disposable) {
        self.disposables.add(disposable)
    }

    // MARK: Notices

    /// A user-facing message about a failed write (shown as a toast by the app, see `MattermostSync.notices`).
    func notice(_ text: String) {
        MMLog.log("notice: \(text)")
        MattermostSync.noticePipe(accountId: self.account.id).putNext(text)
    }

    // MARK: Updating state ("Updating…" in the title)

    func beginUpdating() {
        let count = self.updatingCount.with { value -> Int in
            value += 1
            return value
        }
        if count == 1 {
            self.account.externalIsUpdating.set(.single(true))
        }
    }

    func endUpdating() {
        let count = self.updatingCount.with { value -> Int in
            value = max(0, value - 1)
            return value
        }
        if count == 0 {
            self.account.externalIsUpdating.set(.single(false))
        }
    }

    // MARK: WebSocket

    private func startSocket() {
        let socket = self.client.makeWebSocket()
        self.socket = socket
        self.addTask(Task { [weak self] in
            for await state in socket.connectionStates() {
                guard let self = self else {
                    return
                }
                self.handleConnectionState(state)
            }
        })
        self.addTask(Task { [weak self] in
            for await event in socket.events() {
                guard let self = self else {
                    return
                }
                await self.handleEvent(event)
            }
        })
        Task {
            await socket.connect()
        }
    }

    private func handleConnectionState(_ state: WebSocketConnectionState) {
        switch state {
        case let .connected(info):
            MMLog.log("websocket connected (connection \(info.connectionId), resumed: \(info.resumed))")
            self.isConnected.with { $0 = true }
            self.connectionGeneration.with { $0 += 1 }
            self.account.network.mattermostSetConnectionState(isConnected: true, isNetworkAvailable: true)
            if !info.resumed {
                self.addTask(Task { [weak self] in
                    await self?.catchUp()
                })
            }
        case .connecting, .waitingToReconnect:
            self.isConnected.with { $0 = false }
            self.account.network.mattermostSetConnectionState(isConnected: false, isNetworkAvailable: true)
        case .disconnected:
            self.isConnected.with { $0 = false }
            self.account.network.mattermostSetConnectionState(isConnected: false, isNetworkAvailable: true)
        case .unauthorized:
            self.isConnected.with { $0 = false }
            MMLog.log("websocket: the server rejected the session token")
            self.account.network.mattermostSetConnectionState(isConnected: false, isNetworkAvailable: true)
            MattermostSync.sessionExpired(accountId: self.account.id, reason: "the WebSocket was rejected")
        }
    }

    /// Stops everything `start()` started (logout, session expiry). The object is not reused; a new session
    /// gets a new `MattermostAccountSync`.
    func stop() {
        let tasks = self.tasks.with { tasks -> [Task<Void, Never>] in
            let current = tasks
            tasks.removeAll()
            return current
        }
        for task in tasks {
            task.cancel()
        }
        self.disposables.dispose()
        self.holeFiller = nil
        self.readStatePusher = nil
        // Write path (2A): the operation consumers stop when released. Sends of a stopped sync fail (the
        // sender holds the sync weakly) and can be resent after a new login.
        self.operationRunners = []
        self.isConnected.with { $0 = false }
        if let socket = self.socket {
            Task {
                await socket.disconnect()
            }
        }
        self.account.network.mattermostSetConnectionState(isConnected: false, isNetworkAvailable: true)
        if self.updatingCount.with({ $0 }) > 0 {
            self.account.externalIsUpdating.set(.single(false))
        }
    }

    // MARK: Lookups (callable from any thread)

    func channelState(_ channelId: String) -> ChannelState? {
        return self.state.with { $0.channels[channelId] }
    }

    func channelId(forPeerId peerId: PeerId) -> String? {
        return self.state.with { $0.channelIdByPeerId[peerId] }
    }

    var ownUserId: String {
        return self.server.userId
    }

    var ownUsername: String {
        return self.state.with { $0.me?.username ?? "" }
    }

    /// The peer of a known user (written to Postbox), or nil.
    func userPeerId(_ userId: String) -> PeerId? {
        if userId == self.ownUserId {
            return self.ownPeerId
        }
        guard let peer = self.store.peer(mattermostId: userId), peer.kind == .user else {
            return nil
        }
        return MattermostPeerIds.userPeerId(peer.peerId)
    }

    func storeRef() -> StoreRef {
        return StoreRef(base: self.store)
    }

    // MARK: Users

    /// Fetches and writes the users among `ids` that are not known yet.
    func ensureUsers(_ ids: Set<String>) async {
        let missing = self.state.with { state in ids.filter { !$0.isEmpty && state.users[$0] == nil } }
        if missing.isEmpty {
            return
        }
        do {
            let users = try await self.client.users(ids: Array(missing))
            await self.postbox.mmTransaction { transaction in
                self.writeUsers(users, transaction: transaction)
            }
        } catch {
            MMLog.log("could not load users \(missing.sorted()): \(error)")
        }
    }

    /// Writes users as peers with cached data (every user needs cached data, or their chats never open).
    func writeUsers(_ users: [User], transaction: Transaction) {
        if users.isEmpty {
            return
        }
        var peers: [Peer] = []
        var usersByPeerId: [PeerId: User] = [:]
        for user in users {
            let peerId: PeerId
            if user.id == self.ownUserId {
                peerId = self.ownPeerId
            } else if let peer = self.store.allocatePeer(mattermostId: user.id, kind: .user, teamId: nil) {
                peerId = MattermostPeerIds.userPeerId(peer.peerId)
            } else {
                continue
            }
            peers.append(PeerConverter.user(user, peerId: peerId))
            usersByPeerId[peerId] = user
        }
        updatePeersCustom(transaction: transaction, peers: peers, update: { _, updated in
            return updated
        })
        transaction.updatePeerCachedData(peerIds: Set(usersByPeerId.keys), update: { peerId, current in
            let about = usersByPeerId[peerId].flatMap { user -> String? in
                if user.isBot {
                    return user.botDescription.isEmpty ? nil : user.botDescription
                }
                return user.position.isEmpty ? nil : user.position
            }
            return (current as? CachedUserData ?? CachedUserData())
                .withUpdatedAbout(about)
                .withUpdatedBusinessIntro(nil)
                .withUpdatedPeerStatusSettings(PeerStatusSettings())
        })
        self.state.with { state in
            for user in users {
                state.users[user.id] = user
                state.userIdByUsername[user.username.lowercased()] = user.id
            }
        }
    }

    func writePresences(_ statuses: [UserStatus], transaction: Transaction) {
        let now = Date()
        var presences: [PeerId: PeerPresence] = [:]
        for status in statuses where status.userId != self.ownUserId {
            guard let peerId = self.userPeerId(status.userId) else {
                continue
            }
            presences[peerId] = PeerConverter.presence(status: status.status, lastActivityAt: status.lastActivityAt, dndEndTime: status.dndEndTime, now: now)
        }
        if !presences.isEmpty {
            transaction.updatePeerPresencesInternal(presences: presences, merge: { _, updated in
                return updated
            })
        }
    }

    // MARK: Channels

    /// Writes a channel (or DM) the user is a member of: peer, cached data, chat-list inclusion, mute
    /// state and the read state from the server counters. DM partners must already be written.
    @discardableResult
    func writeChannel(_ channel: Channel, member: ChannelMember, teamId: String, transaction: Transaction) -> ChannelState? {
        let kind: ChatKind
        let peerId: PeerId
        switch channel.type {
        case .directMessage:
            guard let partnerId = channel.directMessagePartnerId(myUserId: self.ownUserId) else {
                MMLog.log("DM \(channel.id) without a partner (\(channel.name))")
                return nil
            }
            self.store.setDirectChannel(channelId: channel.id, userId: partnerId)
            if partnerId == self.ownUserId {
                kind = .saved
                peerId = self.ownPeerId
            } else {
                guard let userPeerId = self.userPeerId(partnerId) else {
                    MMLog.log("DM \(channel.id): partner \(partnerId) unknown")
                    return nil
                }
                kind = .direct
                peerId = userPeerId
            }
        default:
            kind = .channel
            guard let peer = self.store.allocatePeer(mattermostId: channel.id, kind: channel.type == .groupMessage ? .groupMessage : .channel, teamId: channel.teamId.isEmpty ? nil : channel.teamId) else {
                return nil
            }
            peerId = MattermostPeerIds.channelPeerId(peer.peerId)
            let title = channel.displayName.isEmpty ? channel.name : channel.displayName
            updatePeersCustom(transaction: transaction, peers: [PeerConverter.channel(channel, title: title, peerId: peerId)], update: { _, updated in
                return updated
            })
            let about = channel.purpose.isEmpty ? channel.header : channel.purpose
            transaction.updatePeerCachedData(peerIds: [peerId], update: { _, current in
                return (current as? CachedChannelData ?? CachedChannelData())
                    .withUpdatedAbout(about.isEmpty ? nil : about)
                    .withUpdatedParticipantsSummary(CachedChannelParticipantsSummary(memberCount: nil, adminCount: nil, bannedCount: nil, kickedCount: nil))
            })
        }

        // Every chat needs an inclusion: rows sort by `last_post_at` until messages load, and a channel without
        // one would also wait for Telegram's channel polling.
        let groupId: PeerGroupId = channel.isArchived ? Namespaces.PeerGroup.archive : .root
        let minTimestamp = mmSeconds(max(channel.lastPostAt, channel.createAt))
        transaction.updatePeerChatListInclusion(peerId, inclusion: .ifHasMessagesOrOneOf(groupId: groupId, pinningIndex: nil, minTimestamp: minTimestamp))

        let muted = member.notifyProps["mark_unread"] == "mention"
        let notificationSettings = TelegramPeerNotificationSettings.defaultSettings.withUpdatedMuteState(muted ? .muted(until: Int32.max) : .unmuted)
        transaction.updateCurrentPeerNotificationSettings([peerId: notificationSettings])

        let channelState = ChannelState(channel: channel, member: member, kind: kind, peerId: peerId, teamId: teamId, mentionCount: Int32(clamping: member.mentionCount))
        self.state.with { state in
            state.channels[channel.id] = channelState
            state.channelIdByPeerId[peerId] = channel.id
        }
        self.applyServerReadState(channelId: channel.id, transaction: transaction)
        return channelState
    }

    /// Resets the read state and the mention badge from the server counters, resolving the max ids against
    /// the ID map (design: read state before messages, max ids once posts are known).
    func applyServerReadState(channelId: String, transaction: Transaction) {
        guard let channelState = self.channelState(channelId) else {
            return
        }
        let readState = ReadStateMapper.readState(channelId: channelId, store: self.storeRef(), counters: channelState.counters)
        transaction.resetIncomingReadStates([channelState.peerId: [Namespaces.Message.Cloud: .idBased(
            maxIncomingReadId: readState.maxIncomingReadId,
            maxOutgoingReadId: 0,
            maxKnownId: readState.maxKnownId,
            count: readState.unreadCount,
            markedUnread: false
        )]])
        self.applyMentionCount(channelState.mentionCount, peerId: channelState.peerId, transaction: transaction)
    }

    func applyMentionCount(_ count: Int32, peerId: PeerId, transaction: Transaction) {
        let showsBadge = self.state.with { state -> Bool in
            guard let channelId = state.channelIdByPeerId[peerId], let channelState = state.channels[channelId] else {
                return true
            }
            return channelState.showsMentionBadge
        }
        // `maxId` at the top of the id space: tagged messages added later don't count themselves again; live
        // mentions update the count explicitly.
        transaction.replaceMessageTagSummary(peerId: peerId, threadId: nil, tagMask: .unseenPersonalMessage, namespace: Namespaces.Message.Cloud, customTag: nil, count: showsBadge ? max(0, count) : 0, maxId: Int32.max - 1)
    }

    /// Context for converting posts of `channelId` inside a transaction.
    func conversionContext(channelId: String, entries: [String: MessageIdEntry]) -> PostConversionContext? {
        guard let channelState = self.channelState(channelId) else {
            return nil
        }
        let store = self.store
        return PostConversionContext(
            ownUserId: self.ownUserId,
            showsMentionBadge: channelState.showsMentionBadge,
            ownUsername: self.ownUsername.lowercased(),
            accountPeerId: self.ownPeerId,
            chatPeerId: channelState.peerId,
            kind: channelState.kind,
            serverURL: self.server.url,
            lastViewedAt: channelState.member.lastViewedAt,
            userPeerId: { [weak self] userId in
                return self?.userPeerId(userId)
            },
            usernamePeerId: { [weak self] username in
                guard let self = self, let userId = self.state.with({ $0.userIdByUsername[username.lowercased()] }) else {
                    return nil
                }
                return self.userPeerId(userId)
            },
            userDisplayName: { [weak self] userId in
                return self?.state.with { state in state.users[userId].map(PeerConverter.displayName) }
            },
            localId: { postId in
                if let entry = entries[postId] {
                    return entry.isDeleted ? nil : entry.localId
                }
                if let entry = store.entries(channelId: channelId, postIds: [postId])[postId], !entry.isDeleted {
                    return entry.localId
                }
                return nil
            },
            mediaId: { fileId in
                return store.allocateMediaId(fileId: fileId)
            }
        )
    }
}

/// A value-type `MessageIdStore` forwarding to the account's store, for the allocator's generic API.
struct StoreRef: MessageIdStore {
    let base: MattermostSyncStore

    func entries(channelId: String, postIds: [String]) -> [String: MessageIdEntry] {
        return self.base.entries(channelId: channelId, postIds: postIds)
    }

    func entries(channelId: String, keyRange: ClosedRange<PostOrderKey>) -> [MessageIdEntry] {
        return self.base.entries(channelId: channelId, keyRange: keyRange)
    }

    func entries(channelId: String, olderThan key: PostOrderKey?, limit: Int) -> [MessageIdEntry] {
        return self.base.entries(channelId: channelId, olderThan: key, limit: limit)
    }

    func entries(channelId: String, newerThan key: PostOrderKey?, limit: Int) -> [MessageIdEntry] {
        return self.base.entries(channelId: channelId, newerThan: key, limit: limit)
    }

    func entries(channelId: String, fromLocalId localId: Int32, ascending: Bool, limit: Int) -> [MessageIdEntry] {
        return self.base.entries(channelId: channelId, fromLocalId: localId, ascending: ascending, limit: limit)
    }

    func islands(channelId: String) -> [HistoryIsland] {
        return self.base.islands(channelId: channelId)
    }

    func unmappedTombstones(channelId: String, among postIds: [String]) -> Set<String> {
        return self.base.unmappedTombstones(channelId: channelId, among: postIds)
    }

    mutating func apply(_ changes: MessageIdChangeSet) {
        self.base.apply(changes)
    }
}
