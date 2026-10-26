import Foundation

// MATTERMOST: UI entry points of Telegram-only features (docs/plan/06-feature-scope.md "Hide",
// docs/research/ui-inventory.md §0.1).
//
// Each flag is `true` when the Telegram feature is reachable. Hidden features keep their code; only
// the entry points (tabs, settings rows, menus, attach buttons, deep links, …) check these flags.
// Upstream call sites are marked `// MATTERMOST:`.
//
// The flags are static lets: flipping one is a rebuild, not a setting. They follow
// `MattermostBackend.isEnabled`, so a build with the backend switched off shows Telegram's UI
// unchanged for side-by-side comparison. To bring a single feature back, replace its value with
// `true`.
//
// Helpers that need a module's own types live in that module and read these flags:
// - `MattermostFeatures.isAttachButtonEnabled(_:)` (TelegramUI, attach menu);
// - `MattermostFeatures.allows(_: ResolvedUrl)` (AccountContext, deep links);
// - `MattermostFeatures.hiddenSettingsSections` (PeerInfoScreen, Settings root);
// - `MattermostFeatures.settingsSearchAllows(_:)` (SettingsUI, settings search).
public enum MattermostFeatures {
    /// `true` when Telegram's own UI is wanted (the Mattermost backend is off).
    private static let telegram: Bool = !MattermostBackend.isEnabled

    // 06 "Hide"
    public static let secretChats = telegram
    public static let stories = telegram
    /// Sticker and GIF tabs, packs, "add to stickers", sticker suggestions.
    public static let stickersAndGifs = telegram
    /// Telegram custom emoji. Mattermost custom emoji is a Phase 3 "Build" item.
    public static let customEmoji = telegram
    /// Premium, Stars, boosts, gifts, giveaways, TON, emoji status, profile colours.
    public static let premium = telegram
    public static let payments = telegram
    public static let ads = telegram
    /// Contacts tab, phone contacts, invite, contacts permission prompt, phone numbers.
    public static let contacts = telegram
    /// 1:1 and group calls, Calls tab, CallKit, PushKit.
    public static let calls = telegram
    /// "New Channel", Channels search tab.
    public static let broadcastChannels = telegram
    /// Inline mode, attach-menu bots, mini apps, web-app menu button.
    public static let botWebApps = telegram
    public static let passport = telegram
    public static let business = telegram
    public static let mtprotoProxy = telegram
    /// Telegram's privacy rows (last seen, phone, forwards, blocked users, 2FA, …).
    public static let telegramPrivacy = telegram
    /// Telegram server translation.
    public static let translation = telegram
    public static let voiceToText = telegram

    // Telegram-only, not in the 06 list (ui-inventory §1.17)
    public static let aiCompose = telegram
    /// t.me "Copy Link", usernames, QR codes.
    public static let tmeLinks = telegram
    public static let reporting = telegram
    /// Chat-list notices and first-run popups.
    public static let chatListSuggestions = telegram
    /// Auto-delete timers, copy protection, blocking.
    public static let telegramChatSettings = telegram
    /// Telegram's help rows (Ask a Question, FAQ, Telegram Features).
    public static let telegramSupport = telegram
    /// Telegram's alternate app icons.
    public static let alternateAppIcons = telegram
    /// Telegram polls and checklists (Mattermost polls are a server plugin).
    public static let polls = telegram
    /// Telegram rich-text (Instant View style) posts from the attach menu.
    public static let richTextPosts = telegram
    /// Telegram's downloadable language packs (the Language row); Relay is English-only for now.
    public static let languagePacks = telegram
    /// Telegram's server chat themes (Appearance → Chat Themes).
    public static let chatThemes = telegram

    // 06 "Later"
    public static let voiceMessages = telegram
    public static let videoMessages = telegram
    public static let scheduledMessages = telegram

    // 06 "Build"
    /// Relay's own screens that replace Telegram ones (About Relay, slim Privacy and Security).
    public static let relayScreens = !telegram
    public static let mattermostLogin = !telegram
}
