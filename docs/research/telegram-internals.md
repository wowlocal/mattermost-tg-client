# Telegram‑iOS internals for the Mattermost fork

**Status:** Research v1 · 2026‑10‑26 · source tree at upstream `5c20d095` (app 13.0.1). Read-only investigation; nothing was built or run, so every "expected" behaviour below still needs a spike to confirm.

**Path prefixes used below**

| Prefix | Path |
|---|---|
| `TC/` | `submodules/TelegramCore/Sources/` |
| `PB/` | `submodules/Postbox/Sources/` |
| `TUI/` | `submodules/TelegramUI/Sources/` |
| `CLU/` | `submodules/ChatListUI/Sources/` |
| `AVT` | `TC/State/AccountViewTracker.swift` |
| `EM` | `TC/TelegramEngine/Messages/TelegramEngineMessages.swift` |
| `EP` | `TC/TelegramEngine/Peers/TelegramEnginePeers.swift` |

---

## Recommended seam for Spike A

The Rust‑engine refactor already split `Network` from MTProto. `Network` sends every request through a `NetworkEngine` protocol (`TC/Network/NetworkEngine.swift:355`). It never talks to MtProtoKit sessions directly. This makes a **null engine** the smallest seam: `Account`, `Network`, `MTContext` and all ~970 `account.network` references in 212 UI files (count from grep) keep their types. Requests simply never reach a server.

1. **`NullNetworkEngine`** (new file in `TC/Network/`, ~100 lines). It implements `NetworkEngine`, `NetworkEngineSession` and `NetworkEngineRequestService` (`TC/Network/NetworkEngine.swift:221-260, 355-371`).
   - `makeSession` returns a session whose `requestService.add` parks the request forever. It returns an `ActionDisposable` that drops it. Don't return `EmptyDisposable`: that means "refused" and telemetry counts it as dropped.
   - `setPaused`, `setOnline`, `stop` and `addUpdateSink` are no‑ops. `kind` returns `.mtProtoKit` so no Rust‑only branch runs.
   - For the main session, call `delegate.networkSessionConnectionStateChanged(...)` with `isConnected: true`. This turns `Network.connectionStatus` into `.online` (`TC/Network/Network.swift:498-522`). Later, drive it from the Mattermost WebSocket state.
   - Later, map a Mattermost `401` to `delegate.networkSessionAuthorizationRequired()`. It already triggers the logout path (`Network.swift:525-527`).
   - **Never complete requests with an error.** Most callers wrap requests in `retryRequest`, which retries with backoff up to 5 s, forever (`Network.swift:1504-1507`). Parked requests behave like airplane mode, which every Telegram code path already handles.
   - Defense in depth: `activate()` can install `MTContext` external auth‑action factories that never complete (`submodules/MtProtoKit/PublicHeaders/MtProtoKit/MTExternalActions.h:22-26`). Then nothing can make `MTContext` open its own MTProto connection for auth keys.
2. **One edit in `resolveNetworkEngine`** (`Network.swift:452-475`): return `NullNetworkEngine()` when a process‑wide flag is set (for example `MattermostBackend.isEnabled`). A factory alone is not enough:
   - On iOS the factory is used only when `NetworkEngineSettings.engine == .rust`, and the iOS default is `.mtProtoKit` (`TC/SyncCore/SyncCore_NetworkEngineSettings.swift:6-12`).
   - Extensions pass no factory at all (`Telegram/NotificationService/Sources/NotificationService.swift:844`, `submodules/TelegramUI/Components/ShareExtensionContext/Sources/ShareExtensionContext.swift:418`).
   - Also set `networkTelemetryOverrides.recording = false` (`TC/Network/NetworkTelemetry.swift:65-73`). Debug builds always record, and every parked request would show up as stalled.
3. **Seed an authorized account without login**, using only public APIs (no TelegramCore change):
   - Allocate an id with `generateAccountRecordId()` (`TC/AccountManager/AccountRecord.swift:28`).
   - Write the account's postbox with `accountTransaction(rootPath:id:encryptionParameters:isReadOnly:transaction:)` (`TC/SyncCore/SyncCore_StandaloneAccountTransaction.swift:287`):
     - `transaction.setState(AuthorizedAccountState(isTestingEnvironment: false, masterDatacenterId: 2, peerId: ownUserPeerId, state: nil, invalidatedChannels: []))`
     - the own `TelegramUser`, via `updatePeersCustom`
   - Then, in one `accountManager.transaction`: `updateRecord(id) { AccountRecord(id:, attributes: [.environment(.production), .sortOrder(n)], temporarySessionId: nil) }` and `setCurrentId(id)`. This is the same sequence as `switchToAuthorizedAccount` (`TC/Authorization.swift:18-38`).
   - `SharedAccountContextImpl` then loads it through the unchanged `accountWithId` → `.authorized(Account(...))` (`TC/Account/Account.swift:380-388`).
4. **Don't start Telegram sync.**
   - Skip `account.resetStateManagement()` at `TUI/SharedAccountContext.swift:765`. That one call starts `getDifference`, contact sync, sticker sync and the history preloader (`TC/Account/Account.swift:1679-1686`).
   - `AccountStateManager` is passive until `reset()` (`TC/State/AccountStateManager.swift:395-424, 434-447`). `AccountTaskManager` starts its ~80 sync tasks only once `isUpdating` becomes false, which then never happens (`TC/State/AccountTaskManager.swift:51-58`).
5. **Gate the `Account.init` managers that issue requests on their own** with `// MATTERMOST:` guards (`TC/Account/Account.swift:1471-1506, 1516, 1604, 1630`; see §2). For Spike A they can stay: with parked requests they only hang. Two must be handled:
   - **Network state.** `networkState` combines `stateManager.isUpdating` (initially `true`, `AccountStateManager.swift:232`) with the connection status (`Account.swift:1409-1440`). With no `getDifference` the chat‑list title says "Updating…" forever. Add an injectable override (for example `Account.externalIsUpdating: Signal<Bool>`), fed by MattermostSync bootstrap/catch‑up.
   - **Hole filling.** Replace `managedServiceViews` (`Account.swift:1471-1489` → `TC/State/ManagedServiceViews.swift:5-17`) with a MattermostSync hole filler that observes `postbox.messageHistoryHolesView()` exactly as `TC/State/ManagedMessageHistoryHoles.swift:213-224` does (§3.3).
6. **Bootstrap writes that the UI needs** (§3):
   - Remove the seeded chat‑list holes (`transaction.allChatListHoles(groupId:)` + `replaceChatListHole(groupId:index:hole: nil)`, `PB/Postbox.swift:130-143`). Otherwise an empty list shows as "loading" (`CLU/Node/ChatListNode.swift:3455-3506`).
   - Give **every** channel peer a chat‑list inclusion. `AVT:2014-2085` blocks a `CloudChannel` history view until channel polling (network) completes *unless* the peer has a chat‑list index. If it has none, it also resets the read state and re‑adds a full hole.

**What breaks or needs a decision with this seam**

- **Login.** `UnauthorizedAccount.init` asks `MTContext` for auth keys of DCs 1, 2 and 4 and starts backup‑address discovery (`TC/Account/Account.swift:199-216`). Through MtProtoKit this is expected to open TCP to Telegram (not verified). Either install the never‑completing external auth actions (step 1), or don't create an `UnauthorizedAccount` for the Mattermost login (§1.4).
- **Logout.** `managedCleanupAccounts` → `cleanupAccount` removes a logged‑out record only after `auth.logOut` answers (`TC/Account/AccountManager.swift:483-531`). With the null engine, logged‑out records and their data are never deleted. Replace it with a direct `updateRecord(id) { nil }`.
- **Hanging calls.** Anything that awaits `network.request` will spin forever: peer info (`AVT:2342` → cached peer data), search, stickers, Premium/Stars/TON contexts started in `AccountContextImpl.init` (`TUI/AccountContext.swift:318-371`), and so on. Hide those entry points or re‑back them.
- **Sending.** It stays "sending" forever until the PendingMessageManager seam (§5) is implemented.
- **Memory.** Parked requests accumulate. That is acceptable for a spike, but gate the managers before MVP.

---

## Assumptions from docs/plan/09

