import Foundation
import Postbox
import TelegramCore
import MattermostKit

public struct MattermostCallTarget: Sendable {
    public let serverURL: URL
    public let sessionToken: String
    public let channelId: String
    public let title: String
}

extension MattermostSync {
    public static func callTarget(accountId: AccountRecordId, peerId: PeerId) async throws -> MattermostCallTarget {
        guard let sync = self.sync(accountId: accountId), peerId != sync.ownPeerId else {
            throw MattermostDirectoryError.server("This conversation is not available for calls.")
        }
        if sync.channelId(forPeerId: peerId) == nil, sync.userId(forPeerId: peerId) != nil {
            _ = try await sync.openDirectMessage(userPeerId: peerId)
        }
        guard let channelId = sync.channelId(forPeerId: peerId), let channel = sync.channelState(channelId),
              !channel.channel.isArchived, let token = sync.client.token else {
            throw MattermostDirectoryError.server("This conversation is not ready for calls. Please try again.")
        }
        let title: String
        if let userId = channel.channel.directMessagePartnerId(myUserId: sync.ownUserId), let user = sync.state.with({ $0.users[userId] }) {
            let name = (user.firstName + " " + user.lastName).trimmingCharacters(in: .whitespaces)
            title = name.isEmpty ? user.username : name
        } else {
            title = channel.channel.displayName.isEmpty ? "Voice call" : channel.channel.displayName
        }
        return MattermostCallTarget(serverURL: sync.client.serverURL, sessionToken: token, channelId: channelId, title: title)
    }
}
