import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// What the chat screen does after a slash command ran.
public enum MattermostCommandResult: Equatable {
    /// Done. Output arrives on its own: `in_channel` responses as posts, `ephemeral` ones as local messages
    /// ("only visible to you"), a dialog as `open_dialog`.
    case done
    /// The command's `goto_location` is a chat (`/join ~channel`, `/msg @user`).
    case openChat(PeerId)
    /// The command's `goto_location` is another page.
    case openURL(String)
    /// The server has no such command (the text may still be posted as a message).
    case notFound(String)
    case failed(String)
}

extension MattermostComposer {
    /// Whether sending `text` runs a command (`SlashCommand.parse`): a leading `/` and a first word without
    /// another slash, so paths such as `/usr/bin` are posted as text.
    public static func isSlashCommand(_ text: String) -> Bool {
        return SlashCommand.parse(text) != nil
    }

    /// `POST /commands/execute` in the chat (`threadId`: the thread view's root; `replyToMessageId`: the message
    /// the composer replies to, whose thread the command runs in).
    public static func executeCommand(accountId: AccountRecordId, peerId: PeerId, threadId: Int64?, replyToMessageId: MessageId?, text: String) -> Signal<MattermostCommandResult, NoError> {
        return Signal { subscriber in
            let task = Task {
                guard let sync = MattermostSync.sync(accountId: accountId) else {
                    subscriber.putNext(.failed("Not connected to a Mattermost server."))
                    subscriber.putCompletion()
                    return
                }
                let result = await sync.executeCommand(peerId: peerId, threadId: threadId, replyToMessageId: replyToMessageId, text: text)
                subscriber.putNext(result)
                subscriber.putCompletion()
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }
}

extension MattermostAccountSync {
    func executeCommand(peerId: PeerId, threadId: Int64?, replyToMessageId: MessageId?, text: String) async -> MattermostCommandResult {
        await self.waitUntilBootstrapped()
        guard let channelId = self.channelId(forPeerId: peerId), let channelState = self.channelState(channelId) else {
            return .failed("This chat isn't on the server.")
        }
        var rootId: String?
        if let threadId {
            rootId = self.postReference(for: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(clamping: threadId)))?.postId
        } else if let replyToMessageId {
            rootId = await self.postbox.mmTransaction { transaction in
                return self.threadRootPostId(replyTarget: replyToMessageId, transaction: transaction)
            }
        }
        let teamId = self.teamId(for: channelState)
        self.noteInteraction(channelId: channelId, teamId: teamId)
        do {
            let response = try await self.client.executeCommand(text, channelId: channelId, teamId: teamId.isEmpty ? nil : teamId, rootId: rootId)
            MMLog.log("command: \(SlashCommand.parse(text)?.trigger ?? "?") in \(channelId)\(rootId.map { " (thread \($0))" } ?? "") → \(response.responseType.isEmpty ? "ok" : response.responseType)\(response.triggerId.isEmpty ? "" : ", trigger \(response.triggerId)")\(response.gotoLocation.isEmpty ? "" : ", goto \(response.gotoLocation)")")
            if !response.gotoLocation.isEmpty {
                return await self.resolveGotoLocation(response.gotoLocation)
            }
            return .done
        } catch {
            MMLog.log("command: \(SlashCommand.parse(text)?.trigger ?? "?") in \(channelId) failed: \(error)")
            if let error = error as? MattermostError, error.appError?.id == SlashCommand.notFoundErrorId {
                return .notFound(describeError(error))
            }
            return .failed(describeError(error))
        }
    }

    /// A `goto_location` on this server (`<site>/<team>/channels/<name>`, `<site>/<team>/messages/@<user>`)
    /// as a chat, waiting briefly for a channel that the command just joined to arrive; anything else as a URL.
    func resolveGotoLocation(_ location: String) async -> MattermostCommandResult {
        var path = location
        if let url = URL(string: location), let host = url.host {
            guard let server = URL(string: self.server.url), server.host == host else {
                return .openURL(location)
            }
            path = url.path
        }
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 3 else {
            return location.hasPrefix("http") ? .openURL(location) : .done
        }
        let teamName = components[components.count - 3]
        let kind = components[components.count - 2]
        let name = components[components.count - 1]
        for _ in 0 ..< 30 {
            if let peerId = self.peerId(teamName: teamName, kind: kind, name: name) {
                return .openChat(peerId)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return location.hasPrefix("http") ? .openURL(location) : .done
    }

    private func peerId(teamName: String, kind: String, name: String) -> PeerId? {
        return self.state.with { state -> PeerId? in
            switch kind {
            case "channels":
                let teamId = state.teams.first(where: { $0.name == teamName })?.id
                return state.channels.values.first(where: { $0.channel.name == name && ($0.teamId == teamId || $0.channel.type == .directMessage || $0.channel.type == .groupMessage) })?.peerId
            case "messages":
                let username = name.hasPrefix("@") ? String(name.dropFirst()) : name
                guard let userId = state.userIdByUsername[username.lowercased()] else {
                    return nil
                }
                return state.channels.values.first(where: { $0.kind == .direct && $0.channel.directMessagePartnerId(myUserId: self.ownUserId) == userId })?.peerId
            default:
                return nil
            }
        }
    }
}
