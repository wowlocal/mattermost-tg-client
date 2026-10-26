import Foundation

// MARK: - Teams

extension MattermostClient {
    /// `GET /users/{user_id}/teams`.
    public func teams(userId: String = MattermostClient.currentUser) async throws -> [Team] {
        try await send(APIRequest(.get, apiPath("users", userId, "teams")))
    }

    /// `GET /users/{user_id}/teams/members`.
    public func teamMembers(userId: String = MattermostClient.currentUser) async throws -> [TeamMember] {
        try await send(APIRequest(.get, apiPath("users", userId, "teams", "members")))
    }

    /// `GET /users/{user_id}/teams/unread`.
    public func teamsUnread(userId: String = MattermostClient.currentUser, excludeTeamId: String? = nil, includeCollapsedThreads: Bool = false) async throws -> [TeamUnread] {
        var query = QueryBuilder()
        query.add("exclude_team", excludeTeamId)
        query.addFlag("include_collapsed_threads", includeCollapsedThreads)
        return try await send(APIRequest(.get, apiPath("users", userId, "teams", "unread"), query: query.items))
    }

    /// `GET /teams/{team_id}`.
    public func team(id: String) async throws -> Team {
        try await send(APIRequest(.get, apiPath("teams", id)))
    }
}

// MARK: - Channels

extension MattermostClient {
    /// `GET /users/{user_id}/teams/{team_id}/channels`: the user's channels in a
    /// team, including DMs and GMs.
    /// - Parameter lastDeleteAt: With `includeDeleted`, only archived channels
    ///   deleted after this time (ms).
    public func channels(teamId: String, userId: String = MattermostClient.currentUser, includeDeleted: Bool = false, lastDeleteAt: Int64? = nil) async throws -> [Channel] {
        var query = QueryBuilder()
        query.addFlag("include_deleted", includeDeleted)
        query.add("last_delete_at", lastDeleteAt)
        return try await send(APIRequest(.get, apiPath("users", userId, "teams", teamId, "channels"), query: query.items))
    }

    /// `GET /users/{user_id}/teams/{team_id}/channels/members`: read state and
    /// notify props for all of the user's channels in a team.
    public func channelMembers(teamId: String, userId: String = MattermostClient.currentUser) async throws -> [ChannelMember] {
        try await send(APIRequest(.get, apiPath("users", userId, "teams", teamId, "channels", "members")))
    }

    /// `GET /users/{user_id}/teams/{team_id}/channels/categories`.
    public func sidebarCategories(teamId: String, userId: String = MattermostClient.currentUser) async throws -> OrderedSidebarCategories {
        try await send(APIRequest(.get, apiPath("users", userId, "teams", teamId, "channels", "categories")))
    }

    /// `GET /channels/{channel_id}`.
    public func channel(id: String) async throws -> Channel {
        try await send(APIRequest(.get, apiPath("channels", id)))
    }

    /// `GET /channels/{channel_id}/members/{user_id}`.
    public func channelMember(channelId: String, userId: String = MattermostClient.currentUser) async throws -> ChannelMember {
        try await send(APIRequest(.get, apiPath("channels", channelId, "members", userId)))
    }

    /// `GET /channels/{channel_id}/members`: a page of the channel's members (ordered by the server).
    public func channelMembers(channelId: String, page: Int, perPage: Int) async throws -> [ChannelMember] {
        var query = QueryBuilder()
        query.add("page", page)
        query.add("per_page", perPage)
        return try await send(APIRequest(.get, apiPath("channels", channelId, "members"), query: query.items))
    }

    /// `POST /channels/{channel_id}/members/ids`: the memberships of the given users (non-members are left out).
    public func channelMembers(channelId: String, userIds: [String]) async throws -> [ChannelMember] {
        try await send(APIRequest.json(.post, apiPath("channels", channelId, "members", "ids"), body: userIds))
    }

    /// `GET /teams/{team_id}/channels/autocomplete`: channels of a team matching `name` (public channels and
    /// the user's private channels; the server matches words of the name and display name).
    public func autocompleteChannels(teamId: String, name: String) async throws -> [Channel] {
        var query = QueryBuilder()
        query.add("name", name)
        return try await send(APIRequest(.get, apiPath("teams", teamId, "channels", "autocomplete"), query: query.items))
    }

