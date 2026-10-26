import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Entry points for TelegramUI.
public enum MattermostSync {
    private static let accounts = MMLocked<[AccountRecordId: MattermostAccountSync]>([:])

    static let userAgent = "Relay/0.1 (iOS; MattermostSync)"

    /// Starts MattermostSync for an account loaded by `SharedAccountContextImpl` (instead of
    /// `Account.resetStateManagement()`). Does nothing for an account without a Mattermost session.
    public static func startAccount(_ account: Account) {
        if self.accounts.with({ $0[account.id] != nil }) {
            return
        }
        let path = MattermostSyncStore.path(accountBasePath: account.basePath)
        let store: MattermostSyncStore
        do {
            store = try MattermostSyncStore(path: path)
        } catch {
            MMLog.log("account \(account.id.int64): cannot open \(path): \(error)")
            return
        }
        guard let server = store.serverInfo(), let url = URL(string: server.url) else {
            MMLog.log("account \(account.id.int64): no Mattermost server in \(path)")
            return
        }
        guard let token = MattermostKeychain.token(accountId: account.id.int64) else {
            MMLog.log("account \(account.id.int64): no session token in the Keychain")
            return
        }
        let client = MattermostClient(serverURL: url, token: token, userAgent: self.userAgent)
        let sync = MattermostAccountSync(account: account, client: client, store: store, server: server)
        self.accounts.with { $0[account.id] = sync }
        sync.start()
    }

    static func sync(accountId: AccountRecordId) -> MattermostAccountSync? {
        return self.accounts.with { $0[accountId] }
    }
}

/// Debug-only login (Spike D, until the MattermostUI login exists): server URL and credentials come from the
/// launch environment, e.g.
/// `SIMCTL_CHILD_RELAY_DEBUG_MM_URL=http://localhost:8065 SIMCTL_CHILD_RELAY_DEBUG_MM_LOGIN=alice
///  SIMCTL_CHILD_RELAY_DEBUG_MM_PASSWORD=… xcrun simctl launch …`.
public enum MattermostDebugLogin {
    private static let started = Atomic<Bool>(value: false)

    /// Called where Telegram would begin its phone login (no primary account). Logs in and creates the
    /// authorized account: account postbox (state + own user), sync store (server, own peer id), Keychain
    /// token, then the account record, which `SharedAccountContextImpl` loads like any other.
    public static func createAccountIfNeeded(accountManager: AccountManager<TelegramAccountManagerTypes>, rootPath: String, encryptionParameters: ValueBoxEncryptionParameters) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard let urlString = environment["RELAY_DEBUG_MM_URL"], let url = URL(string: urlString), let login = environment["RELAY_DEBUG_MM_LOGIN"], let password = environment["RELAY_DEBUG_MM_PASSWORD"] else {
            MMLog.log("debug login: no RELAY_DEBUG_MM_URL / _LOGIN / _PASSWORD in the environment; staying logged out")
            return
        }
        if self.started.swap(true) {
            return
        }
        Task {
            do {
                let client = MattermostClient(serverURL: url, userAgent: MattermostSync.userAgent)
                let result = try await client.login(loginId: login, password: password)
                let id = generateAccountRecordId()
                let basePath = rootPath + "/" + accountRecordIdPathName(id)
                let store = try MattermostSyncStore(path: MattermostSyncStore.path(accountBasePath: basePath))
                let serverURL = url.absoluteString
                let ownIdValue = MattermostPeerIds.ownUserIdValue(serverURL: serverURL, userId: result.user.id)
                store.setServerInfo(MattermostServerInfo(url: serverURL, userId: result.user.id))
                guard store.reserveOwnUserPeer(userId: result.user.id, peerId: ownIdValue) != nil else {
                    MMLog.log("debug login: could not reserve the own peer id")
                    return
                }
                guard MattermostKeychain.setToken(result.token, accountId: id.int64) else {
                    return
                }
                let ownPeerId = MattermostPeerIds.userPeerId(ownIdValue)
                let ownUser = PeerConverter.user(result.user, peerId: ownPeerId)
                MMLog.log("debug login: \(result.user.username) on \(serverURL) → account \(id.int64), own peer \(ownPeerId)")

                let _ = (accountTransaction(rootPath: rootPath, id: id, encryptionParameters: encryptionParameters, isReadOnly: false, transaction: { _, transaction -> Void in
                    transaction.setState(AuthorizedAccountState(isTestingEnvironment: false, masterDatacenterId: 2, peerId: ownPeerId, state: nil, invalidatedChannels: []))
                    updatePeersCustom(transaction: transaction, peers: [ownUser], update: { _, updated in
                        return updated
                    })
                    transaction.updatePeerCachedData(peerIds: [ownPeerId], update: { _, current in
                        return (current as? CachedUserData ?? CachedUserData())
                            .withUpdatedBusinessIntro(nil)
                            .withUpdatedPeerStatusSettings(PeerStatusSettings())
                    })
                    // As Telegram's login does: no device-contact sync (with it on, no chat ever opens).
                    transaction.updatePreferencesEntry(key: PreferencesKeys.contactsSettings, { _ in
                        return PreferencesEntry(ContactsSettings(synchronizeContacts: false))
                    })
                })
                |> `catch` { error -> Signal<Void, NoError> in
                    MMLog.log("debug login: could not open the account postbox: \(error)")
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
                    MMLog.log("debug login: account \(id.int64) created and selected")
                })
            } catch {
                MMLog.log("debug login failed: \(error)")
                let _ = self.started.swap(false)
            }
        }
        #endif
    }
}
