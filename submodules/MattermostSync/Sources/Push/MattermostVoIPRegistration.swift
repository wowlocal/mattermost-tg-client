import Foundation
import TelegramCore
import MattermostPush
import RelayCallsCore

/// Relay calls' VoIP push registration (docs/livekit-calls-native-ui.md, "VoIP push"): every running account registers
/// the device's PushKit token with the calls plugin (`POST /plugins/org.relaychat.calls/devices/voip`) under its
/// calls device id, so that rings reach CallKit while the app is not running.
///
/// An account registers when its sync starts (launch, login, re-login) and when the token changes, unless its store's
/// record says this session already registered this token, environment and app the same way (re-registered weekly
/// regardless). The plugin drops a registration with its session, so logout needs no call.
extension MattermostSync {
    static let relayVoIPRegistrationCursor = "relay_voip_registration"

    private static let voipPushToken = MMLocked<Data?>(nil)
    private static let voipRegistrations = MMLocked<[AccountRecordId: Task<Void, Never>]>([:])

    /// The PushKit token (nil until iOS gives one). Registers it with every running account.
    public static func setVoIPPushToken(_ token: Data?) {
        let changed = self.voipPushToken.with { current -> Bool in
            let changed = current != token
            current = token
            return changed
        }
        guard changed, token != nil else {
            return
        }
        for sync in self.runningSyncs() {
            self.registerVoIPDevice(sync: sync)
        }
    }

    /// Registers the token for one account if needed (called when its sync starts).
    static func registerVoIPDevice(sync: MattermostAccountSync) {
        guard let token = self.voipPushToken.current else {
            return
        }
        let accountId = sync.account.id
        let task = Task {
            await sync.registerVoIPDevice(token: token)
        }
        let previous = self.voipRegistrations.with { tasks -> Task<Void, Never>? in
            let previous = tasks[accountId]
            tasks[accountId] = task
            return previous
        }
        previous?.cancel()
        sync.addTask(task)
    }
}

extension MattermostAccountSync {
    func registerVoIPDevice(token: Data) async {
        // After the bootstrap: the server is reachable then.
        await self.waitUntilBootstrapped()
        if Task.isCancelled {
            return
        }
        let environment: RelayVoIPEnvironment = MattermostPushDevice.currentEnvironment() == .production ? .production : .sandbox
        let hexToken = MattermostPushDevice.hexToken(token)
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        let deviceId = self.relayCallsDeviceId
        let session = MattermostPushRegistrationRecord.sessionTag(token: self.client.token ?? "")
        let registration = [session, deviceId, environment.rawValue, MattermostPushRegistrationRecord.sessionTag(token: hexToken), bundleId, MattermostAccountSync.appVersion].joined(separator: "|")
        let now = Date().timeIntervalSince1970
        if let previous = self.store.cursor(MattermostSync.relayVoIPRegistrationCursor) {
            let parts = previous.components(separatedBy: "@")
            if parts.count == 2, parts[0] == registration, let registeredAt = Double(parts[1]), now - registeredAt < 7 * 24 * 60 * 60 {
                MMLog.log("calls: account \(self.account.id.int64): VoIP token already registered")
                return
            }
        }
        let client = self.relayCallsClient()
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await client.registerVoIPDevice(deviceId: deviceId, token: hexToken, environment: environment, bundleId: bundleId)
                self.store.setCursor(MattermostSync.relayVoIPRegistrationCursor, registration + "@" + String(Date().timeIntervalSince1970))
                MMLog.log("calls: account \(self.account.id.int64): registered VoIP token \(hexToken.prefix(8))… (\(environment.rawValue))")
                return
            } catch let error as RelayCallsError {
                // The plugin answered: missing (`404`, version 1 or not installed) or refused. Not retried.
                MMLog.log("calls: account \(self.account.id.int64): VoIP registration refused (\(error.statusCode.map { String($0) } ?? "no status")): \(error.localizedDescription)")
                return
            } catch {
                attempt += 1
                if attempt > 8 {
                    MMLog.log("calls: account \(self.account.id.int64): VoIP registration failed: \(error)")
                    return
                }
                let delay = min(60.0, pow(2.0, Double(attempt)))
                MMLog.log("calls: account \(self.account.id.int64): VoIP registration failed (\(error)); retrying in \(Int(delay)) s")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
}
