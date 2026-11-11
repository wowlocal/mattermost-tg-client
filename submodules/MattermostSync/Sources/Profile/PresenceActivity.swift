import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore
import RelayCallsCore

extension MattermostSync {
    static let receiptDisplayVisible = MMLocked<Bool>(false)

    public static func updateReceiptDisplayVisibility(visible: Bool) {
        self.receiptDisplayVisible.with { $0 = visible }
    }

    static let applicationInForeground = MMLocked<Bool>(false)
    private static let callSignallingAccounts = MMLocked<Set<AccountRecordId>>([])
    private static let pushedCallDeadlines = MMLocked<[String: [String: Double]]>([:])

    public static func updateApplicationActivity(inForeground: Bool) {
        let changed = self.applicationInForeground.with { value -> Bool in
            let changed = value != inForeground
            value = inForeground
            return changed
        }
        if changed {
            for sync in self.accounts.with({ Array($0.values) }) { sync.updateSocketIntent() }
        }
    }

    public static func updateCallSignalling(accountId: AccountRecordId, required: Bool) {
        if required, let sync = self.sync(accountId: accountId) {
            self.pushedCallDeadlines.with { $0[sync.ownUserId] = nil }
        }
        let changed = self.callSignallingAccounts.with { accounts -> Bool in
            if required { return accounts.insert(accountId).inserted }
            return accounts.remove(accountId) != nil
        }
        if changed { self.sync(accountId: accountId)?.updateSocketIntent() }
    }

    public static func prepareRelayCallSignalling(push: RelayCallPush) {
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        self.pushedCallDeadlines.with { $0[push.recipientId, default: [:]][push.callId] = deadline }
        self.updatePushedCallSockets(userId: push.recipientId)
        Task {
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            self.updatePushedCallSockets(userId: push.recipientId)
        }
    }

    static func reconcilePushedCallSignalling(userId: String, event: RelayCallsEvent) {
        self.pushedCallDeadlines.with { pending in
            switch event {
            case let .callEnded(call): pending[userId]?[call.id] = nil
            case let .activeCalls(calls):
                let liveIds = Set(calls.map(\.id))
                pending[userId] = pending[userId]?.filter { liveIds.contains($0.key) }
            default:
                if let call = event.call, !call.isLive { pending[userId]?[call.id] = nil }
            }
        }
        self.updatePushedCallSockets(userId: userId)
    }

    private static func updatePushedCallSockets(userId: String) {
        for sync in self.accounts.with({ Array($0.values) }) where sync.ownUserId == userId { sync.updateSocketIntent() }
    }

    static func needsCallSignalling(accountId: AccountRecordId, userId: String) -> Bool {
        if self.callSignallingAccounts.with({ $0.contains(accountId) }) { return true }
        let now = ProcessInfo.processInfo.systemUptime
        return self.pushedCallDeadlines.with { pending in
            pending[userId] = pending[userId]?.filter { $0.value > now }
            return !(pending[userId]?.isEmpty ?? true)
        }
    }
}

extension MattermostAccountSync {
    func startPresenceActivity() {
        self.presenceReporter = PresenceActivityReporter { [weak self] active in
            guard let self, !self.isStopped, let socket = self.socket else { return }
            do {
                try await self.client.recordUserActivity()
                guard !self.isStopped, active == self.presenceActive.current else { return }
                try await socket.updateActiveStatus(isActive: active)
                MMLog.log("presence: activity active=\(active) (automatic)")
            } catch {
                MMLog.log("presence: activity failed: \(error)")
                throw error
            }
        }
        self.addDisposable((self.account.shouldKeepOnlinePresence.get()
        |> distinctUntilChanged).start(next: { [weak self] active in
            guard let self else { return }
            self.presenceActive.with { $0 = active }
            self.addTask(Task { [weak self] in await self?.reportPresenceActivity() })
        }))
        self.addTask(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled, !self.isStopped else { return }
                await self.reportPresenceActivity()
            }
        })
    }

    func reportPresenceActivity() async {
        guard let reporter = self.presenceReporter else { return }
        let intent = self.presenceIntent.with { intent -> PresenceActivityIntent in
            intent.revision += 1
            intent.active = self.presenceActive.current
            intent.connected = self.isConnected.current && !self.isStopped
            return intent
        }
        await reporter.update(intent)
    }

    func updateSocketIntent(reconnect: Bool = false, verify: Bool = false) {
        guard let lifecycle = self.socketLifecycle else { return }
        #if os(iOS)
        let mobile = true
        #else
        let mobile = false
        #endif
        let intent = self.socketIntent.with { intent -> AccountSocketIntent in
            intent.revision += 1
            intent.required = AccountSocketLifecycle.requiresSocket(mobile: mobile, foreground: MattermostSync.applicationInForeground.current, callSignalling: MattermostSync.needsCallSignalling(accountId: self.account.id, userId: self.ownUserId), stopped: self.isStopped)
            if reconnect { intent.reconnect += 1 }
            if verify { intent.verify += 1 }
            return intent
        }
        Task { await lifecycle.update(intent) }
    }
}
