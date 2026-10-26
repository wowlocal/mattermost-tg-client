import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Account-level data that Telegram's server would provide (docs/research/ui-inventory.md §0.2, §1.19):
/// a synthetic `AppConfiguration` (no Premium, Stars, gifts, AI compose or voice-to-text trial; Mattermost's
/// limits) and the `AvailableReactions` list behind the reaction picker and reaction buttons.
enum SyntheticConfiguration {
    /// Mattermost's default `MaxPostSize`.
    static let defaultMaxPostSize = 16383
    /// Sync-store cursor: the built-in emoji (outside the picker) that reactions used, space-separated.
    static let usedEmojiCursor = "reaction_emoji"

    static func appConfigurationData(maxPostSize: Int) -> [String: Any] {
        let maxPostSize = Double(max(1, maxPostSize))
        return [
            // Premium, Stars, gifts, giveaways, paid messages: all off (≈170 `isPremiumDisabled` checks).
            "premium_purchase_blocked": true,
            "stars_purchase_blocked": true,
            "stargifts_blocked": true,
            "stars_gifts_enabled": false,
            "premium_gift_attach_menu_icon": false,
            "premium_gift_text_field_icon": false,
            "giveaway_gifts_purchase_available": false,
            "stars_paid_messages_available": false,
            // Voice-to-text trial (default 2 shows the transcribe button).
            "transcribe_audio_trial_weekly_number": 0.0,
            "stories_posting": "disabled",
            "translations_manual_enabled": "disabled",
            "translations_auto_enabled": "disabled",
            // AI compose (numbers, not bools: the parsers compare with 1).
            "ios_disable_ai_chat": 1.0,
            "ios_disable_ai_attach": 1.0,
            // Limits (`<key>_default`, since Mattermost users are never Premium).
            "dialog_filters_limit_default": 100.0,
            "dialog_filters_chats_limit_default": 5000.0,
            "dialogs_pinned_limit_default": 200.0,
            "dialogs_folder_pinned_limit_default": 200.0,
            "reactions_user_max_default": 25.0,
            "message_length_limit_default": maxPostSize,
            "caption_length_limit_default": maxPostSize,
            "about_length_limit_default": 128.0
        ]
    }

    /// Writes the synthetic configuration; returns whether it changed.
    @discardableResult
    static func writeAppConfiguration(maxPostSize: Int, transaction: Transaction) -> Bool {
        guard let json = JSON(dictionary: appConfigurationData(maxPostSize: maxPostSize)) else {
            MMLog.log("config: could not build the app configuration")
            return false
        }
        var configuration = AppConfiguration.defaultValue
        configuration.data = json
        let current = transaction.getPreferencesEntry(key: PreferencesKeys.appConfiguration)?.get(AppConfiguration.self)
        if current == configuration {
            return false
        }
        transaction.setPreferencesEntry(key: PreferencesKeys.appConfiguration, value: PreferencesEntry(configuration))
        return true
    }

    // MARK: Reactions

    /// Offered in the reaction picker, in this order (Mattermost short names; names missing from the emoji
    /// table are skipped). Every other built-in emoji is listed disabled, so reactions with it still render.
    static let pickerEmojiNames: [String] = [
        "+1", "heart", "joy", "tada", "eyes", "white_check_mark", "pray", "fire", "100", "rocket",
        "clap", "raised_hands", "smile", "slightly_smiling_face", "thinking", "-1", "laughing", "heart_eyes",
        "sweat_smile", "wink", "sunglasses", "star_struck", "partying_face", "hugging_face", "rofl",
        "upside_down_face", "grimacing", "confused", "cry", "sob", "scream", "rage", "skull",
        "see_no_evil", "facepalm", "shrug", "ok_hand", "muscle", "wave", "handshake", "crossed_fingers",
        "sparkles", "star", "zap", "boom", "trophy", "medal", "gift", "coffee", "beers", "pizza", "cake",
        "bug", "warning", "x", "heavy_check_mark", "question", "exclamation", "point_up", "bulb",
        "memo", "lock", "rotating_light", "construction", "ship", "chart_with_upwards_trend"
    ]

