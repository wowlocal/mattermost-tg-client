import Foundation

extension MattermostClient {
    /// The placeholder Mattermost accepts in paths in place of the current
    /// user's ID.
    public static let currentUser = "me"

    /// `GET /users/me`.
    public func me() async throws -> User {
        try await user(id: MattermostClient.currentUser)
    }

    /// `GET /users/{user_id}`.
    public func user(id: String) async throws -> User {
        try await send(APIRequest(.get, apiPath("users", id)))
    }

    /// `POST /users/ids`.
    /// - Parameter since: Only return users updated after this time (ms).
    public func users(ids: [String], since: Int64? = nil) async throws -> [User] {
        var query = QueryBuilder()
        query.add("since", since)
        return try await send(APIRequest.json(.post, "/users/ids", body: ids, query: query.items))
    }

    /// `POST /users/usernames`.
    public func users(usernames: [String]) async throws -> [User] {
        try await send(APIRequest.json(.post, "/users/usernames", body: usernames))
    }

    /// `POST /users/status/ids`.
    public func userStatuses(ids: [String]) async throws -> [UserStatus] {
        try await send(APIRequest.json(.post, "/users/status/ids", body: ids))
    }

    /// `GET /users/autocomplete`.
    public func autocompleteUsers(name: String, teamId: String? = nil, channelId: String? = nil, limit: Int? = nil) async throws -> UserAutocomplete {
        var query = QueryBuilder()
        query.add("in_team", teamId)
        query.add("in_channel", channelId)
        query.add("name", name)
        query.add("limit", limit)
        return try await send(APIRequest(.get, "/users/autocomplete", query: query.items))
    }

    /// `POST /users/search`.
    public func searchUsers(_ options: UserSearchOptions) async throws -> [User] {
        try await send(APIRequest.json(.post, "/users/search", body: options))
    }

    /// `POST /roles/names`: the roles with these names (unknown names are left out).
    public func roles(names: [String]) async throws -> [Role] {
        try await send(APIRequest.json(.post, "/roles/names", body: names))
    }

    // MARK: Preferences

    /// `GET /users/{user_id}/preferences`.
    public func preferences(userId: String = MattermostClient.currentUser) async throws -> [Preference] {
        try await send(APIRequest(.get, apiPath("users", userId, "preferences")))
    }

    /// `PUT /users/{user_id}/preferences` (favorites, saved posts, DM visibility).
    public func savePreferences(_ preferences: [Preference], userId: String = MattermostClient.currentUser) async throws {
        try await sendIgnoringResponse(APIRequest.json(.put, apiPath("users", userId, "preferences"), body: preferences))
    }

    /// `POST /users/{user_id}/preferences/delete`.
    public func deletePreferences(_ preferences: [Preference], userId: String = MattermostClient.currentUser) async throws {
        try await sendIgnoringResponse(APIRequest.json(.post, apiPath("users", userId, "preferences", "delete"), body: preferences))
    }
}
