import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// What Telegram would do over MTProto while a chat or a profile is on screen (TelegramCore
/// `MattermostChatObserver`, Phase 4B), done lazily for Mattermost:
/// - a peer view asks for the peer's cached data → a channel's member count ("N members" in its title), at most
///   once a minute per channel, instead of every channel's count at every launch;
/// - a chat's history opens → a channel that the last catch-up skipped (no new posts, so no `since=` request) is
///   caught up now, for the edits, deletions and reactions it may have had meanwhile.
final class ChatObserver: MattermostChatObserver {
    private weak var sync: MattermostAccountSync?

    init(sync: MattermostAccountSync) {
        self.sync = sync
    }

    func peerDataRequested(peerId: PeerId) {
        self.sync?.chatDataRequested(peerId: peerId)
    }

    func chatHistoryOpened(peerId: PeerId) {
        self.sync?.chatOpened(peerId: peerId)
    }

    func threadReadState(peerId: PeerId, threadId: Int64, transaction: Transaction) -> MattermostThreadReadState? {
        return self.sync?.threadReadState(peerId: peerId, threadId: threadId, transaction: transaction)
    }
}

/// Channels whose posts weren't asked for since a given time (`staleChannels` cursor): edits, deletions and
/// reactions there since then are loaded when the chat opens or with the next catch-up that has to fetch it anyway.
struct StaleChannels: Codable {
    /// Channel id → the `since=` its catch-up still needs.
    var since: [String: Int64] = [:]
}

extension MattermostAccountSync {
    static let staleChannelsCursor = "stale_channels"
    /// Member counts are refreshed at most this often per channel when its title or profile shows.
    static let memberCountInterval: Double = 60.0

    func chatDataRequested(peerId: PeerId) {
        guard let channelId = self.channelId(forPeerId: peerId), let channelState = self.channelState(channelId), channelState.kind == .channel else {
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        let due = self.memberCountsRequested.with { requested -> Bool in
            if let last = requested[channelId], now - last < MattermostAccountSync.memberCountInterval {
                return false
            }
            requested[channelId] = now
            return true
        }
        if due {
            self.addTask(Task { [weak self] in
                await self?.refreshMemberCounts([channelId])
            })
        }
    }

    func chatOpened(peerId: PeerId) {
        guard let channelId = self.channelId(forPeerId: peerId) else {
            return
        }
        let since = self.staleChannels.with { stale -> Int64? in
            return stale?.since[channelId]
        }
        guard let since = since else {
            return
        }
        let start = self.staleCatchUpsInFlight.with { inFlight -> Bool in
            return inFlight.insert(channelId).inserted
        }
        if !start {
            return
        }
        self.addTask(Task { [weak self] in
            guard let self = self else {
                return
            }
            defer {
                self.staleCatchUpsInFlight.with { _ = $0.remove(channelId) }
            }
            do {
                let started = CFAbsoluteTimeGetCurrent()
                let list = try await self.client.posts(channelId: channelId, since: since)
                let count = await self.applySince(channelId: channelId, list: list, since: since)
                self.clearStale([channelId])
                MMLog.log("catch-up: opened \(channelId), stale since \(since): \(count) posts in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
            } catch {
                MMLog.log("catch-up: opened \(channelId) failed: \(error)")
            }
        })
    }

    /// The persisted stale channels (loaded once).
    func loadStaleChannelsIfNeeded() {
        let loaded = self.staleChannels.with { $0 != nil }
        if loaded {
            return
        }
        var value = StaleChannels()
        if let text = self.store.cursor(MattermostAccountSync.staleChannelsCursor), let data = text.data(using: .utf8), let decoded = try? JSONDecoder().decode(StaleChannels.self, from: data) {
            value = decoded
        }
        self.staleChannels.with { current in
            if current == nil {
                current = value
            }
        }
    }

    /// The `since=` a catch-up of the channel needs: the older of `since` and the time it went stale.
    func catchUpSince(_ channelId: String, since: Int64) -> Int64 {
        let stale = self.staleChannels.with { $0?.since[channelId] }
        return min(since, stale ?? since)
    }

    func markStale(_ channelIds: [String], since: Int64) {
        if channelIds.isEmpty {
            return
        }
        self.updateStaleChannels { stale in
            for channelId in channelIds {
                stale.since[channelId] = min(stale.since[channelId] ?? since, since)
            }
        }
    }

    func clearStale(_ channelIds: [String]) {
        self.loadStaleChannelsIfNeeded()
        let present = self.staleChannels.with { stale in channelIds.contains(where: { stale?.since[$0] != nil }) }
        if !present {
            return
        }
        self.updateStaleChannels { stale in
            for channelId in channelIds {
                stale.since[channelId] = nil
            }
        }
    }

    /// Forgets stale channels the user is no longer a member of.
    func pruneStale(keeping channelIds: Set<String>) {
        self.loadStaleChannelsIfNeeded()
        let gone = self.staleChannels.with { stale in (stale?.since.keys).map { Array($0) } ?? [] }.filter { !channelIds.contains($0) }
        if !gone.isEmpty {
            self.clearStale(gone)
        }
    }

    private func updateStaleChannels(_ f: (inout StaleChannels) -> Void) {
        self.loadStaleChannelsIfNeeded()
        let value = self.staleChannels.with { current -> StaleChannels in
            var value = current ?? StaleChannels()
            f(&value)
            current = value
            return value
        }
        let text = (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        self.store.setCursor(MattermostAccountSync.staleChannelsCursor, value.since.isEmpty ? nil : text)
    }
}
