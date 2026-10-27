import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ChatContextQuery
import ChatInterfaceState
import AlertUI
import PresentationDataUtils
import MattermostSync

// MATTERMOST: the composer's autocomplete and slash commands on a Mattermost server, in Telegram's own
// suggestion panels (Phase 3D):
// - `@name` → the mention panel: channel members, then `@here`/`@channel`/`@all` (when the user may notify the
//   channel), then the team's other members (`GET /users/autocomplete`); a pick inserts `@username`;
// - `~name` → the mention panel with channels of the team (`GET /teams/{id}/channels/autocomplete`), the user's
//   first; a pick inserts `~channel-name`;
// - `:name` → the emoji strip: built-in emoji (`EmojiTable`) and the server's custom emoji; a pick inserts the
//   Unicode emoji or `:name:`;
// - `/…` on the first line → the command panel (`GET /teams/{id}/commands/autocomplete_suggestions`, sub-commands
//   included); a tap inserts the command line.
// Sending a slash command runs it on the server (`mattermostRunSlashCommand`, called from `sendCurrentMessage`).

/// Synthetic peers of the suggestion panels (never stored): `@here`/`@channel`/`@all` and one per command word.
private func mattermostSuggestionUser(index: Int64, firstName: String, username: String?) -> TelegramUser {
    return TelegramUser(
        id: MattermostPeerIds.userPeerId(MattermostPeerIds.suggestionPeerIdValue(index)),
        accessHash: nil,
        firstName: firstName,
        lastName: nil,
        username: username,
        phone: nil,
        photo: [],
        botInfo: nil,
        restrictionInfo: nil,
        flags: [],
        emojiStatus: nil,
        usernames: [],
        storiesHidden: nil,
        nameColor: nil,
        backgroundEmojiId: nil,
        profileColor: nil,
        profileBackgroundEmojiId: nil,
        subscriberCount: nil,
        verificationIconFileId: nil
    )
}

private func mattermostSpecialMentionPeer(_ name: String, strings: PresentationStrings) -> EnginePeer {
    let title: String
    let index: Int64
    switch name {
    case "here":
        title = strings.Relay_Mention_Here
        index = 1
    case "all":
        title = strings.Relay_Mention_All
        index = 2
    default:
        title = strings.Relay_Mention_Channel
        index = 3
    }
    return .user(mattermostSuggestionUser(index: index, firstName: title, username: name))
}

/// A stable synthetic peer per command word (its avatar shows the word's initial).
private func mattermostCommandPeer(_ complete: String) -> EnginePeer {
    let word = String(complete.split(separator: " ").first ?? "")
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in word.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return .user(mattermostSuggestionUser(index: 1024 + Int64(hash % 500_000), firstName: word, username: nil))
}

