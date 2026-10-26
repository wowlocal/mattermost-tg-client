import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// The outcome of an interactive message action, for the chat screen to show.
public enum MattermostPostActionResult {
    /// The server accepted the action; the integration's update (if any) arrives as a post edit.
    case done
    /// The integration answered with an ephemeral message ("only visible to you").
    case message(author: String, text: String)
    /// The server refused or the integration failed.
    case failed(String)
}

/// Interactive message attachments (buttons and menus, `AttachmentConverter`): the chat screen routes a
/// tap on such a callback button here instead of Telegram's bot callback query (`ChatController`'s
/// `requestMessageActionCallback`, `MattermostPostActions.swift` in TelegramUI).
public enum MattermostPostActions {
    /// The Mattermost action of a callback button's data, or nil for any other button.
    public static func action(data: MemoryBuffer?) -> MattermostPostActionData? {
        return MattermostPostActionData.decode(data)
    }

    /// A menu's options: its static options, or the known users or channels for dynamic menus
    /// (`data_source`), as Mattermost's own clients offer them.
    public static func options(accountId: AccountRecordId, action: MattermostPostActionData) -> [MattermostPostActionData.Option] {
        guard let sync = MattermostSync.sync(accountId: accountId) else {
            return action.options
        }
        switch action.dataSource {
        case "users":
            return sync.state.with { state in
                return state.users.values.filter { $0.deleteAt == 0 && !$0.isBot }.sorted(by: { PeerConverter.displayName($0).lowercased() < PeerConverter.displayName($1).lowercased() }).map { user in
                    return MattermostPostActionData.Option(text: "\(PeerConverter.displayName(user)) (@\(user.username))", value: user.id)
                }
            }
        case "channels":
            return sync.state.with { state in
                return state.channels.values.filter { $0.kind == .channel && $0.channel.type != .groupMessage && !$0.channel.isArchived }.sorted(by: { $0.channel.displayName.lowercased() < $1.channel.displayName.lowercased() }).map { channelState in
                    return MattermostPostActionData.Option(text: channelState.channel.displayName.isEmpty ? channelState.channel.name : channelState.channel.displayName, value: channelState.channel.id)
                }
            }
        default:
            return action.options
        }
    }

    /// `POST /posts/{post}/actions/{action}` for the post of `messageId` (with the chosen menu option).
    /// Waits briefly for the integration's ephemeral answer so it can be shown with the result; a later one
    /// is shown as a notice.
    public static func perform(accountId: AccountRecordId, messageId: MessageId, action: MattermostPostActionData, selectedOption: String?) -> Signal<MattermostPostActionResult, NoError> {
        return Signal { subscriber in
            let task = Task {
                guard let sync = MattermostSync.sync(accountId: accountId) else {
                    subscriber.putNext(.failed("Not connected to a Mattermost server."))
                    subscriber.putCompletion()
                    return
                }
                let result = await sync.performPostAction(messageId: messageId, action: action, selectedOption: selectedOption)
                subscriber.putNext(result)
                subscriber.putCompletion()
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }
}

/// Ephemeral messages the server sends while an action waits for its answer (per account and channel).
final class PostActionWaiters {
    static let shared = PostActionWaiters()

    private struct Key: Hashable {
        var accountId: AccountRecordId
        var channelId: String
    }

    private let waiters = MMLocked<[Key: [UUID: (Post) -> Void]]>([:])

    func add(accountId: AccountRecordId, channelId: String, _ handler: @escaping (Post) -> Void) -> UUID {
        let id = UUID()
        self.waiters.with { $0[Key(accountId: accountId, channelId: channelId), default: [:]][id] = handler }
        return id
    }

    func remove(accountId: AccountRecordId, channelId: String, id: UUID) {
        self.waiters.with { _ = $0[Key(accountId: accountId, channelId: channelId)]?.removeValue(forKey: id) }
    }

    /// Hands the post to the waiters of its channel; false when nobody waits.
    func deliver(accountId: AccountRecordId, post: Post) -> Bool {
        let handlers = self.waiters.with { waiters -> [(Post) -> Void] in
            let key = Key(accountId: accountId, channelId: post.channelId)
            let handlers = Array((waiters[key] ?? [:]).values)
            waiters[key] = nil
            return handlers
        }
        for handler in handlers {
            handler(post)
        }
        return !handlers.isEmpty
    }
}

extension MattermostAccountSync {
    func performPostAction(messageId: MessageId, action: MattermostPostActionData, selectedOption: String?) async -> MattermostPostActionResult {
        guard let reference = self.postReference(for: messageId) else {
            return .failed("This message isn't on the server yet.")
        }
        let answer = MMLocked<Post?>(nil)
        let waiter = PostActionWaiters.shared.add(accountId: self.account.id, channelId: reference.channelId, { post in
            answer.with { $0 = post }
        })
        defer {
            PostActionWaiters.shared.remove(accountId: self.account.id, channelId: reference.channelId, id: waiter)
        }
        do {
            let response = try await self.client.performPostAction(postId: reference.postId, actionId: action.actionId, selectedOption: selectedOption, cookie: action.cookie.isEmpty ? nil : action.cookie)
            MMLog.log("action: \(action.actionId) on \(reference.postId)\(selectedOption.map { " (\($0))" } ?? "") → \(response.status.isEmpty ? "ok" : response.status)\(response.triggerId.isEmpty ? "" : ", trigger \(response.triggerId)")")
        } catch {
            MMLog.log("action: \(action.actionId) on \(reference.postId) failed: \(error)")
            return .failed(describeError(error))
        }
        // The integration's ephemeral answer, if any, comes over the WebSocket right after the response.
        for _ in 0 ..< 15 {
            if answer.current != nil {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if let post = answer.current {
            return .message(author: self.ephemeralAuthorName(post), text: MattermostMarkdown.parse(post.message).text)
        }
        return .done
    }

    /// `ephemeral_message`: a message only this user sees (an integration's answer, a slash command's
    /// output). It goes to a waiting action, or is shown as a notice.
    func applyEphemeral(_ post: Post) {
        if PostActionWaiters.shared.deliver(accountId: self.account.id, post: post) {
            MMLog.log("live: ephemeral message in \(post.channelId) answers an action")
            return
        }
        let text = MattermostMarkdown.parse(post.message).text
        if text.isEmpty {
            return
        }
        MMLog.log("live: ephemeral message in \(post.channelId)")
        self.notice("\(self.ephemeralAuthorName(post)) (only visible to you): \(text)")
    }

    private func ephemeralAuthorName(_ post: Post) -> String {
        if let override = MattermostAccountSync.authorOverride(post), !override.username.isEmpty {
            return override.username
        }
        if let user = self.state.with({ $0.users[post.userId] }) {
            return PeerConverter.displayName(user)
        }
        return "System"
    }
}
