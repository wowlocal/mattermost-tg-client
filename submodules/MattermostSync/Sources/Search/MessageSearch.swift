import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Telegram's search UI on Mattermost (Phase 3C): TelegramCore asks this provider instead of Telegram's server
/// while the Mattermost backend is on (`MattermostSearchProvider`).
///
/// - Messages: `POST /teams/{id}/posts/search` per team (DMs and GMs come back in every team; merged by post
///   id), or `POST /teams/{id}/files/search` for the media tabs. The user's text goes to the server as typed,
///   modifiers included; the location adds `in:<channel id>`, `from:`, `after:`/`before:`.
/// - Results not stored yet are written through the normal page-write path (ids from the allocator, the roots
///   of replies along), so a result opens like a permalink: the chat (or the thread, with collapsed reply
///   threads) at the post, with the history around it loaded by the hole filler.
/// - People and channels (`PeerSearch.swift`), pinning (`Pinning.swift`).
final class SearchProvider: MattermostSearchProvider {
    private weak var sync: MattermostAccountSync?

    init(sync: MattermostAccountSync) {
        self.sync = sync
    }

    private func run<T>(empty: T, _ body: @escaping (MattermostAccountSync) async -> T) -> Signal<T, NoError> {
        return Signal { [weak self] subscriber in
            let task = Task {
                let value: T
                if let sync = self?.sync, !sync.isStopped {
                    value = await body(sync)
                } else {
                    value = empty
                }
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

    func searchMessages(location: SearchMessagesLocation, query: String, page: Int32, limit: Int32) -> Signal<MattermostSearchPage, NoError> {
        return self.run(empty: MattermostSearchPage.empty) { sync in
            return await sync.searchMessages(location: location, query: query, page: Int(page))
        }
    }

    func searchPeers(query: String, scope: TelegramSearchPeersScope) -> Signal<(myResults: [FoundPeer], otherResults: [FoundPeer]), NoError> {
        return self.run(empty: (myResults: [FoundPeer](), otherResults: [FoundPeer]())) { sync in
            return await sync.searchPeers(query: query, scope: scope)
        }
    }

    func updatePinned(messageId: MessageId, pinned: Bool) -> Signal<Bool, NoError> {
        return self.run(empty: false) { sync in
            return await sync.setPinned(messageId: messageId, pinned: pinned)
        }
    }

    func unpinAll(peerId: PeerId, threadId: Int64?) -> Signal<Bool, NoError> {
        return self.run(empty: false) { sync in
            return await sync.unpinAll(peerId: peerId, threadId: threadId)
        }
    }
}

/// One server search, built from Telegram's search location.
struct PostSearchRequest {
    enum Endpoint {
        /// `POST /teams/{id}/posts/search`.
        case posts
        /// `POST /teams/{id}/files/search`: the posts of the files found.
        case files
    }

    var endpoint: Endpoint = .posts
    var terms: String
    var isOrSearch = false
    var teamIds: [String]
    /// Which found posts count (chat kind, thread, root posts only).
    var include: (Post, MattermostAccountSync.ChannelState) -> Bool = { _, _ in true }
    /// Media tabs: the messages of a post that carry one of these tags; nil: the message with the post's text.
    var tags: MessageTags?
}

extension MattermostAccountSync {
    /// Seconds east of UTC for the date modifiers.
    var searchTimeZoneOffset: Int {
        return TimeZone.current.secondsFromGMT()
    }

    /// The team of a team folder (chat list filter id), see `writeTeamFolders`.
    func teamId(chatListFilterId: Int32) -> String? {
        for team in self.state.with({ $0.teams }) where self.store.cursor(MattermostCursorKey.folderId(teamId: team.id)) == String(chatListFilterId) {
            return team.id
        }
        return nil
    }

    /// The Mattermost user of a user peer (the own user included).
    func mattermostUserId(peerId: PeerId) -> String? {
        if peerId == self.ownPeerId {
            return self.ownUserId
        }
        guard peerId.namespace == Namespaces.Peer.CloudUser, let peer = self.store.peer(namespace: .user, peerId: peerId.id._internalGetInt64Value()), peer.kind == .user else {
            return nil
        }
        return peer.mattermostId
    }

    func searchMessages(location: SearchMessagesLocation, query: String, page: Int) async -> MattermostSearchPage {
        await self.waitUntilBootstrapped()
        guard let request = await self.searchRequest(location: location, query: query) else {
            return .empty
        }
        let started = CFAbsoluteTimeGetCurrent()
        let result = await self.runSearch(request, page: page)
        MMLog.log("search: \(request.terms.count) characters\(request.isOrSearch ? " (or)" : "")\(request.endpoint == .files ? " (files)" : "") page \(page) → \(result.messageIds.count) message(s)\(result.nextPage != nil ? ", more" : "") in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
        return result
    }

    /// The server search for one of Telegram's search locations; nil when there is nothing to ask (an empty
    /// query, Telegram-only scopes such as public posts or saved-message reactions).
    func searchRequest(location: SearchMessagesLocation, query: String) async -> PostSearchRequest? {
        let teams = self.state.with { $0.teams.map(\.id) }
        guard let firstTeamId = teams.first else {
            return nil
        }
        let offset = self.searchTimeZoneOffset
        switch location {
        case let .general(scope, _, tags, minDate, maxDate, folderId, _):
            let kinds: Set<ChatKind>
            switch scope {
            case .everywhere:
                kinds = [.channel, .direct, .saved]
            case .channels, .groups:
                kinds = [.channel]
            case .privateChats:
                kinds = [.direct, .saved]
            case .bots, .globalPosts:
                return nil
            }
            var teamIds = teams
            if let folderId = folderId, let teamId = self.teamId(chatListFilterId: folderId) {
                teamIds = [teamId]
            }
            let terms = SearchQuery.terms(query: query, minDate: minDate.map(Int64.init), maxDate: maxDate.map(Int64.init), secondsFromGMT: offset)
            var request = PostSearchRequest(terms: terms, teamIds: teamIds)
            request.include = { _, channelState in
                return kinds.contains(channelState.kind)
            }
            return self.applyTags(tags, to: request)
        case let .peer(peerId, fromId, tags, reactions, threadId, minDate, maxDate):
            if let reactions = reactions, !reactions.isEmpty {
                // Telegram's saved-message reaction tags.
                return nil
            }
            guard let channelId = self.channelId(forPeerId: peerId), let channelState = self.channelState(channelId) else {
                return nil
            }
            var fromUsernames: [String] = []
            if let fromId = fromId {
                guard let userId = self.mattermostUserId(peerId: fromId) else {
                    return nil
                }
                await self.ensureUsers([userId])
                guard let username = self.state.with({ $0.users[userId]?.username }) else {
                    return nil
                }
                fromUsernames.append(username)
            }
            var threadRootPostId: String?
            if let threadId = threadId, let localId = Int32(exactly: threadId), localId > 0 {
                guard let entry = self.store.entries(channelId: channelId, fromLocalId: localId, ascending: true, limit: 1).first, entry.localId == localId else {
                    return nil
                }
                threadRootPostId = entry.serverPostId
            }
            // Replies are found too, as Mattermost's search in a channel finds them (4F): with collapsed reply
            // threads stepping to one (or picking it from the list) opens its thread (TelegramUI
            // `mattermostNavigateToReplyInThread`; the newest result shown while typing is shown as its root).
            let terms = SearchQuery.terms(query: query, inChannels: [channelId], fromUsernames: fromUsernames, minDate: minDate.map(Int64.init), maxDate: maxDate.map(Int64.init), secondsFromGMT: offset)
            let teamId = channelState.teamId.isEmpty ? firstTeamId : channelState.teamId
            var request = PostSearchRequest(terms: terms, teamIds: [teamId])
            request.include = { post, _ in
                if let root = threadRootPostId {
                    return post.id == root || post.rootId == root
                }
                return true
            }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && fromUsernames.isEmpty && (tags?.isEmpty ?? true) {
                return nil
            }
            return self.applyTags(tags, to: request)
        case .sentMedia:
            return nil
        }
    }

    /// Media tabs: file search for file tags (an extension filter per tab), post search filtered to posts with
    /// links for the links tab.
    private func applyTags(_ tags: MessageTags?, to request: PostSearchRequest) -> PostSearchRequest? {
        var request = request
        guard let tags = tags, !tags.isEmpty else {
            return SearchQuery.isEmpty(request.terms) ? nil : request
        }
        request.tags = tags
        if tags.contains(.webPage) {
            let include = request.include
            request.include = { post, channelState in
                return include(post, channelState) && (post.message.contains("http://") || post.message.contains("https://"))
            }
            request.tags = nil
            return SearchQuery.isEmpty(request.terms) ? nil : request
        }
        request.endpoint = .files
        var extensions: [String] = []
        if !tags.intersection([.photoOrVideo, .photo, .video, .gif]).isEmpty {
            extensions += ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "mp4", "mov", "m4v", "webm", "avi", "mkv"]
        }
        if tags.contains(.music) {
            extensions += ["mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "wma", "aif", "aiff"]
        }
        if tags.contains(.voiceOrInstantVideo) && !tags.contains(.file) && extensions.isEmpty {
            // Mattermost has no voice messages.
            return nil
        }
        if tags.contains(.file) && SearchQuery.isEmpty(request.terms) {
            // The files tab before anything is typed: recent documents (the server needs some terms).
            extensions += ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt", "rtf", "md", "csv", "json", "xml", "log", "zip", "gz", "tar", "7z", "rar", "dmg", "apk", "ipa"]
        } else if tags.contains(.file) {
            extensions = []
        }
        request.terms = ([request.terms] + extensions.map { "ext:" + $0 }).filter { !$0.isEmpty }.joined(separator: " ")
        return SearchQuery.isEmpty(request.terms) ? nil : request
    }

    /// Runs a search on every team of the request and stores the posts found. More pages are asked for when a
    /// team's page was full (the database search backend answers page 0 only, with at most 100 posts).
    func runSearch(_ request: PostSearchRequest, page: Int) async -> MattermostSearchPage {
        var postsById: [String: Post] = [:]
        // Files search: the files found (a post's other files are left out).
        var fileIds = Set<String>()
        var hasMore = false
        let perPage = PostSearchOptions.maxPerPage
        for teamId in request.teamIds {
            if Task.isCancelled {
                return .empty
            }
            do {
                switch request.endpoint {
                case .posts:
                    let results = try await self.client.searchPosts(teamId: teamId, options: PostSearchOptions(terms: request.terms, isOrSearch: request.isOrSearch, timeZoneOffset: self.searchTimeZoneOffset, includeDeletedChannels: false, page: page, perPage: perPage))
                    let found = results.orderedPosts
                    if found.count >= perPage {
                        hasMore = true
                    }
                    for post in found {
                        postsById[post.id] = post
                    }
                case .files:
                    let list = try await self.client.searchFiles(teamId: teamId, options: FileSearchOptions(terms: request.terms, isOrSearch: request.isOrSearch, timeZoneOffset: self.searchTimeZoneOffset, includeDeletedChannels: false, page: page, perPage: perPage))
                    let files = list.orderedFiles
                    if files.count >= perPage {
                        hasMore = true
                    }
                    var missing: [String] = []
                    for file in files where !file.postId.isEmpty && file.deleteAt == 0 {
                        fileIds.insert(file.id)
                        if postsById[file.postId] == nil && !missing.contains(file.postId) {
                            missing.append(file.postId)
                        }
                    }
                    for start in stride(from: 0, to: missing.count, by: 100) {
                        for post in try await self.client.posts(ids: Array(missing[start ..< min(missing.count, start + 100)])) {
                            postsById[post.id] = post
                        }
                    }
                }
            } catch {
                MMLog.log("search: team \(teamId) failed: \(error)")
            }
        }
        var posts = postsById.values.filter { $0.deleteAt == 0 && !$0.type.hasPrefix("system_ephemeral") }
        // Channels joined since the bootstrap (search only finds posts of channels the user is a member of).
        let unknownChannels = Set(posts.map(\.channelId)).filter { self.channelState($0) == nil }
        for channelId in unknownChannels.prefix(10) {
            await self.refreshChannel(channelId)
        }
        posts = posts.filter { post in
            guard let channelState = self.channelState(post.channelId) else {
                return false
            }
            return request.include(post, channelState)
        }
        posts.sort(by: { PostOrderKey(createAt: $0.createAt, postId: $0.id) > PostOrderKey(createAt: $1.createAt, postId: $1.id) })
        await self.storeFoundPosts(posts)
        let messageIds = await self.messageIds(of: posts, tags: request.tags, fileIds: request.endpoint == .files ? fileIds : nil)
        return MattermostSearchPage(messageIds: messageIds, totalCount: Int32(messageIds.count), nextPage: hasMore ? Int32(page + 1) : nil)
    }

    /// Writes the posts that aren't stored yet (and the thread roots of replies among them) through the page-write
    /// path, one by one: a post far back becomes a one-post island that the chat's hole requests load around.
    func storeFoundPosts(_ posts: [Post]) async {
        if posts.isEmpty {
            return
        }
        let byChannel = Dictionary(grouping: posts, by: \.channelId)
        var rootsByChannel: [String: [Post]] = [:]
        var rootIds: [String] = []
        for (channelId, channelPosts) in byChannel {
            let found = Set(channelPosts.map(\.id))
            let wanted = Set(channelPosts.compactMap { $0.rootId.isEmpty || found.contains($0.rootId) ? nil : $0.rootId })
            if wanted.isEmpty {
                continue
            }
            let known = self.store.entries(channelId: channelId, postIds: Array(wanted))
            rootIds.append(contentsOf: wanted.filter { known[$0] == nil })
        }
        for start in stride(from: 0, to: rootIds.count, by: 100) {
            if let roots = try? await self.client.posts(ids: Array(rootIds[start ..< min(rootIds.count, start + 100)])) {
                for root in roots where root.deleteAt == 0 {
                    rootsByChannel[root.channelId, default: []].append(root)
                }
            }
        }
        await self.ensureUsers(referencedUserIds(posts + rootsByChannel.values.flatMap { $0 }))
        for (channelId, channelPosts) in byChannel {
            guard let peerId = self.channelState(channelId)?.peerId else {
                continue
            }
            let roots = rootsByChannel[channelId] ?? []
            await self.postbox.mmTransaction { transaction in
                let known = self.store.entries(channelId: channelId, postIds: (channelPosts + roots).map(\.id))
                let isMissing: (Post) -> Bool = { post in
                    guard let entry = known[post.id] else {
                        return true
                    }
                    return !entry.isDeleted && !transaction.messageExists(id: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: entry.localId))
                }
                let run = channelPosts.filter(isMissing).sorted(by: { $0.createAt < $1.createAt })
                let extra = roots.filter(isMissing)
                if !run.isEmpty || !extra.isEmpty {
                    let result = self.write(PageWrite(channelId: channelId, kind: .singles, run: run, extra: extra), transaction: transaction)
                    MMLog.log("search: stored \(run.count) post(s) and \(extra.count) root(s) of \(channelId) (\(result.writtenCount) message(s), \(result.insertedCount) new id(s))")
                }
            }
        }
    }

    /// The stored messages of `posts`, in their order: the message with each post's text, or (media tabs) every
    /// message of a post that carries one of `tags`.
    /// `fileIds`: only the messages of these files (a files search).
    func messageIds(of posts: [Post], tags: MessageTags?, fileIds: Set<String>? = nil) async -> [MessageId] {
        return await self.postMessageIds(of: posts, tags: tags, fileIds: fileIds).map(\.messageId)
    }

    /// `messageIds(of:tags:)` with the post of each message.
    func postMessageIds(of posts: [Post], tags: MessageTags?, fileIds: Set<String>? = nil) async -> [(postId: String, messageId: MessageId)] {
        return await self.postbox.mmTransaction { transaction -> [(postId: String, messageId: MessageId)] in
            let mediaIds: Set<Int64>? = fileIds.map { Set($0.map { self.store.allocateMediaId(fileId: $0) }) }
            var result: [(postId: String, messageId: MessageId)] = []
            for post in posts {
                guard let channelState = self.channelState(post.channelId) else {
                    continue
                }
                let layout = PostLayout(post: post)
                let keys = PostOrderKey(createAt: post.createAt, postId: post.id).parts(count: layout.count)
                let entries = self.store.entries(channelId: post.channelId, postIds: keys.map(\.postId))
                let candidates: [PostOrderKey]
                if tags != nil {
                    candidates = keys
                } else {
                    candidates = [keys[min(layout.textPartIndex, keys.count - 1)]]
                }
                for key in candidates {
                    guard let entry = entries[key.postId], !entry.isDeleted else {
                        continue
                    }
                    let id = MessageId(peerId: channelState.peerId, namespace: Namespaces.Message.Cloud, id: entry.localId)
                    if let tags = tags {
                        guard let message = transaction.getMessage(id), !message.tags.intersection(tags).isEmpty else {
                            continue
                        }
                        if let mediaIds = mediaIds, !message.media.contains(where: { $0.id.map { mediaIds.contains($0.id) } ?? false }) {
                            continue
                        }
                    } else if !transaction.messageExists(id: id) {
                        continue
                    }
                    result.append((post.id, id))
                }
            }
            return result
        }
    }
}
