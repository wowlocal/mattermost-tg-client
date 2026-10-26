import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Rich content settings (Phase 3E, `RichContentSettings`): link previews, the image proxy, emoticons and inline
/// LaTeX follow the server config and the user's display settings. They are applied when posts are converted, so a
/// change re-renders what the user is likely to look at: the newest page of every chat (`rerenderRichContent`). The
/// same pass upgrades data written before 3E once.
extension MattermostAccountSync {
    /// Version of the rendering `rerenderRichContent` brings stored messages to (3E: link previews, headings, list
    /// indents, tables, emoticons; 2 (4F): a post with images and other files as one group, attachment colours
    /// and icons).
    static let richContentCursor = "rich_content"
    static let richContentVersion = "2"
    /// The settings the stored messages were rendered with (`RichContentSettings.encoded`).
    static let richContentSettingsCursor = "rich_content_settings"
    /// Newest messages per chat re-rendered on a settings change or the upgrade (about a screen and a half).
    static let richContentRerenderNewest = 60

    var richContent: RichContentSettings {
        return self.state.with { $0.richContent }
    }

    /// Takes new settings; true when they changed what posts look like.
    @discardableResult
    func setRichContent(_ settings: RichContentSettings, reason: String) -> Bool {
        let previous = self.state.with { state -> RichContentSettings in
            let previous = state.richContent
            state.richContent = settings
            return previous
        }
        MattermostResourceClients.shared.setImageProxy(postbox: self.postbox, enabled: settings.imageProxy)
        if previous != settings {
            MMLog.log("rich content (\(reason)): link previews \(settings.linkPreviews ? "on" : "off") (server \(settings.serverLinkPreviews), user \(settings.userLinkPreviews)), permalink previews \(settings.permalinkPreviews), image proxy \(settings.imageProxy), emoticons \(settings.emoticons), inline LaTeX \(settings.inlineLatex)")
        }
        return previous != settings
    }

    /// The server config changed (`config_changed`).
    func refreshRichContentConfig() async {
        guard let config = try? await self.client.clientConfig() else {
            return
        }
        if self.setRichContent(self.richContent.withConfig(config), reason: "config changed") {
            await self.rerenderRichContent(reason: "config changed")
            await self.saveRichContent(self.richContent)
        }
    }

    /// Display settings changed on another client (`preferences_changed`: the changed preferences only).
    func applyRichContentPreferences(_ changed: [Preference]) async {
        guard changed.contains(where: { $0.category == PreferenceCategory.displaySettings }) else {
            return
        }
        if self.setRichContent(self.richContent.withChangedPreferences(changed), reason: "preferences changed") {
            await self.rerenderRichContent(reason: "preferences changed")
            await self.saveRichContent(self.richContent)
        }
    }

    /// A display setting was deleted (back to its default): reloads all preferences.
    func reloadRichContentPreferences() async {
        guard let preferences = try? await self.client.preferences() else {
            return
        }
        if self.setRichContent(self.richContent.withPreferences(preferences), reason: "preferences deleted") {
            await self.rerenderRichContent(reason: "preferences deleted")
            await self.saveRichContent(self.richContent)
        }
    }

    /// The settings last used, before the bootstrap asks the server (hole fills may write posts before it).
    func restoreRichContent() {
        if let stored = self.store.cursor(MattermostAccountSync.richContentSettingsCursor).flatMap(RichContentSettings.init(encoded:)) {
            self.setRichContent(stored, reason: "last known")
        } else {
            MattermostResourceClients.shared.setImageProxy(postbox: self.postbox, enabled: self.richContent.imageProxy)
        }
    }

    /// After the bootstrap read the settings: stored messages are re-rendered when the settings changed while the
    /// app wasn't running, and data written by builds before 3E once; then the settings are kept.
    func finishRichContentBootstrap(isFirstSync: Bool) async {
        let settings = self.richContent
        let (version, stored) = await self.postbox.mmTransaction { _ in
            return (self.store.cursor(MattermostAccountSync.richContentCursor), self.store.cursor(MattermostAccountSync.richContentSettingsCursor))
        }
        if !isFirstSync {
            if version != MattermostAccountSync.richContentVersion {
                await self.rerenderRichContent(reason: "upgrade \(version ?? "none") → \(MattermostAccountSync.richContentVersion)")
            } else if stored != settings.encoded {
                await self.rerenderRichContent(reason: "settings changed while not running")
            }
        }
        await self.saveRichContent(settings)
    }

    func saveRichContent(_ settings: RichContentSettings) async {
        await self.postbox.mmTransaction { _ in
            self.store.setCursor(MattermostAccountSync.richContentCursor, MattermostAccountSync.richContentVersion)
            self.store.setCursor(MattermostAccountSync.richContentSettingsCursor, settings.encoded)
        }
    }

    /// Re-renders stored messages with the current settings. Without link previews, every stored card is dropped at
    /// once (no network). Then the newest page of every chat is fetched again and rewritten: the stored messages no
    /// longer have their markdown and embeds. Channel pages, because `POST /posts/ids` leaves `metadata.embeds` out
    /// (11.7: files, reactions and emoji only). Older history keeps its rendering until it is loaded again.
    func rerenderRichContent(reason: String) async {
        let started = CFAbsoluteTimeGetCurrent()
        let channels = self.state.with { state in state.channels.map { (channelId: $0.key, peerId: $0.value.peerId) } }
        var stripped = 0
        if !self.richContent.linkPreviews {
            stripped = await self.postbox.mmTransaction { transaction -> Int in
                var count = 0
                for channel in channels {
                    var ids: [MessageId] = []
                    transaction.scanMessages(peerId: channel.peerId, namespace: Namespaces.Message.Cloud, tag: .webPage) { message in
                        // Permalink previews stay (they don't follow the link preview setting).
                        if message.media.contains(where: { $0 is TelegramMediaWebpage }) && !LinkPreviewConverter.isPermalinkPreview(message) {
                            ids.append(message.id)
                        }
                        return true
                    }
                    for id in ids {
                        transaction.updateMessage(id, update: { current in
                            let media = current.media.filter { !($0 is TelegramMediaWebpage) }
                            let attributes = current.attributes.filter { !($0 is WebpagePreviewMessageAttribute) }
                            return .update(StoreMessage.mmCopy(of: current, id: current.id, threadId: current.threadId, attributes: attributes, media: media))
                        })
                    }
                    count += ids.count
                }
                return count
            }
        }
        let written = MMLocked<Int>(0)
        let failed = MMLocked<Int>(0)
        try? await self.forEachConcurrently(channels.map { $0.channelId }, limit: 4) { channelId in
            do {
                let list = try await self.client.posts(channelId: channelId, page: 0, perPage: MattermostAccountSync.richContentRerenderNewest)
                let posts = list.order.compactMap { list.posts[$0] }.filter { $0.deleteAt == 0 }
                if posts.isEmpty {
                    return
                }
                await self.ensureUsers(referencedUserIds(posts))
                let count = await self.postbox.mmTransaction { transaction in
                    return self.writeMessages(channelId: channelId, posts: posts, transaction: transaction)
                }
                written.with { $0 += count }
            } catch {
                failed.with { $0 += 1 }
            }
        }
        MMLog.log("rich content (\(reason)): \(stripped) card(s) removed, re-rendered \(written.current) message(s) in \(channels.count) chat(s) (\(failed.current) failed) in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
    }
}