| # | Assumption (09 / 02) | Verdict | Evidence / correction |
|---|---|---|---|
| 1 | `LICENSE` is GPL‑2.0 ("only" vs "or later") | **Not verifiable here** | This checkout has no `LICENSE` at the repo root. The only licenses found are submodule ones, e.g. `submodules/AsyncDisplayKit/LICENSE`. Take it from the upstream tag. |
| 2a | `MessageIndex` sorts timestamp → namespace → id | **Confirmed** (+ peerId as last tiebreak) | `PB/Message.swift:236-250`. `MessageId` is `(peerId, namespace: Int32, id: Int32)`, `PB/Message.swift:3-9`. |
| 2b | Holes are Int32 ID ranges per peer and namespace | **Partial** | They are per **(peer, namespace, space)**, where space is `.everywhere` or `.tag(MessageTags)` (key at `PB/MessageHistoryHoleIndexTable.swift:108-121`). Thread and custom‑tag holes live in separate tables. Every Cloud‑namespace peer gets the hole `1...Int32.max-1` on first touch (`:178-190`). Removing an `.everywhere` range also removes it from every tag space (`:411-426`). **Extra constraint:** within (peer, namespace), id order must equal (timestamp, id) order; the hole sampler asserts it (`PB/MessageHistoryViewState.swift:746-750, 815-819`). |
| 3 | `PeerReadState` supports id‑based state with an explicit unread `count` | **Confirmed** | `.idBased(maxIncomingReadId:maxOutgoingReadId:maxKnownId:count:markedUnread:)` (`PB/PeerReadState.swift:2`). There is also `.indexBased(maxIncomingReadIndex: MessageIndex, …)` (`:3`), but `applyIncomingMaxReadId` asserts on it (`PB/MessageHistoryReadStateTable.swift:295`), so use `.idBased` for cloud peers. `count` is stored and kept incrementally: +1 per added incoming message with `id > maxKnownId && id > maxIncomingReadId`, and **only if the peer already has a read state** (`:156-211`). Set authoritative values with `transaction.resetIncomingReadStates` (`PB/Postbox.swift:209`). |
| 4 | Chat‑list inclusion can place a peer with no messages using a minimum timestamp | **Confirmed** | `.ifHasMessagesOrOneOf(groupId:pinningIndex:minTimestamp:)` (`PB/PeerChatListInclusion.swift:3-5`). The row index is the top message, or `MessageIndex(peerId,0,0, minTimestamp)` when there is no newer message (`PB/ChatListIndexTable.swift:7-24`). The default is `.notIncluded` (`:152`). A pinned peer with no messages and no minTimestamp is also listed (`:20-21`). |
| 5 | `includePeers` has no blocking client limit; folder server sync can be disabled cleanly | **Partial** | Storage has no cap (`TC/TelegramEngine/Peers/ChatListFiltering.swift:86-158`, `setPeers` public). The UI does cap things:<br>• The folder editor enforces `maxFolderChatsCount` (default 100) (`CLU/ChatListController.swift:1111, 1141`).<br>• Non‑premium accounts get tabs beyond `maxFoldersCount` (default **10**) disabled (`CLU/ChatListController.swift:4113`; defaults at `TC/State/UserLimitsConfiguration.swift:45-46`). Override them through AppConfiguration keys `dialog_filters_limit_default` and `dialog_filters_chats_limit_default` (`:144-168`).<br>• Folder ids are random in 2…254 (`ChatListFiltering.swift:1108-1114`).<br>Sync: don't start `managedChatListFilters` (`TC/State/AccountTaskManager.swift:112`). Without it, `requestChatListFiltersSync` only appends one deduplicated op‑log entry (`ChatListFiltering.swift:1501-1518`). |
| 6 | Main history can exclude thread replies, or forum topics already do this | **Wrong** | Main history (`threadId == nil`) reads the whole per‑peer table; the thread index is used only when `threadId != nil` (`PB/MessageHistoryTable.swift:3293-3460`). Forums don't filter main history either. They make the chat list and unread counters per‑thread (`peerSummaryIsThreadBased`, `TC/SyncCore/SyncCore_StandaloneAccountTransaction.swift:85-107`) and open each topic as a `.peer(peerId, threadId)` view. CRT needs new work; see §3.9 for the options. |
| 7 | Emoji status can show a Unicode emoji + text without Premium checks | **Wrong** | `PeerEmojiStatus.Content` is only `.emoji(fileId: Int64)` or `.starGift(…)` (`TC/SyncCore/SyncCore_CachedUserData.swift:395-418`). The chat list draws it as a custom‑emoji animation by file id (`CLU/Node/ChatListItem.swift:3574-3578`). It is not Premium‑gated there, but it needs a resolvable custom‑emoji `TelegramMediaFile` and has no text. Needs a new variant or a separate field plus UI. |
| 8 | Which extensions exist under `Telegram/` | **Confirmed** (§8) | Share, NotificationContent, NotificationService, SiriIntents, WidgetKitWidget, BroadcastUpload, the watch app (`Telegram/WatchApp`), plus dead `Telegram/Watch`. All are wired at `Telegram/BUILD:1868-1885`. |
| 02 | Read state is "max read ID" | **Confirmed** | See row 3. Marking read pushes through `synchronizeReadStateTable` → `managedSynchronizePeerReadStates` (§3.5). |
| 02 | DM = user peer; self‑DM = Saved Messages; GM = `TelegramGroup` | **Confirmed, with a caveat** | Saved Messages is `peerId == account.peerId`. **Caveat:** basic groups never get `threadId` on replies. `enqueueMessages` derives `threadId` from the reply target only for `TelegramChannel` with `.group` info (`TC/PendingMessages/EnqueueMessage.swift:1177-1198`). Consider mapping GMs to `TelegramChannel` too (§4). |
| 02 | A Local‑namespace message is replaced by the Cloud one on success | **Confirmed** | `transaction.updateMessage(localId) { .update(StoreMessage(id: cloudId, …)) }` (`TC/State/ApplyUpdateMessage.swift:246-433`). Postbox moves the index and keeps the stable id. |
| 03 | When the chat reaches a hole, Postbox asks for it to be filled | **Confirmed** | Via `postbox.messageHistoryHolesView()`; consumer is `managedMessageHistoryHoles` (§3.3). |
| 03 | A MediaBox fetcher can add the auth header | **Confirmed** | `AccountAuxiliaryMethods.fetchResource` is consulted before TelegramCore's fetcher (`TC/Account/Account.swift:1763-1776`) (§6). |
| 09 R2 | Building an `Account` without MTProto needs deep TelegramCore changes | **Lower risk than assumed** | The null `NetworkEngine` plus about 5 guarded hooks is enough (see the seam above). |

---

## 1. Boot path

### 1.1 Launch sequence

| Step | Where |
|---|---|
| `AppDelegate.application(_:didFinishLaunchingWithOptions:)` | `TUI/AppDelegate.swift:349` |
| App group `group.<bundleId>`, passcode/keychain setup, container URL | `TUI/AppDelegate.swift:560-565` |
| `NetworkInitializationArguments(…)`: apiId/hash, `appData` (APNs token blob), `networkEngineFactory: RustNetworkEngineFactory()` (main app only) | `TUI/AppDelegate.swift:588-686` |
| `setupAccountManager(basePath: rootPath + "/accounts-metadata")`; `rootPath` = `<appGroup>/telegram-data` (`TC/Account/AccountManager.swift:260`) | `TUI/AppDelegate.swift:1054`; impl `submodules/PasscodeCore/Sources/AccountManagerIntegration.swift:65` |
| `telegramUIDeclareEncodables()` + `initializeAccountManagement()` (registers PostboxCoding types) | `TUI/AppDelegate.swift:1059-1060` |
| `SharedAccountContextImpl(… accountManager, networkArguments …)` | `TUI/AppDelegate.swift:1133`; init `TUI/SharedAccountContext.swift:317` |
| Shared context observes `accountManager.accountRecords()`. For each record not marked logged‑out it calls `accountWithId(…)`, then `setupAccount(...)` on `.authorized`, reads 5 configuration items from Postbox, and builds `AccountContextImpl(...)` followed by `account.resetStateManagement()` | `TUI/SharedAccountContext.swift:589-823` (`accountWithId` :658, `setupAccount` :662, `AccountContextImpl` :760, `resetStateManagement` :765) |
| With no primary and no auth record, it calls `beginNewAuth`, which creates an auth record, which becomes an `UnauthorizedAccount` | `TUI/SharedAccountContext.swift:820-822, 1779-1783`; auth signal :681-692 |
| AppDelegate maps `activeAccountContexts` to `AuthorizedApplicationContext` (primary) or `UnauthorizedApplicationContext` (auth) | `TUI/AppDelegate.swift:1258-1305`, `1307-1360` |

### 1.2 `accountWithId` and where `Network` is created

`accountWithId(accountManager:networkArguments:id:encryptionParameters:supplementary:isSupportUser:rootPath:beginWithTestingEnvironment:backupData:auxiliaryMethods:)` is at `TC/Account/Account.swift:303-409`:

- Opens `openPostbox(basePath: "<root>/account-<id>/postbox", seedConfiguration: telegramPostboxSeedConfiguration, …)` (`:306-317`).
- Reads `transaction.getState()`:
  - `UnauthorizedAccountState` → `initializedNetwork(...)` → `.unauthorized(UnauthorizedAccount(...))` (`:375-379`)
  - `AuthorizedAccountState` → `initializedNetwork(...)` → `.authorized(Account(...))` (`:380-388`)
  - no state → `initializedNetwork` → `.unauthorized` (`:401-404`)
- `initializedNetwork(...)` (`TC/Network/Network.swift:534-797`) builds the `MTContext` with seed DC addresses (`:575-622`) and iCloud and backup‑address sources (`:625-695`). It then picks the engine with `resolveNetworkEngine` (`:707`, defined at `:452`), optionally wraps it in `RecordingNetworkEngine` telemetry (`:719-735`), creates the main session (`:742`) and returns `Network(...)`. `Network.init` is `fileprivate` (`:995`), so a `Network` can **only** come from `initializedNetwork`.
- Other `initializedNetwork` callers: `UnauthorizedAccount.changedMasterDatacenterId` (`Account.swift:278`) and `standaloneStateManager` (notification extension, `Account.swift:1867`).
- `Network.request` / `requestWithAdditionalInfo` wrap the TL function in a `NetworkEngineRequest` and call `requestService.add` (`Network.swift:1371-1470`). Download and upload workers use `engine.makeSession(role: .worker…)` (`TC/Network/Download.swift:57`, `Network.swift:1301-1310`).

**`Account` members that depend on `network`** (`TC/Account/Account.swift:1315-1639`):

- `StorySubscriptionsContext` ×2 (`:1334-1335`)
- `CallSessionManager` (`:1341`)
- `AccountStateManager` (`:1347`)
- `AccountViewTracker` (`:1351`, which reaches `account.network` internally)
- `AccountTaskManager` (`:1356`)
- `ContactSyncManager` (`:1367`)
- `AccountPresenceManager` (`:1369`)
- `network.isUserOnline` (`:1373`)
- `NotificationAutolockReportManager` (`:1379`)
- `PendingMessageManager` (`:1386`), `PendingStoryManager` (`:1389`), `PendingUpdateMessageManager` (`:1393`), `PendingPeerMediaUploadManager` (`:1394`)
- `network.loggedOut` / `didReceiveSoftAuthResetError` hooks (`:1396-1405`)
- `networkState` (`:1409-1440`)
- `shouldKeepConnection` (`:1467-1469`)
- the managed operations in §2

`setupAccount` (`:1763-1789`) installs `mediaBox.fetchResource` and `fetchCachedResourceRepresentation`.

### 1.3 `Account` initialization facts relevant to us