func mattermostContextQueryResult(context: AccountContext, chatLocation: ChatLocation, inputQuery: ChatPresentationInputQuery, previousQuery: ChatPresentationInputQuery?) -> Signal<(ChatPresentationInputQueryResult?) -> ChatPresentationInputQueryResult?, ChatContextQueryError>? {
    guard MattermostBackend.isEnabled, let peerId = chatLocation.peerId else {
        return nil
    }
    let accountId = context.account.id
    switch inputQuery {
    case let .mention(query, types):
        // Keep the previous results on screen while the next ones load.
        var initial: Signal<(ChatPresentationInputQueryResult?) -> ChatPresentationInputQueryResult?, ChatContextQueryError> = .complete()
        if case .mention = previousQuery {
        } else {
            initial = .single({ _ in return .mentions([]) })
        }
        if types.contains(.mattermostChannels) {
            return initial |> then(MattermostComposer.channelSuggestions(accountId: accountId, peerId: peerId, query: query)
            |> map { peers -> (ChatPresentationInputQueryResult?) -> ChatPresentationInputQueryResult? in
                return { _ in return .mentions(peers) }
            }
            |> castError(ChatContextQueryError.self))
        }
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        return initial |> then(MattermostComposer.mentionSuggestions(accountId: accountId, peerId: peerId, query: query)
        |> map { suggestions -> (ChatPresentationInputQueryResult?) -> ChatPresentationInputQueryResult? in
            let peers = suggestions.map { suggestion -> EnginePeer in
                switch suggestion {
                case let .user(peer, _):
                    return peer
                case let .special(name):
                    return mattermostSpecialMentionPeer(name, strings: strings)
                }
            }
            return { _ in return .mentions(peers) }
        }
        |> castError(ChatContextQueryError.self))
    case let .command(query):
        let empty = ChatInputQueryCommandsResult(commands: [], accountPeer: nil, hasShortcuts: false, query: "")
        var initial: Signal<(ChatPresentationInputQueryResult?) -> ChatPresentationInputQueryResult?, ChatContextQueryError> = .complete()
        if case .command = previousQuery {
        } else {
            initial = .single({ _ in return .commands(empty) })
        }
        return initial |> then(MattermostComposer.commandSuggestions(accountId: accountId, peerId: peerId, threadId: chatLocation.threadId, userInput: query)
        |> map { suggestions -> (ChatPresentationInputQueryResult?) -> ChatPresentationInputQueryResult? in
            let commands = suggestions.map { suggestion -> ChatInputTextCommand in
                let description = suggestion.hint.isEmpty ? suggestion.description : (suggestion.description.isEmpty ? suggestion.hint : "\(suggestion.hint)  \(suggestion.description)")
                return .command(PeerCommand(mattermostPeer: mattermostCommandPeer(suggestion.complete), command: BotCommand(text: suggestion.complete, description: description)))
            }
            return { _ in return .commands(ChatInputQueryCommandsResult(commands: commands, accountPeer: nil, hasShortcuts: false, query: query)) }
        }
        |> castError(ChatContextQueryError.self))
    case let .emojiSearch(query, _, range):
        return MattermostComposer.emojiSuggestions(accountId: accountId, query: query)
        |> map { results -> (ChatPresentationInputQueryResult?) -> ChatPresentationInputQueryResult? in
            return { _ in return .emojis(results, range) }
        }
        |> castError(ChatContextQueryError.self)
    default:
        return nil
    }
}

extension ChatControllerNode {
    /// MATTERMOST: sending a slash command (`MattermostComposer.isSlashCommand`) runs it on the server
    /// (`POST /commands/execute`) instead of posting it. The composer clears as for a sent message; the
    /// command's visible output arrives as posts, local "only visible to you" messages or a dialog. An unknown
    /// command can still be posted as text; other errors show an alert and put the text back.
    func mattermostRunSlashCommand(text: String, controller: ChatControllerImpl?, completion: @escaping () -> Void) -> Bool {
        guard MattermostBackend.isEnabled, MattermostComposer.isSlashCommand(text), let peerId = self.chatLocation.peerId else {
            return false
        }
        let threadId = self.chatLocation.threadId
        let replySubject = self.chatPresentationInterfaceState.interfaceState.replyMessageSubject
        let context = self.context
        weak let controller = controller

        self.collapseInput()
        if let textInputPanelNode = self.textInputPanelNode {
            textInputPanelNode.text = ""
        }
        self.requestUpdateChatInterfaceState(.immediate, true, { state in
            return state.withUpdatedReplyMessageSubject(nil).withUpdatedComposeDisableUrlPreviews([])
        })
        completion()

        let restoreText: () -> Void = { [weak self] in
            guard let self else {
                return
            }
            self.interfaceInteraction?.updateTextInputStateAndMode { current, inputMode in
                if current.inputText.length != 0 {
                    return (current, inputMode)
                }
                return (ChatTextInputState(inputText: NSAttributedString(string: text)), inputMode)
            }
        }

        let _ = (MattermostComposer.executeCommand(accountId: context.account.id, peerId: peerId, threadId: threadId, replyToMessageId: replySubject?.messageId, text: text)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] result in
            guard let self, let controller else {
                return
            }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            switch result {
            case .done:
                break
            case let .openChat(chatPeerId):
                let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: chatPeerId))
                |> deliverOnMainQueue).startStandalone(next: { [weak controller] peer in
                    guard let peer, let navigationController = controller?.navigationController as? NavigationController else {
                        return
                    }
                    context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
                })
            case let .openURL(url):
                context.sharedContext.openExternalUrl(context: context, urlContext: .generic, url: url, forceExternal: false, presentationData: presentationData, navigationController: controller.navigationController as? NavigationController, dismissInput: {})
            case let .notFound(message):
                controller.present(textAlertController(context: context, title: presentationData.strings.Relay_Command_NotFoundTitle, text: presentationData.strings.Relay_Command_NotFoundText(message).string, actions: [
                    TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {
                        restoreText()
                    }),
                    TextAlertAction(type: .defaultAction, title: presentationData.strings.Relay_Command_SendAsMessage, action: { [weak self] in
                        self?.sendMessages([.message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: threadId, replyToMessageId: replySubject?.subjectModel, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])], nil, nil, nil, false, false)
                    })
                ]), in: .window(.root))
            case let .failed(message):
                restoreText()
                controller.present(textAlertController(context: context, title: nil, text: message, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
            }
        })
        return true
    }
}

