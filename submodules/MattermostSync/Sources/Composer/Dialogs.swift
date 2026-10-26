import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// An interactive dialog to show (`open_dialog`), with the chat it belongs to.
public struct MattermostDialogRequest: Equatable {
    public let accountId: AccountRecordId
    /// Unique per process (a dialog may be opened twice with the same trigger).
    public let id: Int64
    public let request: OpenDialogRequest
    /// The chat of the command or button that opened it (the submission carries it).
    public let channelId: String
    public let teamId: String
}

/// The server's answer to a dialog submission.
public enum MattermostDialogSubmitResult: Equatable {
    case done
    /// The integration refused the values: a general error and/or errors per element name.
    case errors(general: String?, fields: [String: String])
    case failed(String)
}

/// Interactive dialogs: the WebSocket's `open_dialog` events for the app to show (MattermostUI's dialog screen),
/// and their submission (`POST /actions/dialogs/submit`).
extension MattermostComposer {
    public static func dialogs(accountId: AccountRecordId) -> Signal<MattermostDialogRequest, NoError> {
        return MattermostSync.dialogPipe(accountId: accountId).signal()
    }

    public static func submitDialog(_ dialog: MattermostDialogRequest, values: [String: JSONValue]) -> Signal<MattermostDialogSubmitResult, NoError> {
        return self.dialogSignal(dialog) { sync in
            return await sync.submitDialog(dialog, values: values, cancelled: false)
        }
    }

    /// Cancel: tells the integration when the dialog asks for it (`notify_on_cancel`).
    public static func cancelDialog(_ dialog: MattermostDialogRequest) {
        guard dialog.request.dialog.notifyOnCancel else {
            return
        }
        let _ = self.dialogSignal(dialog) { sync in
            return await sync.submitDialog(dialog, values: [:], cancelled: true)
        }.start()
    }

    /// The choices of a `users` or `channels` select: users of the dialog's team matching `query`, or the
    /// team's channels (Mattermost's clients search the same way).
    public static func dialogOptions(_ dialog: MattermostDialogRequest, dataSource: String, query: String) -> Signal<[DialogOption], NoError> {
        return self.signal(accountId: dialog.accountId, empty: []) { sync in
            return await sync.dialogOptions(teamId: dialog.teamId, dataSource: dataSource, query: query)
        }
    }

    private static func dialogSignal(_ dialog: MattermostDialogRequest, _ body: @escaping (MattermostAccountSync) async -> MattermostDialogSubmitResult) -> Signal<MattermostDialogSubmitResult, NoError> {
        return Signal { subscriber in
            let task = Task {
                guard let sync = MattermostSync.sync(accountId: dialog.accountId) else {
                    subscriber.putNext(.failed("Not connected to a Mattermost server."))
                    subscriber.putCompletion()
                    return
                }
                subscriber.putNext(await body(sync))
                subscriber.putCompletion()
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }
}

extension MattermostSync {
    private static let dialogPipes = MMLocked<[AccountRecordId: ValuePipe<MattermostDialogRequest>]>([:])
    private static let nextDialogId = MMLocked<Int64>(1)

    static func dialogPipe(accountId: AccountRecordId) -> ValuePipe<MattermostDialogRequest> {
        return self.dialogPipes.with { pipes in
            if let pipe = pipes[accountId] {
                return pipe
            }
            let pipe = ValuePipe<MattermostDialogRequest>()
            pipes[accountId] = pipe
            return pipe
        }
    }

    static func makeDialogId() -> Int64 {
        return self.nextDialogId.with { value in
            let id = value
            value += 1
            return id
        }
    }
}

/// The chat of the user's last command or button tap per account: an `open_dialog` that follows belongs to it.
private let lastInteractions = MMLocked<[AccountRecordId: (channelId: String, teamId: String, time: Double)]>([:])

extension MattermostAccountSync {
    func noteInteraction(channelId: String, teamId: String) {
        lastInteractions.with { $0[self.account.id] = (channelId, teamId, CFAbsoluteTimeGetCurrent()) }
    }

    /// `open_dialog`: hands the dialog to the app with the chat of the interaction that opened it.
    func applyOpenDialog(_ request: OpenDialogRequest) {
        let interaction = lastInteractions.with { $0[self.account.id] }
        var channelId = ""
        var teamId = ""
        if let interaction, CFAbsoluteTimeGetCurrent() - interaction.time < 10 * 60 {
            channelId = interaction.channelId
            teamId = interaction.teamId
        }
        if teamId.isEmpty {
            teamId = self.state.with { $0.teams.first?.id ?? "" }
        }
        MMLog.log("live: open_dialog \"\(request.dialog.title)\" (\(request.dialog.elements.count) elements, callback \(request.dialog.callbackId)) for \(channelId.isEmpty ? "no chat" : channelId)")
        MattermostSync.dialogPipe(accountId: self.account.id).putNext(MattermostDialogRequest(accountId: self.account.id, id: MattermostSync.makeDialogId(), request: request, channelId: channelId, teamId: teamId))
    }

    func submitDialog(_ dialog: MattermostDialogRequest, values: [String: JSONValue], cancelled: Bool) async -> MattermostDialogSubmitResult {
        let submission = DialogSubmission(
            url: dialog.request.url,
            callbackId: dialog.request.dialog.callbackId,
            state: dialog.request.dialog.state,
            userId: self.ownUserId,
            channelId: dialog.channelId,
            teamId: dialog.teamId,
            submission: values,
            cancelled: cancelled
        )
        do {
            let response = try await self.client.submitDialog(submission)
            MMLog.log("dialog: \(cancelled ? "cancel" : "submit") \(dialog.request.dialog.callbackId) → \(response.error.isEmpty && response.errors.isEmpty ? "ok" : "errors \(response.errors.keys.sorted()) \(response.error)")")
            if !response.error.isEmpty || !response.errors.isEmpty {
                return .errors(general: response.error.isEmpty ? nil : response.error, fields: response.errors)
            }
            return .done
        } catch {
            MMLog.log("dialog: \(cancelled ? "cancel" : "submit") \(dialog.request.dialog.callbackId) failed: \(error)")
            return .failed(describeError(error))
        }
    }

    func dialogOptions(teamId: String, dataSource: String, query: String) async -> [DialogOption] {
        let teamId = teamId.isEmpty ? (self.state.with { $0.teams.first?.id ?? "" }) : teamId
        switch dataSource {
        case "users":
            guard let found = try? await self.client.autocompleteUsers(name: query.lowercased(), teamId: teamId.isEmpty ? nil : teamId, limit: 50) else {
                return []
            }
            return (found.users + found.outOfChannel).filter { $0.deleteAt == 0 }.map { user in
                DialogOption(text: "\(PeerConverter.displayName(user)) (@\(user.username))", value: user.id)
            }
        case "channels":
            guard !teamId.isEmpty, let channels = try? await self.client.autocompleteChannels(teamId: teamId, name: query.lowercased()) else {
                return []
            }
            return channels.filter { !$0.isArchived && ($0.type == .publicChannel || $0.type == .privateChannel) }.map { channel in
                DialogOption(text: channel.displayName.isEmpty ? channel.name : channel.displayName, value: channel.id)
            }
        default:
            return []
        }
    }
}
