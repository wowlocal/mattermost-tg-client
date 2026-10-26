import Foundation

public struct Reaction: Codable, Sendable, Equatable, Hashable {
    public var userId: String
    public var postId: String
    /// Emoji name without colons, e.g. `"+1"`, `"smile"`, or a custom emoji name.
    public var emojiName: String
    public var createAt: Int64
    public var updateAt: Int64
    public var deleteAt: Int64
    public var remoteId: String?
    public var channelId: String?

    public init(
        userId: String,
        postId: String,
        emojiName: String,
        createAt: Int64 = 0,
        updateAt: Int64 = 0,
        deleteAt: Int64 = 0,
        remoteId: String? = nil,
        channelId: String? = nil
    ) {
        self.userId = userId
        self.postId = postId
        self.emojiName = emojiName
        self.createAt = createAt
        self.updateAt = updateAt
        self.deleteAt = deleteAt
        self.remoteId = remoteId
        self.channelId = channelId
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case postId = "post_id"
        case emojiName = "emoji_name"
        case createAt = "create_at"
        case updateAt = "update_at"
        case deleteAt = "delete_at"
        case remoteId = "remote_id"
        case channelId = "channel_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = c.string(.userId)
        postId = c.string(.postId)
        emojiName = c.string(.emojiName)
        createAt = c.int64(.createAt)
        updateAt = c.int64(.updateAt)
        deleteAt = c.int64(.deleteAt)
        remoteId = c.optionalString(.remoteId)
        channelId = c.optionalString(.channelId)
    }
}

public struct CustomEmoji: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var creatorId: String
    public var name: String
    public var createAt: Int64
    public var updateAt: Int64
    public var deleteAt: Int64

    public init(id: String, creatorId: String = "", name: String = "", createAt: Int64 = 0, updateAt: Int64 = 0, deleteAt: Int64 = 0) {
        self.id = id
        self.creatorId = creatorId
        self.name = name
        self.createAt = createAt
        self.updateAt = updateAt
        self.deleteAt = deleteAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case creatorId = "creator_id"
        case name
        case createAt = "create_at"
        case updateAt = "update_at"
        case deleteAt = "delete_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        creatorId = c.string(.creatorId)
        name = c.string(.name)
        createAt = c.int64(.createAt)
        updateAt = c.int64(.updateAt)
        deleteAt = c.int64(.deleteAt)
    }
}
