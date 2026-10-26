import Foundation

// MARK: - Posts

extension MattermostClient {
    /// `GET /channels/{channel_id}/posts`.
    ///
    /// Use one paging style per call: `page`/`perPage`, a `before`/`after`
    /// post-ID cursor (with `perPage`), or `since` (ms; returns posts created,
    /// edited or deleted since then, ignoring the other paging arguments).
    public func posts(
        channelId: String,
        page: Int? = nil,
        perPage: Int? = nil,
        before: String? = nil,
        after: String? = nil,
        since: Int64? = nil,
        includeDeleted: Bool = false,
        collapsedThreads: Bool = false,
        collapsedThreadsExtended: Bool = false
    ) async throws -> PostList {
        var query = QueryBuilder()
        query.add("page", page)
        query.add("per_page", perPage)
        query.add("before", before)
        query.add("after", after)
        query.add("since", since)
        query.addFlag("include_deleted", includeDeleted)
        query.addFlag("collapsedThreads", collapsedThreads)
        query.addFlag("collapsedThreadsExtended", collapsedThreadsExtended)
        return try await send(APIRequest(.get, apiPath("channels", channelId, "posts"), query: query.items))
    }

    /// `GET /posts/{post_id}`.
    public func post(id: String, includeDeleted: Bool = false) async throws -> Post {
        var query = QueryBuilder()
        query.addFlag("include_deleted", includeDeleted)
        return try await send(APIRequest(.get, apiPath("posts", id), query: query.items))
    }

    /// `GET /posts/{post_id}/thread`: the root post and its replies.
    public func postThread(postId: String, options: PostThreadOptions = PostThreadOptions()) async throws -> PostList {
        var query = QueryBuilder()
        query.add("perPage", options.perPage)
        query.add("fromPost", options.fromPost)
        query.add("fromCreateAt", options.fromCreateAt)
        query.add("direction", options.direction?.rawValue)
        query.addFlag("skipFetchThreads", options.skipFetchThreads)
        query.addFlag("collapsedThreads", options.collapsedThreads)
        query.addFlag("collapsedThreadsExtended", options.collapsedThreadsExtended)
        return try await send(APIRequest(.get, apiPath("posts", postId, "thread"), query: query.items))
    }

    /// `GET /channels/{channel_id}/pinned`.
    public func pinnedPosts(channelId: String) async throws -> PostList {
        try await send(APIRequest(.get, apiPath("channels", channelId, "pinned")))
    }

    /// `POST /posts`.
    /// - Parameter setOnline: Whether sending marks the user online (false for
    ///   replies sent from a notification action in the background).
    public func createPost(_ draft: PostDraft, setOnline: Bool? = nil) async throws -> Post {
        var query = QueryBuilder()
        query.add("set_online", setOnline)
        return try await send(APIRequest.json(.post, "/posts", body: draft, query: query.items))
    }

    /// `PUT /posts/{post_id}/patch`.
    public func patchPost(id: String, patch: PostPatch) async throws -> Post {
        try await send(APIRequest.json(.put, apiPath("posts", id, "patch"), body: patch))
    }

    /// `DELETE /posts/{post_id}`.
    public func deletePost(id: String) async throws {
        try await sendIgnoringResponse(APIRequest(.delete, apiPath("posts", id)))
    }

    private struct SetUnreadBody: Encodable {
        var collapsedThreadsSupported: Bool

        enum CodingKeys: String, CodingKey {
            case collapsedThreadsSupported = "collapsed_threads_supported"
        }
    }

    /// `POST /users/{user_id}/posts/{post_id}/set_unread`: marks the channel
    /// (or thread) unread starting at this post.
    @discardableResult
    public func markPostUnread(postId: String, collapsedThreadsSupported: Bool = true, userId: String = MattermostClient.currentUser) async throws -> ChannelUnreadAt {
        try await send(APIRequest.json(
            .post,
            apiPath("users", userId, "posts", postId, "set_unread"),
            body: SetUnreadBody(collapsedThreadsSupported: collapsedThreadsSupported)
        ))
    }

    /// `POST /teams/{team_id}/posts/search`.
    public func searchPosts(teamId: String, options: PostSearchOptions) async throws -> PostSearchResults {
        try await send(APIRequest.json(.post, apiPath("teams", teamId, "posts", "search"), body: options))
    }
}

// MARK: - Threads (collapsed reply threads)

extension MattermostClient {
    /// `GET /users/{user_id}/teams/{team_id}/threads`.
    public func userThreads(teamId: String, userId: String = MattermostClient.currentUser, options: UserThreadsOptions = UserThreadsOptions()) async throws -> ThreadList {
        var query = QueryBuilder()
        query.add("since", options.since)
        query.add("before", options.before)
        query.add("after", options.after)
        query.add("per_page", options.perPage)
        query.addFlag("extended", options.extended)
        query.addFlag("deleted", options.includeDeleted)
        query.addFlag("unread", options.unreadOnly)
        query.addFlag("totalsOnly", options.totalsOnly)
        query.addFlag("threadsOnly", options.threadsOnly)
        return try await send(APIRequest(.get, apiPath("users", userId, "teams", teamId, "threads"), query: query.items))
    }

    /// `GET /users/{user_id}/teams/{team_id}/threads/{thread_id}`: one followed thread (e.g. after
    /// `thread_follow_changed`).
    public func userThread(teamId: String, threadId: String, extended: Bool = false, userId: String = MattermostClient.currentUser) async throws -> UserThread {
        var query = QueryBuilder()
        query.addFlag("extended", extended)
        return try await send(APIRequest(.get, apiPath("users", userId, "teams", teamId, "threads", threadId), query: query.items))
    }

    /// `PUT /users/{user_id}/teams/{team_id}/threads/{thread_id}/read/{timestamp}`.
    /// - Parameter timestamp: The new `last_viewed_at` (ms).
    public func markThreadRead(teamId: String, threadId: String, timestamp: Int64, userId: String = MattermostClient.currentUser) async throws {
        try await sendIgnoringResponse(APIRequest(.put, apiPath("users", userId, "teams", teamId, "threads", threadId, "read", String(timestamp))))
    }

    /// `PUT /users/{user_id}/teams/{team_id}/threads/{thread_id}/following`.
    public func followThread(teamId: String, threadId: String, userId: String = MattermostClient.currentUser) async throws {
        try await sendIgnoringResponse(APIRequest(.put, apiPath("users", userId, "teams", teamId, "threads", threadId, "following")))
    }

    /// `DELETE /users/{user_id}/teams/{team_id}/threads/{thread_id}/following`.
    public func unfollowThread(teamId: String, threadId: String, userId: String = MattermostClient.currentUser) async throws {
        try await sendIgnoringResponse(APIRequest(.delete, apiPath("users", userId, "teams", teamId, "threads", threadId, "following")))
    }
}

// MARK: - Reactions

extension MattermostClient {
    /// `POST /reactions`. The body needs the real user ID; `"me"` is not
    /// accepted there.
    @discardableResult
    public func addReaction(userId: String, postId: String, emojiName: String) async throws -> Reaction {
        try await send(APIRequest.json(.post, "/reactions", body: Reaction(userId: userId, postId: postId, emojiName: emojiName)))
    }

    /// `DELETE /users/{user_id}/posts/{post_id}/reactions/{emoji_name}`.
    public func removeReaction(postId: String, emojiName: String, userId: String = MattermostClient.currentUser) async throws {
        try await sendIgnoringResponse(APIRequest(.delete, apiPath("users", userId, "posts", postId, "reactions", emojiName)))
    }
}
