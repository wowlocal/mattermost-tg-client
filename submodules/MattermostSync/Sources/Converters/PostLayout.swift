import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// How a post is split into messages (design: multi-file posts as grouped messages).
///
/// Telegram shows several photos as an album and several files as a file group: one message per item,
/// sharing a `groupingKey`. A Mattermost post with N files therefore becomes N messages, one per file, which
/// need N local ids: the post's own id-map entry (part 0, the primary message) and N-1 parts
/// (`PostParts`). Images come first (one album), then the other files (one file group), each in the
/// post's order; Telegram can't mix photos and files in one group, so a post with both shows two bubbles.
///
/// - The text goes on the last file (Telegram shows a file group's text under its file) or, without other
///   files, on the first image (an album's caption).
/// - Reactions, the reply count, the pinned flag and buttons go on the primary message, which Telegram
///   reads them from for the whole group (`ChatMessageBubbleItemNode` uses the group's first message).
/// - Every part carries the thread and reply references, so the whole group shows in its thread.
struct PostLayout: Equatable {
    struct Part: Equatable {
        /// Nil for the single message of a post without files.
        var file: FileInfo?
        var isAlbumImage: Bool
        var groupingKey: Int64?
    }

    var parts: [Part]
    var textPartIndex: Int

    var count: Int {
        return self.parts.count
    }

    init(post: Post) {
        if post.type.hasPrefix("system_") {
            self.parts = [Part(file: nil, isAlbumImage: false, groupingKey: nil)]
            self.textPartIndex = 0
            return
        }
        let files = (post.metadata?.files ?? []).filter { $0.deleteAt == 0 }
        let images = files.filter { MediaConverter.isAlbumImage($0) }
        let others = files.filter { !MediaConverter.isAlbumImage($0) }
        if images.count + others.count <= 1 {
            self.parts = [Part(file: files.first, isAlbumImage: !images.isEmpty, groupingKey: nil)]
            self.textPartIndex = 0
            return
        }
        // Mattermost allows 10 files per post by default; the id map has room for 100 parts.
        let imageKey = images.count > 1 ? PostLayout.groupingKey(postId: post.id, group: "images") : nil
        let fileKey = others.count > 1 ? PostLayout.groupingKey(postId: post.id, group: "files") : nil
        var parts = images.map { Part(file: $0, isAlbumImage: true, groupingKey: imageKey) }
        parts += others.map { Part(file: $0, isAlbumImage: false, groupingKey: fileKey) }
        self.parts = Array(parts.prefix(PostParts.maximumCount))
        self.textPartIndex = others.isEmpty ? 0 : self.parts.count - 1
    }

    /// The number of messages (local ids) a post needs.
    static func partCount(_ post: Post) -> Int {
        return PostLayout(post: post).count
    }

    /// A stable, non-zero grouping key per post and group (FNV-1a).
    static func groupingKey(postId: String, group: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (postId + "/" + group).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let value = Int64(bitPattern: hash & 0x7fff_ffff_ffff_ffff)
        return value == 0 ? 1 : value
    }
}

/// The id-map keys of posts: each live post followed by its parts.
func postKeys(_ posts: [Post]) -> [PostOrderKey] {
    return posts.filter { $0.deleteAt == 0 }.flatMap { post in
        return PostOrderKey(createAt: post.createAt, postId: post.id).parts(count: PostLayout.partCount(post))
    }
}
