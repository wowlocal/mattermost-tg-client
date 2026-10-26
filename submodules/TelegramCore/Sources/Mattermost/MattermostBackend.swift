import Foundation
import SwiftSignalKit
import Postbox

// MATTERMOST: process-wide switch of the Mattermost fork ("Relay").
//
// While it is set, TelegramCore never talks to Telegram:
// - every `Network` runs on `NullNetworkEngine` (`resolveNetworkEngine`), which parks requests forever
//   and reports the main session connected; network telemetry does not record;
// - `Account.networkState` reads "updating" from `Account.externalIsUpdating` instead of the MTProto
//   state manager, which never starts;
// - `Account` does not start Telegram's hole management (`managedServiceViews`); MattermostSync fills
//   holes instead.
// TelegramUI additionally skips `Account.resetStateManagement()` and Telegram's phone login.
//
// Every guarded hook in upstream code is marked `// MATTERMOST:`.
public enum MattermostBackend {
    /// Set once at launch, before the first account is created. Defaults to true in this fork.
    public static var isEnabled: Bool = true

    /// Opens the re-login for the current account when its session expired (`Account.mattermostSessionExpired`):
    /// the chat list title "Session Expired" calls it when tapped. Installed by MattermostUI (main app).
    public static var requestRelogin: (() -> Void)?

    // MARK: Collapsed reply threads

    private static let collapsedThreadsLock = NSLock()
    private static var collapsedThreadsAccounts = Set<PeerId>()
    private static let collapsedThreadsPromise = ValuePromise<Set<PeerId>>(Set(), ignoreRepeated: true)

    /// Collapsed reply threads on or off for an account (keyed by the account's own peer id, which is distinct per
    /// account). Set by MattermostSync from the server config and the user's preference. While on, a chat's main
    /// history shows root posts only (`AccountViewTracker`, `MessageTags.mattermostRootPost`).
    public static func setCollapsedThreads(_ isOn: Bool, accountPeerId: PeerId) {
        self.collapsedThreadsLock.lock()
        if isOn {
            self.collapsedThreadsAccounts.insert(accountPeerId)
        } else {
            self.collapsedThreadsAccounts.remove(accountPeerId)
        }
        let value = self.collapsedThreadsAccounts
        self.collapsedThreadsLock.unlock()
        self.collapsedThreadsPromise.set(value)
    }

    public static func isCollapsedThreads(accountPeerId: PeerId) -> Bool {
        if !self.isEnabled {
            return false
        }
        self.collapsedThreadsLock.lock()
        defer {
            self.collapsedThreadsLock.unlock()
        }
        return self.collapsedThreadsAccounts.contains(accountPeerId)
    }

    public static func collapsedThreadsUpdates(accountPeerId: PeerId) -> Signal<Bool, NoError> {
        return self.collapsedThreadsPromise.get()
        |> map { accounts -> Bool in
            return accounts.contains(accountPeerId)
        }
        |> distinctUntilChanged
    }

    /// The tag a chat's main history is filtered by: root posts only while collapsed reply threads are on, for
    /// channels, group messages and DMs (Saved Messages keep their replies inline).
    public static func mainHistoryTag(accountPeerId: PeerId, peerId: PeerId) -> MessageTags? {
        guard self.isEnabled, peerId != accountPeerId, peerId.namespace == Namespaces.Peer.CloudChannel || peerId.namespace == Namespaces.Peer.CloudUser else {
            return nil
        }
        return self.isCollapsedThreads(accountPeerId: accountPeerId) ? .mattermostRootPost : nil
    }
}
