import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Saved posts (Mattermost's "flagged" posts, Phase 3C) and recent mentions.
///
/// Saved posts are `flagged_post` preferences (`name` = post id). The set is loaded from the preferences on every
/// new WebSocket connection and kept current by `preferences_changed` / `preferences_deleted`, so the message
/// menu offers Save or Unsave without a request and the saved posts list follows other clients live. Not to be
/// confused with Telegram's Saved Messages, which is the self-DM.
extension MattermostAccountSync {
    // MARK: The saved set

    func loadSavedPostIds() async {
        do {
            let preferences = try await self.client.preferences()
            let ids = Set(preferences.filter { $0.category == PreferenceCategory.flaggedPost && $0.value == "true" }.map(\.name))
            let changed = self.state.with { state -> Bool in
                let changed = state.savedPostIds != ids
                state.savedPostIds = ids
                return changed
            }
            if changed {
                self.savedPostsChanged()
            }
            MMLog.log("saved posts: \(ids.count)")
        } catch {
            MMLog.log("saved posts: preferences not loaded: \(error)")
        }
    }

    func savedPostsChanged() {
        let version = self.savedPostsVersion.with { value -> Int in
            value += 1
            return value
        }
        self.savedPostsVersionPromise.set(version)
    }

    /// `preferences_changed` / `preference_changed` / `preferences_deleted` with `flagged_post` preferences.
    func applySavedPostsEvent(_ event: WebSocketEvent) {
        var preferences = event.decodeEmbedded([Preference].self, key: "preferences") ?? []
        if let single = event.decodeEmbedded(Preference.self, key: "preference") {
            preferences.append(single)
        }
        let flagged = preferences.filter { $0.category == PreferenceCategory.flaggedPost }
        if flagged.isEmpty {
            return
        }
        let isDeleted = event.type == .preferencesDeleted
        self.state.with { state in
            var ids = state.savedPostIds ?? []
            for preference in flagged {
                if isDeleted || preference.value != "true" {
                    ids.remove(preference.name)
                } else {
                    ids.insert(preference.name)
                }
            }
            state.savedPostIds = ids
        }
        self.savedPostsChanged()
        MMLog.log("live: saved posts \(isDeleted ? "removed" : "changed"): \(flagged.map(\.name))")
    }

    /// Whether the post of a message is saved; nil while unknown (not loaded, or not a post).
    func isSaved(messageId: MessageId) -> Bool? {
        guard let reference = self.postReference(for: messageId), let ids = self.state.with({ $0.savedPostIds }) else {
            return nil
        }
        return ids.contains(reference.postId)
    }

    /// Saves or unsaves the post of a message: the set changes at once (the menu and the list follow), and back
    /// when the server refuses.
    func setSaved(messageId: MessageId, saved: Bool) async -> Bool {
        guard let reference = self.postReference(for: messageId) else {
            return false
        }
        let previous = self.state.with { state -> Set<String> in
            let previous = state.savedPostIds ?? []
            var ids = previous
            if saved {
                ids.insert(reference.postId)
            } else {
                ids.remove(reference.postId)
            }
            state.savedPostIds = ids
            return previous
        }
        self.savedPostsChanged()
        do {
            if saved {
                try await self.client.savePost(id: reference.postId, userId: self.ownUserId)
            } else {
                try await self.client.unsavePost(id: reference.postId, userId: self.ownUserId)
            }
            MMLog.log("saved posts: \(saved ? "saved" : "unsaved") \(reference.postId)")
            return true
        } catch {
            MMLog.log("saved posts: \(saved ? "save" : "unsave") \(reference.postId) failed: \(error)")
            self.state.with { $0.savedPostIds = previous }
            self.savedPostsChanged()
            if !(await MattermostSync.isSessionRejected(error, sync: self)) {
                self.notice(saved ? "The message couldn't be saved." : "The message couldn't be removed from Saved.")
            }
            return false
        }
    }

    // MARK: Lists

    /// A page of saved posts (`GET /users/me/posts/flagged`, every team), stored; newest first.
    func loadSavedPostsPage(_ page: Int, perPage: Int) async throws -> (entries: [(postId: String, messageId: MessageId)], hasMore: Bool) {
        await self.waitUntilBootstrapped()
        let list = try await self.client.flaggedPosts(page: page, perPage: perPage)
        var posts = list.orderedPosts.filter { $0.deleteAt == 0 }
        let unknownChannels = Set(posts.map(\.channelId)).filter { self.channelState($0) == nil }
        for channelId in unknownChannels.prefix(10) {
            await self.refreshChannel(channelId)
        }
        posts = posts.filter { self.channelState($0.channelId) != nil }
        await self.storeFoundPosts(posts)
        let entries = await self.postMessageIds(of: posts, tags: nil)
        return (entries, list.order.count >= perPage)
    }

    /// The search terms of the user's mentions (Mattermost's "Recent Mentions"), or nil before the user is known.
    var mentionSearchTerms: String? {
        guard let me = self.state.with({ $0.me }) else {
            return nil
        }
        let terms = SearchQuery.mentionTerms(username: me.username, firstName: me.firstName, notifyProps: me.notifyProps)
        return terms.isEmpty ? nil : terms
    }

    /// A page of recent mentions: an OR search for the user's mention keys in every team, stored; newest first.
    func loadMentionsPage(_ page: Int) async throws -> (entries: [(postId: String, messageId: MessageId)], hasMore: Bool) {
        await self.waitUntilBootstrapped()
        guard let terms = self.mentionSearchTerms else {
            return ([], false)
        }
        var request = PostSearchRequest(terms: terms, teamIds: self.state.with { $0.teams.map(\.id) })
        request.isOrSearch = true
        let result = await self.runSearch(request, page: page)
        // `runSearch` keeps the posts' order; map the messages back to their posts for the list.
        let entries: [(postId: String, messageId: MessageId)] = result.messageIds.compactMap { messageId in
            guard let reference = self.postReference(for: messageId) else {
                return nil
            }
            return (reference.postId, messageId)
        }
        MMLog.log("mentions: \"\(terms)\" page \(page) → \(entries.count)")
        return (entries, result.nextPage != nil)
    }
}

// MARK: - Lists for the app

public enum MattermostPostListKind: Equatable {
    /// Saved posts (`flagged_post`).
    case saved
    /// Posts that mention the user.
    case mentions
}

public struct MattermostPostListState: Equatable {
    /// Newest first; the post's message with its text.
    public var messageIds: [MessageId]
    public var isLoading: Bool
    public var hasMore: Bool
    /// The first load failed (offline, server error).
    public var failed: Bool

    public init(messageIds: [MessageId], isLoading: Bool, hasMore: Bool, failed: Bool) {
        self.messageIds = messageIds
        self.isLoading = isLoading
        self.hasMore = hasMore
        self.failed = failed
    }
}

/// The saved posts or recent mentions of an account, page by page; the saved list follows saves and unsaves
/// (this device and others) live.
public final class MattermostPostList {
    public let kind: MattermostPostListKind
    private let accountId: AccountRecordId

    private struct Contents {
        var entries: [(postId: String, messageId: MessageId)] = []
        var nextPage: Int? = 0
        var isLoading = false
        var failed = false
        var generation = 0
        var savedSnapshot: Set<String>?
    }

    private let contents = MMLocked(Contents())
    private let statePromise = ValuePromise<MattermostPostListState>(MattermostPostListState(messageIds: [], isLoading: true, hasMore: false, failed: false), ignoreRepeated: true)
    private let savedDisposable = MetaDisposable()
    private static let savedPageSize = 60

    init(accountId: AccountRecordId, kind: MattermostPostListKind) {
        self.accountId = accountId
        self.kind = kind
    }

    deinit {
        self.savedDisposable.dispose()
    }

    public var state: Signal<MattermostPostListState, NoError> {
        return self.statePromise.get()
    }

    /// Loads the first page (again).
    public func reload() {
        self.contents.with { contents in
            contents.generation += 1
            contents.entries = []
            contents.nextPage = 0
            contents.isLoading = false
            contents.failed = false
        }
        self.loadMore()
        if self.kind == .saved {
            self.observeSaved()
        }
    }

    public func loadMore() {
        let request = self.contents.with { contents -> (page: Int, generation: Int)? in
            guard !contents.isLoading, let page = contents.nextPage else {
                return nil
            }
            contents.isLoading = true
            return (page, contents.generation)
        }
        guard let (page, generation) = request else {
            return
        }
        self.publish()
        let accountId = self.accountId
        let kind = self.kind
        Task { [weak self] in
            guard let sync = await MattermostSync.waitForRunningSync(accountId: accountId) else {
                self?.finish(generation: generation, entries: [], hasMore: false, failed: true)
                return
            }
            do {
                let result: (entries: [(postId: String, messageId: MessageId)], hasMore: Bool)
                switch kind {
                case .saved:
                    result = try await sync.loadSavedPostsPage(page, perPage: MattermostPostList.savedPageSize)
                case .mentions:
                    result = try await sync.loadMentionsPage(page)
                }
                self?.finish(generation: generation, entries: result.entries, hasMore: result.hasMore, failed: false)
            } catch {
                MMLog.log("post list \(kind): page \(page) failed: \(error)")
                self?.finish(generation: generation, entries: [], hasMore: true, failed: true)
            }
        }
    }

    private func finish(generation: Int, entries: [(postId: String, messageId: MessageId)], hasMore: Bool, failed: Bool) {
        self.contents.with { contents in
            guard contents.generation == generation else {
                return
            }
            contents.isLoading = false
            if failed {
                contents.failed = contents.entries.isEmpty
                return
            }
            var seen = Set(contents.entries.map(\.messageId))
            for entry in entries where seen.insert(entry.messageId).inserted {
                contents.entries.append(entry)
            }
            contents.nextPage = hasMore ? (contents.nextPage ?? 0) + 1 : nil
            contents.failed = false
        }
        self.publish()
    }

    private func publish() {
        let state = self.contents.with { contents in
            return MattermostPostListState(messageIds: contents.entries.map(\.messageId), isLoading: contents.isLoading, hasMore: contents.nextPage != nil, failed: contents.failed)
        }
        self.statePromise.set(state)
    }

    /// Saved posts: an unsaved post leaves the list at once; a newly saved one reloads it (it may be anywhere).
    private func observeSaved() {
        let accountId = self.accountId
        let signal: Signal<Set<String>?, NoError> = MattermostSync.asyncSignal {
            return await MattermostSync.waitForRunningSync(accountId: accountId)
        }
        |> mapToSignal { sync -> Signal<Set<String>?, NoError> in
            guard let sync = sync else {
                return .single(nil)
            }
            return sync.savedPostsVersionPromise.get()
            |> map { _ -> Set<String>? in
                return sync.state.with { $0.savedPostIds }
            }
        }
        self.savedDisposable.set(signal.start(next: { [weak self] saved in
            guard let self = self, let saved = saved else {
                return
            }
            var needsReload = false
            let removedAny = self.contents.with { contents -> Bool in
                defer {
                    contents.savedSnapshot = saved
                }
                if let previous = contents.savedSnapshot, !saved.subtracting(previous).isEmpty {
                    needsReload = true
                }
                let before = contents.entries.count
                contents.entries.removeAll(where: { !saved.contains($0.postId) })
                return contents.entries.count != before
            }
            if needsReload {
                self.reloadKeepingObserver()
            } else if removedAny {
                self.publish()
            }
        }))
    }

    private func reloadKeepingObserver() {
        self.contents.with { contents in
            contents.generation += 1
            contents.entries = []
            contents.nextPage = 0
            contents.isLoading = false
        }
        self.loadMore()
    }
}

public extension MattermostSync {
    /// The account's saved posts or recent mentions; call `reload()` to load the first page.
    static func postList(accountId: AccountRecordId, kind: MattermostPostListKind) -> MattermostPostList {
        return MattermostPostList(accountId: accountId, kind: kind)
    }

    /// The words of a search query to highlight in results: Mattermost modifiers, quotes and excluded words removed.
    static func searchHighlightText(_ query: String) -> String {
        return SearchQuery.highlightText(query)
    }

    /// The user's mention keys as words to highlight in the mentions list (`@alice relay`), or nil.
    static func mentionHighlightText(accountId: AccountRecordId) -> String? {
        guard let terms = self.sync(accountId: accountId)?.mentionSearchTerms else {
            return nil
        }
        return SearchQuery.highlightText(terms)
    }

    /// Whether the message's post is saved; nil when unknown (not a Mattermost post, or the set isn't loaded).
    static func isPostSaved(accountId: AccountRecordId, messageId: MessageId) -> Bool? {
        return self.sync(accountId: accountId)?.isSaved(messageId: messageId)
    }

    /// Saves (or unsaves) the message's post; true when the server accepted it.
    static func setPostSaved(accountId: AccountRecordId, messageId: MessageId, saved: Bool) -> Signal<Bool, NoError> {
        return self.asyncSignal {
            guard let sync = self.sync(accountId: accountId) else {
                return false
            }
            return await sync.setSaved(messageId: messageId, saved: saved)
        }
    }

    /// Joins a public channel shown by search (a `.left` channel peer) and returns the chat to open; nil when it
    /// isn't such a channel or joining failed.
    static func joinPublicChannel(accountId: AccountRecordId, peerId: PeerId) -> Signal<PeerId?, NoError> {
        return self.asyncSignal {
            guard let sync = await self.waitForRunningSync(accountId: accountId) else {
                return nil
            }
            return await sync.joinPreviewChannel(peerId: peerId)
        }
    }

    /// Whether `peerId` is a public channel shown by search that the user hasn't joined.
    static func isPreviewChannel(accountId: AccountRecordId, peerId: PeerId) -> Bool {
        guard let sync = self.sync(accountId: accountId) else {
            return false
        }
        if let channelId = sync.channelId(forPeerId: peerId), sync.channelState(channelId) != nil {
            return false
        }
        return sync.state.with { $0.previewChannels[peerId] != nil }
    }

    /// Runs `body` in a task as a signal (one value, then completion); cancelled with the subscription.
    static func asyncSignal<T>(_ body: @escaping () async -> T) -> Signal<T, NoError> {
        return Signal { subscriber in
            let task = Task {
                let value = await body()
                if !Task.isCancelled {
                    subscriber.putNext(value)
                    subscriber.putCompletion()
                }
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }
}
