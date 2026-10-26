import Foundation
import Postbox
import TelegramCore
import MattermostSyncCore

/// One signed-in account as an exported diagnostics bundle describes it (Phase 4G): the server and its version,
/// whether the account syncs. No user id, username, token or anything the account holds.
public struct MattermostDiagnosticsAccount: Equatable {
    public let accountId: AccountRecordId
    /// The server's address (host, port, path), e.g. `chat.example.com`.
    public let server: String
    public let serverVersion: String?
    public let siteName: String?
    public let isSyncing: Bool
    public let isSessionExpired: Bool
}

extension MattermostSync {
    /// The accounts loaded in this process (the diagnostics export, MattermostUI).
    public static func diagnosticsAccounts() -> [MattermostDiagnosticsAccount] {
        let registry = self.registry.with { $0 }
        return registry.keys.sorted(by: { $0.int64 < $1.int64 }).compactMap { accountId -> MattermostDiagnosticsAccount? in
            guard let registered = registry[accountId] else {
                return nil
            }
            let sync = self.sync(accountId: accountId)
            let server = sync?.store.serverInfo() ?? registered.server
            let address = URL(string: server.url).map(MattermostAccountSetup.hostDisplay) ?? server.url
            return MattermostDiagnosticsAccount(
                accountId: accountId,
                server: address,
                serverVersion: server.version,
                siteName: server.siteName,
                isSyncing: sync != nil,
                isSessionExpired: self.expiredSession(accountId: accountId) != nil
            )
        }
    }
}
