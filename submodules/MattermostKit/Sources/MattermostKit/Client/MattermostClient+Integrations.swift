import Foundation

// MARK: - Emoji

extension MattermostClient {
    /// `GET /emoji`: custom emoji, paged.
    /// - Parameter sort: `"name"` or nil (creation order).
    public func customEmojis(page: Int? = nil, perPage: Int? = nil, sort: String? = nil) async throws -> [CustomEmoji] {
        var query = QueryBuilder()
        query.add("page", page)
        query.add("per_page", perPage)
        query.add("sort", sort)
        return try await send(APIRequest(.get, "/emoji", query: query.items))
    }

    /// `GET /emoji/name/{emoji_name}`.
    public func customEmoji(name: String) async throws -> CustomEmoji {
        try await send(APIRequest(.get, apiPath("emoji", "name", name)))
    }
}

// MARK: - Slash commands and interactive messages

extension MattermostClient {
    /// `GET /teams/{team_id}/commands/autocomplete_suggestions`.
    /// - Parameter userInput: The text typed so far, including the leading `/`.
    public func commandAutocompleteSuggestions(teamId: String, userInput: String, channelId: String, rootId: String? = nil) async throws -> [AutocompleteSuggestion] {
        var query = QueryBuilder()
        query.add("user_input", userInput)
        query.add("channel_id", channelId)
        query.add("root_id", rootId)
        return try await send(APIRequest(.get, apiPath("teams", teamId, "commands", "autocomplete_suggestions"), query: query.items))
    }

    private struct ExecuteCommandBody: Encodable {
        var command: String
        var channelId: String
        var teamId: String?
        var rootId: String?
        var parentId: String?

        enum CodingKeys: String, CodingKey {
            case command
            case channelId = "channel_id"
            case teamId = "team_id"
            case rootId = "root_id"
            case parentId = "parent_id"
        }
    }

    /// `POST /commands/execute`.
    /// - Parameter command: The full command line, e.g. `"/echo hi"`.
    public func executeCommand(_ command: String, channelId: String, teamId: String? = nil, rootId: String? = nil) async throws -> CommandResponse {
        let body = ExecuteCommandBody(command: command, channelId: channelId, teamId: teamId, rootId: rootId, parentId: rootId)
        return try await send(APIRequest.json(.post, "/commands/execute", body: body))
    }

    private struct PostActionBody: Encodable {
        var selectedOption: String?
        var cookie: String?

        enum CodingKeys: String, CodingKey {
            case selectedOption = "selected_option"
            case cookie
        }
    }

    /// `POST /posts/{post_id}/actions/{action_id}`: a message-attachment button
    /// or menu.
    public func performPostAction(postId: String, actionId: String, selectedOption: String? = nil, cookie: String? = nil) async throws -> PostActionResponse {
        let body = PostActionBody(selectedOption: selectedOption, cookie: cookie)
        return try await send(APIRequest.json(.post, apiPath("posts", postId, "actions", actionId), body: body))
    }

    /// `POST /actions/dialogs/submit`.
    public func submitDialog(_ submission: DialogSubmission) async throws -> DialogSubmissionResponse {
        let (data, _) = try await perform(APIRequest.json(.post, "/actions/dialogs/submit", body: submission))
        if data.isEmpty {
            return DialogSubmissionResponse()
        }
        return try decode(DialogSubmissionResponse.self, from: data)
    }
}

// MARK: - Push and misc

extension MattermostClient {
    /// `POST /notifications/ack`. For ID-only pushes (`isIdLoaded`), the server
    /// returns the notification content; otherwise usually `{"status":"OK"}`.
    /// The response shape is returned raw because it differs by push type and
    /// server version.
    @discardableResult
    public func acknowledgeNotification(_ ack: PushNotificationAck) async throws -> JSONValue {
        let (data, _) = try await perform(APIRequest.json(.post, "/notifications/ack", body: ack))
        if data.isEmpty {
            return .null
        }
        return try decode(JSONValue.self, from: data)
    }

    /// `POST /opengraph`: link preview for a URL.
    public func openGraph(url: String) async throws -> OpenGraph {
        try await send(APIRequest.json(.post, "/opengraph", body: ["url": url]))
    }
}
