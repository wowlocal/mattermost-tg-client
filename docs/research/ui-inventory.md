# UI inventory: hiding Telegram-only features, tab bar, login, rebranding

**Status:** Research v1 · 2026‑10‑26 · source tree at upstream `5c20d095` plus the Spike A hooks. Read‑only investigation: nothing was built or run. Line numbers were read from the tree on this date; they drift as soon as anyone edits these files, so re‑grep before patching.

This extends [telegram-internals.md](telegram-internals.md) (§8 extensions, §9 rebranding hooks), which is not repeated here. Checklist source: [06 · Feature scope](../plan/06-feature-scope.md) "Hide". Design rule: [01 · Architecture → Feature flags](../plan/01-architecture.md#feature-flags).

**Path prefixes used below**

| Prefix | Path |
|---|---|
| `TUI/` | `submodules/TelegramUI/Sources/` |
| `TUIC/` | `submodules/TelegramUI/Components/` |
| `CLU/` | `submodules/ChatListUI/Sources/` |
| `PIS/` | `submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/` |
| `SUI/` | `submodules/SettingsUI/Sources/` |
| `AC/` | `submodules/AccountContext/Sources/` |
| `TC/` | `submodules/TelegramCore/Sources/` |
| `AUI/` | `submodules/AuthorizationUI/Sources/` |
| `CNT/` | `submodules/ContactListUI/Sources/` |
| `ITP` | `TUIC/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift` |
| `LDN` | `TUI/Chat/ChatControllerLoadDisplayNode.swift` |
| `CTX` | `TUI/ChatInterfaceStateContextMenus.swift` |
| `PDATA` | `PIS/PeerInfoData.swift` |
| `PITEMS` | `PIS/PeerInfoProfileItems.swift` (peer rows) |
| `SITEMS` | `PIS/PeerInfoSettingsItems.swift` (Settings rows) |
| `BTN` | `PIS/PeerInfoScreenPerformButtonAction.swift` (peer "more" menu) |

---

## 0. Summary and the central levers

Most Telegram‑only UI is already wired to a server switch. Four levers hide most of it before any per‑screen `if`:

1. **A synthetic `AppConfiguration`** (§0.2). Every `*Configuration.with(appConfiguration:)` parser falls back to defaults when `AppConfiguration.data == nil`, which is the state of a Mattermost account today. Some defaults already hide things (stories posting, translation, Stars purchases). Others **show** them: Premium promos (`isPremiumDisabled` defaults to `false`) and the AI compose button (on unless `ios_disable_ai_chat == 1`). One write of a synthetic dictionary into the account's Postbox flips ~170 Premium checks plus Stars, gifts, stories, translation, AI and the user limits.
2. **One `MattermostFeatures` enum** (§0.1) for the entry points that have no server switch: tabs, settings rows, the compose menu, the attach menu, chat header buttons, peer‑info buttons, deep links, settings search.
3. **"Never `isPremium`".** Mattermost users must keep `TelegramUser.flags.isPremium == false`. Premium also draws star badges and premium‑only UI. Raise the limits with app‑configuration keys instead (§0.2).
4. **`nil` the optional Stars, TON, wallet and in‑app‑purchase contexts** in `AccountContextImpl` (§0.3). The UI already hides what has no context.

After these four, the per‑feature gates in §1 are mostly **one line in a central builder**:

- the attach‑menu list;
- the input accessory list;
- the chat‑state funnel;
- the message‑action options;
- `peerInfoHeaderButtons`;
- the peer‑info pane list;
- the Settings section loop;
- the settings‑search list;
- the chat‑search panes;
- the deep‑link switch.

### 0.1 Where `MattermostFeatures` lives

Put it next to `MattermostBackend` in `TC/Mattermost/MattermostFeatures.swift`:

- Every module that needs a gate already depends on TelegramCore: ChatListUI, SettingsUI, PeerInfoScreen, AttachmentUI, ContactListUI, ShareController, TelegramPermissions, TelegramUIPreferences (checked their `BUILD` files). No `BUILD` edits are needed.
- The extensions see it too.
- Precedent: `GlobalExperimentalSettings` (`AC/GlobalExperimentalSettings.swift:3-6`) is the same pattern, a process‑wide static struct. It lives in AccountContext, which TelegramUIPreferences cannot see.

```swift
// MATTERMOST: UI entry points of Telegram-only features. Static lets: flipping one is a rebuild, not a setting.
public enum MattermostFeatures {
    // 06 "Hide"
    public static let secretChats = false
    public static let stories = false
    public static let stickersAndGifs = false      // sticker/GIF tabs, packs, "add to stickers"
    public static let customEmoji = false          // Telegram custom emoji; Mattermost custom emoji is Phase 3 "Build"
    public static let premium = false              // Premium, Stars, boosts, gifts, giveaways, TON, emoji status
    public static let payments = false
    public static let ads = false
    public static let contacts = false             // Contacts tab, phone contacts, invite, contacts permission prompt
    public static let calls = false                // 1:1 and group calls, Calls tab, CallKit, PushKit
    public static let broadcastChannels = false    // "New Channel", Channels search tab
    public static let botWebApps = false           // inline mode, attach-menu bots, mini apps, web-app menu button
    public static let passport = false
    public static let business = false
    public static let mtprotoProxy = false
    public static let telegramPrivacy = false      // Telegram's privacy rows (last seen, phone, forwards…)
    public static let translation = false          // Telegram server translation (Apple on-device: see §1.15)
    public static let voiceToText = false
    // Telegram-only, not in the 06 list (§1.17)
    public static let aiCompose = false
    public static let tmeLinks = false             // t.me "Copy Link", usernames, QR codes
    public static let reporting = false
    public static let chatListSuggestions = false  // chat-list notices and first-run popups
    // 06 "Later"
    public static let voiceMessages = false
    public static let videoMessages = false
    public static let scheduledMessages = false
    public static let mattermostLogin = MattermostBackend.isEnabled
}
```

Static `let`s let the compiler drop dead branches. The plan wants reversibility; a rebuild is enough for that.

Put the helpers that need a module's own types in that module, as small extensions that read these flags:

- `isAttachButtonEnabled(_ : AttachmentButtonType)`;
- `allows(_ : ResolvedUrl)` (in AccountContext);
- `hiddenSettingsSections` (in PeerInfoScreen);
- `settingsSearchAllows(_ : SettingsSearchableItemIcon)` (in SettingsUI).

TelegramCore can't see those types.

### 0.2 Synthetic `AppConfiguration`

- `AppConfiguration` is `{ data: JSON?, hash }` (`TC/SyncCore/SyncCore_AppConfiguration.swift:4-13`). Its `init(data:hash:)` and `updateAppConfiguration` (`TC/State/AppConfiguration.swift:11-17`) are internal. **No TelegramCore change is needed** anyway: `defaultValue` is public static, `data` is `public var`, `JSON(dictionary:)` is public (`TC/Utils/JSON.swift:54`) and `PreferencesEntry(_:)` is public (`submodules/Postbox/Sources/PreferencesEntry.swift:59`). MattermostSync can write it at bootstrap (the seeder can today, next to its `setState`):

  ```swift
  var config = AppConfiguration.defaultValue
  config.data = JSON(dictionary: ["premium_purchase_blocked": true, "ios_disable_ai_chat": 1.0 as Double, …])
  transaction.setPreferencesEntry(key: PreferencesKeys.appConfiguration, value: PreferencesEntry(config))
  ```

  Use Swift `Bool` and `Double` values in the dictionary, not `JSONSerialization` output. `JSON`'s private initializer first checks for its private `JSONValue` protocol, which Swift `Bool` and `Double` conform to, and then falls back to `as? Int` (`TC/Utils/JSON.swift:6-35`). A bridged `NSNumber` boolean probably lands in the `Int` branch and becomes `.number`, and then the parsers' `as? Bool` fails. This is unverified; avoid it.
- UI code reads it through `context.currentAppConfiguration` / `context.appConfiguration` (`TUI/AccountContext.swift:170, 423-440`, sourced from `getAppConfiguration` at `:1130-1137`). Nothing is cached elsewhere, so the write takes effect on the next emission.
- Telegram's own writer is `managedAppConfigurationUpdates`, inside `AccountTaskManager`, which never starts in this fork (internals §2). Nothing overwrites the synthetic value.

| Key | Value | Effect (parser) |
|---|---|---|
| `premium_purchase_blocked` | `true` | `PremiumConfiguration.isPremiumDisabled` (`AC/Premium.swift:282`). Default `false` (`:159`). `isPremiumDisabled` appears about 170 times in the tree |
| `stars_purchase_blocked` | `true` | `areStarsDisabled` (`:283`; default already `true`) |
| `stargifts_blocked` / `stars_gifts_enabled` | `true` / `false` | `starGiftsPurchaseBlocked`, `starsGiftsPurchaseAvailable` (`:288-289`) |
| `premium_gift_attach_menu_icon` / `premium_gift_text_field_icon` | `false` | gift icon in the attach menu and the input field (`:285-286`) |
| `giveaway_gifts_purchase_available` | `false` | (`:287`) |
| `transcribe_audio_trial_weekly_number` | `0` (a number) | voice‑to‑text trial; default **2**, which shows the transcribe button (`:292`, default `:169`; §1.16) |
| `stars_paid_messages_available` | `false` | paid messages (`AC/AccountContext.swift:2065`) |
| `stories_posting` | `"disabled"` | `StoriesConfiguration.posting` (`AC/AccountContext.swift:1905-1915`; default already `.disabled`) |
| `translations_manual_enabled` / `translations_auto_enabled` | `"disabled"` (later `"system"`, §1.15) | `TranslationConfiguration` (`AC/AccountContext.swift:2140-2151`) |
| `ios_disable_ai_chat` / `ios_disable_ai_attach` | `1` (a number, not a bool) | AI compose button in the composer and attach panel (`TUI/ChatControllerNode.swift:966-968`, `TUI/ChatInterfaceStateInputPanels.swift:506-508`, `submodules/AttachmentUI/Sources/AttachmentPanel.swift:2338-2340`, `TUIC/LegacyMessageInputPanel/Sources/LegacyMessageInputPanel.swift:101-103`). **On by default** |
| `dialog_filters_limit_default` / `dialog_filters_chats_limit_default` | e.g. `100` / `1000` | folder count and folder size (`TC/State/UserLimitsConfiguration.swift:167-168`; key is `name + "_default"`, `:144-149`) |
| `dialogs_pinned_limit_default` | e.g. `100` | pinned chats (favorites) (`:160`) |
| `reactions_user_max_default` | e.g. `25` | reactions per user per message; default **1** (`:173`) |
| `message_length_limit_default` / `caption_length_limit_default` | server `MaxPostSize` (16383 by default) | default `4096` / `1024` (`:67, :47`; parsed `:189, :169`); Mattermost posts are longer |
| `about_length_limit_default` | e.g. `128` (Mattermost position field) | bio length (`:171`) |

The values belong to MattermostSync: limits come from the server's client config. The rest is constant.

### 0.3 A fourth lever: optional account‑level contexts

`AccountContextImpl.init` builds these for the main app only, `TUI/AccountContext.swift:340-372`:

- `InAppPurchaseManager`, which **registers a StoreKit observer at launch**: `SKPaymentQueue.default().add(self)` (`submodules/InAppPurchaseManager/Sources/InAppPurchaseManager.swift:270`);
- `starsContext`, `tonContext`, `walletContext`, `giftAuctionsManager`.

They are all optional, and the extension path already sets them to `nil` (`:374-381`). Set them to `nil` when `!MattermostFeatures.premium`. The UI's own `if let starsContext` checks then hide the Stars and gift rows (Settings rows 26–29 in §2). This also removes Telegram's Stars and TON polling (internals §2).

---

## 1. Feature‑hiding inventory

**How to read the tables.**
- *Decided by* is the existing condition or switch.
- *Gate* is the proposed `MattermostFeatures` check at the most central point.
- **Bold** gates are the ones to do first: one edit hides several entry points.
- "AppConfig" means the synthetic configuration in §0.2.
- "Data‑driven" means Mattermost data never produces the case (no secret‑chat peers, no invoice media, …). Those need no gate, only a note.

**Seeded‑account baseline.** On today's Spike A account (`AppConfiguration.data == nil`, `isPremium == false`, chats are `.group` megagroups), these Telegram‑only items are **already visible**. Each one calls Telegram's server and then hangs:

- the call button on every user profile (`callsAvailable` is `true` when `cachedData` is nil, `PDATA:2660-2667`);
- "Copy Link" and "Report" in the message menu (§1.17);
- the voice‑to‑text button on incoming voice messages under 300 s (§1.16);
- the AI compose button (§1.17);
- "Translate" in the text‑selection menu (§1.15);
- the Premium rows in Settings (§2);
- Premium stars next to names (§1.4).

### 1.1 Secret chats

Mostly **data‑driven**: Mattermost never creates `Namespaces.Peer.SecretChat` peers.

| Surface | Entry point | Decided by | Gate |
|---|---|---|---|
| Compose ("New Secret Chat") | Handler exists, no row (`TUI/ComposeController.swift:151`) | — | none needed |
| Contacts row menu "Start Secret Chat" | `CNT/ContactContextMenus.swift:125-205` (`if canStartSecretChat {`) | peer is a user | `&& MattermostFeatures.secretChats` (Contacts tab is gone anyway, §3) |
| Peer info more‑menu "Start Secret Chat" | `BTN:554-566` | CloudUser, not bot/support | `MattermostFeatures.secretChats` |
| Chat: self‑destruct timer button, handshake panel, media timer | `TUI/ChatInterfaceInputContexts.swift:117-153, 184-188`; `TUI/ChatInterfaceStateInputPanels.swift:229-235`; `TUI/ChatControllerOpenAttachmentMenu.swift:1936-1940` | secret‑chat peer, or `currentAutoremoveTimeout != nil` | data‑driven (see §1.17 auto‑delete) |
| Settings → Privacy → Data Settings → "secret chat link previews" | `SUI/Privacy and Security/DataPrivacySettingsController.swift:325-327` | — | screen hidden (§2) |

### 1.2 Stories

| Surface | Entry point | Decided by | Gate |
|---|---|---|---|
| **Chat list story bar** (header peer list, upload progress, archive story ring, tooltip, overscroll‑to‑open) | subscription at `CLU/ChatListController.swift:2189-2192` (`if self.previewing { self.storiesReady.set(.single(true)) } else { … storySubscriptions(…) }`); drawn at `CLU/ChatListControllerNode.swift:1698` | local story subscriptions | **`if self.previewing \|\| !MattermostFeatures.stories`** at `:2189`. Keep `storiesReady.set(.single(true))`: the root list waits on it (`:2092`). Keep passing an *empty* `EngineStorySubscriptions`, not `nil`: the header draws the title inside the story list (`TUIC/ChatListHeaderComponent/Sources/ChatListHeaderComponent.swift:1110-1137`) |
| "Post story" nav button | `CLU/ChatListController.swift:7313` (`if storyPostingAvailable {`), fed by `:320-327` | `StoriesConfiguration.posting` (`stories_posting`; default already `.disabled`, `AC/AccountContext.swift:1887`) | AppConfig; belt and braces `&& MattermostFeatures.stories` at `:320` |
| Swipe right on the first folder tab → story camera | `CLU/ChatListControllerNode.swift:548, 612` → `isStoryPostingAvailable` (`CLU/ChatListController.swift:6694`) | same | return `false` at `:6694` |
| Story rings on chat rows | `CLU/Node/ChatListNodeEntries.swift:758` (`storyState: … entry.storyStats.flatMap {`) | per‑peer story stats | `MattermostFeatures.stories ? … : nil` |
| Story rings in search | `CLU/ChatListSearchContainerNode.swift:322` (`openStories:`) | stats | gate the closure |
| Contacts rows with stories | `CNT/ContactListNode.swift:1117` | — | Contacts tab hidden (§3) |
| Peer info: story ring on avatar, Stories / Archive panes, "Post Story" nav button (**unconditional for My Profile**), "Archived Stories" menu | `PIS/PeerInfoScreen.swift:2516-2570` (`PeerExpiringStoryListContext`), panes `PDATA:1579-1590, 1913, 2312`, nav `PIS/PeerInfoScreen.swift:5889-5893`, menu `BTN:943-951` | story data; `postStories` right | **Filter `availablePanes` once at `PDATA:531`**. Feed `hasStories` as `.single(false)`, **not nil**: with `nil` all tabs disappear (`PDATA:1632, 1938, 2310`). Gate the nav button and the menu item |
| Share sheet "Share to Story" | `submodules/ShareController/Sources/ShareController.swift:668` (`shareStory: self.shareStory`) | caller sets `shareStory` | `shareStory: MattermostFeatures.stories ? self.shareStory : nil` |
| Notifications → Stories row; Reactions row (stories part) | `SUI/Notifications/NotificationsAndSoundsController.swift:577, 601` | — | gate the append |
| Deep links (`.story`, `.storyFolder`, `.shareStory`, `.postStory`) | `TUI/OpenResolvedUrl.swift:92` (`switch resolvedUrl`) | — | central deep‑link gate (§1.18) |

### 1.3 Sticker and GIF stores, sticker packs (and custom emoji)

| Surface | Entry point | Decided by | Gate |
|---|---|---|---|
| **Sticker/emoji toggle in the input bar** | `TUI/ChatInterfaceInputContexts.swift:256-267` (`.input(isEnabled: true, inputMode: stickersAreEmoji ? .emoji : .stickers)`) | `stickersEnabled` (banned rights, `:214-231`) | `stickersEnabled = stickersEnabled && MattermostFeatures.stickersAndGifs`. Only the emoji keyboard remains |
| **Sticker / GIF / trending tabs in the keyboard** | `ChatEntityKeyboardInputNode.inputData(…hasTrending:hasSearch:hasStickers:hasGifs:)` (`TUIC/ChatEntityKeyboardInputNode/Sources/ChatEntityKeyboardInputNode.swift:167-180`); the chat call site passes defaults (`TUI/ChatControllerNode.swift:4117-4131`) | parameters default to `true` | pass `hasTrending: false, hasStickers: …, hasGifs: …` at `TUI/ChatControllerNode.swift:4117` |
| Custom emoji (keyboard section, reactions grid) | `areCustomEmojiEnabled` ← `customEmojiAvailable` (`TUI/ChatControllerContentData.swift:2122-2131`, applied `LDN:446`); reactions `TUI/Chat/ChatControllerOpenMessageContextMenu.swift:171-191` | secret‑chat layer; `isPremiumDisabled` | `LDN:446` `&& MattermostFeatures.customEmoji`. **Later:** Mattermost custom emoji is a "Build" item that may reuse this path |
| Sticker suggestions while typing | `.emoji` query → `searchStickers` (`TUI/ChatInterfaceStateContextQueries.swift:97`) | — | gate in `inputContextQueriesForChatPresentationIntefaceState` (`TUI/ChatInterfaceInputContexts.swift:49`) |
| Attach menu "Sticker" / "Emoji" buttons | `AttachmentButtonType` (`submodules/AttachmentUI/Sources/AttachmentController.swift:23`) | — | attach‑menu filter (§1.10) |
| Message menu: Add/Remove favourite sticker, Save GIF, Edit Sticker, View Pack | `CTX:999-1015, 1878-1915, 1923-1937, 1939-1946`; option `.viewStickerPack` at `CTX:2629` | message media | **`reducedOptions.subtract(...)` once at `CTX:2838-2843`** for `.viewStickerPack`; per‑line `if` for the rest |
| Settings → Appearance → "Stickers & Emoji" | `SUI/Themes/ThemeSettingsController.swift:483` | — | gate the entry |
| Settings search "Stickers" items | `SUI/Search/SettingsSearchableItems.swift:1352, 4404-4405` | — | settings‑search filter (§1.18) |
| Deep links `.stickerPack`, `.importStickers` | `TUI/OpenResolvedUrl.swift:92` | — | deep‑link gate |
| Background: greeting sticker prefetch | `CLU/ChatListController.swift:2376` | — | harmless (parks) |

### 1.4 Premium, Stars, boosts, giveaways, gifts (and TON wallet)

Central switches: **AppConfig `premium_purchase_blocked: true`** (§0.2), **nil the Stars/TON/wallet/IAP contexts** (§0.3), and never set `isPremium`.

| Surface | Entry point | Decided by | Gate |
|---|---|---|---|
| Premium star / emoji status next to names (chat list rows) | `CLU/Node/ChatListItem.swift:3574-3581, 3605-3612` (`} else if peer.isPremium && !premiumConfiguration.isPremiumDisabled {`) | `isPremium`, `isPremiumDisabled` | AppConfig hides the star. Emoji status needs `MattermostFeatures.premium` (or reuse it for Mattermost custom status later, internals Assumption 7) |
| Own status in the chat‑list title and the status picker | `CLU/ChatListController.swift:6892-6911` → `openStatusSetup` (`:862`) | `user.emojiStatus` / `isPremium` | `peerStatus = .single(nil)` at `:6894` |
| Folder‑tab Premium lock / limit screens | `CLU/ChatListController.swift:4113` (`let filtersLimit = isPremium == false ? limits.maxFoldersCount : nil`), tab‑bar long‑press `:6376` | `UserLimits` | AppConfig `dialog_filters_limit_default` high; or `nil` at `:4113` and `:6376` |
| Pin limit → Premium screen | `CLU/ChatContextMenus.swift:419-459` | `dialogs_pinned_limit_*` | AppConfig |
| Chat title Premium badge | `TUIC/ChatTitleView/Sources/ChatTitleView.swift:306-314` | `isPremiumDisabled` | AppConfig |
| Attach‑menu and input‑bar **Gift** buttons | attach `TUI/ChatControllerOpenAttachmentMenu.swift:389-417`; input `TUI/ChatInterfaceInputContexts.swift:194-207` | `premiumGiftOptions`, `premium_gift_*_icon`, `alwaysShowGiftButton` | AppConfig, plus the attach filter (§1.10). The funnel `LDN:424, 450` (`alwaysShowGiftButton`, `premiumGiftOptions`) can force them off |
| Message menu "Send gift", custom‑emoji reaction grid, "Hide ad" (Premium) | `CTX:1203-1224` (option `.sendGift` `CTX:2638`); `TUI/Chat/ChatControllerOpenMessageContextMenu.swift:171-191, 235-240` | options / `isPremiumDisabled` | `.sendGift` in the `CTX:2838` subtract |
| **Stars / paid reactions** | `TUIC/Chat/TopMessageReactions/Sources/TopMessageReactions.swift:38-41` (`areStarsEnabled = reactionSettings…starsAllowed`), inserted `:455-469` | per‑peer reaction settings | force `areStarsEnabled = false` at `:38` |
| Paid messages (stars price in placeholder / send button / fee panel) | `TUI/ChatControllerContentData.swift:882, 907-923` → `LDN:422`, `:451` | `sendPaidMessageStars` | data‑driven; `nil` at `LDN:422` |
| Boost buttons (slow mode, unrestrict) | `ITP:1027-1030, 2415`; source `LDN:428` (`boostsToUnrestrict`) | channel data | `nil` at `LDN:428` |
| Peer info: Send Gift (user/channel), **Boost (unconditional)**, gifts pane, header gift cover, star rating, collectible background | `BTN:636-649, 918-926, 928-941`; panes `PDATA:1582, 1595, 1934`; header `PIS/PeerInfoHeaderNode.swift:566-580, 1379-1450, 2547-2576`; gifts context `PDATA:1209-1220, 1867` | flags, `cachedData` | `MattermostFeatures.premium` on the menu items; pane filter at `PDATA:531`; do not create `profileGiftsContext` |
| Peer info: Premium badge / hidden‑status badge | `PIS/PeerInfoHeaderNode.swift:619, 1610` | `isPremiumDisabled` | AppConfig |
| Channel edit: Appearance (boost levels), Auto‑translate (boost), "Don't restrict boosters", charge for messages | `PITEMS:1216-1245`; `submodules/PeerInfoUI/Sources/ChannelPermissionsController.swift:741-773` | admin rights, `.paidMessagesAvailable` | `MattermostFeatures.premium` per row |
| Settings rows: Telegram Premium, Your Stars, My GRAM, Telegram Business, Send a Gift, Money (TON), Emoji Status, Profile Color, Premium expiring | §2 rows 1, 2, 5, 12, 25–29 | `isPremiumDisabled \|\| context.isPremium`, `starsState != nil`, `wallet_available` | drop the `.payment` and `.wallet` sections (§2) |
| Add Account limit (3 accounts, 4 with Premium) → `PremiumLimitScreen` | `PIS/PeerInfoScreenSettingsActions.swift:219-252`; constants `submodules/AccountUtils/Sources/AccountUtils.swift:7-8` (`maximumNumberOfAccounts = 3`) | `isPremium` | for multi‑server, raise `maximumNumberOfAccounts` and skip the Premium screen |
| Attach‑menu "Todo/Checklist" (Premium demo for non‑Premium) | `TUI/ChatControllerOpenAttachmentMenu.swift:274-276`, handler `:963-964` | `canSendTodos`, `isPremium` | attach filter |
| Deep links `.premiumOffer`, `.premiumGiftCode`, `.premiumMultiGift`, `.starsTopup`, `.stars`, `.ton`, `.boost`, `.sendGift`, `.giftCollection`, `.auction`, `.collectible`, `.sendGrams`, `.invoice` | `AC/AccountContext.swift:363-390` (enum), handled at `TUI/OpenResolvedUrl.swift:92` | — | deep‑link gate (§1.18) |
| App‑level contexts and StoreKit observer | `TUI/AccountContext.swift:345-371` | main app | §0.3 |

### 1.5 Payments, bot payments

Mostly **data‑driven**: invoice media (`TelegramMediaInvoice`) only comes from Telegram bots.

| Surface | Entry point | Decided by | Gate |
|---|---|---|---|
| Invoice bubbles, "Pay" buttons | `BotPaymentsUI`, invoice bubble nodes | message media | data‑driven |
| Deep link `.invoice(slug:)` | `AC/AccountContext.swift:363`, `TUI/OpenResolvedUrl.swift:92` | — | deep‑link gate |
| Settings → Privacy → Data Settings → "Clear payment info" | `SUI/Privacy and Security/DataPrivacySettingsController.swift:321-323` | — | screen hidden (§2) |
| StoreKit observer | `TUI/AccountContext.swift:345` | — | §0.3 |
| Apple Pay merchant ids in the entitlements | `submodules/BotPaymentsUI` (internals §9) | official bundle ids only | nothing for our bundle id |

### 1.6 Ads and sponsored messages

| Surface | Entry point | Decided by | Gate |
|---|---|---|---|
| **Sponsored messages in history and the bot ad panel** | `TUI/ChatControllerNode.swift:785-797` (`if let displayAdPeer { self.adMessagesContext = context.engine.messages.adMessages(…) }`); history use `TUI/ChatHistoryListNode.swift:909-1002`; panel `TUI/ChatControllerNode.swift:1575-1618` | peer location; `ExperimentalUISettings.fakeAds` (`TUI/ChatHistoryListNode.swift:916`) | **`if MattermostFeatures.ads, let displayAdPeer`** at `:793`. One gate covers both |
| Sponsored‑message context menu ("Hide ad", "About ads") | `CTX:528-720` | message is sponsored | data‑driven after the gate above |
| Chat list promo rows (proxy sponsor, PSA) | `CLU/Node/ChatListNodeEntries.swift:653` (`view.additionalItems.filter`), inserted `:858-918`; "Ad" label `CLU/Node/ChatListItem.swift:3370-3380` | Postbox additional items (server promo info) | return `[]` at `:653` |
| Sponsored peers in chat‑list search | `CLU/ChatListSearchListPaneNode.swift:2710` (`searchAdPeers`), inserted `:3356` (`if !adsHidden {`) | — | skip at `:3356` |
| Settings: "Sensitive Content" (Data and Storage) | `SUI/Data and Storage/DataAndStorageSettingsController.swift:644-647` | server content settings (stays hidden) | none |

### 1.7 Phone‑number login, contact sync, QR login (and the Contacts tab)

| Surface | Entry point | Decided by | Gate |
|---|---|---|---|
| Phone login, intro carousel, QR login | `AuthorizationSequenceController` (§4) | auth state | replaced by the Mattermost login (§4.3) |
| **Contacts tab** | `TUI/TelegramRootController.swift:208-212` | always | §3 |
| **System Contacts permission prompt on first launch** | `TUI/ApplicationContext.swift:627-660` (order loop; `case .contacts:` `:634`, request `:696-708`). Default order is `[.contacts, .notifications]` (`submodules/TelegramPermissionsUI/Sources/PermissionSplitTest.swift:10, 34-35`) | `requiredPermissions` (`submodules/TelegramPermissions/Sources/Permission.swift:69`) | **skip `.contacts` (and `.siri`, `:652`) in the loop at `:627`** when `!MattermostFeatures.contacts` |
| Contact sync manager | `ContactSyncManager` (internals §2) | started by `resetStateManagement`, which never runs | none |
| Chat list "suggested contacts" section (fewer than 5 chats) | `CLU/Node/ChatListNode.swift:2105` (`if case .chatList(groupId: .root) = location, chatListFilter == nil, case .chatList = mode {`) | notice `displayChatListContacts` | `&& MattermostFeatures.contacts` |
| Chat list row menu "Add to Contacts" | `CLU/ChatContextMenus.swift:180-195` | `!isContact` | gate |
| Chat list search "add contact" for phone numbers | `CLU/ChatListSearchListPaneNode.swift:3471` | `isViablePhoneNumber` | gate |
| Compose menu: New Contact | `TUI/ComposeControllerNode.swift:48-50` (inside the `options:` array at `:44-54`) | always | **build `options` conditionally at `:44`** |
| Contacts tab internals (if ever kept): Add button, "Invite Friends", permission rows and placeholder, tab badge, row menu (Secret chat, Call, Video Call) | `CNT/ContactsControllerNode.swift:102, 115, 333`; `CNT/ContactListNode.swift:456-478, 1268`; `CNT/ContactsController.swift:216, 750-765`; `CNT/ContactContextMenus.swift:125-234` | `DeviceAccess`, `ContactsSettings.synchronizeContacts` | moot once the tab is gone |
| Peer info: phone row, "Share Contact", "Add to Contacts", "Delete contact", birthday | `PITEMS:176-191, 404-408, 1106-1110, 226-245`; `BTN:568-634` | user data | gate per row (`MattermostFeatures.contacts`); Mattermost users have no phone |
| Settings: "Check phone number" suggestion, Phone Number edit row, Privacy → Phone Number, Data Settings → contacts sync/reset | §2 rows 6, edit rows; `SUI/Privacy and Security/DataPrivacySettingsController.swift:311-317` | server suggestions | §2 |
| Notifications → "Contact Joined" | `SUI/Notifications/NotificationsAndSoundsController.swift:618-619` | — | gate the append |
| `NSContactsUsageDescription` | `Telegram/BUILD:1685-1686`, `en.lproj/InfoPlist.strings:3` | — | remove (§5.3) |
| Logout → "Change phone number" / "Contact support" | `SUI/LogoutOptionsController.swift:124-125` | — | gate the appends |

### 1.8 Voice and video calls, group calls

| Surface | Entry point | Decided by | Gate |
|---|---|---|---|
| **Calls tab** | `TUI/TelegramRootController.swift:204, 214-216` | `CallListSettings.showTab` | §3: `showTab` returns `false` |
| Settings → "Recent Calls" | `SITEMS:228-230` | always | gate the append |
| **Peer info header Call / Video Call** | `PDATA:2652-2680` (`peerInfoHeaderButtons`). `callsAvailable = true` when there is no `CachedUserData` (`:2660-2667`); `videoCallsEnabled` hard‑coded `true` (`PIS/PeerInfoScreen.swift:387`) | cached user data | **`if callsAvailable && MattermostFeatures.calls`** at `:2668`. Also used for overflow (`BTN:398-399, 446-461`) |
| Peer info: voice chat / live stream button; call list row | `PDATA:2720-2722, 2779-2781`; `PITEMS:136-138` | `.hasVoiceChat`, call messages | same flag |
| **Chat screen: every call path** (call bubble tap, `.call` bubble action, phone‑number menu, `beginCall`) | single closure `callPeer` at `TUI/ChatController.swift:3629-3656` → `context.requestCall` (`:3653`); callers `TUIC/Chat/ChatMessageCallBubbleContentNode/Sources/ChatMessageCallBubbleContentNode.swift:406`, `LDN:3600-3603` | `callsAvailable` (`LDN:439`) | **early return in `callPeer`**; `updatedCallsAvailable(false)` at `LDN:439` |
| Phone‑number context menu "Telegram call / video call" items | `TUI/Chat/ChatControllerOpenPhoneContextMenu.swift:95-114` | — | remove the items |
| Group‑call / voice‑chat panel in chat | `TUI/ChatControllerNode.swift:1509-1563`, fed by `GlobalControlPanelsContext(groupCalls:)` at `LDN:5040-5046` | location | `groupCalls: MattermostFeatures.calls ? groupCallPanelSource : nil` |
| Group‑call panel in forum chat lists | `CLU/ChatListController.swift:274-275, 284` | forum location | same |
| Join from a service message | `TUI/ChatController.swift:1057-1059` (`.groupPhoneCall` → `joinGroupCall`) | data | data‑driven |
| Message menu "Rate call" | `CTX:1017`, option `.rateCall` `CTX:2636` | call message | `CTX:2838` subtract |
| Contacts row menu Call / Video Call | `CNT/ContactContextMenus.swift:219-227` | — | tab gone |
| Data and Storage → "Use Less Data for Calls"; Privacy → Calls (P2P) | `SUI/Data and Storage/DataAndStorageSettingsController.swift:631-633`; `SUI/Privacy and Security/PrivacyAndSecurityController.swift:751, 781` | — | §2 |
| **CallKit / PushKit** | `CallKitIntegration.isAvailable` (`submodules/TelegramCallsUI/Sources/CallKitIntegration.swift:18-28`); VoIP push registration `TUI/AppDelegate.swift:1098-1103`; `voip` background mode `Telegram/BUILD:1738` | simulator / region | `isAvailable` returns `false` when `!MattermostFeatures.calls`; skip the PushKit registration |
| Broadcast Upload extension (screen sharing in calls) | `Telegram/BUILD:1876` | — | drop it (internals §8) |
| Deep links `.joinCall`, `.joinVoiceChat` | `TUI/OpenResolvedUrl.swift:92` | — | deep‑link gate |

### 1.9 Broadcast channels (Telegram "channels")

| Surface | Entry point | Decided by | Gate |
|---|---|---|---|
| Compose menu "New Channel" | `TUI/ComposeControllerNode.swift:51-53` | always | conditional `options` at `:44` |
| Chat‑list search "Channels" tab (with recommended channels) | `CLU/ChatListSearchPaneContainerNode.swift:112`; data `CLU/ChatListSearchListPaneNode.swift:4218-4220` | — | **filter `defaultAvailableSearchPanes` (`:102-124`)**, see §1.18 |
| "Join Channel" in search row menu | `CLU/ChatContextMenus.swift:474-545` | — | data‑driven (no public channel results) |
| Input bar "silent post" | `TUI/ChatInterfaceInputContexts.swift:217-218` | broadcast channel peer | data‑driven |
| Peer info: Discussion button and menu, channel DMs (monoforum), signatures, linked discussion, "Channel type" | `PDATA:2697-2703, 2723-2729`; `BTN:463-479`; `PITEMS:809-822, 1161-1180, 1248-1302`; `submodules/PeerInfoUI/Sources/ChannelAdminsController.swift:579-585` | `info == .broadcast` | data‑driven: all Mattermost channels map to supergroups (`.group`). Hide "Channel type" / "Group type" (`PITEMS:1137-1147, 1460-1465`) because public/private links are t.me usernames |
| Notifications → "Channels" category; Data and Storage → "Save to Photos: Channels" | `SUI/Notifications/NotificationsAndSoundsController.swift:565`; `SUI/Data and Storage/DataAndStorageSettingsController.swift:619-628` | — | hide the Channels row; relabel Save to Photos |

### 1.10 Bot inline mode, mini apps, web apps

| Surface | Entry point | Decided by | Gate |
|---|---|---|---|
| **Attach menu** (bot apps, gift, poll, todo, money, quick reply, rich text, audio, sticker, emoji) | assembled in `presentAttachmentMenu` (`TUI/ChatControllerOpenAttachmentMenu.swift:56`): base list `:264-280`, wallet `:292-293`, quick reply `:344-356`, bot apps `:359-376` (`attachMenuBots()`), gift `:416`, rich text `:425`; `AttachmentController(…buttons:)` `:477` | peer type and rights, `isPremium`, `wallet_available` | **one filter after `:426`**: `buttons = buttons.filter { MattermostFeatures.isAttachButtonEnabled($0) }`. If `initialButton` was removed, fall back to `.gallery`. Keep gallery, file, location, contact; poll only once Mattermost polls exist |
| **Inline bot mode** (`@bot query`) and inline‑bot mentions | `TUI/ChatInterfaceInputContexts.swift:75` (`types.insert(.contextBots)`), `:80-82` (`.contextRequest`); resolved `TUI/ChatInterfaceStateContextQueries.swift:276` | input text | skip both when `!MattermostFeatures.botWebApps` |
| Bot menu button / web‑app button, bot commands "/" button, bot keyboard | `ITP:1774-1811`; `TUI/ChatInterfaceInputContexts.swift:252-254, 269-271`; state from `LDN:407-409, 435` | `hasBotCommands`, `botMenuButton`, `keyboardButtonsMessage` | force `botMenuButton` to `.commands` at `LDN:409`. **Keep** "/" commands: Mattermost slash commands are a Phase 3 "Build" item that can reuse it |
| Chat list: "Open" button on bot rows; "Apps" search tab | `CLU/Node/ChatListItem.swift:3690` (`botInfo.flags.contains(.hasWebApp)`); `CLU/ChatListSearchPaneContainerNode.swift:113` | bot flags | gate `:3690`; pane filter |
| Peer info: "Open App" in bot info, bot preview pane, similar bots, bot settings/privacy/help menu | `PITEMS:270-302`; `PDATA:1622-1629`; `BTN:492-551` | bot flags | `MattermostFeatures.botWebApps`; pane filter at `PDATA:531` |
| Settings: attach‑menu bots shown in Settings | `SITEMS:198-223` (section `.apps`) | `.showInSettings` bots | drop section `.apps` (§2) |
| Deep links `.startAttach`, `.botStart`, `.groupBotStart`, `.gameStart`, `.createBot`, `.oauth` / `.urlAuth` | `TUI/OpenResolvedUrl.swift:92` | — | deep‑link gate |

### 1.11 Telegram Passport

Already unreachable in practice: every entry needs `twoStepAuthData`, which is network‑only.

| Surface | Entry point | Decided by | Gate |
|---|---|---|---|
| Settings row | `SITEMS:333-337` → `PIS/PeerInfoScreenSettingsActions.swift:178` | `hasPassport` (`PIS/PeerInfoScreen.swift:2071-2074`) | drop section `.extra` (§2) |
| Settings search | `SUI/Search/SettingsSearchableItems.swift:4434-4446` | `hasTwoStepAuth` | search filter (§1.18) |
| `tg://resolve?domain=telegrampassport…` | `TUI/OpenUrl.swift:545` | URL | `tg://` gate (§1.18) |

### 1.12 Business features; nearby people

| Surface | Entry point | Decided by | Gate |
|---|---|---|---|
| Settings "Telegram Business" | `SITEMS:319-323` | `!isPremiumDisabled \|\| isPremium` | AppConfig; section `.payment` |
| Edit profile "Chat Automation" (business bot), "Personal Channel" | `SITEMS:506-534` | — | gate |
| Peer info: business hours / location rows | `PITEMS:371-400` | business data | data‑driven |
| Chat: managing‑bot bar, business‑link panel | `TUI/ChatInterfaceTitlePanelNodes.swift:66-73, 250-292` | data | data‑driven |
| **People Nearby** | none: no UI module references `PeersNearby` at this upstream pin | — | nothing to do |

### 1.13 MTProto proxy settings

| Surface | Entry point | Decided by | Gate |
|---|---|---|---|
| **Chat list proxy shield button** (+ "proxy unavailable" tooltip, iPhone Duo overflow) | `CLU/ChatListController.swift:7367` (`if titleContent.hasProxy {`), fed by `:6874-6884` | `SharedDataKeys.proxySettings` servers | return `(false, false)` at `:6876` |
| Settings root "Proxy" row; Data and Storage → Proxy | `SITEMS:178-195` (section `.proxy`); `SUI/Data and Storage/DataAndStorageSettingsController.swift:649-663` | servers non‑empty / always | drop section `.proxy`; gate the Data row |
| Settings search proxy items | `SUI/Search/SettingsSearchableItems.swift:3677, 4416-4417` | — | search filter |
| `tg://proxy`, `tg://socks`, `tg://webproxy` | `.proxy`, `.webProxy` (`AC/AccountContext.swift:350-351`) | — | deep‑link gate |
| Network effect | none under the null engine (`TC/Account/Account.swift:1575-1585` only feeds `network.updateProxySettings`) | — | — |

The Mattermost HTTP proxy (06 note) would be a new row in Data and Storage, not this one.

### 1.14 Telegram privacy settings

See §2: the Privacy and Security screen becomes Passcode plus "Open Links In". Peer‑side remnants:

- Bio privacy footer: `SITEMS:402-425`, `openBioPrivacy` at `PIS/PeerInfoScreen.swift:3720`.
- Birthday privacy footer: `SITEMS:427-470`.

### 1.15 Message translation

`TranslationConfiguration` defaults to `.disabled` for both modes when `data == nil` (`AC/AccountContext.swift:2108-2110`). That already hides the translation bar (`canTranslateChats`, `submodules/TranslateUI/Sources/Translate.swift:175-190`). **What still shows:**

| Surface | Entry point | Decided by | Gate |
|---|---|---|---|
| Translation bar | `TUI/ChatControllerNode.swift:1565-1573, 1688-1732`; state `TUI/ChatControllerContentData.swift:2212-2224` → `chatTranslationState` (`submodules/TranslateUI/Sources/ChatTranslation.swift:211-216`) | `TranslationConfiguration.auto` | already off; AppConfig keeps it off |
| Message menu "Translate" | `CTX:1456-1481` (`canTranslateText(… showTranslate: translationSettings.showTranslate, showTranslateIfTopical …)` `:1463`) | `TranslationSettings.showTranslate` (default `false`), **but `showTranslateIfTopical` (`CTX:1456-1461`) bypasses both it and the config for uk/ru text in any `TelegramChannel` with a username. Mattermost channels get one if MattermostSync fills `addressName`**; `ExperimentalUISettings.disableLanguageRecognition` returns `canTranslate = true` (`Translate.swift:213-214`) | `if canTranslate && MattermostFeatures.translation` |
| **Text‑selection "Translate"** (bubbles) | `submodules/TextSelectionNode/Sources/TextSelectionNode.swift:286` (`enableTranslate = true`), shown `:794`; handled `TUI/ChatController.swift:4479` (`case .translate:` → `TextProcessingScreen`, server) | **no config check** | `enableTranslate = MattermostFeatures.translation` where set (`ChatMessageTextBubbleContentNode.swift:1675`, `ChatMessageRichDataBubbleContentNode.swift:2309`), or early return at `:4479` |
| Composer "Translate" (text input menu) | `ITP:5001, 5251` → `LDN:4697-4706` (`presentInputTextTranslation`) | `TranslationConfiguration` | gate at `LDN:4697` |
| Peer info "Translate" menu items; channel Auto‑translate | `BTN:673-692, 961-980, 1220-1239`; `PITEMS:1234-1245` | `canTranslateChats`, `.translationHidden` | already off via config |
| Settings → Language → "Translate" section | `SUI/Language Selection/LocalizationListControllerNode.swift:438` | config | already off |

**Keep‑later option:** `TranslationAvailability.system` uses Apple's on‑device `Translation` framework (`submodules/TranslateUI/Sources/Translate.swift:9, 179, 202, 260-312`; `TranslateScreen.swift:30`). Setting `translations_manual_enabled: "system"` would give Mattermost users server‑free translation on iOS 18 or later. Check that each path really avoids `TextProcessingScreen` before enabling it.

### 1.16 Voice‑to‑text

| Surface | Entry point | Decided by | Gate |
|---|---|---|---|
| **Transcribe button on voice bubbles** (visible today) | `TUIC/Chat/ChatMessageInteractiveFileNode/Sources/ChatMessageInteractiveFileNode.swift:769-789`: `isPremium` or group boost, **else `audioTransciptionTrialCount > 0` (default 2, `AC/Premium.swift:169`) for incoming messages under 300 s**, else `alwaysDisplayTranscribeButton` | trial config, `isPremium`, boost level | `displayTranscribe = … && MattermostFeatures.voiceToText` |
| Transcribe button on round videos | `TUIC/Chat/ChatMessageInteractiveInstantVideoNode/Sources/ChatMessageInteractiveInstantVideoNode.swift:829-844` | same | same |
| Shared input for both | `TUI/ChatHistoryListNode.swift:2271-2301` (`DisplayTranscribeButton(canBeDisplayed: …)`) | | **one gate**: force `DisplayTranscribeButton(false, false, false)` at `:2297`, plus AppConfig `transcribe_audio_trial_weekly_number: 0` (`AC/Premium.swift:292`) for the trial branch |
| Message menu "Rate transcription" | `CTX:1085-1100` | expanded transcription | data‑driven |
| `NSSpeechRecognitionUsageDescription` | `Telegram/BUILD:1703-1704` | — | remove (§5.3). `ExperimentalUISettings.localTranscription` (`ChatMessageInteractiveFileNode.swift:422`) is the on‑device path: a possible "Later" option |

### 1.17 Telegram‑only items not on the 06 list

| Feature | Entry point | Decided by | Proposed gate |
|---|---|---|---|
| **AI compose** (rewrite/styles; server) | `isAIEnabled` set at `TUI/ChatInterfaceStateInputPanels.swift:506-509`, `TUI/ChatControllerNode.swift:966-969`, `submodules/AttachmentUI/Sources/AttachmentPanel.swift:2338-2340`, `TUIC/LegacyMessageInputPanel/Sources/LegacyMessageInputPanel.swift:101-103`; button `ITP:3527`, tap `:3903` | **on unless `ios_disable_ai_chat == 1` / `ios_disable_ai_attach == 1`** | AppConfig (§0.2), plus `MattermostFeatures.aiCompose` |
| **"Copy Link" (t.me)** on supergroup messages (visible today; `exportMessageLink` hangs) | `CTX:1809-1844` (condition `:1809`: Cloud message in a `TelegramChannel`) | peer type | `&& MattermostFeatures.tmeLinks` now; Phase 3 replaces it with a Mattermost permalink |
| **"Report"** (visible on incoming channel messages) | `CTX:1959-1964`; option `.report` at `CTX:2658, 2697, 2767, 2806` | options | `.report` in the `CTX:2838` subtract; peer‑info Report `BTN:983-1000, 1241-1255` |
| Message statistics, poll stats, read‑receipt stats, fact check | `CTX:1975-2015, 2017, 2169-2171` | `canViewStats`, `can_edit_factcheck` | data/config‑driven; read receipts (`CTX:64, 141-143`) may be repurposed later |
| Send‑as peer button | `ITP:1786`; source `LDN:797-802` (`engine.peers.sendAsAvailablePeers`, server) | channel/group peer | skip the subscription at `:797` |
| Send‑options sheet: message effects, "send when online", schedule, silent | `TUI/Chat/ChatMessageDisplaySendMessageOptions.swift:53-59, 198-207`; `submodules/ChatSendMessageActionUI/Sources/ChatSendMessageContextScreen.swift:479-501, 557, 578, 601, 623` | peer type | effects: data‑driven (empty cache). Schedule: hide until Mattermost scheduled posts (06 "Later") |
| **Video messages (round videos)**; **voice messages** (06 "Later") | mode toggle `LDN:3055-3118` (`switchMediaRecordingMode`); recording `ITP:898-908`; mic button `ITP:4577` (`var hideMicButton = false`) | `mediaRecordingMode` | `guard MattermostFeatures.videoMessages` at `LDN:3055`. `hideMicButton = !MattermostFeatures.voiceMessages` at `ITP:4577`. That only fades the button, as `businessLinkSetup` already does (`:4708`). **5A (2026‑10‑27): voice messages on** (`MattermostFeatures.voiceMessages = true`): the mic button shows; a tap shows "Hold to record audio." instead of switching to video; view‑once is hidden; §1.16 voice‑to‑text stays off |
| Chat‑list notices (review login, set up password, birthday, Premium upgrade/annual/restore, Stars low balance, account freeze, set photo, …) | enum `TUIC/GlobalControlPanelsContext/Sources/GlobalControlPanelsContext.swift:70-86`; produced `:318-473`; enabled at `CLU/ChatListController.swift:268-273` (`chatListNotices = true` for root) | server data | **`chatListNotices = false`** at `:272`. Today it never emits because it waits on `twoStepAuthData` (`GlobalControlPanelsContext.swift:319`) |
| Chat‑list first‑appearance popups (language suggestion, login email, passkey, auto‑archive alert, forced 2FA, "start chatting" tooltip) | `CLU/ChatListController.swift:2520-2754` (`if !self.didSuggestLocalization {`); featured‑folders tooltip `:2779-2847` | notices | gate the `if` at `:2520`. Keep the archive intro (`:1603-1610`) |
| Global posts search / public posts / downloads tabs | `CLU/ChatListSearchPaneContainerNode.swift:102-124` | `hasPublicPosts`, `hasDownloads` | pane filter (§1.18) |
| Shared folders (invite links, chat‑list updates) | `CLU/ChatListController.swift:1238-1249`; `CLU/ChatListContainerItemNode.swift:206, 313` | folder `isShared` | gate the "Share" item at `:1238` |
| t.me username / QR code | Settings nav QR button `PIS/PeerInfoScreen.swift:5881` → `openQrCode` `:4626`; username rows `PITEMS:192-224, 627-663`; Settings "Set Username" `SITEMS:78-82`; collectible lookup hangs (`PIS/PeerInfoScreenOpenURL.swift:288-291`) | — | `MattermostFeatures.tmeLinks`. Show the Mattermost `@username` read‑only instead |
| Emoji status, profile colour, name colour, chat themes, channel appearance | `SITEMS:64-71`; `SUI/Themes/ThemeSettingsController.swift:439, 450`; `PITEMS:1216-1232` | `isPremium` / boosts | `MattermostFeatures.premium` |
| Auto‑delete timers | `BTN:716-795, 1002-1088, 1139-1218`; Privacy → Auto‑Delete `SUI/Privacy and Security/PrivacyAndSecurityController.swift:705-722` | rights | hide (no Mattermost equivalent) |
| Copy protection ("Disable sharing") | `BTN:797-872` | — | hide |
| Contact/peer "Block" | `PITEMS:420-438`; `BTN:885-909`; Privacy → Blocked Users `PrivacyAndSecurityController.swift:668` | — | hide (Mattermost has no user blocking) |
| Wallet / TON ("Money" attach button, Settings row, Send Money) | `TUI/ChatControllerOpenAttachmentMenu.swift:292-293`; `SITEMS:156-176`; `BTN:651-671` | `WalletConfiguration.isAvailable` (`wallet_available`, default `false`, `submodules/WalletContext/Sources/WalletContext.swift:543, 572`) | already off; §0.3 |
| Apple Watch row | `SITEMS:338-342` | `hasWatchApp` hard‑coded `false` (`PDATA:1060`) | dead |

### 1.18 Cross‑cutting gates

| Gate | Where | What it covers |
|---|---|---|
| **Deep links** | `openResolvedUrlImpl`, `switch resolvedUrl` at `TUI/OpenResolvedUrl.swift:92`. The `ResolvedUrl` enum is at `AC/AccountContext.swift:337-440` | One `guard MattermostFeatures.allows(resolvedUrl) else { completion?(); return }` covers stories, stickers, Premium, Stars, gifts, boosts, proxy, calls, bot apps, invoices and settings sections (`.settings(SettingsSection)` at `:435`) |
| `tg://` and `relay://` parsing | `TUI/OpenUrl.swift:433, 441`: the app‑specific scheme is treated **exactly like `tg://`**; t.me hosts at `submodules/UrlHandling/Sources/UrlHandling.swift:12-28` | Phase 3 permalinks need their own `relay://` branch before `:433`. Until then, consider treating `t.me` links as plain external links (`isTelegramMeLink`, `UrlHandling.swift:1491`) |
| **Settings search** | `settingsSearchableItems` (`SUI/Search/SettingsSearchableItems.swift:4257`), assembled `:4378-4467`. Categories are `SettingsSearchableItemIcon` (`:34-61`) | One `allItems.filter { MattermostFeatures.settingsSearchAllows($0.icon) }` before `return allItems` (`:4467`) removes calls, stickers, privacy, proxy, premium, business, stars, ton, stories, gift, passport, support, faq, tips and delete‑account. Nothing there checks `isPremiumDisabled` today |
| **Chat search tabs** | `defaultAvailableSearchPanes` (`CLU/ChatListSearchPaneContainerNode.swift:102-124`) | Remove `.publicPosts`, `.channels`, `.apps`, `.globalPosts`. Keep chats, media, links, files, music and voice; map them to Mattermost search later |
| **Chat‑state funnel** | `LDN:398-454`, inside `contentDataUpdated` | Masking fields here turns off panels and buttons in one place: `contactStatus` `:405`, bot menu `:407-409`, `sendPaidMessageStars` `:422`, gift `:424`, `boostsToUnrestrict` `:428`, `adMessage` `:431`, `peerVerification` `:432`, `keyboardButtonsMessage` `:435`, calls `:439-441`, `translationState` `:444`, `customEmojiAvailable` `:446`, `premiumGiftOptions` `:450`, `removePaidMessageFeeData` `:451` |
| **Message action options** | `chatAvailableMessageActionsImpl` (`CTX:2526`), reduced at `CTX:2838-2843` | `.viewStickerPack`, `.rateCall`, `.sendGift`, `.report` |
| **Peer‑info panes** | `PDATA:531` (`self.availablePanes = availablePanes`) | stories, story archive, gifts, bot preview, similar channels/bots, in one line |
| **Onboarding / permission prompts** | `TUI/ApplicationContext.swift:600-750` | contacts and Siri prompts (see §1.7). Notification and cellular prompts stay. The terms‑of‑service sheet (`:516-560`) and forced app update (`:586-597`) come from Telegram's state manager and never fire |
| **Home‑screen quick actions** | `TUI/ApplicationShortcutItem.swift:43-61` | drop `.appIcon` |

### 1.19 Kept features that look broken rather than hidden

These are not Hide items, but the inventory turned them up. MattermostSync has to feed them:

- **Reaction picker is empty.** `availableReactions()` and `availableMessageEffects()` only read Postbox caches that Telegram's server fills (`TC/State/AvailableReactions.swift:355`, `TC/State/AvailableMessageEffects.swift:195`). `TopMessageReactions.swift:313-314` then returns `[]`, so the gate at `TUI/Chat/ChatControllerOpenMessageContextMenu.swift:131` hides the whole reaction bar. MattermostSync must write an `AvailableReactions` built from Unicode emoji (and later custom emoji). Also raise `reactions_user_max_default` (§0.2).
- **Settings → Log Out does nothing without a phone number.** It needs `user.phone` (`PIS/PeerInfoScreenSettingsActions.swift:259`), and Mattermost users have none.
- **Calls that hang under the null engine.** Each one shows a spinner forever:
  - "Ask a Question" (`supportPeerId`, `PIS/PeerInfoScreenSettingsActions.swift:181-197`)
  - "FAQ" (`:320-353`)
  - "Telegram Features" (`:356-375`)
  - a username tap (collectible lookup)
  - Privacy rows: `requestAccountPrivacySettings()` never returns (`PIS/PeerInfoScreen.swift:2064`, `SUI/Privacy and Security/PrivacyAndSecurityController.swift:773-787`)
  - channel boost status (`PIS/PeerInfoScreen.swift:2493-2509`)
  - "Copy Link" (`exportMessageLink`)

---

## 2. Settings screen

### 2.1 Where it is assembled

- The Settings tab is `PeerInfoScreenImpl(… isSettings: true)` (`TUI/TelegramRootController.swift:228`).
- Rows are built by **`settingsItems(data:context:presentationData:interaction:isExpanded:)`** (`SITEMS:32-362`), called at `PIS/PeerInfoScreen.swift:5437`.
  - Each row is appended to `items[SettingsSection]`. `enum SettingsSection` (`SITEMS:17-30`) fixes the order: `edit, phone, accounts, myProfile, wallet, proxy, apps, shortcuts, advanced, payment, extra, support`.
  - The result is flattened by one loop at the end (`SITEMS:355-361`):

    ```swift
    for section in SettingsSection.allCases {
        if let sectionItems = items[section], !sectionItems.isEmpty { result.append((section, sectionItems)) }
    }
    ```

- Data: `peerInfoScreenSettingsData` (`PDATA:852-1114`, called at `PIS/PeerInfoScreen.swift:2076`); `TelegramGlobalSettings` (server suggestions, sessions count, …) at `PDATA:1040-1063`.
- Taps: `openSettings(section:)` (`PIS/PeerInfoScreenSettingsActions.swift:22-311`). Section keys: `enum PeerInfoSettingsSection` (`PIS/PeerInfoScreen.swift:158-195`).
- Nav bar: QR code (`PIS/PeerInfoScreen.swift:5881`), Search (`:5882`, §1.18), Edit (`:5883`). Header subtitle: phone and @username (`PIS/PeerInfoHeaderNode.swift:1241-1249`).

**Most central gate.** Skip whole sections in that final loop:

```swift
for section in SettingsSection.allCases where !MattermostFeatures.hiddenSettingsSections.contains(section) {
```

with `hiddenSettingsSections = [.phone, .wallet, .proxy, .apps, .payment, .extra, .support]`. That removes 17 of the 34 rows below with one line. The rest need per‑row `if`s in `.edit`, `.shortcuts` and `.advanced`, plus a new "About" row (§5.4).

### 2.2 Settings root rows

`SITEMS` lines are where the row is appended; `PS` is the `PeerInfoSettingsSection` case in `PIS/PeerInfoScreen.swift`; `SA` is the handler in `PIS/PeerInfoScreenSettingsActions.swift`.

| # | Section | Row | Appended | Existing condition | Opens | Verdict |
|---|---|---|---|---|---|---|
| 1 | edit | Set Emoji Status | `SITEMS:64-67` | `peer.isPremium` | Premium intro (`SA:275`) | Hide (later: Mattermost custom status) |
| 2 | edit | Change Profile Color | `:69-71` | `isPremium` | `UserAppearanceScreen` | Hide |
| 3 | edit | Set Profile Photo | `:74-76` | — | avatar editor | Keep (needs Mattermost upload) |
| 4 | edit | Set Username | `:78-82` | `addressName` empty | `usernameSetupController` | Hide (Mattermost usernames are admin‑managed) |
| 5 | phone | Premium expiring / restore | `:85-89` | `premiumGracePeriod` | subscription URL | Hide (section) |
| 6 | phone | Check phone number | `:90-102` | `suggestPhoneNumberConfirmation` | change phone | Hide (section) |
| 7 | phone | Check password | `:103-111` | `suggestPasswordConfirmation` | 2FA | Hide (section) |
| 8 | phone | Set up password | `:112-117` | `suggestPasswordSetup` | 2FA setup | Hide (section) |
| 9 | accounts | Other accounts | `:120-145` | other accounts exist | `switchToAccount` | Keep (servers) |
| 10 | accounts | Add Account | `:147-149` | same | `SA:219-257`: Premium limit at 3, then `beginNewAuth` | Keep: Mattermost login (§4.3). Drop the Premium limit (§1.4) |
| 11 | myProfile | My Profile | `:152-154` | — | own `PeerInfoScreenImpl` | Keep (hide stories and gifts there) |
| 12 | wallet | Money (TON) | `:156-176` | `wallet_available` (off) | wallet | Hide (section) |
| 13 | proxy | Proxy | `:178-195` | servers non‑empty | proxy list | Hide (section) |
| 14 | apps | Attach‑menu bot apps | `:198-223` | `.showInSettings` bots | web app | Hide (section) |
| 15 | shortcuts | Saved Messages | `:225-227` | — | self chat | Keep (Mattermost self‑DM) |
| 16 | shortcuts | Recent Calls | `:228-230` | — | `CallListController` | Hide (`calls`) |
| 17 | shortcuts | Devices | `:232-245` | label from sessions count and `qr_login_camera` | `recentSessionsController` (`SUI/Privacy and Security/Recent Sessions/RecentSessionsController.swift:631`) | **Replace** with Mattermost sessions (`GET /users/{id}/sessions`); drop "Link Desktop Device" (QR) |
| 18 | shortcuts | Chat Folders | `:246-248` | — | folder settings | Keep (team folders, local) |
| 19 | advanced | Notifications and Sounds | `:250-258` | permission warning badge | `notificationsAndSoundsController` | Keep; hide Channels (`NotificationsAndSoundsController.swift:565`), Stories (`:577`), story part of Reactions (`:601`), Contact Joined (`:618-619`). Later: map to Mattermost notify props |
| 20 | advanced | Privacy and Security | `:259-261` | — | `privacyAndSecurityController` (`SUI/Privacy and Security/PrivacyAndSecurityController.swift:850`) | **Replace** with a slim screen (§2.3) |
| 21 | advanced | Data and Storage | `:262-264` | — | `dataAndStorageController` (`SUI/Data and Storage/DataAndStorageSettingsController.swift:668`) | Keep, trimmed (§2.4) |
| 22 | advanced | Appearance | `:265-267` | — | `themeSettingsController` (`SUI/Themes/ThemeSettingsController.swift:507`) | Keep; hide app icons (`:485-487`, §5.1), Stickers & Emoji (`:483`), name colour (`:450`), chat themes (`:439`, server themes) |
| 23 | advanced | Power Saving | `:269-271` | — | energy saving | Keep |
| 24 | advanced | Language | `:273-276` | — | `LocalizationListController` | Keep only with bundled languages; the server list never loads (§5.3). Otherwise hide |
| 25 | payment | Telegram Premium | `:278-284` | `!isPremiumDisabled \|\| context.isPremium` | Premium intro | Hide (section) |
| 26 | payment | Your Stars | `:285-301` | `starsState != nil && (…)` | Stars | Hide (section) |
| 27 | payment | My GRAM (TON) | `:302-318` | TON balance | TON | Hide (section) |
| 28 | payment | Telegram Business | `:319-323` | as row 25 | business setup | Hide (section) |
| 29 | payment | Send a Gift | `:324-330` | `starsState != nil && (…)` | gift picker | Hide (section) |
| 30 | extra | Telegram Passport | `:333-337` | `hasPassport` | Passport | Hide (section) |
| 31 | extra | Apple Watch | `:338-342` | hard‑coded `false` | — | Hide (section, dead anyway) |
| 32 | support | Ask a Question | `:345-347` | — | `supportPeerId` (**hangs**) | Hide (section); replace with "Help" → server help link from the client config |
| 33 | support | Telegram FAQ | `:348-350` | — | FAQ Instant View (**hangs**) | Hide (section) |
| 34 | support | Telegram Features | `:351-353` | — | `@TelegramTips` (**hangs**) | Hide (section); add **About Relay** (§5.4) |

**Not in the root list:**

- **Log Out** is in the Edit screen (`SITEMS:557-559`) and the Settings‑tab long‑press menu (`PIS/PeerInfoSettingsTabActions.swift:33-36, 72-107`). It does nothing without a phone number (§1.19). The intermediate `logoutOptionsController` (`SUI/LogoutOptionsController.swift:116-127`) offers Add Account, Set Passcode, Clear Cache, **Change Phone Number**, **Contact Support**, Log Out. Keep the first three and Log Out.
- **Debug** opens from the Settings tab item (`TUI/TelegramRootController.swift:229-234`).
- `.stickers` and `.stories` cases have handlers but are never appended.

**Edit‑profile screen** (`settingsEditingItems`, `SITEMS:364`):

| Row | Lines | Verdict |
|---|---|---|
| First / last name, bio | `SITEMS:402-425` | Keep (`PUT /users/me/patch`); hide the bio privacy footer |
| Birthday | `:427-470` | Hide |
| Phone Number | `:472-476` | Hide |
| Username | `:477-483` | Read‑only |
| Your Color | `:485-504` | Hide |
| Personal Channel | `:506-521` | Hide |
| Chat Automation (business bot) | `:524-534` | Hide |
| Add Another Account | `:536-555` | Keep (Mattermost login) |
| Log Out | `:557-559` | Keep; fix the phone guard |

### 2.3 Privacy and Security → replace

Built in `privacyAndSecurityControllerEntries` (`SUI/Privacy and Security/PrivacyAndSecurityController.swift:647-829`). Every row except two is Telegram‑only:

- **Keep:** Passcode / Face ID (`:681-690`), Open Links In (`:826` → `webBrowserSettingsController`).
- **Hide (Telegram concepts):**
  - Blocked Users `:668`; Active Websites `:669-671`
  - Two‑Step Verification `:695`; Passkeys `:697-703` (`ios_display_passkeys`); Login Email `:724-739`
  - Auto‑Delete Messages `:705-722`
  - Privacy rows `:743-787`: Phone Number, Last Seen, Profile Photos, Bio, Gifts, Birthday, Saved Music, Forwarded Messages, Calls (+P2P), Voice Messages, Messages (non‑contacts / paid), Groups & Channels
  - Auto‑archive `:791-806` (`autoarchive_setting_available`; already hidden)
  - Delete account if away `:808-821`
  - Data Settings `:823-824` → `DataPrivacySettingsController.swift:311-330` (contacts sync, frequent contacts, cloud drafts, payment info, secret‑chat previews, bots)
- These rows also **hang**: the screen waits on `requestAccountPrivacySettings()` (`:773-787`).

Simplest: on the Settings row (`SA:102-138`), open a new two‑row `ItemListController` (Passcode and Open Links In) instead of `privacyAndSecurityController`. The Passcode screen is self‑contained in `PasscodeUI`. Do the same for the settings‑search `.privacy` items.

### 2.4 Data and Storage → keep, trim

Built in `dataAndStorageControllerEntries` (`SUI/Data and Storage/DataAndStorageSettingsController.swift:606-666`):

- **Keep:**
  - Storage Usage `:609`; Data Usage `:610` (counters are Telegram network stats: zero, or relabel later)
  - Auto‑download `:612-617`; Save to Photos `:619-628` (relabel "Channels")
  - Share Sheet `:636-638`; Save Edited Photos `:639`; Pause Music `:640`; Raise to Listen `:641-642`
- **Hide:**
  - Use Less Data for Calls `:631-633`
  - Proxy `:649-663`
  - Sensitive Content `:644-647` (server‑driven, already hidden)

### 2.5 Settings search

See §1.18: one filter on `SettingsSearchableItemIcon` before `return allItems` (`SUI/Search/SettingsSearchableItems.swift:4467`). Keep `profile`, `savedMessages`, `devices` (re‑pointed), `chatFolders`, `notifications`, `data`, `appearance`, `powerSaving`, `language` (if kept) and passcode (filed under `.privacy`, `:2198-2201`: keep those ids). Drop the rest.

---

## 3. Tab bar

**Where it is built.** `TelegramRootController.addRootControllers(showCallsTab:)` (`TUI/TelegramRootController.swift:197-246`):

```swift
let callListController = CallListController(context: self.context, mode: .tab)        // :204
let contactsController = ContactsController(context: self.context)                     // :208
controllers.append(contactsController)                                                 // :212
if showCallsTab { controllers.append(callListController) }                             // :214-216
controllers.append(chatListController)                                                 // :217
… controllers.append(accountSettingsController)                                        // :236
tabBarController.setControllers(controllers, selectedIndex: restoreSettignsController != nil ? (controllers.count - 1) : (controllers.count - 2))  // :238
```

- `updateRootControllers(showCallsTab:)` (`:248-260`) rebuilds the same list and **force‑unwraps** `self.contactsController!` (`:253`) and `self.callListController!` (`:255`).
- `showCallsTab` comes from `CallListSettings.showTab`. It is read at launch (`TUI/AppDelegate.swift:1272-1296`), passed into `AuthorizedApplicationContext` (`TUI/ApplicationContext.swift:158, 169, 252`) and live‑updated (`:805-817`). Its getter defaults to `true` when unset (`submodules/TelegramUIPreferences/Sources/CallListSettings.swift:12-18`).
- The Settings tab is `PeerInfoScreenImpl(… isSettings: true)` (`:228`). Its `tabBarItemDebugTapAction` opens the Debug controller (`:229-234`; the chat list has the same hook at `CLU/ChatListController.swift:742`).
- Other dependents: `getContactsController()` (`:151-153`, protocol `AC/AccountContext.swift:1094`) is used by the `.contacts` deep link (`TUI/OpenResolvedUrl.swift:896-900`). `openChatsController` finds the chat list by type (`:263-280`), so tab indices don't matter there.

**Minimal change (Chats + Settings).**

1. Calls: make `CallListSettings.showTab` return `false` when `!MattermostFeatures.calls` (`CallListSettings.swift:12-18`). This one edit covers launch, live updates and the Calls toggle in `CallListUI` (`submodules/CallListUI/Sources/CallListControllerNode.swift:497`). Don't construct `CallListController` at `:204` either: it subscribes to the call list and group calls.
2. Contacts: in `addRootControllers` only create and append `ContactsController` when `MattermostFeatures.contacts` (`:208-212`). In `updateRootControllers` replace the force unwraps with `if let`. `contactsController` is already `ContactsController?` (`:78`), and `getContactsController()` returns an optional. `ContactsController` reads device contacts on load, so don't construct it at all.
3. `selectedIndex` (`:238`) stays correct for `[Chats, Settings]`: `count - 2 == 0` is Chats and `count - 1` is Settings.
4. A future **Threads** tab is one more `controllers.append(threadsController)` between `:217` and `:236`, plus the same line in `updateRootControllers` (`:257-258`). `TabBarControllerImpl.setControllers` takes any `[ViewController]` (`submodules/TabBarUI/Sources/TabBarController.swift:448`). Keep a `threadsController` property for deep links, the same way `chatListController` is kept.
   - With `[Chats, Threads, Settings]`, `count - 2` would select Threads. Change `:238` to `controllers.firstIndex(where: { $0 === chatListController })`.

Related: the home‑screen quick actions (`TUI/ApplicationShortcutItem.swift:43-61`) are Search, New Message, Saved Messages and App Icon / Switch Account. Drop `.appIcon` (`:56`) if alternate icons go (§5.1).

---

## 4. Login UI reuse

### 4.1 How Telegram's flow is built

- `AuthorizationSequenceController` (`AUI/AuthorizationSequenceController.swift:34`) is a `NavigationController`. Its init (`:66`) takes an `UnauthorizedAccount` and `apiId`/`apiHash`, and creates an `InAppPurchaseManager` (`:86`, for paid sign‑up). It drives every screen from the **Postbox auth state machine**: it subscribes to `engine.auth.state()` (`:88-100`) and maps `UnauthorizedAccountStateContents` to screens in `updateState` (`:1245-1360`; contents enum at `TC/SyncCore/SyncCore_UnauthorizedAccountState.swift:177`).
- Screen factories in the controller, and what the screens need:

  | Screen | Factory | Controller init | Couplings |
  |---|---|---|---|
  | Splash (RMIntro "Start Messaging" carousel) | `splashController()` `:131` | `AuthorizationSequenceSplashController(accountManager:account:theme:)` (`…SplashController.swift:33`) | `UnauthorizedAccount`, Telegram tour |
  | Phone entry | `phoneEntryController(countryCode:number:splashController:)` `:161` | `…PhoneEntryController(sharedContext:account:countriesConfiguration:apiId:apiHash:isTestingEnvironment:otherAccountPhoneNumbers:network:presentationData:openUrl:back:)` (`…PhoneEntryController.swift:67`) | `Network`, phone formatting, QR login, proxy |
  | Code entry (SMS / app / email / fragment) | `codeEntryController(...)` `:365` | `public init(sharedContext:presentationData:back:)` (`…CodeEntryController.swift:51`); `loginWithCode` callback `:23` | Node (1,118 lines) is phone‑code specific: timers, "resend via SMS", animations |
  | Email setup / login | `emailSetupController(number:appleSignInAllowed:)` `:734` | `…EmailEntryController(context:presentationData:mode:blocking:back:)` (`…EmailEntryController.swift:47`); `proceedWithEmail` `:27` | Sign in with Apple button |
  | Password (2FA) | `passwordEntryController(hint:suggestReset:syncContacts:)` `:918` | `…PasswordEntryController(sharedContext:presentationData:back:)` (`…PasswordEntryController.swift:46`, **internal**); `loginWithPassword` `:20`, `forgot` `:21`, `reset` `:22` | Monkey animation, "Forgot password" / reset copy |
  | Sign up (name + photo) | `signUpController(...)` `:1123` | `…SignUpController(sharedContext:presentationData:back:displayCancel:)` (`…SignUpController.swift:51`, internal) | Telegram terms of service |

- Success is `switchToAuthorizedAccount(transaction:account:isSupportUser:)` (`TC/Authorization.swift:18-39`, **internal**): `updateRecord`, `setCurrentId`, `removeAuth`.
- Cancel ("Add Account" then back) is `transaction.removeAuth()` when other accounts exist (`AUI/AuthorizationSequenceController.swift:176-185`).

### 4.2 Recommendation

**Don't reuse `AuthorizationSequenceController` or its screens.** The controller is bound to the Postbox auth state machine and `engine.auth` calls, which park forever under the null engine. Most screens are internal to `AuthorizationUI`, and each node is full of Telegram‑specific behaviour (phone codes, monkey, terms of service). **Build new MattermostUI screens**, borrowing these public building blocks:

| Need | Reuse | Where |
|---|---|---|
| Form screens that work **without an `AccountContext`** | `ItemListController` + `ItemListSingleLineInputItem` (`.regular(capitalization:false, autocorrection:false)`, `.password`, `.number`), `ItemListNavigationButton` (Done/progress), `ItemListTextItem` footers | The template is `proxyServerSettingsController(sharedContext:context: nil, presentationData:updatedPresentationData:accountManager:network:currentSettings:)` (`SUI/Data and Storage/ProxyServerSettingsController.swift:320-440`). Telegram already presents it **from the login screen**, before any account exists. Inputs at `:134-168`, Done button `:406`, `ItemListController(...)` `:439` |
| Branded "auth look" screen (animation + title + text field + big button + "or" divider) | `AuthorizationLayoutItem` / `layoutAuthorizationItems` (public, `submodules/AuthorizationUtils/Sources/AuthorizationLayout.swift:16, 49`), `SolidRoundedButtonNode`, `TextFieldNode`, `DefaultAnimatedStickerNodeImpl` for a Lottie | Copy the structure of `AuthorizationSequenceEmailEntryControllerNode` (`AUI/AuthorizationSequenceEmailEntryControllerNode.swift:51-120`). Its `AuthorizationDividerNode` (`:13-49`) is internal, so copy it (~35 lines). Its Sign in with Apple slot is where the SSO buttons go |
| Navigation bar style of the auth flow | `AuthorizationSequenceController.navigationBarTheme(_:)` (`AUI/AuthorizationSequenceController.swift:35-37`, internal static; copy it) | |
| MFA code field | `CodeInputView` (public, `submodules/CodeInputView/Sources/CodeInputView.swift:8`; `update(theme:prefix:count:width:compact:)` `:311`, `updated` callback `:120`), or simply `ItemListSingleLineInputItem(type: .number)` | |
| SSO | `ASWebAuthenticationSession` plus MattermostKit's `MobileSSO.loginURL(serverURL:provider:redirectURL:)` (`submodules/MattermostKit/Sources/MattermostKit/Auth/MobileSSO.swift:48`) | The callback scheme does **not** need to be in `CFBundleURLTypes` for `ASWebAuthenticationSession`. This matters because `relay://` is not registered today (internals §9) |

**Suggested screens** (all in `submodules/MattermostUI`):

1. **Server** (`ItemListController`): URL field, then `/system/ping` and the client config. A footer shows the server name and version.
2. **Sign in** (an auth‑look `ViewController`): username/email and password fields, "Sign in". Below an "or" divider, one `SolidRoundedButtonNode` per enabled SSO provider from the client config.
3. **MFA**: `CodeInputView`, six digits, shown when login returns `mfa_required`.
4. A **progress/bootstrap** screen until the first sync is done.

Phase 2 can ship 1–3 as `ItemListController`s in days and restyle 2 later. Nothing else depends on how they look.

### 4.3 How the login root replaces the auth flow

The app shows auth like this:

1. `SharedAccountContextImpl` creates an auth record when there is no primary account and no auth (`TUI/SharedAccountContext.swift:825-832`).
2. `accountWithId` turns it into an `UnauthorizedAccount` (`:681-692`).
3. `AppDelegate` maps it to an `UnauthorizedApplicationContext` (`TUI/AppDelegate.swift:1309-1361`).
4. It presents `context.rootController` on the window root once it is ready (`:1489-1495`) and dismisses it on completion (`:1451-1470`).

`UnauthorizedApplicationContext.rootController` is typed `AuthorizationSequenceController` (`TUI/ApplicationContext.swift:41`) and built at `:56`. The AppDelegate only uses `NavigationController` API on it (`ready`, `view.endEditing`, `dismiss()`).

Today's Spike A hook replaces step 1 with `MattermostSpikeSeeder.createSeededAccountIfNeeded` (`TUI/SharedAccountContext.swift:828-829`).

The research doc listed two options (internals §1.4). With the AppDelegate wiring above, **option (a) is less code than (b)**:

- **(a) Keep the auth record, swap the root controller.** Recommended.
  1. Change `let rootController: AuthorizationSequenceController` to `NavigationController` (`ApplicationContext.swift:41`). At `:56` build `MattermostLoginController(sharedContext:account:presentationData:completed:)` when `MattermostFeatures.mattermostLogin`.
  2. In `UnauthorizedAccount.init`, guard the DC auth‑key prefetch and backup‑address discovery (`TC/Account/Account.swift:201-215`) with `if !MattermostBackend.isEnabled`. This is simpler than the `MTContext` external‑action trick in internals §1.4. `UnauthorizedAccountStateManager` is passive.
  3. Restore `self.beginNewAuth(...)` at `SharedAccountContext.swift:831` (drop the seeder branch, keep it behind a debug flag).
  4. On success, MattermostSync:
     - writes `AuthorizedAccountState`, the own user and the synthetic `AppConfiguration` (§0.2) into `unauthorizedAccount.postbox`;
     - stores the server URL and token (Keychain);
     - repeats `switchToAuthorizedAccount`'s three record calls: `updateRecord` (environment + sort order), `setCurrentId`, `removeAuth`.

     The `AccountManagerModifier` members are public (internals §1.4), so no TelegramCore change is needed.

  What this buys:
  - **"Add Account" works unchanged.** The Settings row (`PIS/PeerInfoScreenSettingsActions.swift:255`), settings search (`SUI/Search/SettingsSearchableItems.swift:378`) and logout options (`SUI/LogoutOptionsController.swift:171`) all call `beginNewAuth`.
  - The AppDelegate's present/dismiss and "wait for the new account, then dismiss" logic (`AppDelegate.swift:1451-1466`) is reused.
  - Cancel = `removeAuth()`, as Telegram does (`AUI/AuthorizationSequenceController.swift:176-181`).
- **(b) Bypass auth records.** The AppDelegate would need a third presentation path next to `context` and `authContext` (`AppDelegate.swift:1259-1361`), and every `beginNewAuth` caller would need rerouting. Only worth it if `UnauthorizedAccount` can't be made silent.

Also in `UnauthorizedApplicationContext.init`:
- it requests **cellular‑data access** (`ApplicationContext.swift:75-83`); keep it;
- it subscribes to `serviceNotificationEvents` (`:85-94`); it stays silent.

---

## 5. Rebranding additions (beyond internals §9)

### 5.1 App icons

- **Primary icon:** an Icon Composer bundle `Telegram/Telegram-iOS/Telegram.icon/` (`icon.json` plus `Assets/Plane.svg`, `Assets/Oval.svg`), wired by `composer_icon_folders = ["Telegram"]` (`Telegram/BUILD:339`) → `filegroup "{name}_icon"` (`:350-357`) → `app_icons` (`:1850`).
  - Replace the two SVGs and the layer names in `icon.json`. Or add `Relay.icon` and change `composer_icon_folders`.
  - The same bundle has `watchOS` specializations; the watch app is dropped anyway.
- **Alternate icons:** 12 `*.alticon` folders of PNGs (`Telegram/BUILD:324-337` `alternate_icon_folders`, `:341-348`, `:1851-1853`). There are also `AppIcons.xcassets` (Black/BlackFilled/Blue/BlueFilled `.appiconset`, `:303-308`) and `DefaultAppIcon.xcassets` (`AppIconLLC`, `:310-315`; commented out of `resources` at `:1856`).
  - The in‑app list is `getAvailableAlternateIcons` (`TUI/AppDelegate.swift:992-1016`): 8 regular, `WhiteFilledIcon` for internal builds, 3 Premium icons.
  - **Return `[]` and empty `alternate_icon_folders`.** The Appearance screen hides its icon picker when the list is empty (`SUI/Themes/ThemeSettingsController.swift:485-487`), and Premium's icon demo goes away with Premium (`submodules/PremiumUI/Sources/PremiumDemoScreen.swift:527`). Also drop the `.appIcon` home‑screen shortcut (`TUI/ApplicationShortcutItem.swift:56`).
  - `BlueIcon@3x.png` is also the UTI icon of the `.tgios-theme` document type (`Telegram/BUILD:1776-1797`, icon at `:1784`).
- **Quick‑action glyphs:** `Telegram/Telegram-iOS/Icons.xcassets/Shortcuts/{Account,AppIcon,SavedMessages}.imageset` (`:296-301`).

### 5.2 Launch screen

`Telegram/Telegram-iOS/Base.lproj/LaunchScreen.xib` (25 lines; `Telegram/BUILD:359-364`, `UILaunchStoryboardName` `:1748-1749`) is an empty view with `systemBackgroundColor` and no logo. **Nothing to rebrand.** Adding a logo is optional.

### 5.3 "Telegram" in `PresentationStrings`

**How strings work:**

- The genrule `GeneratedPresentationStrings` (`Telegram/BUILD:148-166`) runs `build-system/GenerateStrings/GenerateStrings.py` on `Telegram-iOS/en.lproj/Localizable.strings`. It emits `PresentationStrings.h/.m` (one accessor per key) and `PresentationStrings.data` (the **key table only**, `GenerateStrings.py:669-671`).
- **Values are not compiled in.** At runtime they come from one of:
  - the bundled `en.lproj/Localizable.strings`, loaded as `defaultPresentationStrings` (`submodules/TelegramPresentationData/Sources/DefaultPresentationStrings.swift:44`);
  - a downloaded language pack (`LocalizationSettings` → `PresentationData.swift:419, 826`, `dictFromLocalization` `:127`);
  - with a final fallback to the bundle's `en` table in the generated `getSingle` (`GenerateStrings.py:447-475`).
- The 18 other languages are empty stub files (`Telegram/BUILD:172-199`; `AppStringResources` `:273-280`). Language packs only come from Telegram's server (`langpack.getLangPack`), which the null engine never reaches. **Relay is English‑only until we ship our own translations.** Hide the Language row or ship bundled packs (§2).

**Size of the problem.** 598 lines of `en.lproj` contain "Telegram" (internals §9):
- about 200 are "Telegram Premium", plus Passport (8), Stars (7), Ads (11), Business (4) and Gifts (3). These are all on hidden surfaces.
- about **100 keys** remain on surfaces we keep. Examples:
  - `Settings.FAQ`, `Settings.Tips`, `Cache.Help`, `ClearCache.*`, `StorageManagement.*`, `PasscodeSettings.EncryptDataHelp`
  - `EnterPasscode.*`, `DialogList.PasscodeLockHelp`, `AccessDenied.*Restricted`, `Media.LimitedAccessText`, `Attachment.CameraAccessText`
  - `Conversation.UnsupportedMedia*` / `Conversation.UpdateTelegram`, `Update.AppVersion` ("Telegram %@"), `Share.AuthTitle` / `Share.AuthDescription`
  - `Notification.Joined`, `PUSH_CONTACT_JOINED`, `Username.Help`, `Report.Succeed`, `Intents.ErrorLockedText`, `Widget.GalleryTitle`
  - `Application.Name` (defined, but no Swift or ObjC reference)

**Cleanest override: a branded overlay applied at build time.**

1. Add `Telegram/Telegram-iOS/Relay.strings` with only the overridden or new keys. Mattermost‑specific strings (login, threads, …) go here too.
2. Add a genrule `RelayLocalizableStrings` that merges `en.lproj/Localizable.strings` + `Relay.strings` (the later key wins) into `en.lproj/Localizable.strings` in the output tree. That is the same output path pattern the empty‑language genrules already use (`Telegram/BUILD:193-199`).
3. Point both `GeneratedPresentationStrings` (`:149-152`, so new keys get accessors) and `AppStringResources` (`:276`, so the shipped values are the merged ones) at the merged file.
4. Optional: a CI check that fails on new "Telegram" in values of keys that the UI still reaches.

Why this beats a regex over the whole file: upstream's file stays untouched, so cherry‑picks don't conflict. Hidden‑feature strings, where "Telegram" is part of a product name, are left alone. The other 18 languages are empty anyway.

A runtime substitution in `defaultPresentationStrings` would also miss the `getSingle` bundle fallback and the `InfoPlist.strings` files. Avoid it.

**Not in `Localizable.strings`:**

- Usage descriptions: `Telegram/Telegram-iOS/en.lproj/InfoPlist.strings:3-6` (contacts and location texts name Telegram) and the base copies in `TelegramInfoPlist` (`Telegram/BUILD:1685-1704`; e.g. `NSContactsUsageDescription` "Telegram stores your contacts…"). Drop `NSContactsUsageDescription`, `NSSiriUsageDescription` and `NSSpeechRecognitionUsageDescription` ("transcribe audio messages") if those features stay hidden.
- `UIBackgroundModes` includes `voip` and `location` (`Telegram/BUILD:1732-1741`). With calls and live location hidden, App Review will ask about `voip`. PushKit VoIP registration is in `TUI/AppDelegate.swift:1098-1103`.
- The photo‑library album name is the literal `"Telegram"` (`TUI/StoreDownloadedMedia.swift:12`).
- `Telegram/Share/en.lproj/Localizable.strings:2-3` duplicates `Share.AuthTitle` / `Share.AuthDescription`. They are shown by `ShareExtensionContext.swift:969` when no account is signed in.

### 5.4 About and version screens

- **Telegram has no About screen.** The version appears only in Debug settings (`submodules/DebugSettingsUI/Sources/DebugController.swift:1678-1683`: bundle id, `CFBundleShortVersionString`, build). Debug is opened by tapping the Settings or Chats tab item (`TUI/TelegramRootController.swift:229`, `CLU/ChatListController.swift:742`). The version also appears in the forced‑update sheet (`Update.AppVersion`, shown from `TUI/ApplicationContext.swift:586-597`; it never fires under the null engine).
- The help rows "Ask a Question", "Telegram FAQ" and "Telegram Features" (§2) are the natural slot for an **"About Relay"** row. Build it as an `ItemListController` with:
  - the version (copy `DebugController` `.versionInfo`);
  - the connected server and its version;
  - licenses, plus the **GPL source offer** link required by [08 · Legal](../plan/08-legal-and-licensing.md).

### 5.5 Share extension and notifications

- **Share extension name and icon** come from `CFBundleDisplayName` in `AppNameInfoPlist` (merged into every extension, `Telegram/BUILD:633-640`) and from the primary app icon. Nothing else is branded.
- **Notifications.** iOS draws the app name and icon above each notification. That comes from the same display name and icon.
  - `NotificationService` sets the title and body from the push payload. Two literals, "You have a new message", are used when previews are hidden or the app is locked (`Telegram/NotificationService/Sources/NotificationService.swift:853, 1411`).
  - Telegram's `loc-key` pushes resolve `PUSH_*` keys from the app's `Localizable.strings` (`en.lproj/Localizable.strings:16, 102`). Our push proxy controls the payload, so either reuse a few `PUSH_*` keys or send plain `alert` text.
  - Lock‑screen privacy wording: `Notifications.DisplayNamesOnLockScreenInfoWithLink`.
- **CallKit** shows the app name and icon in the system call UI. `CallKitIntegration.isAvailable` (`submodules/TelegramCallsUI/Sources/CallKitIntegration.swift:18-28`) is the central off switch: return `false` when `!MattermostFeatures.calls`.

---

## 6. Ordering advice

Each step builds and runs on its own, and none depends on a later one. Largest visible impact per line changed comes first. Mark every upstream edit `// MATTERMOST:`.

| # | Change | Files | Hides / fixes | Size |
|---|---|---|---|---|
| 1 | **Synthetic `AppConfiguration`** written by the seeder (later by MattermostSync bootstrap) | `submodules/MattermostSync` only (§0.2) | Premium promos, badges and rows; AI compose; voice‑to‑text trial; gift icons; translation stays off; limits raised (folders, pins, reactions, message length) | ~20 lines, **no upstream edit** |
| 2 | Add `MattermostFeatures` | new `TC/Mattermost/MattermostFeatures.swift` | nothing yet | 1 file |
| 3 | **Tab bar + first‑launch prompts** | `CallListSettings.swift:12-18`; `TUI/TelegramRootController.swift:204-260`; `TUI/ApplicationContext.swift:627-660` (skip contacts and Siri) | Calls and Contacts tabs; system Contacts permission prompt | ~25 lines |
| 4 | **Settings root + search** | `SITEMS:355-361` (section loop) and rows 1, 2, 4, 16; `SUI/Search/SettingsSearchableItems.swift:4467`; `PIS/PeerInfoScreen.swift:5881` (QR) | 17 rows with one line; Premium, Proxy, Passport, Help rows; hanging FAQ and support | ~30 lines |
| 5 | **Chat screen funnels** | attach filter (`TUI/ChatControllerOpenAttachmentMenu.swift:426`); `stickersEnabled` (`TUI/ChatInterfaceInputContexts.swift:214-231`); keyboard params (`TUI/ChatControllerNode.swift:4117`); `callPeer` (`TUI/ChatController.swift:3629`) + `LDN:439`; ads (`TUI/ChatControllerNode.swift:793`); transcribe (`TUI/ChatHistoryListNode.swift:2297`); `CTX:2838` subtract + Copy Link `:1809` + Translate `:1463`; text‑selection translate; mic and video mode (`ITP:4577`, `LDN:3055`) | attach‑menu bots, gift, poll, todo; stickers and GIFs; calls; ads; voice‑to‑text; Copy Link, Report, Translate | ~40 lines |
| 6 | **Chat list** | stories `CLU/ChatListController.swift:2189, 320, 6694`; proxy `:6876`; notices `:272`; popups `:2520`; compose options `TUI/ComposeControllerNode.swift:44`; search panes `CLU/ChatListSearchPaneContainerNode.swift:102`; promo rows `CLU/Node/ChatListNodeEntries.swift:653`; story rings `:758`; suggested contacts `CLU/Node/ChatListNode.swift:2105`; emoji status `CLU/Node/ChatListItem.swift:3574-3612` | story bar and camera, proxy shield, notices, New Channel/Contact, Channels/Apps/global search | ~30 lines |
| 7 | **Peer info** | `peerInfoHeaderButtons` `PDATA:2668`; panes `PDATA:531` + `hasStories` → `.single(false)`; `BTN` items (gift, boost, secret chat, share contact, translate, auto‑delete, block, report); `PITEMS` rows (phone, username, birthday, bot app); `PIS/PeerInfoScreen.swift:5889` post story | call buttons, stories and gifts panes, boost, gifts | ~40 lines |
| 8 | **Deep links, share sheet, quick actions** | `TUI/OpenResolvedUrl.swift:92`; `ShareController.swift:668`; `TUI/ApplicationShortcutItem.swift:56` | every hidden feature reached by link | ~15 lines + `allows(_:)` |
| 9 | **App‑level services** | `TUI/AccountContext.swift:340-372` (nil IAP/Stars/TON/wallet/gift contexts); `CallKitIntegration.isAvailable`; PushKit `TUI/AppDelegate.swift:1098-1103`; `Telegram/BUILD` drop `voip` background mode, BroadcastUpload/Siri/Widget extensions (internals §8) | StoreKit observer, Stars/TON polling, CallKit, VoIP pushes | ~15 lines |
| 10 | **Settings sub‑screens** | slim Privacy screen (§2.3); Data and Storage rows (§2.4); Notifications rows (§2 row 19); Appearance rows (§2 row 22); Logout options; logout phone guard (`PIS/PeerInfoScreenSettingsActions.swift:259`) | Telegram privacy, proxy, calls data saving | one new small `ItemListController` + ~20 lines |
| 11 | **Rebranding: names, icons, strings** | internals §9 display name + §5.1 icons (replace `Telegram.icon`, empty alternate icons, `getAvailableAlternateIcons` → `[]`); `Relay.strings` overlay genrule (§5.3); `InfoPlist.strings` usage descriptions; photo album literal | the remaining "Telegram" on kept surfaces | assets + 1 genrule + ~100 string keys |
| 12 | **About Relay** row in place of the help section | new `ItemListController` (§5.4) | GPL source offer, version | 1 small screen |
| 13 | **Phase‑1 exit: empty "Add server" screen** | §4.3 option (a): `TC/Account/Account.swift:201-215` guard; `TUI/ApplicationContext.swift:41, 56` root swap; `TUI/SharedAccountContext.swift:825-832` back to `beginNewAuth`; stub `MattermostLoginController` | launch without the Spike A seeder; Add Account works | ~30 lines + the stub screen |

**Notes on order:**

- Steps 1 and 3 change the most pixels for the least code. Step 1 also removes the false "Premium" impression in every list.
- Steps 5–7 should go in before anyone dogfoods: they remove the actions that **hang** under the null engine (Copy Link, Report, Translate, calls, transcribe).
- Do steps 9 and 11 before any TestFlight build. App Review checks background modes, usage strings and the app name.
- Feed `AvailableReactions` (§1.19) in MattermostSync at the same time as step 1, or the kept reaction feature stays invisible.
- **Verification.** For each step, walk the matching table in §1 or §2 in the simulator. Keep `MattermostBackend.isEnabled = false` builds compiling, so upstream behaviour can be compared side by side.