    /// `GET /channels/{channel_id}/stats`: member count and other counters.
    public func channelStats(channelId: String) async throws -> ChannelStats {
        try await send(APIRequest(.get, apiPath("channels", channelId, "stats")))
    }

    /// `GET /teams/{team_id}/channels`: public channels in a team (browse).
    public func publicChannels(teamId: String, page: Int? = nil, perPage: Int? = nil) async throws -> [Channel] {
        var query = QueryBuilder()
        query.add("page", page)
        query.add("per_page", perPage)
        return try await send(APIRequest(.get, apiPath("teams", teamId, "channels"), query: query.items))
    }

    private struct ViewChannelBody: Encodable {
        var channelId: String
        var prevChannelId: String
        var collapsedThreadsSupported: Bool

        enum CodingKeys: String, CodingKey {
            case channelId = "channel_id"
            case prevChannelId = "prev_channel_id"
            case collapsedThreadsSupported = "collapsed_threads_supported"
        }
    }

    /// `POST /channels/members/{user_id}/view`: marks a channel as read.
    @discardableResult
    public func viewChannel(channelId: String, previousChannelId: String = "", collapsedThreadsSupported: Bool = true, userId: String = MattermostClient.currentUser) async throws -> ChannelViewResponse {
        let body = ViewChannelBody(channelId: channelId, prevChannelId: previousChannelId, collapsedThreadsSupported: collapsedThreadsSupported)
        return try await send(APIRequest.json(.post, apiPath("channels", "members", userId, "view"), body: body))
    }

    /// `POST /channels`.
    public func createChannel(_ draft: ChannelDraft) async throws -> Channel {
        try await send(APIRequest.json(.post, "/channels", body: draft))
    }

    /// `POST /channels/direct`. Pass the same ID twice for a self-DM. Returns
    /// the existing channel if the DM already exists.
    public func createDirectChannel(userId: String, otherUserId: String) async throws -> Channel {
        try await send(APIRequest.json(.post, "/channels/direct", body: [userId, otherUserId]))
    }

    /// `POST /channels/group`. Include the current user's ID.
    public func createGroupChannel(userIds: [String]) async throws -> Channel {
        try await send(APIRequest.json(.post, "/channels/group", body: userIds))
    }

    private struct AddMemberBody: Encodable {
        var userId: String
        var postRootId: String?

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case postRootId = "post_root_id"
        }
    }

    /// `POST /channels/{channel_id}/members`: joins a channel (pass your own ID)
    /// or adds another user.
    @discardableResult
    public func addChannelMember(channelId: String, userId: String, postRootId: String? = nil) async throws -> ChannelMember {
        try await send(APIRequest.json(.post, apiPath("channels", channelId, "members"), body: AddMemberBody(userId: userId, postRootId: postRootId)))
    }

    /// `DELETE /channels/{channel_id}/members/{user_id}`: leaves a channel or
    /// removes a user.
    public func removeChannelMember(channelId: String, userId: String = MattermostClient.currentUser) async throws {
        try await sendIgnoringResponse(APIRequest(.delete, apiPath("channels", channelId, "members", userId)))
    }

    /// `PUT /channels/{channel_id}/members/{user_id}/notify_props`: merges the
    /// given props into the member's notify props (keys not listed are kept).
    /// Muting is `mark_unread: "mention"`, unmuting `mark_unread: "all"`.
    public func updateChannelNotifyProps(channelId: String, props: [String: String], userId: String = MattermostClient.currentUser) async throws {
        try await sendIgnoringResponse(APIRequest.json(.put, apiPath("channels", channelId, "members", userId, "notify_props"), body: props))
    }
}

// MARK: - Directory and channel management (Phase 3D-2)

extension MattermostClient {
    private struct TermBody: Encodable {
        var term: String
    }

    /// `POST /teams/{team_id}/channels/search`: public channels of a team whose name or display name matches
    /// `term` (members and non-members; archived channels are left out).
    public func searchChannels(teamId: String, term: String) async throws -> [Channel] {
        try await send(APIRequest.json(.post, apiPath("teams", teamId, "channels", "search"), body: TermBody(term: term)))
    }