- Own presence is forced to `.present(until: Int32.max-1)` at start (`Account.swift:1375-1378`).
- `Account.peerId` comes from `AuthorizedAccountState.peerId`. The state's `state: AuthorizedAccountState.State?` (pts/qts/date/seq) can stay `nil`; it is read only by `AccountStateManager.pollDifference` (`TC/State/AccountStateManager.swift:829-935`).
- `SharedAccountContextImpl` deduplicates the accounts loaded in one pass (at launch, all records) by `(peerId, isTestingEnvironment)`, and **deletes the record processed second** (`TUI/SharedAccountContext.swift:743-751`). Two Mattermost servers whose own user maps to the same local `PeerId` would collide, and one account would be wiped. Allocate peer ids per account so that each own user gets a distinct `PeerId`, or derive them from a per‑server offset.

### 1.4 Unauthorized / login flow

- `UnauthorizedAccount` (`TC/Account/Account.swift:68-287`) holds `postbox`, `network` and an `UnauthorizedAccountStateManager`. Its `init` prefetches auth keys for DCs [1, 2, 4] and starts `beginExplicitBackupAddressDiscovery` (`:199-216`).
- UI: `UnauthorizedApplicationContext` (`TUI/ApplicationContext.swift:37-90`) hosts `AuthorizationSequenceController` (`submodules/AuthorizationUI/Sources/AuthorizationSequenceController.swift`). That controller switches screens on the postbox `UnauthorizedAccountStateContents` (`:1245-1300`; contents enum at `TC/SyncCore/SyncCore_UnauthorizedAccountState.swift:177`).
- On success, the same `postbox` gets `AuthorizedAccountState`, then `switchToAuthorizedAccount` runs: `updateRecord(auth.id)`, `setCurrentId`, `removeAuth` (`TC/Account/Account.swift:157-163`, `TC/Authorization.swift:18-38`). The shared context then loads the record as an authorized `Account`.
- **Mattermost login options:**
  - **(a)** Keep the auth record and the `UnauthorizedAccount` for its `id`/`postbox` (needs the null engine with neutralized `MTContext` auth actions). Replace `UnauthorizedApplicationContext.rootController` with a MattermostUI login controller. On success, write `AuthorizedAccountState` plus the own user into `unauthorizedAccount.postbox` and run the three record calls above. The `AccountManagerModifier` members are public (`TC/AccountManager/AccountManagerImpl.swift:41-49`).
  - **(b)** Bypass auth records entirely: at `TUI/SharedAccountContext.swift:820`, show the MattermostUI login root instead of `beginNewAuth`, then seed the record as in Seam step 3.
  - Recommendation: (b) for Spike A (a debug seeding path), and (a) or (b) for Phase 1, depending on how much of the auth UI shell is reused.
- Server URL and token have no slot in `TelegramAccountRecordAttribute` (`TC/Account/AccountManager.swift:17-30`: `backupData`, `environment`, `sortOrder`, `loggedOut`, `supportUserInfo`). Store them in the account postbox (preferences entry) or Keychain, or add an attribute case (it is Codable, `CodingKeys` at `:18-25`).

### 1.5 Rust MTProto engine: what changes for us

- The `NetworkEngine` / `NetworkEngineSession` / `NetworkEngineRequestService` / `NetworkEngineFactory` protocols (`TC/Network/NetworkEngine.swift:179-393`) exist because of the Rust engine. They are what make the null‑engine seam possible.
- Implementations:
  - `MtProtoKitEngine` (`TC/Network/MtProtoKitEngine.swift:118`)
  - `RustNetworkEngine` (`submodules/MTProtoRustEngine/Sources/MTProtoRustEngine/RustNetworkEngine.swift:72` for the factory)
  - `SwitchingNetworkEngine` and `RecordingNetworkEngine` wrappers (`TC/Network/SwitchingNetworkEngine.swift:376`, `TC/Network/RecordingNetworkEngine.swift:8`)
- On iOS, Rust is opt‑in (Debug Settings) and the default is `.mtProtoKit` (`SyncCore_NetworkEngineSettings.swift:6-12`). Only the main app passes a factory (`TUI/AppDelegate.swift:685`). Live engine switching and the liveness monitor are `#if os(macOS)` (`Network.swift:702-706, 714-722, 1098-1139`; `Account.swift:1586-1602`).
- Engine choice reads the account‑manager shared entries `networkEngineSettings` and `networkEngineState` through `networkEngineInputs(transaction:)` (`TC/Settings/NetworkEngineSettings.swift:52-58`). After `help.getAppConfig`, `AccountTaskManager.reloadAppConfiguration` writes the server kill‑switch flag (`TC/State/AccountTaskManager.swift:173-201`). None of this matters once `resolveNetworkEngine` returns the null engine.
- Later cleanup: drop `RustNetworkEngineFactory()` from `AppDelegate` and the `MTProtoRustEngine` dependency, which saves the Rust static libraries (CLAUDE.md "Rust MTProto engine on iOS").

---

## 2. Background managed operations

"Treatment" is what MattermostSync should do. **D** = disable, **R** = replace with a Mattermost implementation, **K** = keep (local only).