    /// The reaction list: picker emoji first (enabled), then the server's custom emoji (enabled, `:name:`),
    /// then the other built-in emoji that reactions use (disabled: listed so those reactions render).
    ///
    /// Only emoji seen in reactions are listed, not the whole table (1,900 emoji, about 4.4 MB encoded, which
    /// Postbox would decode whenever the list is read): `usedEmoji` grows as posts with new reactions arrive
    /// (`noteReactionEmoji`) and is kept in the stored list itself.
    static func availableReactions(customEmojiNames: [String], usedEmoji: [String]) -> AvailableReactions {
        var reactions: [AvailableReactions.Reaction] = []
        var seen = Set<String>()
        func add(_ value: String, title: String, isEnabled: Bool) {
            guard seen.insert(value).inserted else {
                return
            }
            let file = MattermostReactionImages.file(for: value)
            reactions.append(AvailableReactions.Reaction(
                isEnabled: isEnabled,
                isPremium: false,
                value: .builtin(value),
                title: title,
                staticIcon: file,
                appearAnimation: file,
                selectAnimation: file,
                activateAnimation: file,
                effectAnimation: file,
                aroundAnimation: file,
                centerAnimation: file
            ))
        }
        for name in pickerEmojiNames {
            if let emoji = EmojiTable.unicode(forName: name) {
                add(emoji, title: name, isEnabled: true)
            }
        }
        for name in customEmojiNames.sorted() {
            add(":\(name):", title: name, isEnabled: true)
        }
        for emoji in usedEmoji {
            add(emoji, title: EmojiTable.name(forUnicode: emoji) ?? emoji, isEnabled: false)
        }
        return AvailableReactions(hash: 0, reactions: reactions)
    }

    static func writeAvailableReactions(_ reactions: AvailableReactions, transaction: Transaction) {
        let key = ValueBoxKey(length: 8)
        key.setInt64(0, value: 0)
        guard let entry = CodableEntry(reactions) else {
            MMLog.log("config: could not encode the reaction list")
            return
        }
        transaction.putItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.availableReactions, key: key), entry: entry)
        MMLog.log("config: reaction list with \(reactions.reactions.count) reactions (\(entry.data.count / 1024) KB)")

        // The context menu's reaction bar takes its items from the "top reactions" list when every reaction is
        // allowed (Telegram's server fills it); use the picker emoji, in order.
        var topItems: [OrderedItemListEntry] = []
        for reaction in reactions.reactions where reaction.isEnabled {
            guard case let .builtin(value) = reaction.value else {
                continue
            }
            let item = RecentReactionItem(.builtin(value))
            if let entry = CodableEntry(item) {
                topItems.append(OrderedItemListEntry(id: item.id.rawValue, contents: entry))
            }
        }
        transaction.replaceOrderedItemListItems(collectionId: Namespaces.OrderedItemList.CloudTopReactions, items: topItems)
    }

    static func storedAvailableReactions(transaction: Transaction) -> AvailableReactions? {
        let key = ValueBoxKey(length: 8)
        key.setInt64(0, value: 0)
        return transaction.retrieveItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.availableReactions, key: key))?.get(AvailableReactions.self)
    }

    /// The Mattermost emoji name of a reaction value: `:name:` for custom emoji, the table's short name for
    /// Unicode emoji.
    static func emojiName(for value: MessageReaction.Reaction) -> String? {
        guard case let .builtin(string) = value else {
            return nil
        }
        if string.count > 2, string.hasPrefix(":"), string.hasSuffix(":") {
            return String(string.dropFirst().dropLast())
        }
        return EmojiTable.name(forUnicode: string)
    }
}

