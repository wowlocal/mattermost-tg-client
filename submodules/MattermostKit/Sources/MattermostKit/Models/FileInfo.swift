import Foundation

public struct FileInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var userId: String
    /// Empty until the file is attached to a post.
    public var postId: String
    public var channelId: String
    public var createAt: Int64
    public var updateAt: Int64
    public var deleteAt: Int64
    public var name: String
    public var `extension`: String
    public var size: Int64
    public var mimeType: String
    public var width: Int
    public var height: Int
    public var hasPreviewImage: Bool
    /// Tiny JPEG thumbnail (base64 in JSON), sent for images by newer servers.
    public var miniPreview: Data?
    public var remoteId: String?
    /// True when the file content was removed by a data retention policy.
    public var archived: Bool

    public init(
        id: String,
        userId: String = "",
        postId: String = "",
        channelId: String = "",
        createAt: Int64 = 0,
        updateAt: Int64 = 0,
        deleteAt: Int64 = 0,
        name: String = "",
        extension: String = "",
        size: Int64 = 0,
        mimeType: String = "",
        width: Int = 0,
        height: Int = 0,
        hasPreviewImage: Bool = false,
        miniPreview: Data? = nil,
        remoteId: String? = nil,
        archived: Bool = false
    ) {
        self.id = id
        self.userId = userId
        self.postId = postId
        self.channelId = channelId
        self.createAt = createAt
        self.updateAt = updateAt
        self.deleteAt = deleteAt
        self.name = name
        self.extension = `extension`
        self.size = size
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.hasPreviewImage = hasPreviewImage
        self.miniPreview = miniPreview
        self.remoteId = remoteId
        self.archived = archived
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case postId = "post_id"
        case channelId = "channel_id"
        case createAt = "create_at"
        case updateAt = "update_at"
        case deleteAt = "delete_at"
        case name
        case `extension`
        case size
        case mimeType = "mime_type"
        case width
        case height
        case hasPreviewImage = "has_preview_image"
        case miniPreview = "mini_preview"
        case remoteId = "remote_id"
        case archived
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = c.string(.userId)
        postId = c.string(.postId)
        channelId = c.string(.channelId)
        createAt = c.int64(.createAt)
        updateAt = c.int64(.updateAt)
        deleteAt = c.int64(.deleteAt)
        name = c.string(.name)
        self.extension = c.string(.extension)
        size = c.int64(.size)
        mimeType = c.string(.mimeType)
        width = c.int(.width)
        height = c.int(.height)
        hasPreviewImage = c.bool(.hasPreviewImage)
        miniPreview = c.optionalString(.miniPreview).flatMap { Data(base64Encoded: $0) }
        remoteId = c.optionalString(.remoteId)
        archived = c.bool(.archived)
    }
}

extension FileInfo {
    public var isImage: Bool { mimeType.hasPrefix("image/") }
    public var isVideo: Bool { mimeType.hasPrefix("video/") }
    public var isAudio: Bool { mimeType.hasPrefix("audio/") }
}

/// Response of `POST /files`.
public struct FileUploadResponse: Codable, Sendable, Equatable {
    public var fileInfos: [FileInfo]
    /// Echoes the `client_ids` sent with the upload, in the same order.
    public var clientIds: [String]

    public init(fileInfos: [FileInfo] = [], clientIds: [String] = []) {
        self.fileInfos = fileInfos
        self.clientIds = clientIds
    }

    enum CodingKeys: String, CodingKey {
        case fileInfos = "file_infos"
        case clientIds = "client_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileInfos = c.array(FileInfo.self, .fileInfos)
        clientIds = c.array(String.self, .clientIds)
    }

    /// File info for a client ID, when the server echoed client IDs.
    public func fileInfo(forClientId clientId: String) -> FileInfo? {
        guard let index = clientIds.firstIndex(of: clientId), fileInfos.indices.contains(index) else { return nil }
        return fileInfos[index]
    }
}