| Started at | Operation | Network work | Treatment |
|---|---|---|---|
| `Account.swift:1334-1335` | `StorySubscriptionsContext` ×2 | stories | D |
| `:1341` | `CallSessionManager` | calls | D |
| `:1347` + `resetStateManagement` `:1680` | `AccountStateManager.reset()` → `pollDifference` / `getState` and update sink (`AccountStateManager.swift:434-447, 806-971`) | the whole MTProto update loop | D (never `reset`); R by MattermostSync WS + catch‑up |
| `:1351` | `AccountViewTracker` (side effects in §7.3) | many | K the object; D/R the per‑message fetchers |
| `:1356` → `AccountTaskManager.swift:51-158` | ~80 tasks, started only after `isUpdating == false`: read‑state sync (`:72`), group stats (`:73`), global notification settings (`:79`), pinned chats (`:80-81`), archive (`:82`), stickers/emoji/gifs/reactions catalogs (`:83-138`), filters (`:112`), autodownload/web/terms/app‑update/localization (`:145-149`), pending peer notification settings (`:150`), app log (`:151`), themes (`:153`), and `reloadAppConfiguration` → `managedAppConfigurationUpdates` + `managedPromoInfoUpdates` (`:143, 173-202`) | yes | D the whole manager. R as needed: read state → `/channels/members/me/view`, mute → channel notify props, pin → favorites |
| `:1367` + `restartContactManagement` `:1706` | `ContactSyncManager` | contacts import | D |
| `:1369` | `AccountPresenceManager` (`account.updateStatus` while foreground) | yes | D, or R → Mattermost status |
| `:1379` | `NotificationAutolockReportManager` | yes | D |
| `:1386` + `:1493` | `PendingMessageManager` ← `postbox.unsentMessageIdsView()` | send | R the send path (§5) |
| `:1389`, `:1394` | `PendingStoryManager`, `PendingPeerMediaUploadManager` | stories, profile photo | D |
| `:1393` | `PendingUpdateMessageManager` (edits) | `messages.editMessage` | R `requestEditMessage` (§5) |
| `:1471-1489` → `TC/State/ManagedServiceViews.swift:5-17` | `managedMessageHistoryHoles`, `managedChatListHoles`, `managedForumTopicListHoles`, `_internal_refreshSeenStories` (only while master client) | history, dialogs, topics, stories | **R** holes (§3.3); D the rest |
| `:1497` | `managedSecretChatOutgoingOperations` | secret chats | D |
| `:1498` | `managedCloudChatRemoveMessagesOperations` (op‑log tag `CloudChatRemoveMessages`) | deletes | **R** → `DELETE /posts/{id}` |
| `:1499-1500` | `managedAutoremoveMessageOperations` ×2 | local timers, some requests | D |
| `:1501-1505` | autoexpire stories, peer timestamp attributes, wallet transfer, view/peer stories | yes | D |
| `:1506` | `managedLocalTypingActivities` | `setTyping` | **R** → WS `user_typing` |
| `:1516` | `managedSynchronizeChatInputStateOperations` (cloud drafts) | yes | D (or R → Mattermost drafts) |
| `:1575-1585` | proxy settings → `network.updateProxySettings` | none with null engine | K/D |
| `:1604` | `managedNetworkTelemetryReports` | `help.saveAppLog` | D |
| `:1619-1624` | master notification key → `<basePath>/notificationsKey` | local | K/D |
| `:1630`, `:1653` | `managedConfigurationUpdates` (`help.getConfig`) | yes | D |
| `:1632` | `AutomaticCacheEvictionContext` | local | K |
| `resetStateManagement` `:1679-1686` | `manageStickerPacks`; `viewTracker.chatHistoryPreloadManager.start()` (preloads top chats via `fetchMessageHistoryHole(.download)`, `TC/State/ChatHistoryPreloadManager.swift:115`) | yes | D (don't call `resetStateManagement`) |
| `TUI/SharedAccountContext.swift:1080` | `managedCleanupAccounts` (`auth.logOut`, then remove record) | yes | **R** (§1, logout) |
| `TUI/AccountContext.swift:318-371` | `InAppPurchaseManager`, `peerStarsContext`, `peerTonContext`, `WalletContext`, `GiftAuctionsManager` | yes | D (hide features) |

**Pattern worth reusing.** Almost every "interactive" engine call only writes to Postbox: an op‑log entry, a pending message action, the unsent flag, or a read‑state sync marker. A *managed operation* then turns that write into network requests. MattermostSync can keep the interactive APIs unchanged and supply its own consumers:

| UI action | Postbox write | Consumer to replace |
|---|---|---|
| send | `.Unsent` flag | `PendingMessageManager` |
| delete | `CloudChatRemoveMessages` op‑log entry (`TC/State/CloudChatRemoveMessagesOperation.swift:3-5`) | `managedCloudChatRemoveMessagesOperations` |
| react | pending action `.updateReaction` (`TC/State/MessageReactions.swift:112`) | `managedApplyPendingMessageReactionsActions` (`AccountTaskManager.swift:97`) |
| mark read | read‑state sync table | `managedSynchronizePeerReadStates` (`TC/State/ManagedSynchronizePeerReadStates.swift:145`) |
| mute | pending peer notification settings | `managedPendingPeerNotificationSettings` |
| pin | `SynchronizePinnedChats` op log | `managedSynchronizePinnedChatsOperations` |
| folders | `SynchronizeChatListFilters` op log | `managedChatListFilters` |
| mention seen | `.consumeUnseenPersonalMessage` | `managedConsumePersonalMessagesActions` |

---

## 3. Postbox data model

### 3.1 Ids and ordering

- `MessageId = (peerId: PeerId, namespace: Int32, id: Int32)` (`PB/Message.swift:3-9`). `MessageId <` compares namespace, then id, then peer (`:138-148`).
- `MessageIndex = (id: MessageId, timestamp: Int32)`, ordered by timestamp → namespace → id → peerId (`PB/Message.swift:151-250`).
- `ChatListIndex = (pinningIndex: UInt16?, messageIndex)`; pinned items sort first (`:252-277`).
- Storage keys:
  - history: `peerId | namespace | timestamp | id` (`PB/MessageHistoryTable.swift:122-128`)
  - id → timestamp index: `peerId | namespace | id` (`PB/MessageHistoryIndexTable.swift:59-65`)
  - holes are keyed by **id**, while messages are ordered by **timestamp**. The two must agree.
- Message namespaces (`TC/SyncCore/SyncCore_Namespaces.swift:6-31`): `Cloud=0`, `Local=1`, `SecretIncoming=2`, `ScheduledCloud=3`, `ScheduledLocal=4`, `QuickReply*=5/6`, `EphemeralLocal=7`, `EphemeralAnchored=8`, `WelcomeMessage*=9/10`. The chat view excludes `allNonRegular` (`AVT:2242, 2270, 2278`).
- Peer namespaces: `CloudUser=0`, `CloudGroup=1`, `CloudChannel=2`, `SecretChat=3` (`:53-57`). `PeerId.Id` is an Int64 with a 32+‑bit payload (`PB/Peer.swift:148-235`), so sequential local ids are fine.
- **Global message ids.** Postbox treats Cloud message ids of `CloudUser`/`CloudGroup` peers as account‑wide unique (Telegram's common message box): `globalMessageIdsPeerIdNamespaces` (`SyncCore_StandaloneAccountTransaction.swift:25-28`), written on every insert (`PB/MessageHistoryIndexTable.swift:188-199`). With per‑peer id allocation these entries overwrite each other silently. Only MTProto update code reads them (`TC/State/AccountStateManagementUtils.swift`, `TC/Account/AccountIntermediateState.swift`), so this is harmless as long as nothing calls `messageIdsForGlobalIds` / `deleteMessagesWithGlobalIds`. Optionally remove the namespaces from the seed configuration.

### 3.2 Seed configuration (what Postbox assumes per namespace)

`telegramPostboxSeedConfiguration` (`TC/SyncCore/SyncCore_StandaloneAccountTransaction.swift:5-…`):

- `messageHoles`: user, group and channel peers get Cloud holes for `.everywhere` plus every tag (`:6-11`, namespaces list `SyncCore_Namespaces.swift:227`).
- `initializeChatListWithHole`: the root and group chat lists start with a hole at `Int32.max-1` (`:32-35`).
- `messageThreadHoles`: threads of those peers get Cloud thread holes (`:38-46`).
- `defaultMessageNamespaceReadStates`: only `Local` has a default read state (`:110`).
- `chatMessagesNamespaces = {Cloud, Local, SecretIncoming}` (`:111`).
- `peerSummaryIsThreadBased` (forums, `:85-107`).

### 3.3 History holes: representation and fill flow

- **Representation.**
  - `MessageHistoryHoleIndexTable` keys holes by `(peerId, namespace, tag|0, upperId)` and stores the lower id as the value (`PB/MessageHistoryHoleIndexTable.swift:108-121`).
  - A hole space is `MessageHistoryHoleOperationSpace = .everywhere | .tag(MessageTags) | .customTag(...)` (`:36-39`).
  - Threads use `MessageHistoryThreadHoleIndexTable`; custom tags use their own tables (`PB/Postbox.swift:2248-2292`).
  - The first touch of a peer seeds `1...Int32.max-1` (`:178-190`).
- **Who requests a fill.**
  1. Each open `MutableMessageHistoryView` with `trackHoles` computes `firstHole()`. It returns `.aroundId(id)` while loading, or `.range(start:end:)` / `.aroundId` for the hole nearest the anchor, always with `count = 100` (`PB/MessageHistoryView.swift:1226-1253`).
  2. `ViewTracker.updateTrackedHoles` collects these into `MessageHistoryHolesViewEntry(hole: .peer(peerId, namespace, threadId), direction, space, count, userId)` (`PB/ViewTracker.swift:476-518`, struct at `PB/MessageHistoryHolesView.swift:3-15`). They are published as `postbox.messageHistoryHolesView()` (`PB/Postbox.swift:4063, 5110`).
- **Who fills it.**
  - `managedMessageHistoryHoles` (`TC/State/ManagedMessageHistoryHoles.swift:213-237`) keeps one pending fetch per `(peerId, threadId, space)` key (`:177-189`) and calls `fetchMessageHistoryHole(accountPeerId:source:postbox:peerInput:namespace:direction:space:count:)` (`TC/State/Holes.swift:423`).
  - Other callers:
    - reply threads in non‑forum channels: `TC/TelegramEngine/Messages/ReplyThreadHistory.swift:314, 939`
    - sparse media lists: `SparseMessageList.swift:363, 451`
    - forum topics: `ForumChannels.swift:638`
    - the preload manager: `ChatHistoryPreloadManager.swift:115`
- **How a fill is reported.** Everything happens inside one Postbox transaction (`Holes.swift:1036-1157`):
  1. `transaction.addMessages(storeMessages, location: .Random)`
  2. compute `filledRange`:
     - `.range(start, end)`: from `start` to the farthest returned id
     - `.aroundId`: the min/max of the returned ids and the anchor
     - no results: the whole requested range (`implicitelyFillHole`)
  3. `transaction.removeHole(peerId:threadId:namespace:space:range: filledRange)`
  4. `updatePeers(...)`

  Views re‑sample automatically. No callback is involved; the hole simply disappears.
- **Fill contract for MattermostSync (load‑bearing):**
  - Always remove at least the requested range, even when the server returns nothing. Otherwise `firstHole()` re‑emits the same entry. The manager suppresses a completed key for **20 s** (`ManagedMessageHistoryHoles.swift:160-165`) and then fetches again, forever.
  - Allocate ids so that within a peer/namespace, id order equals `(timestamp, id)` order (assertions at `PB/MessageHistoryViewState.swift:746-750, 815-819`).
  - `.everywhere` removal also clears tag spaces (`PB/MessageHistoryHoleIndexTable.swift:411-426`). Media‑tab (tag) views therefore need no separate fills once main history is filled. Their own holes would request `space: .tag(...)`.
  - `addMessages(..., location: .UpperHistoryBlock)` removes the hole from the earliest added id up to `Int32.max-1` per namespace. This is the right call for "latest page" bootstrap (`PB/Postbox.swift:2194-2222`).
- **CloudChannel gate.** `AVT:2014-2085` ties a channel's history to `polledChannel` (`AVT:1877`, `getChannelDifference`). A channel with a chat‑list index counts as "automatically tracked" and shows its history immediately. A channel without one shows `isLoading` until polling succeeds, and also gets `resetIncomingReadStates` plus a full hole (`AVT:2036-2050`). Mattermost channels must therefore always have a chat‑list inclusion. For MVP, remove or replace this block.

### 3.4 Writing messages

- **Insert.** `transaction.addMessages([StoreMessage], location: .Random | .UpperHistoryBlock) -> [Int64: MessageId]` (`PB/Postbox.swift:46`). The returned map is keyed by `globallyUniqueId`, which is useful for `pending_post_id`.
- **`StoreMessage(id: MessageId, customStableId:, globallyUniqueId:, groupingKey:, threadId:, timestamp:, flags:, tags:, globalTags:, localTags:, forwardInfo:, authorId:, text:, attributes:, media:)`** (`PB/Message.swift:922-955`).
  - A `Partial(peerId, namespace)` variant lets Postbox allocate the id; it is used for Local messages (`:957`).
  - Incoming messages need `flags: [.Incoming]`.
  - `tags` drive media tabs and mention badges (`TC/SyncCore/SyncCore_Namespaces.swift:185-202`, bits 0…15 in use, 16…31 free).
- **Update.** `transaction.updateMessage(id) { current in .update(StoreMessage(...)) | .skip }` (`PB/Postbox.swift:541`, enum at `:13-16`). The `StoreMessage` may carry a new id or timestamp, which is how Local becomes Cloud.
- **Delete.**
  - `_internal_deleteMessages(transaction:mediaBox:ids:)` (`TC/TelegramEngine/Messages/DeleteMessages.swift:42`, public) also cleans up media.
  - Raw: `transaction.deleteMessages(_:forEachMedia:)`, `deleteMessagesInRange`, `clearHistory` (`PB/Postbox.swift:145-196`).
- **Holes.** `transaction.addHole/removeHole(peerId:threadId:namespace:space:range:)` (`PB/Postbox.swift:70-78`); `getHoles(peerId:namespace:)` (`:85`).
- **Attributes** (all in `TC/SyncCore/`):
  - `ReplyMessageAttribute(messageId:threadMessageId:quote:isQuote:innerSubject:)` (`SyncCore_ReplyMessageAttribute.swift:16`)
  - `ReplyThreadMessageAttribute(count:latestUsers:commentsPeerId:maxMessageId:maxReadMessageId:)`, which drives "N replies" (`SyncCore_ReplyThreadMessageAttribute.swift:15`)
  - `EditedMessageAttribute(date:isHidden:)` (`SyncCore_EditedMessageAttribute.swift:9`)
  - `ReactionsMessageAttribute(canViewList:isTags:reactions:recentPeers:topPeers:)` (`SyncCore_ReactionsMessageAttribute.swift:403`)
  - `TextEntitiesMessageAttribute` (`SyncCore_TextEntitiesMessageAttribute.swift`)

### 3.5 Read state and unread counts

- **State.** `PeerReadState` is per (peer, namespace) and combined into `CombinedPeerReadState` (§Assumptions row 3).
  - Set authoritative state with `transaction.resetIncomingReadStates([peerId: [Cloud: .idBased(...)]])` (`PB/Postbox.swift:209`). Do this for every peer at bootstrap, **before** adding messages: without a state, `addIncomingMessages` only invalidates (`PB/MessageHistoryReadStateTable.swift:205-210`).
  - Use `applyIncomingReadMaxId` (`PB/Postbox.swift:224`) and `applyMarkUnread` (`:243`) when another device reads.
- **Mark read (local, from the UI).**
  1. `context.applyMaxReadIndex` (`TUI/AccountContext.swift:800`)
  2. `engine.messages.applyMaxReadIndexInteractively` (`EM:106`)
  3. `_internal_applyMaxReadIndexInteractively` (`TC/TelegramEngine/Messages/ApplyMaxReadIndexInteractively.swift:7, 43`)
  4. `transaction.applyInteractiveReadMaxIndex` (`PB/Postbox.swift:234`). This recomputes `count` from stored incoming messages in the range and returns `.Push(thenSync:)` (`PB/MessageHistoryReadStateTable.swift:385-436`), which marks the peer in the synchronize‑read‑state table.
  5. The server push is `managedSynchronizePeerReadStates` → `pushPeerReadState` (`TC/State/SynchronizePeerReadState.swift:249-330`, `messages.readHistory` / `channels.readHistory`). **R** → `POST /channels/members/me/view`.
- **Counters.**
  - The chat‑list badge is `CombinedPeerReadState.count`.
  - Totals (`TotalReadCounters`, `MessagesData.swift:268`) are kept by `ChatListIndexTable`, using `peerSummaryCounterTags` and global notification settings to exclude muted chats.
  - The mention badge is the `.unseenPersonalMessage` tag summary. Set it with `transaction.replaceMessageTagSummary(peerId:threadId:tagMask:namespace:customTag:count:maxId:)` (`PB/Postbox.swift:1058`).

### 3.6 Chat‑list inclusion

- API: `transaction.updatePeerChatListInclusion(peerId, inclusion:)` (`PB/Postbox.swift:410`).
- TelegramCore helpers:
  - `updatePeerChatInclusionWithMinTimestamp` raises minTimestamp only (`TC/UpdatePeers.swift:44-73`).
  - `minTimestampForPeerInclusion` uses group or channel `creationDate` (`:75-85`).
- `updatePeersCustom` (`TC/UpdatePeers.swift:298-428`, public) applies inclusion automatically:
  - `CloudChannel` with a `.personal` access hash and `.member` → minTimestamp `= channel.creationDate`, forced into `.root`.
  - `CloudGroup` with `.Member` → minTimestamp `= creationDate`, but not forced (a new group stays `.notIncluded`).
  - Users → nothing (DM inclusion must be set explicitly, as `fetchChatListHole` does at `TC/State/Holes.swift:1244-1256`).
  - **Recommendation:** after `updatePeersCustom`, set the inclusion explicitly to `.ifHasMessagesOrOneOf(groupId: .root, pinningIndex: nil, minTimestamp: Int32(last_post_at/1000))`, or set `creationDate = last_post_at` on channels.
- Rows without messages render at `minTimestamp`. How `ChatListItem` draws an empty message line was not checked; verify in the spike.
- **Pinned order** (favorites): `transaction.setPinnedItemIds(groupId:itemIds:)` bypasses limits. The interactive `toggleItemPinned` enforces `maxPinnedChatCount` (default **5** for non‑premium; `TC/TelegramEngine/Peers/TogglePeerChatPinned.swift:15-60`, `UserLimitsConfiguration.swift:38`).

### 3.7 Chat‑list holes

The root and archive chat lists are seeded with a hole (`SyncCore_StandaloneAccountTransaction.swift:32-35`). It is filled by `managedChatListHoles` → `fetchChatListHole` → `messages.getDialogs` (`TC/State/ManagedChatListHoles.swift:39`, `Holes.swift:1179-1288`). At bootstrap MattermostSync should remove it with `replaceChatListHole(groupId:index:hole:nil)` for `.root` and `Namespaces.PeerGroup.archive`.

### 3.8 Chat folders (`ChatListFilter`)

- **Model.**
  - `ChatListFilter = .allChats | .filter(id: Int32, title: ChatFolderTitle, emoticon: String?, data: ChatListFilterData)` (`TC/TelegramEngine/Peers/ChatListFiltering.swift:298-301`).
  - `ChatListFilterData`: `categories`, `excludeMuted`, `excludeRead`, `excludeArchived`, `includePeers`, `excludePeers`, `color` (`:213-240`).
  - `ChatListFilterIncludePeers`: `peers`, `pinnedPeers`; mutate with `addPeer`, `setPeers`, `addPinnedPeer` (`:86-158`).
- **Storage.** Preferences key `PreferencesKeys.chatListFilters` holds `ChatListFiltersState` (`:1042-1070`). Write it through `engine.peers.updateChatListFiltersInteractively` (`EP:785` → `:1117`), which also calls `requestChatListFiltersSync`, or through `updateChatListFiltersState(transaction:_:)` (`:1256`, internal), which does not.
- **Predicate.** `chatListFilterPredicate(filter:accountPeerId:)` (`CLU/Node/ChatListNodeLocation.swift:112`).
- Limits and sync: see Assumptions row 5. Per‑folder pinning also exists (`pinnedPeers`). A DM can appear in every team folder through the `categories` contact/non‑contact flags, so no explicit peer list is needed for DMs.

### 3.9 Threads and replies (CRT)

- **Storage.** `StoreMessage.threadId: Int64?`. The thread index is `MessageHistoryThreadsTable`, with per‑thread holes in `MessageHistoryThreadHoleIndexTable`.
  - When sending a reply in a `TelegramChannel` with `.group` info, `enqueueMessages` sets `threadId = replyTarget.threadId ?? replyTarget.id` (`TC/PendingMessages/EnqueueMessage.swift:1177-1198`).
  - Basic groups (`TelegramGroup`) get no `threadId`.
  - Saved Messages uses `threadId = savedPeerId` (`TC/ApiUtils/StoreMessage_Telegram.swift:1261-1263`).
- **Opening a thread.**
  - `ChatLocation.replyThread(ChatReplyThreadMessage)` (fields at `TC/TelegramEngine/Messages/ReplyThreadHistory.swift:612-634`).
  - `chatLocationInput` (`TUI/AccountContext.swift:734-747`) maps it to a **plain Postbox view** `.peer(peerId, threadId)` when `isForumPost` is set or the peer is not a `CloudChannel`. Otherwise it maps to `.thread(...)`, backed by the network `ReplyThreadHistoryContext` (`ReplyThreadHistory.swift:108, 310`).
  - **For Mattermost, build `ChatReplyThreadMessage(... isForumPost: true ...)` yourself** so threads use Postbox thread holes. Those holes are filled by the same hole consumer, with `threadId` set, which maps to `GET /posts/{root}/thread`. Side effects of `isForumPost` on titles and headers are not yet checked.
  - Whether the root post appears in the thread view (Telegram forum roots carry `threadId == own id`) is to be verified.
- **Excluding replies from main history** (row 6 is wrong). Options, none verified:
  - **(a)** A new `MessageTags` bit (for example `1 << 16`, "root post") set on non‑reply posts. The channel screen would then open with `tag: .tag(rootPost)`; tag spaces get holes automatically if the bit is added to `MessageTags.all` and `upgradedMessageHoles` (`SyncCore_StandaloneAccountTransaction.swift:15-23`). `ChatHistoryViewForLocation` already threads a `tag` through (`TUI/ChatHistoryViewForLocation.swift:112-314`).
  - **(b)** Store replies in a separate message namespace, excluded from the main view's `namespaces` but included in thread views. This needs `AVT:2242-2281` to differ by location.
  - **(c)** Plan option 3 (custom loader).
  - (a) looks least invasive.

---

## 4. Peers

- **Writing peers.**
  - Use `updatePeersCustom(transaction:peers:update:)` (`TC/UpdatePeers.swift:298`, public). It merges, applies inclusion rules, and calls `transaction.updatePeersInternal` (`PB/Postbox.swift:351`).
  - Use `accessHash: .personal(0)` (`TC/SyncCore/SyncCore_PeerAccessHash.swift:5-7`). `TelegramUser.merge` replaces the stored user fully only for `.personal` (`TC/ApiUtils/TelegramUser.swift:336-341`), and channel inclusion runs only for `.personal` (`UpdatePeers.swift:380-391`).
- **Constructors.**
  - `TelegramUser(id:accessHash:firstName:lastName:username:phone:photo:botInfo:restrictionInfo:flags:emojiStatus:usernames:storiesHidden:nameColor:backgroundEmojiId:profileColor:profileBackgroundEmojiId:subscriberCount:verificationIconFileId:linkedCommunityId:)` (`TC/SyncCore/SyncCore_TelegramUser.swift:260-300`).
    - Bots: `botInfo: BotUserInfo(flags:inlinePlaceholder:)` (`:56`).
    - `UserInfoFlags.isPremium` (`:20`) lifts the Premium‑based limits (§3.8).
  - `TelegramGroup(id:title:photo:participantCount:role:membership:flags:defaultBannedRights:migrationReference:creationDate:version:)` (`SyncCore_TelegramGroup.swift:172`).
    - `TelegramGroupMembership` is `.Member`, `.Left` or `.Removed` (`:102-106`).
    - `TelegramGroupRole` is `.creator`, `.admin` or `.member` (`:5-8`).
  - `TelegramChannel(id:accessHash:title:username:photo:creationDate:version:participationStatus:info:flags:restrictionInfo:adminRights:bannedRights:defaultBannedRights:usernames:storiesHidden:nameColor:backgroundEmojiId:profileColor:profileBackgroundEmojiId:emojiStatus:approximateBoostLevel:subscriptionUntilDate:verificationIconFileId:sendPaidMessageStars:linkedMonoforumId:linkedCommunityId:)` (`SyncCore_TelegramChannel.swift:282-310`).
    - `info: .group(TelegramChannelGroupInfo(flags:))` (`:67-69, 78-80`).
    - `participationStatus: .member` (`:5-8`).
- **Private chats.** The chat *is* the user peer: `MessageId(peerId: userPeerId, …)`. Incoming messages carry `.Incoming` with `authorId = user`. Outgoing messages have `authorId = account.peerId`.
- **Saved Messages.** The chat with `peerId == account.peerId`.
  - Telegram groups saved messages by `threadId = savedPeerId`, and Saved Messages may render as a list of sub‑chats depending on `PreferencesKeys.displaySavedChatsAsTopics()` (`EP:1732`, `TC/TelegramEngine/Messages/ChatList.swift:685`).
  - Proposal: store self‑DM posts with `threadId = accountPeerId.toInt64()` and set the preference to false. Verify.
- **Presence.**
  - `transaction.updatePeerPresencesInternal(presences: [PeerId: TelegramUserPresence], merge:)` (`PB/Postbox.swift:469`).
  - `TelegramUserPresence(status:lastActivity:)` (`TC/SyncCore/SyncCore_TelegramUserPresence.swift:83-87`).
  - `UserPresenceStatus` is `.none`, `.present(until:)`, `.recently(isHidden:)`, `.lastWeek(isHidden:)` or `.lastMonth(isHidden:)` (`:21-25`). There is no away or DND variant.
- **Emoji status.** File‑id based only (Assumptions row 7).
- **Peer data loaded on chat open.** `viewTracker.peerView` → `updateCachedPeerData` → `_internal_fetchAndUpdateCachedPeerData` runs every 5 minutes (`AVT:1822-1849, 2316-2342`). Member lists, "about" and pinned messages come from `CachedChannelData` / `CachedGroupData` / `CachedUserData`. MattermostSync should write these with `transaction.updatePeerCachedData(peerIds:update:)` and stub the fetcher.

---

## 5. Sending

**Path from the composer to the server:**

1. The composer calls `ChatControllerNode.sendCurrentMessage` (`TUI/ChatControllerNode.swift:5043`, building `.message(text:… replyToMessageId:)` at `:5340`).
2. That goes to the `sendMessages` closure (`TUI/Chat/ChatControllerLoadDisplayNode.swift:1000`).
3. The closure calls `enqueueMessages(account:peerId:messages:)` (`:1124`; defined at `TC/PendingMessages/EnqueueMessage.swift:697`; enum `EnqueueMessage` at `:129-131`).
4. `enqueueMessages` stores a `StoreMessage(peerId:, namespace: Local, …, flags: [.Unsent], globallyUniqueId: randomId, threadId:)` with an `.Partial` id (`:1101-1204`, `addMessages` at `:1456`).
5. Postbox's unsent table feeds `postbox.unsentMessageIdsView()`, which reaches `PendingMessageManager.updatePendingMessageIds` (`TC/Account/Account.swift:1493`; `TC/State/PendingMessageManager.swift:414`).
6. The manager runs `beginSendingMessages` (`:598`) and uploads content through `messageContentToUpload` (`:768` → `TC/PendingMessages/PendingMessageUploadedContent.swift:131-202`, TL upload).
7. It then calls `sendMessageContent` (`:1724`, `messages.sendMessage` at `:1954`) or `sendGroupMessagesContent` (`:1183`).
8. The result goes through `applySentMessage` (`:2318`) and `applyUpdateMessage(postbox:stateManager:message:cacheReferenceKey:result: Api.Updates,…)` (`TC/State/ApplyUpdateMessage.swift:167`). It rewrites the Local message into the Cloud one with `transaction.updateMessage(localId) { .update(StoreMessage(id: cloudId, …, flags: [])) }` (`:246-433`) and moves media resources from local to cloud ids (`:7-15`). Failure calls `failMessages` → `flags: [.Failed]` (`PendingMessageManager.swift:175-188`).

**What the UI reads from the manager:**
- `pendingMessageStatus(id)` for progress (`PendingMessageManager.swift:541`; used by media bubbles and `FileMediaResourceStatus`)
- `deliveredMessageEvents(peerId:)` (`:2431`; sent sound and animation in `ChatHistoryListNode`)
- `pendingMessageCount` (`:233`)

**Narrowest plug.** Keep `enqueueMessages` and `PendingMessageManager`'s bookkeeping (contexts, status, progress, delivered events, fail). Inject a `PendingMessageSender` into `PendingMessageManager` that replaces:
1. `messageContentToUpload` with: read local resource data from `mediaBox`, then `POST /files` with progress;
2. `sendMessageContent` / `sendGroupMessagesContent` with `POST /posts`, sending `pending_post_id = String(message.globallyUniqueId)`;
3. `applyUpdateMessage(...)` with a Mattermost equivalent that does the same `transaction.updateMessage` rewrite using the allocated Cloud id, server timestamp, `MattermostFileResource` media, and `pending_post_id` deduplication against the WebSocket `posted` event.

The Telegram path also needs an `Api.InputPeer` (`forceApiInputPeer`), so it can't be reused as is. Swapping only the consumer of `unsentMessageIdsView` is simpler, but then the UI's status and delivered‑event signals go silent.

**Edits.** The text edit commit uses `account.pendingUpdateMessageManager.add(...)` (`TUI/Chat/ChatControllerLoadDisplayNode.swift:2322`) → `PendingUpdateMessageManager` (`TC/PendingMessages/PendingUpdateMessageManager.swift:67-172`) → `requestEditMessage` (`:84` → `TC/PendingMessages/RequestEditMessage.swift:34`). Replace that call with `PUT /posts/{id}/patch`.

---

## 6. Media

- **Fetch wiring.** `setupAccount` installs `mediaBox.fetchResource` (`TC/Account/Account.swift:1764-1776`). It tries:
  1. `account.auxiliaryMethods.fetchResource(postbox, resource, intervals, parameters)`, the app‑level hook: `makeTelegramAccountAuxiliaryMethods` at `submodules/TelegramUI/Components/TelegramAccountAuxiliaryMethods/Sources/TelegramAccountAuxiliaryMethods.swift:20`, passed in at `TUI/SharedAccountContext.swift:658`;
  2. then TelegramCore's `fetchResource(account:…)` (`TC/State/Fetch.swift:64-140`: cloud MTProto locations, `LocalFileReferenceMediaResource`, `HttpReferenceMediaResource`).

  **Put Mattermost resources in the auxiliary hook**, which needs no TelegramCore change, or as a new branch in `Fetch.swift`. Extensions build their own auxiliary methods (for example `TC/Account/Account.swift:1886-1912` in `standaloneStateManager`), so register there too.
- **Fetch result protocol.** `MediaResourceDataFetchResult` is `.reset`, `.dataPart(resourceOffset:data:range:complete:)`, `.resourceSizeUpdated`, `.progressUpdated`, `.moveLocalFile(path:)`, `.moveTempFile(file:)` or `.copyLocalItem` (`PB/MediaBox.swift:74-83`). `intervals` carries the requested byte ranges and priorities, which suit Range requests for video.
  - The existing `fetchHttpResource` (`TC/Network/FetchHttpResource.swift:6-38`) shows the minimal shape, but it can't add headers (it uses `MTHttpRequestOperation`). Write a `URLSession` fetcher with the bearer token.
- **Custom resource type.**
  - Implement `TelegramMediaResource` (`TC/SyncCore/SyncCore_TelegramMediaResource.swift:4`; that is `MediaResource` (`PB/MediaResource.swift:11-18`: `id`, `size`, `isEqual`, optional `streamable`/`headerSize`) plus `PostboxCoding`). The template is `HttpReferenceMediaResource` (`TC/SyncCore/SyncCore_CloudFileMediaResource.swift:618-658`).
  - Register with `declareEncodable(Type.self, f:)` (`PB/Coding.swift:32-38`) or `engineDeclareEncodable` (`TC/TelegramEngine/Utils/EnginePostboxCoding.swift:88`).
  - The type hash is `murmur("\(type)")`, the **unqualified type name**. Renaming the class orphans stored data, and a duplicate name asserts.
  - Register in a `mattermostDeclareEncodables()` next to `telegramUIDeclareEncodables()` (`submodules/TelegramUI/Components/TelegramUIDeclareEncodables/Sources/TelegramUIDeclareEncodables.swift:16-28`, called at `TUI/AppDelegate.swift:1059`) and in every extension that opens Postbox.
- **Media objects.**
  - `TelegramMediaImage(imageId: MediaId, representations: [TelegramMediaImageRepresentation(dimensions:resource:…)], …)` (`TC/SyncCore/SyncCore_TelegramMediaImage.swift:292, 547`)
  - `TelegramMediaFile` (`SyncCore_TelegramMediaFile.swift:660`)
  - `MediaId` is `(namespace: Int32, id: Int64)`. Media records are deduplicated by `MediaId` across messages, which is the shared‑record caveat in CLAUDE.md "Postbox shared‑media removal". Derive a stable Int64 from the Mattermost file id.
  - The UI keys some behaviour on `Namespaces.Media.Cloud*` / `Local*` (21 and 32 occurrences outside TelegramCore). Prefer `CloudImage` / `CloudFile` with hashed ids over a new namespace, unless collisions are a concern.
- **Downloads in bubbles.**
  1. `messageMediaImageInteractiveFetched` / `messageMediaFileInteractiveFetched` (`submodules/AccountContext/Sources/FetchMediaUtils.swift:37, 50`)
  2. `FetchManagerImpl.interactivelyFetched` (`submodules/FetchManagerImpl/Sources/FetchManagerImpl.swift:775`)
  3. `fetchedMediaResource` (`TC/Network/FetchedMediaResource.swift:28`)
  4. the `mediaBox.fetchResource` hook above.

  The gallery reads history directly from `postbox.aroundMessageHistoryViewForLocation` (`submodules/GalleryUI/Sources/GalleryController.swift:909, 1746`).
- **Uploads.** Telegram's are `multipartUpload` through `network.upload` workers. For Mattermost, read the local resource (`mediaBox.resourceData` / `completedResourcePath`), call `POST /files`, then move the data to the new resource id with `mediaBox.moveResourceData(from:to:)` / `copyResourceData`, as `ApplyUpdateMessage.swift:7-15` does.
- **Avatars.** `TelegramUser.photo` / `TelegramChannel.photo: [TelegramMediaImageRepresentation]` with a `MattermostAvatarResource`.

---

## 7. Engine surface of the main screens (core flows)

Most interactive calls are Postbox‑only (§2 pattern). Network work happens in the managers or the view tracker.

### 7.1 Chat list

| Flow | Call | Call site | Definition |
|---|---|---|---|
| list | `chatListViewForLocation` → `account.viewTracker.tailChatListView` / `aroundChatListView` (no side effects) | `CLU/Node/ChatListNode.swift:1947` | `CLU/Node/ChatListNodeLocation.swift:198, 213, 226`; `AVT:2641-2702` → `PB/Postbox.swift:4946, 4972` |
| list (misc) | `engine.messages.chatList(group:count:)` | `CLU/ChatListController.swift:1588` | `EM:517` |
| preload | `account.viewTracker.chatListPreloadItems.set` (feeds network preload) | `CLU/ChatListControllerNode.swift:409` | `AVT:350, 372` |
| typing | `account.allPeerInputActivities()` | `CLU/Node/ChatListNode.swift:2769` | `TC/Account/Account.swift:1720` |
| unread totals | `renderedTotalUnreadCount` → `Item.Messages.TotalReadCounters` | `CLU/ChatListController.swift:444` | `submodules/TelegramUIPreferences/Sources/RenderedTotalUnreadCount.swift:19-23` |
| folder tabs | `chatListFilterItems` | `CLU/ChatListController.swift:4045` | `CLU/TabBarChatListFilterController.swift:11-105` |
| folders | `engine.peers.updatedChatListFilters` / `updatedChatListFiltersInfo` / `currentChatListFilters` / `updateChatListFiltersInteractively` | `CLU/Node/ChatListNode.swift:2168`; `CLU/ChatListController.swift:2790, 965, 3717` | `EP:793, 801, 805, 785` → `ChatListFiltering.swift:1195, 1222, 1239, 1117` |
| mark read | `engine.messages.markAllChatsAsReadInteractively`, `togglePeersUnreadMarkInteractively` | `CLU/ChatListController.swift:4230`; `CLU/Node/ChatListNode.swift:1689` | `EM:926, 945` → `ApplyMaxReadIndexInteractively.swift:362, 166/259` |
| delete chat | `engine.peers.removePeerChat(s)`, `engine.messages.clearHistoryInteractively` | `CLU/ChatListController.swift:6254, 5139, 5644` | `EP:654, 658` → `TC/TelegramEngine/Peers/RemovePeerChat.swift:7, 27`; `EM:212` |
| pin | `engine.peers.toggleItemPinned` | `CLU/Node/ChatListNode.swift:1598` | `EP:884` → `TogglePeerChatPinned.swift:15` |
| mute | `engine.peers.togglePeerMuted`, `updatePeerMuteSetting` | `CLU/Node/ChatListNode.swift:1652, 1663` | `EP:421, 430` → `TC/TelegramEngine/Peers/ChangePeerNotificationSettings.swift:6, 132` |
| archive | `engine.peers.updatePeersGroupIdInteractively` | `CLU/ChatListController.swift:6131` | `EP:1332` |

Data items (Postbox‑only, keep as they are), all in `TC/TelegramEngine/Data/`:
- `Peer.Peer`, `Peer.NotificationSettings`, `NotificationSettings.Global`, `Peer.IsContact`, `Peer.RenderedPeer` (`PeersData.swift:169, 299, 146, 663, 226`)
- `Messages.PeerReadCounters`, `Messages.ChatListGroup`, `Messages.TotalReadCounters` (`MessagesData.swift:180, 313, 268`)
- `ChatList.FiltersDisplayTags` (`ChatListData.swift:6`)
- `Configuration.UserLimits` (`ConfigurationData.swift:299`)

### 7.2 Chat screen

| Flow | Call | Call site | Definition |
|---|---|---|---|
| open / scroll | `chatHistoryViewForLocation`, which calls `viewTracker.aroundMessageOfInterestHistoryViewForLocation` (initial), `aroundMessageHistoryViewForLocation` (navigation and scroll), `aroundIdMessageHistoryViewForLocation` (open at message), `scheduledMessagesViewForLocation` | `TUI/ChatHistoryListNode.swift:1733`; `TUI/ChatHistoryViewForLocation.swift:62-314` | `AVT:2202, 2298, 2289, 2105` → `PB/Postbox.swift:4778, 4864, 4820`. All go through `wrappedMessageHistorySignal` (`AVT:1930`) |
| paging trigger | `processDisplayedItemRangeChanged` sets a `.Navigation` location | `TUI/ChatHistoryListNode.swift:3083, 3694, 3703` | holes per §3.3 |
| peer header | `viewTracker.peerView` (**network**: cached data), `forceUpdateCachedPeerData`, `polledChannel` (**network**) | `TUI/ChatControllerContentData.swift:295, 947, 1048` | `AVT:2342, 1793, 1877` |
| send / reply | `enqueueMessages(account:peerId:messages:)` (free function) | `TUI/Chat/ChatControllerLoadDisplayNode.swift:1124` (grouped :1100), `TUI/ChatController.swift:9188` | `TC/PendingMessages/EnqueueMessage.swift:697` |
| edit | `account.pendingUpdateMessageManager.add` (text); `engine.messages.requestEditMessage` (other) | `ChatControllerLoadDisplayNode.swift:2322`; `TUI/ChatController.swift:4426` | `PendingUpdateMessageManager.swift:172`; `EM:220` |
| delete | `engine.messages.deleteMessagesInteractively` | `ChatControllerLoadDisplayNode.swift:2055, 2058` | `EM:200` → `DeleteMessagesInteractively.swift:12, 70` |
| react | `updateMessageReactionsInteractively(account:…)` (free function) | `TUI/ChatController.swift:2264`; `TUI/Chat/ChatControllerOpenMessageContextMenu.swift:630` | `TC/State/MessageReactions.swift:24` (pending action `:112`, sender `:327`, manager `:573`) |
| mark read | `context.applyMaxReadIndex` → `engine.messages.applyMaxReadIndexInteractively`; `installInteractiveReadMessagesAction` / `…ReactionsAction` | `TUI/ChatHistoryListNode.swift:2692, 4921, 4939` | `TUI/AccountContext.swift:800`; `EM:106, 289, 293` |
| mentions | `clearPeerUnseenPersonalMessagesInteractively` | `ChatControllerLoadDisplayNode.swift:1447` | `ApplyMaxReadIndexInteractively.swift:342` |
| drafts / state | `ChatInterfaceState.update(engine:…)` → `engine.peers.get/setOpaqueChatInterfaceState` | `TUI/ChatController.swift:8342, 8360` | `submodules/ChatInterfaceState/Sources/ChatInterfaceState.swift:949`; `EP:1153, 1177` |
| typing | `account.updateLocalInputActivity`; `account.peerInputActivities` | `TUI/ChatController.swift:6671`; `ChatControllerLoadDisplayNode.swift:5172` | `TC/Account/Account.swift:1731, 1713` |
| open media | `sharedContext.openChatMessage` → `openChatMessageImpl` → gallery; `engine.resources.data` | `TUI/ChatController.swift:1758`; `TUI/OpenChatMessage.swift:32, 140` | `submodules/GalleryData/Sources/GalleryData.swift:95`; `TC/TelegramEngine/Resources/TelegramEngineResources.swift:454` |
| analytics | `engine.messages.reportPeerReadMetrics` (**network**, stub) | `TUI/ChatHistoryListNode.swift:1435` | `EM:1844` |

Chat‑screen data items (Postbox‑only):
- `Peer.Peer`, `Peer.Presence`, `Peer.NotificationSettings`, `Peer.ThreadData`, `Peer.ReactionSettings`, `Peer.IsContact`, `Peer.TranslationHidden` (`PeersData.swift:169, 268, 299, 1918, 809, 663, 1642`)
- `Messages.PeerUnreadCount`, `Messages.PeerReadCounters`, `Messages.Message`, `Messages.ThreadInfo`, `Messages.MessageCount` (`MessagesData.swift:205, 180, 106, 464, 337`)

### 7.3 `AccountViewTracker` side effects that hit the network

- **On every history update** (`wrappedMessageHistorySignal`, `AVT:1930`):
  - `updatePendingWebpages` → `fetchWebpage` (`AVT:401, 64-94`)
  - `updatePolls` (`AVT:490, 166-175`)
  - channel `historyViewStateValidationContexts` (`AVT:1979` → `TC/State/HistoryViewStateValidation.swift:122, 520-552`)
  - channel `polledChannel` → `keepPollingChannel` (`AVT:2019, 1877` → `TC/State/AccountStateManagementUtils.swift:3255, 3483`), plus the gate and hole insertion at `AVT:2036-2085`
- **For visible messages** (wired at `TUI/ChatHistoryListNode.swift:1075-1134`, fed at `:3499-3536`):
  - `updateViewCountForMessageIds` (`AVT:701`)
  - `updateReactionsForMessageIds` (reaction polling, `AVT:843`)
  - `updateSeenLiveLocationForMessageIds` (`:945`)
  - `updateUnsupportedMediaForMessageIds` (`:1054`)
  - `refreshSecretMediaMediaForMessageIds` (`:1155`)
  - `refreshStoriesForMessageIds` (`:1248`)
  - `updatedExtendedMediaForMessageIds` (`:1001`)
  - `refreshInlineGroupCallsForMessageIds` (`:1328`)
  - `updateMarkMentionsSeenForMessageIds` (`:1647`, pending action)
  - `updateMarkReactionsAndVotesSeenForMessageIds` (`:1750`)
  - `refreshStoryStatsForPeerIds` (`:1392`)
  - translations (`submodules/TranslateUI/Sources/ChatTranslation.swift:141`)
  - fact checks (`EM:989`)
- **Peer data:** `peerView` → `updateCachedPeerData` every 5 minutes (`AVT:1822-1849`); `forceUpdateCachedPeerData` (`AVT:1793`, also triggered by `stateManager.externallyUpdatedPeerIds`, `AVT:374`).

With the null engine all of these just hang. For MVP, short‑circuit them in the view tracker (one `// MATTERMOST:` flag per function), or turn off the UI wiring at `TUI/ChatHistoryListNode.swift:1075-1134`.

---

## 8. Extensions and targets

| Extension | Directory | Bazel target (`Telegram/BUILD`) | Bundle id |
|---|---|---|---|
| Share | `Telegram/Share/` | `ShareExtension` :1034-1059 | `<id>.Share` |
| Notification Content | `Telegram/NotificationContent/` | `NotificationContentExtension` :1141-1167 | `.NotificationContent` |
| Notification Service | `Telegram/NotificationService/` | `NotificationServiceExtension` + version :1577-1606 | `.NotificationService` |
| Siri Intents | `Telegram/SiriIntents/` | `IntentsExtension` :1421-1449 (intent library `GeneratedSources` :1329-1334) | `.SiriIntents` |
| Widget | `Telegram/WidgetKitWidget/` | `WidgetExtension` :1247-1285 | `.Widget` |
| Broadcast Upload (call screen share) | `Telegram/BroadcastUpload/` | `BroadcastUploadExtension` :1516-1543 | `.BroadcastUpload` |
| Watch app (tgwatch, xcodebuild) | `Telegram/WatchApp/` | `TelegramWatchApp` :1818-1829 (`Telegram/prebuilt_watchos.bzl`) | `.watchkitapp` |
| (dead) legacy WatchKit | `Telegram/Watch/` | none | n/a |

- **Wiring.**
  - `ios_application "Telegram"` is at :1831-1891.
  - `extensions = select({":disableExtensionsSetting": [], default: [Share, NotificationContent, NotificationService, Intents, Widget, BroadcastUpload]})` is at :1868-1878.
  - `watch_application = select({":embedWatchAppSetting": ":TelegramWatchApp", default: None})` is at :1882-1885. `embedWatchApp` defaults to False (:109-115) and is set only by `Make.py --embedWatchApp` for device builds.
- **To drop Widget, Siri and BroadcastUpload,** delete lines :1874-1876. Keep the `GeneratedSources` intent library, which `submodules/TelegramUI/BUILD:249` and `WidgetItems` depend on. Keep NotificationService for push and Share; NotificationContent is optional.
- **Entitlements** are generated, not files: `TelegramEntitlements` plist fragments (:583-600).
  - Siri: gated by `telegram_enable_siri` (:535-538).
  - iCloud: gated by `telegram_enable_icloud` (:504-522).
  - App group + application‑identifier: always on (:545-555).
  - aps: comes from the provisioning profile (`build-system/Make/BuildConfiguration.py:194-221`).
  - Apple Pay, CarPlay, associated domains, VoIP and communication notifications only for the official bundle ids (:450-581).
  - Extensions have no `entitlements` attribute, so they get theirs from their provisioning profiles.
  - Runtime flags: `BuildConfig` `-D` macros (`submodules/BuildConfig/BUILD:32-33`) → `isICloudEnabled` (`TUI/AppDelegate.swift:681`) / `isSiriEnabled` (:967).
- **Active configuration.** `build-config/development-configuration.json` already uses `bundle_id: org.relaychat.Relay`, `app_specific_url_scheme: relay`, `enable_siri/icloud: false`, but still has Telegram's `team_id C67CF9S4VU`. `build-system/fake-codesigning/profiles/*` are all for `C67CF9S4VU.ph.telegra.Telegraph.*` and are skipped for other ids (`BuildConfiguration.py:186-191`), so the aps check fails (`Make.py:523-525`) unless `--xcodeManagedCodesigning` is used.

## 9. Rebranding hooks

- **Display name.**
  - `CFBundleDisplayName` "Telegram" in `TelegramInfoPlist` (`Telegram/BUILD:1623-1628`) and `AppNameInfoPlist` (:633-641), the latter merged into every extension.
  - Per‑extension `CFBundleName` (:978, 1071, 1179, 1297, 1461, 1555).
  - Localized names: `Telegram/Telegram-iOS/{ar,ko}.lproj/InfoPlist.strings`. Usage descriptions: `en.lproj/InfoPlist.strings:3-6` and BUILD :1686-1696.
  - The target and executable name `Telegram` (:1832) is assumed by `Make.py` (`Telegram.ipa`, `'Telegram/Telegram'`).
- **Bundle id.** Config `bundle_id` → `telegram_bundle_id` (`build-system/Make/BuildConfiguration.py:43`) → `Telegram/BUILD:55`.
  - Extensions use `"{id}.Suffix"`. Framework ids: :663-938.
  - Extensions recover the base id by dropping the last component (e.g. `Telegram/Share/ShareRootController.swift:27-32`, `Telegram/NotificationService/Sources/NotificationService.swift:778-784`). The app uses `Bundle.main.bundleIdentifier!` (`TUI/AppDelegate.swift:560`).
  - Hard‑coded ids: theme UTI `org.telegram.Telegram-iOS.theme` (BUILD :1787), UI‑test bundle (:1935), watch default `ph.telegra.Telegraph.watchkitapp` (`Telegram/prebuilt_watchos.bzl:192`), Apple Pay merchant ids in `submodules/BotPaymentsUI`.
- **App group.** Always `"group.\(baseAppBundleId)"`: `TUI/AppDelegate.swift:315-318, 561-565`, `NotificationService.swift:791-793`, `ShareRootController.swift:38-40`, `submodules/WidgetItems/Sources/WidgetItems.swift:362-363`, and others. The data root is `<group>/telegram-data` (`TC/Account/AccountManager.swift:260-261`).
- **Keychain.** There is no `keychain-access-groups` entitlement; the default group is `{team}.{bundle}` (BUILD :550-551). `BuildConfig.keychainAccessGroup` uses the runtime seed id plus the base bundle id (`submodules/BuildConfig/Sources/BuildConfig.m:206-234`), as the passcode private group. The passcode shared group is the app group, with service `org.telegram.passcode.v1` (`submodules/PasscodeCore/Sources/Passcode.swift:72-77, 127-133`).
- **URL schemes.**
  - `UrlTypesInfoPlist` hard‑codes `telegram`, `tg`, `tonsite`, `ton`, `tc` (BUILD :414-448) and ignores `app_specific_url_scheme`. As a result `relay://` (used by the widget, `Telegram/WidgetKitWidget/TodayViewController.swift:304-306`) is **not registered**.
  - Handling: `SceneDelegate` → `AppDelegate.handleOpenURL` (:2588) → `openUrl` (:2600); scheme checks at `TUI/AppDelegate.swift:1570-1572, 1789`; `TUI/OpenUrl.swift:121, 433, 441`; `submodules/UrlHandling/Sources/UrlHandling.swift:12-14` (t.me hosts), :168 (`parseInternalUrl`).
- **BuildConfig.** `submodules/BuildConfig/BUILD:3-34` (variables → `-D`), getters in `BuildConfig.m:135-202`: apiId/hash, `isAppStoreBuild`, `appSpecificUrlScheme`, iCloud, Siri.
- **Strings.**
  - `Telegram/Telegram-iOS/en.lproj/Localizable.strings` has 13,396 entries; **598 lines contain "Telegram"**.
  - It is generated into `PresentationStrings` by the `GeneratedPresentationStrings` genrule (BUILD :148-224, `build-system/GenerateStrings/GenerateStrings.py`). Other languages are empty stubs.
  - There are 14 Swift `"Telegram"` literals (e.g. `TUI/StoreDownloadedMedia.swift:12`).
- **Icons.** `Telegram/Telegram-iOS/Telegram.icon` (BUILD :339-357, :1850); alternate icons `*.alticon` (:324-337, in‑app list `TUI/AppDelegate.swift:991-1012`); glyphs in `Icons.xcassets` (:296-301).

---

## Open items for the spikes

1. **Spike A:** confirm the null engine opens no sockets. Check with Instruments' Network template or a proxy, covering app launch, chat list, chat, and an `UnauthorizedAccount` (if kept). Confirm the "Updating…" override.
2. **Spike A:** confirm that rows with only `minTimestamp` render acceptably in `ChatListItem`, and that removing the chat‑list hole clears the loading state.
3. **Spike C:** property‑test id allocation against the two `assertionFailure()`s in `MessageHistoryViewState.swift:746-750, 815-819`, the 20 s re‑fetch suppression, and island merging with `removeHole`.
4. **Threads:** `isForumPost: true` side effects on the thread screen; whether the root post shows; the CRT tag‑bit approach (§3.9a).
5. **GMs:** `TelegramGroup` (no reply `threadId`) vs `TelegramChannel` for GMs.
6. **Saved Messages:** `threadId` convention and the `displaySavedChatsAsTopics` preference.
7. **Limits:** write a synthetic `AppConfiguration` (`PreferencesKeys.appConfiguration`) with `dialog_filters_limit_default`, `dialog_filters_chats_limit_default`, `dialogs_pinned_limit_default` and `reactions_user_max_default` (the default is **1** reaction per user, `UserLimitsConfiguration.swift:173`), or flag the own user `isPremium`.
