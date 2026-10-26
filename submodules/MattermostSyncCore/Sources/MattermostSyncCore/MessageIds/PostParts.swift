import Foundation

/// A post shown as several messages: a post with N files becomes N messages (a Telegram album or file
/// group), so it needs N local ids. The first message is the post's own id-map entry ("part 0", the
/// primary message); parts 1…N-1 are entries keyed by synthetic part ids, `<post id>#01`, `<post id>#02`, ….
///
/// Part keys share the post's `create_at` and sort right after the post and before any other post: `#`
/// (0x23) sorts before every character of a Mattermost id (`[a-z0-9]`), so no other id can fall between a
/// post id and its part ids, and the two-digit suffix keeps the parts in index order. The allocator places
/// part entries like any other key, so a post and its parts always get consecutive local ids in key
/// order, and paging, islands and holes need no special cases. Only cursors (which name server posts) and
/// deletions (which remove a post with all its parts) know about parts.
public enum PostParts {
    /// The largest part count (Mattermost allows 10 files per post by default).
    public static let maximumCount = 100

    static let marker: Character = "#"
    /// Sorts after every part suffix of the same post (`$` is 0x24).
    static let upperSentinel = "$"

    /// The id-map id of part `index` of a post (`index` 0 is the post id itself).
    public static func partId(postId: String, index: Int) -> String {
        precondition(index >= 0 && index < maximumCount)
        if index == 0 {
            return postId
        }
        return postId + String(marker) + (index < 10 ? "0" : "") + String(index)
    }

    /// The server post id of an id-map id (the id itself for part 0).
    public static func postId(ofPartId id: String) -> String {
        guard let index = id.firstIndex(of: marker) else {
            return id
        }
        return String(id[id.startIndex ..< index])
    }

    /// The part index of an id-map id (0 for the post id itself).
    public static func index(ofPartId id: String) -> Int {
        guard let index = id.firstIndex(of: marker) else {
            return 0
        }
        return Int(id[id.index(after: index)...]) ?? 0
    }

    public static func isPartId(_ id: String) -> Bool {
        return id.contains(marker)
    }
}

extension PostOrderKey {
    /// The key of part `index` of this post (`self` must be a post key, not a part key).
    public func part(_ index: Int) -> PostOrderKey {
        return PostOrderKey(createAt: createAt, postId: PostParts.partId(postId: postId, index: index))
    }

    /// The post key followed by the keys of parts 1…count-1.
    public func parts(count: Int) -> [PostOrderKey] {
        return (0 ..< max(1, min(count, PostParts.maximumCount))).map { part($0) }
    }

    /// The server post this key belongs to.
    public var serverPostId: String {
        return PostParts.postId(ofPartId: postId)
    }

    public var partIndex: Int {
        return PostParts.index(ofPartId: postId)
    }

    /// The range covering this post and all of its parts.
    public var partsRange: ClosedRange<PostOrderKey> {
        let base = serverPostId
        return PostOrderKey(createAt: createAt, postId: base) ... PostOrderKey(createAt: createAt, postId: base + PostParts.upperSentinel)
    }
}

extension MessageIdEntry {
    /// The server post this entry belongs to (its own id unless it is a part).
    public var serverPostId: String {
        return key.serverPostId
    }

    public var partIndex: Int {
        return key.partIndex
    }
}
