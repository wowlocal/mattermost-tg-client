import Foundation

// MARK: - Sessions

extension MattermostClient {
    /// `GET /users/{user_id}/sessions`: the user's login sessions (tokens omitted).
    public func sessions(userId: String = MattermostClient.currentUser) async throws -> [Session] {
        try await send(APIRequest(.get, apiPath("users", userId, "sessions")))
    }

    /// `POST /users/{user_id}/sessions/revoke`: ends one session (logs that device out).
    public func revokeSession(id sessionId: String, userId: String = MattermostClient.currentUser) async throws {
        try await sendIgnoringResponse(APIRequest.json(.post, apiPath("users", userId, "sessions", "revoke"), body: ["session_id": sessionId]))
    }
}

// MARK: - File search

extension MattermostClient {
    /// `POST /files/search` (all of the user's teams, DMs and GMs included). Supports the modifiers of the
    /// web app's file search: `in:<channel name or id>`, `from:`, `ext:`, `before:`/`after:`/`on:`.
    ///
    /// On 11.7 the server returns up to 100 files per page, newest first; `page` pages on, `per_page` is
    /// ignored. An empty page means there are no more results.
    public func searchFiles(_ options: FileSearchOptions) async throws -> FileInfoList {
        try await send(APIRequest.json(.post, "/files/search", body: options))
    }

    /// `POST /posts/ids`: posts by id, in no particular order (unknown or inaccessible ids are left out).
    public func posts(ids: [String]) async throws -> [Post] {
        try await send(APIRequest.json(.post, "/posts/ids", body: ids))
    }
}

public struct FileSearchOptions: Codable, Sendable, Equatable {
    public var terms: String
    public var isOrSearch: Bool
    /// Seconds east of UTC, used for the date modifiers.
    public var timeZoneOffset: Int
    public var includeDeletedChannels: Bool
    public var page: Int
    public var perPage: Int

    public init(
        terms: String,
        isOrSearch: Bool = false,
        timeZoneOffset: Int = TimeZone.current.secondsFromGMT(),
        includeDeletedChannels: Bool = false,
        page: Int = 0,
        perPage: Int = 100
    ) {
        self.terms = terms
        self.isOrSearch = isOrSearch
        self.timeZoneOffset = timeZoneOffset
        self.includeDeletedChannels = includeDeletedChannels
        self.page = page
        self.perPage = perPage
    }

    /// Every file of one channel (`in:<channel id>`; the server also accepts ids there).
    public static func channel(_ channelId: String, page: Int = 0) -> FileSearchOptions {
        return FileSearchOptions(terms: "in:\(channelId)", page: page)
    }

    enum CodingKeys: String, CodingKey {
        case terms
        case isOrSearch = "is_or_search"
        case timeZoneOffset = "time_zone_offset"
        case includeDeletedChannels = "include_deleted_channels"
        case page
        case perPage = "per_page"
    }
}

/// Response of the file search endpoints.
public struct FileInfoList: Codable, Sendable, Equatable {
    /// File ids, newest first.
    public var order: [String]
    public var fileInfos: [String: FileInfo]

    public init(order: [String] = [], fileInfos: [String: FileInfo] = [:]) {
        self.order = order
        self.fileInfos = fileInfos
    }

    /// The files in `order`.
    public var orderedFiles: [FileInfo] {
        return order.compactMap { fileInfos[$0] }
    }

    enum CodingKeys: String, CodingKey {
        case order
        case fileInfos = "file_infos"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = c.array(String.self, .order)
        fileInfos = c.dictionary(FileInfo.self, .fileInfos)
    }
}
