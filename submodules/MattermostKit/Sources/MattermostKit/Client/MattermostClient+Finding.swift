import Foundation

// MARK: - Finding things (Phase 3C): saved posts, pinning, team file search

extension MattermostClient {
    // Channel search: `searchChannels(teamId:term:)` (Phase 3D-2, `MattermostClient+Channels.swift`).

    /// `GET /users/{user_id}/posts/flagged`: the user's saved ("flagged") posts, newest first, in every team
    /// (`teamId` limits them to one team and its DMs/GMs, `channelId` to one channel). Only posts of channels
    /// the user is a member of.
    public func flaggedPosts(userId: String = MattermostClient.currentUser, teamId: String? = nil, channelId: String? = nil, page: Int? = nil, perPage: Int? = nil) async throws -> PostList {
        var query = QueryBuilder()
        query.add("team_id", teamId)
        query.add("channel_id", channelId)
        query.add("page", page)
        query.add("per_page", perPage)
        return try await send(APIRequest(.get, apiPath("users", userId, "posts", "flagged"), query: query.items))
    }

    /// `POST /posts/{post_id}/pin`. The server sends `post_edited` (with `is_pinned`) and `channel_updated`.
    public func pinPost(id: String) async throws {
        try await sendIgnoringResponse(APIRequest(.post, apiPath("posts", id, "pin")))
    }

    /// `POST /posts/{post_id}/unpin`.
    public func unpinPost(id: String) async throws {
        try await sendIgnoringResponse(APIRequest(.post, apiPath("posts", id, "unpin")))
    }

    /// `POST /teams/{team_id}/files/search`: file search limited to a team (and the user's DMs/GMs). Same
    /// modifiers and paging as `searchFiles(_:)`.
    public func searchFiles(teamId: String, options: FileSearchOptions) async throws -> FileInfoList {
        try await send(APIRequest.json(.post, apiPath("teams", teamId, "files", "search"), body: options))
    }

    /// Saves a post (`flagged_post` preference).
    public func savePost(id: String, userId: String) async throws {
        try await self.savePreferences([Preference.flaggedPost(userId: userId, postId: id)])
    }

    /// Removes a post from the saved posts.
    public func unsavePost(id: String, userId: String) async throws {
        try await self.deletePreferences([Preference.flaggedPost(userId: userId, postId: id)])
    }
}

extension Preference {
    /// The preference that marks `postId` as saved by `userId`.
    public static func flaggedPost(userId: String, postId: String) -> Preference {
        return Preference(userId: userId, category: PreferenceCategory.flaggedPost, name: postId, value: "true")
    }
}

extension PostSearchOptions {
    /// Every page of a search returns up to `perPage` posts (the database search backend ignores `perPage`, returns
    /// at most 100 posts on page 0 and nothing on later pages).
    public static let maxPerPage = 100
}
