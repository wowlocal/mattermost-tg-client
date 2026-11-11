import Foundation

public enum DirectMessageReadReceipt {
    public static func isCaughtUp(total: Int64, totalRoots: Int64, viewed: Int64, viewedRoots: Int64) -> Bool {
        return totalRoots > 0 && total >= totalRoots && viewed == total && viewedRoots == totalRoots
    }

    public static func isEligible(isDirect: Bool, rootId: String, type: String, silent: Bool, forceNotification: Bool) -> Bool {
        return isDirect && rootId.isEmpty && (type.isEmpty || type == "me") && (!silent || forceNotification)
    }
}

public struct DirectMessageReadCheckpoint: Codable, Equatable, Sendable {
    public var createAt: Int64
    public var postId: String

    public init(key: PostOrderKey) {
        self.createAt = key.createAt
        self.postId = key.postId
    }

    public var key: PostOrderKey { PostOrderKey(createAt: createAt, postId: postId) }
}