/// MATTERMOST: a message that passed the `@channel` confirmation (4H), sent again without asking.
private var mattermostConfirmedChannelMentionText: String?

extension ChatControllerNode {
    /// MATTERMOST: `@all`, `@channel` or `@here` in a channel with more than 5 members asks first, as Mattermost's
    /// clients do ("Confirm sending notifications to entire channel", with the number of people and, when members
    /// have them, time zones). The check needs the server (member count, the user's `use_channel_mentions`), so the
    /// send stops here and `resend` runs it again once confirmed; the composer keeps the text meanwhile. Messages
    /// without such a mention are sent at once.
    func mattermostConfirmChannelWideMention(text: String, controller: ChatControllerImpl?, resend: @escaping () -> Void) -> Bool {
        guard MattermostBackend.isEnabled, let peerId = self.chatLocation.peerId, MattermostComposer.containsChannelWideMention(text) else {
            return false
        }
        if mattermostConfirmedChannelMentionText == text {
            mattermostConfirmedChannelMentionText = nil
            return false
        }
        let context = self.context
        weak let controller = controller
        let _ = (MattermostComposer.channelMentionConfirmation(accountId: context.account.id, peerId: peerId, text: text)
        |> deliverOnMainQueue).startStandalone(next: { confirmation in
            guard let confirmation else {
                mattermostConfirmedChannelMentionText = text
                resend()
                return
            }
            guard let controller else {
                return
            }
            let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
            let people = "\(confirmation.memberCount)"
            let message: String
            if confirmation.timezoneCount > 0 {
                let zones = confirmation.timezoneCount == 1 ? strings.Relay_ChannelMention_Timezone : strings.Relay_ChannelMention_Timezones("\(confirmation.timezoneCount)").string
                message = confirmation.isHereOnly ? strings.Relay_ChannelMention_HereTimezones(people, zones).string : strings.Relay_ChannelMention_AllTimezones(people, zones).string
            } else {
                message = confirmation.isHereOnly ? strings.Relay_ChannelMention_Here(people).string : strings.Relay_ChannelMention_All(people).string
            }
            controller.present(textAlertController(context: context, title: strings.Relay_ChannelMention_Title, text: message, actions: [
                TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
                TextAlertAction(type: .defaultAction, title: strings.Relay_ChannelMention_Confirm, action: {
                    mattermostConfirmedChannelMentionText = text
                    resend()
                })
            ]), in: .window(.root))
        })
        return true
    }
}
