import Foundation
import SwiftSignalKit
import MattermostKit

extension MattermostAccountSync {
    func startPresenceActivity() {
        self.addDisposable((self.account.shouldKeepOnlinePresence.get()
        |> distinctUntilChanged).start(next: { [weak self] active in
            guard let self else { return }
            self.presenceActive.with { $0 = active }
            self.addTask(Task { [weak self] in
                guard let self, !self.isStopped else { return }
                #if os(iOS)
                guard let socket = self.socket else { return }
                if self.presenceActive.current {
                    await socket.connect()
                } else {
                    await socket.disconnect()
                }
                #endif
                await self.reportPresenceActivity()
            })
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
        guard !self.isStopped, self.isConnected.current, let socket = self.socket else { return }
        let started = self.presenceReporting.with { inFlight -> Bool in
            if inFlight { return false }
            inFlight = true
            return true
        }
        guard started else { return }
        defer { self.presenceReporting.with { $0 = false } }
        do {
            let active = self.presenceActive.current
            if active {
                try await self.client.recordUserActivity()
            }
            guard !Task.isCancelled, !self.isStopped, active == self.presenceActive.current else { return }
            try await socket.updateActiveStatus(isActive: active)
            MMLog.log("presence: activity active=\(active) (automatic)")
        } catch {
            MMLog.log("presence: activity failed: \(error)")
        }
    }
}