extension MattermostAccountSync {
    /// At start: the configuration with default limits and the reaction list known so far (also registers
    /// its values with the image renderer, so reaction images load before the network is up).
    func writeSyntheticConfiguration() async {
        await self.postbox.mmTransaction { transaction in
            SyntheticConfiguration.writeAppConfiguration(maxPostSize: SyntheticConfiguration.defaultMaxPostSize, transaction: transaction)
            var customNames: [String] = []
            if let stored = SyntheticConfiguration.storedAvailableReactions(transaction: transaction) {
                for reaction in stored.reactions {
                    if case let .builtin(value) = reaction.value, value.hasPrefix(":") {
                        customNames.append(String(value.dropFirst().dropLast()))
                    }
                }
            }
            // Kept in the sync store, not read back from the list: lists written before 2D held every emoji.
            let usedEmoji = (self.store.cursor(SyntheticConfiguration.usedEmojiCursor) ?? "").split(separator: " ").map(String.init)
            self.writeReactionList(customNames: customNames, usedEmoji: usedEmoji, transaction: transaction)
        }
    }

    /// Writes the reaction list and remembers what it holds.
    func writeReactionList(customNames: [String], usedEmoji: [String], transaction: Transaction) {
        let reactions = SyntheticConfiguration.availableReactions(customEmojiNames: customNames, usedEmoji: usedEmoji)
        SyntheticConfiguration.writeAvailableReactions(reactions, transaction: transaction)
        var listed = Set<String>()
        for reaction in reactions.reactions {
            if case let .builtin(value) = reaction.value {
                listed.insert(value)
            }
        }
        self.reactionList.with { $0 = (customNames, usedEmoji, listed) }
    }

    /// Reactions with emoji the list doesn't have yet (posts, live `reaction_added`): adds them, disabled, so
    /// they render. Called inside the transaction that writes them.
    func noteReactionEmoji(names: [String], transaction: Transaction) {
        let current = self.reactionList.with { $0 }
        var added: [String] = []
        for name in names {
            guard let emoji = EmojiTable.unicode(forName: name), !current.listed.contains(emoji), !added.contains(emoji) else {
                continue
            }
            added.append(emoji)
        }
        if added.isEmpty {
            return
        }
        MMLog.log("config: \(added.count) more emoji in the reaction list: \(added.joined())")
        let usedEmoji = current.usedEmoji + added
        self.store.setCursor(SyntheticConfiguration.usedEmojiCursor, usedEmoji.joined(separator: " "))
        self.writeReactionList(customNames: current.customNames, usedEmoji: usedEmoji, transaction: transaction)
    }

    /// After bootstrap: limits from the server's client config, custom emoji in the reaction list.
    func refreshSyntheticConfiguration() async {
        var maxPostSize = SyntheticConfiguration.defaultMaxPostSize
        if let config = try? await self.client.clientConfig() {
            if let value = config.int64("MaxPostSize"), value > 0 {
                maxPostSize = Int(value)
            }
            if let value = config.int64("TimeBetweenUserTypingUpdatesMilliseconds"), value > 0 {
                self.typingInterval.with { $0 = Double(value) / 1000.0 }
            }
        }
        var customNames: [String] = []
        var page = 0
        while page < 20 {
            guard let emojis = try? await self.client.customEmojis(page: page, perPage: 200, sort: "name") else {
                break
            }
            customNames.append(contentsOf: emojis.map { $0.name })
            if emojis.count < 200 {
                break
            }
            page += 1
        }
        let changed: Bool = await self.postbox.mmTransaction { transaction in
            let changed = SyntheticConfiguration.writeAppConfiguration(maxPostSize: maxPostSize, transaction: transaction)
            self.writeReactionList(customNames: customNames, usedEmoji: self.reactionList.with { $0.usedEmoji }, transaction: transaction)
            return changed
        }
        MMLog.log("config: MaxPostSize \(maxPostSize)\(changed ? " (updated)" : ""), \(customNames.count) custom emoji in the reaction list")
    }
}