    /// `POST /teams/{team_id}/channels/search_archived`: archived channels of a team matching `term` (the
    /// public ones and the private ones the user is a member of).
    public func searchArchivedChannels(teamId: String, term: String) async throws -> [Channel] {
        try await send(APIRequest.json(.post, apiPath("teams", teamId, "channels", "search_archived"), body: TermBody(term: term)))
    }

    /// `GET /teams/{team_id}/channels/deleted`: archived public channels of a team (and the private ones the
    /// user is a member of).
    public func archivedChannels(teamId: String, page: Int? = nil, perPage: Int? = nil) async throws -> [Channel] {
        var query = QueryBuilder()
        query.add("page", page)
        query.add("per_page", perPage)
        return try await send(APIRequest(.get, apiPath("teams", teamId, "channels", "deleted"), query: query.items))
    }

    /// `GET /teams/{team_id}/channels/name/{channel_name}`: a channel by its URL name.
    public func channel(teamId: String, name: String, includeDeleted: Bool = false) async throws -> Channel {
        var query = QueryBuilder()
        query.addFlag("include_deleted", includeDeleted)
        return try await send(APIRequest(.get, apiPath("teams", teamId, "channels", "name", name), query: query.items))
    }

    /// `POST /channels/stats/member_count`: member counts of several channels (also for channels the user is
    /// not a member of), keyed by channel id.
    public func channelMemberCounts(channelIds: [String]) async throws -> [String: Int64] {
        try await send(APIRequest.json(.post, "/channels/stats/member_count", body: channelIds))
    }

    /// `PUT /channels/{channel_id}/patch`: changes the given fields (nil fields are kept).
    @discardableResult
    public func patchChannel(id: String, patch: ChannelPatch) async throws -> Channel {
        try await send(APIRequest.json(.put, apiPath("channels", id, "patch"), body: patch))
    }

    /// `DELETE /channels/{channel_id}`: archives a channel (members keep it, read-only).
    public func archiveChannel(id: String) async throws {
        try await sendIgnoringResponse(APIRequest(.delete, apiPath("channels", id)))
    }

    /// `POST /channels/{channel_id}/restore`: unarchives a channel.
    @discardableResult
    public func restoreChannel(id: String) async throws -> Channel {
        try await send(APIRequest(.post, apiPath("channels", id, "restore")))
    }

    private struct PrivacyBody: Encodable {
        var privacy: String
    }

    /// `PUT /channels/{channel_id}/privacy`: converts a channel to private (`.privateChannel`) or public.
    @discardableResult
    public func updateChannelPrivacy(id: String, type: ChannelType) async throws -> Channel {
        try await send(APIRequest.json(.put, apiPath("channels", id, "privacy"), body: PrivacyBody(privacy: type.rawValue)))
    }

    private struct SchemeRolesBody: Encodable {
        var schemeAdmin: Bool
        var schemeUser: Bool

        enum CodingKeys: String, CodingKey {
            case schemeAdmin = "scheme_admin"
            case schemeUser = "scheme_user"
        }
    }

    /// `PUT /channels/{channel_id}/members/{user_id}/schemeRoles`: makes a member a channel admin or a plain
    /// member.
    public func updateChannelMemberSchemeRoles(channelId: String, userId: String, isAdmin: Bool) async throws {
        try await sendIgnoringResponse(APIRequest.json(.put, apiPath("channels", channelId, "members", userId, "schemeRoles"), body: SchemeRolesBody(schemeAdmin: isAdmin, schemeUser: true)))
    }
}

// MARK: - Sidebar categories

extension MattermostClient {
    /// `PUT /users/{user_id}/teams/{team_id}/channels/categories`: updates
    /// several categories at once. A channel added to one category is removed
    /// from its previous one; channels removed from Favorites go back to their
    /// default category. Returns the updated categories.
    @discardableResult
    public func updateSidebarCategories(_ categories: [SidebarCategory], teamId: String, userId: String = MattermostClient.currentUser) async throws -> [SidebarCategory] {
        try await send(APIRequest.json(.put, apiPath("users", userId, "teams", teamId, "channels", "categories"), body: categories))
    }
}
