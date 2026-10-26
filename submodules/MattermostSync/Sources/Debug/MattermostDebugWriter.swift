import Foundation
import UIKit
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

#if DEBUG
/// Debug-only driver for the write path (Phase 2A), for verification without UI automation. It calls the
/// same engine entry points the composer, the context menus and the chat list call, never MattermostKit:
///
/// `SIMCTL_CHILD_RELAY_DEBUG_WRITE='<action>;<action>;…'`, fields separated by `|`, `<chat>` as in
/// `RELAY_DEBUG_OPEN_CHAT` (`town-square`, `engineering/town-square`, `dm:bob`, `saved`), `<msg>` one of
/// `last` (newest message), `mine` (my newest), `other` (newest by someone else) or a post id:
///
/// | action | engine call |
/// |---|---|
/// | `send\|<chat>\|<text>` (`**bold**` etc. become entities, like the composer's formatting) | `enqueueMessages` |
/// | `reply\|<chat>\|<msg>\|<text>` | `enqueueMessages` with `replyToMessageId` |
/// | `senduser\|<username>\|<text>` (to the user's peer; creates the DM channel if needed) | `enqueueMessages` |
/// | `image\|<chat>\|<caption>` (a generated 1200×800 JPEG) | `enqueueMessages` with a local `TelegramMediaImage` |
/// | `file\|<chat>\|<file name>\|<content>` | `enqueueMessages` with a local `TelegramMediaFile` |
/// | `album\|<chat>\|<count>\|<caption>` (generated JPEGs, one grouping key) | `enqueueMessages` as the media picker's album |
/// | `files\|<chat>\|<count>\|<caption>` (text files, one grouping key, caption on the last) | `enqueueMessages` as grouped files |
/// | `react\|<chat>\|<msg>\|<emoji>` / `unreact\|…` | `updateMessageReactionsInteractively` (as a reaction tap) |
/// | `edit\|<chat>\|<msg>\|<text>` | `account.pendingUpdateMessageManager.add` (as the edit panel) |
/// | `delete\|<chat>\|<msg>` | `engine.messages.deleteMessagesInteractively(.forEveryone)` |
/// | `typing\|<chat>[\|<msg in a thread>]` | `account.updateLocalInputActivity(.typingText)` (as the composer) |
/// | `resend\|<chat>` (every failed message) | `resendMessages` (as "Resend") |
/// | `mute\|<chat>` / `unmute\|<chat>` | `engine.peers.updatePeerMuteSetting` |
/// | `pin\|<chat>` / `unpin\|<chat>` | `engine.peers.toggleItemPinned(.group(.root))` |
/// | `folderpin\|<chat>\|<team>` / `folderunpin\|…` | `engine.peers.toggleItemPinned(.filter(team folder))` |
/// | `wait\|<seconds>`, `waitfor\|offline`, `waitfor\|online` | — |
enum MattermostDebugWriter {
    static func run(script: String, sync: MattermostAccountSync) async {
        let actions = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        MMLog.log("debug-write: \(actions.count) action(s)")
        for (index, action) in actions.enumerated() {
            let fields = action.components(separatedBy: "|")
            let result = await perform(fields, sync: sync)
            MMLog.log("debug-write: [\(index + 1)/\(actions.count)] \(action) → \(result)")
            // Give each action's consumers a moment, as a user would.
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        MMLog.log("debug-write: done")
    }

    private static func perform(_ fields: [String], sync: MattermostAccountSync) async -> String {
        guard let action = fields.first else {
            return "empty"
        }
        let account = sync.account
        let engine = TelegramEngine(account: account)
        func field(_ index: Int) -> String {
            return index < fields.count ? fields[index] : ""
        }
        if action == "wait" {
            try? await Task.sleep(nanoseconds: UInt64((Double(field(1)) ?? 1.0) * 1_000_000_000))
            return "ok"
        }
        if action == "waitfor" {
            let wantConnected = field(1) == "online"
            for _ in 0 ..< 1200 {
                if sync.isConnected.current == wantConnected {
                    return "ok"
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return "timed out"
        }
        if action == "senduser" {
            // A message to a user's peer, as a new chat from the compose screen (the DM channel may not exist).
            if sync.state.with({ $0.userIdByUsername[field(1).lowercased()] }) == nil, let user = try? await sync.client.users(usernames: [field(1)]).first {
                await sync.ensureUsers([user.id])
            }
            guard let userId = sync.state.with({ $0.userIdByUsername[field(1).lowercased()] }), let userPeerId = sync.userPeerId(userId) else {
                return "no user \(field(1))"
            }
            return await enqueue(account: account, peerId: userPeerId, message: .message(text: field(2), attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
        }
        guard let channelId = sync.debugFindChannel(field(1)), let channelState = sync.channelState(channelId) else {
            return "no chat \(field(1))"
        }
        let peerId = channelState.peerId
        switch action {
        case "send":
            let (text, entities) = formatted(field(2))
            var attributes: [MessageAttribute] = []
            if !entities.isEmpty {
                attributes.append(TextEntitiesMessageAttribute(entities: entities))
            }
            return await enqueue(account: account, peerId: peerId, message: .message(text: text, attributes: attributes, inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
        case "reply":
            guard let target = await message(field(2), peerId: peerId, sync: sync) else {
                return "no message \(field(2))"
            }
            let (text, entities) = formatted(field(3))
            var attributes: [MessageAttribute] = []
            if !entities.isEmpty {
                attributes.append(TextEntitiesMessageAttribute(entities: entities))
            }
            return await enqueue(account: account, peerId: peerId, message: .message(text: text, attributes: attributes, inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: EngineMessageReplySubject(messageId: target.id, quote: nil, innerSubject: nil), replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
        case "image":
            guard let data = generatedJpeg() else {
                return "could not render an image"
            }
            // As the media picker does: the data under a local resource, a local image referencing it.
            let id = Int64.random(in: 1 ... Int64.max)
            let resource = LocalFileMediaResource(fileId: id)
            account.postbox.mediaBox.storeResourceData(resource.id, data: data, synchronous: true)
            let image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: id), representations: [TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 1200, height: 800), resource: resource, progressiveSizes: [], immediateThumbnailData: nil)], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
            return await enqueue(account: account, peerId: peerId, message: .message(text: field(2), attributes: [], inlineStickers: [:], mediaReference: .standalone(media: image), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
        case "album", "files":
            // As the media picker sends an album (or files with "group items" on): one message per item, all
            // with the same local grouping key; the caption on the first photo or the last file.
            let count = max(2, min(10, Int(field(2)) ?? 3))
            let groupingKey = Int64.random(in: 1 ... Int64.max)
            var messages: [EnqueueMessage] = []
            for index in 0 ..< count {
                let id = Int64.random(in: 1 ... Int64.max)
                let media: Media
                if action == "album" {
                    guard let data = generatedJpeg(label: "\(index + 1)/\(count)", hue: CGFloat(index) / CGFloat(count)) else {
                        return "could not render an image"
                    }
                    let resource = LocalFileMediaResource(fileId: id)
                    account.postbox.mediaBox.storeResourceData(resource.id, data: data, synchronous: true)
                    media = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: id), representations: [TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 1200, height: 800), resource: resource, progressiveSizes: [], immediateThumbnailData: nil)], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
                } else {
                    let data = Data("Relay grouped file \(index + 1) of \(count)\n".utf8)
                    let resource = LocalFileMediaResource(fileId: id, size: Int64(data.count))
                    account.postbox.mediaBox.storeResourceData(resource.id, data: data, synchronous: true)
                    media = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: id), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "text/plain", size: Int64(data.count), attributes: [.FileName(fileName: "part-\(index + 1).txt")], alternativeRepresentations: [])
                }
                let captionIndex = action == "album" ? 0 : count - 1
                messages.append(.message(text: index == captionIndex ? field(3) : "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: media), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: groupingKey, correlationId: nil, bubbleUpEmojiOrStickersets: []))
            }
            let ids = await signalValue(enqueueMessages(account: account, peerId: peerId, messages: messages))
            return "enqueued \(ids?.compactMap { $0 }.map { "\($0)" } ?? [])"
        case "file":
            let name = field(2).isEmpty ? "notes.txt" : field(2)
            let data = Data((field(3).isEmpty ? "Relay debug file \(Date())\n" : field(3) + "\n").utf8)
            let id = Int64.random(in: 1 ... Int64.max)
            let resource = LocalFileMediaResource(fileId: id, size: Int64(data.count))
            account.postbox.mediaBox.storeResourceData(resource.id, data: data, synchronous: true)
            let file = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: id), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: name.hasSuffix(".txt") ? "text/plain" : "application/octet-stream", size: Int64(data.count), attributes: [.FileName(fileName: name)], alternativeRepresentations: [])
            return await enqueue(account: account, peerId: peerId, message: .message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: file), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
        case "react", "unreact":
            guard let target = await message(field(2), peerId: peerId, sync: sync) else {
                return "no message \(field(2))"
            }
            let value = MessageReaction.Reaction.builtin(field(3))
            // As a tap on a reaction: the selected set toggled (ChatController's updateMessageReaction).
            var selected = (mergedMessageReactions(attributes: target.attributes, isTags: false)?.reactions ?? []).filter { $0.isSelected }.map { $0.value }
            if action == "react" {
                if !selected.contains(value) {
                    selected.append(value)
                }
            } else {
                selected.removeAll(where: { $0 == value })
            }
            let reactions = selected.compactMap { value -> UpdateMessageReaction? in
                if case let .builtin(string) = value {
                    return .builtin(string)
                }
                return nil
            }
            let _ = await signalValue(updateMessageReactionsInteractively(account: account, messageIds: [target.id], reactions: reactions, isLarge: false, storeAsRecentlyUsed: false) |> map { _ -> Void in })
            return "ok (\(target.id), wanted \(reactions.map { $0.reaction }))"
        case "edit":
            guard let target = await message(field(2), peerId: peerId, sync: sync) else {
                return "no message \(field(2))"
            }
            let (text, entities) = formatted(field(3))
            account.pendingUpdateMessageManager.add(messageId: target.id, text: text, media: .keep, entities: entities.isEmpty ? nil : TextEntitiesMessageAttribute(entities: entities), richText: nil, inlineStickers: [:], disableUrlPreview: false)
            return "ok (\(target.id))"
        case "delete":
            guard let target = await message(field(2), peerId: peerId, sync: sync) else {
                return "no message \(field(2))"
            }
            let _ = await signalValue(engine.messages.deleteMessagesInteractively(messageIds: [target.id], type: .forEveryone))
            return "ok (\(target.id))"
        case "typing":
            var category: PeerActivitySpace.Category = .global
            if !field(2).isEmpty, let target = await message(field(2), peerId: peerId, sync: sync) {
                category = .thread(target.threadId.flatMap { $0 != 1 ? $0 : nil } ?? Int64(target.id.id))
            }
            account.updateLocalInputActivity(peerId: PeerActivitySpace(peerId: peerId, category: category), activity: .typingText, isPresent: true)
            return "ok (\(category))"
        case "resend":
            // As "Resend" on a failed message.
            let failed: [MessageId] = await sync.postbox.mmTransaction { transaction in
                var ids: [MessageId] = []
                transaction.withAllMessages(peerId: peerId, namespace: Namespaces.Message.Local, { message in
                    if message.flags.contains(.Failed) {
                        ids.append(message.id)
                    }
                    return true
                })
                return ids
            }
            if failed.isEmpty {
                return "no failed messages"
            }
            let _ = await signalValue(resendMessages(account: account, messageIds: failed) |> map { _ -> Void in })
            return "ok (\(failed))"
        case "mute", "unmute":
            let _ = await signalValue(engine.peers.updatePeerMuteSetting(peerId: peerId, threadId: nil, muteInterval: action == "mute" ? Int32.max : 0))
            return "ok"
        case "folderpin", "folderunpin":
            // As pinning inside a team folder tab: `toggleItemPinned(.filter(folder id))`.
            let teamName = field(2).lowercased()
            guard let team = sync.state.with({ $0.teams.first(where: { $0.name.lowercased() == teamName || $0.displayName.lowercased() == teamName }) }), let value = sync.store.cursor(MattermostCursorKey.folderId(teamId: team.id)), let folderId = Int32(value) else {
                return "no folder for team \(field(2))"
            }
            let filters = await signalValue(engine.peers.updatedChatListFilters()) ?? []
            var isPinned = false
            if let filter = filters.first(where: { $0.id == folderId }), case let .filter(_, _, _, data) = filter {
                isPinned = data.includePeers.pinnedPeers.contains(peerId)
            }
            if isPinned == (action == "folderpin") {
                return "already \(action == "folderpin" ? "pinned" : "unpinned") in \(team.name)"
            }
            let result = await signalValue(engine.peers.toggleItemPinned(location: .filter(folderId), itemId: .peer(peerId)))
            return "\(result.map { "\($0)" } ?? "nil") in folder \(folderId)"
        case "pin", "unpin":
            let isPinned: Bool = await sync.postbox.mmTransaction { transaction in
                return transaction.getPinnedItemIds(groupId: .root).contains(.peer(peerId))
            }
            if isPinned == (action == "pin") {
                return "already \(action)ned"
            }
            let result = await signalValue(engine.peers.toggleItemPinned(location: .group(.root), itemId: .peer(peerId)))
            return "\(result.map { "\($0)" } ?? "nil")"
        default:
            return "unknown action"
        }
    }

    private static func enqueue(account: Account, peerId: PeerId, message: EnqueueMessage) async -> String {
        let ids = await signalValue(enqueueMessages(account: account, peerId: peerId, messages: [message]))
        return "enqueued \(ids?.compactMap { $0 }.map { "\($0)" } ?? [])"
    }

    /// The newest Cloud message matching a selector.
    private static func message(_ selector: String, peerId: PeerId, sync: MattermostAccountSync) async -> Message? {
        if selector.count == 26, let channelId = sync.channelId(forPeerId: peerId), let entry = sync.store.entries(channelId: channelId, postIds: [selector])[selector], !entry.isDeleted {
            return await sync.postbox.mmTransaction { transaction in
                return transaction.getMessage(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: entry.localId))
            }
        }
        let ownPeerId = sync.ownPeerId
        return await sync.postbox.mmTransaction { transaction -> Message? in
            var found: Message?
            var best: MessageIndex?
            transaction.withAllMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, { message in
                if message.media.contains(where: { $0 is TelegramMediaAction }) {
                    return true
                }
                let isMine = message.author?.id == ownPeerId
                if (selector == "mine" && !isMine) || (selector == "other" && isMine) {
                    return true
                }
                if best == nil || message.index > best! {
                    best = message.index
                    found = message
                }
                return true
            })
            return found
        }
    }

    /// `**bold**`, `_italic_` and `` `code` `` in the debug text become entities, as the composer's formatting
    /// menu produces them (the sender turns them back into markdown).
    private static func formatted(_ input: String) -> (String, [MessageTextEntity]) {
        var text = ""
        var entities: [MessageTextEntity] = []
        var rest = Substring(input)
        let markers: [(String, MessageTextEntityType)] = [("**", .Bold), ("_", .Italic), ("`", .Code)]
        outer: while !rest.isEmpty {
            for (marker, type) in markers where rest.hasPrefix(marker) {
                let afterOpen = rest.dropFirst(marker.count)
                if let close = afterOpen.range(of: marker) {
                    let inner = afterOpen[afterOpen.startIndex ..< close.lowerBound]
                    let start = (text as NSString).length
                    text += inner
                    entities.append(MessageTextEntity(range: start ..< (text as NSString).length, type: type))
                    rest = afterOpen[close.upperBound...]
                    continue outer
                }
            }
            text.append(rest.removeFirst())
        }
        return (text, entities)
    }

    private static func generatedJpeg(label: String = "Relay 2A", hue: CGFloat? = nil) -> Data? {
        let size = CGSize(width: 1200, height: 800)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            var colors = [UIColor(red: 0.12, green: 0.45, blue: 0.86, alpha: 1.0).cgColor, UIColor(red: 0.55, green: 0.2, blue: 0.75, alpha: 1.0).cgColor]
            if let hue = hue {
                colors = [UIColor(hue: hue, saturation: 0.7, brightness: 0.85, alpha: 1.0).cgColor, UIColor(hue: fmod(hue + 0.2, 1.0), saturation: 0.7, brightness: 0.6, alpha: 1.0).cgColor]
            }
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0.0, 1.0]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let text = NSAttributedString(string: "\(label)\n\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium))", attributes: [.font: UIFont.boldSystemFont(ofSize: 96), .foregroundColor: UIColor.white])
            text.draw(at: CGPoint(x: 80, y: 260))
        }
        return image.jpegData(compressionQuality: 0.85)
    }
}

/// The first value of a signal (nil if it completes without one).
func signalValue<T>(_ signal: Signal<T, NoError>) async -> T? {
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let resumed = Atomic<Bool>(value: false)
        let _ = (signal |> take(1)).start(next: { value in
            if !resumed.swap(true) {
                continuation.resume(returning: value)
            }
        }, completed: {
            if !resumed.swap(true) {
                continuation.resume(returning: nil)
            }
        })
    }
}
#endif
