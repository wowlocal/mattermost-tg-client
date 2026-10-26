import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

#if DEBUG // MATTERMOST: debug builds only; release builds compile none of this file (Phase 4A)

// Debug only (Phase 3C): lookups for the debug remote's search commands (TelegramUI `RelayDebugSearch.swift`).
public extension MattermostSync {
    /// The peer of a user by username (fetched and written when not known yet).
    static func debugUserPeerId(accountId: AccountRecordId, username: String) -> PeerId? {
        #if DEBUG
        guard let sync = self.sync(accountId: accountId) else {
            return nil
        }
        let name = username.hasPrefix("@") ? String(username.dropFirst()) : username
        guard let userId = sync.state.with({ $0.userIdByUsername[name.lowercased()] }) else {
            return nil
        }
        return sync.userPeerId(userId)
        #else
        return nil
        #endif
    }
}
#endif
