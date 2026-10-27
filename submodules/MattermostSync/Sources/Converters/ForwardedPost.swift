import Foundation
import MattermostKit
import MattermostSyncCore

/// 4H: Mattermost's forwards (the web app's Forward, 11.7): a post whose message is only the permalink of another
/// post, which the server previews with a `permalink` embed carrying that post (`PermalinkForward`). Relay shows such
/// a post as Telegram shows a forwarded message: "Forwarded from <author>" (the forwarded post's author and date),
/// with the forwarded post's text, files and attachments; the forward's own reactions, replies, pin and thread stay
/// the forward's. A forward with a comment keeps 3E's rendering (the comment and the permalink card under it): one
/// Telegram message can't carry both. Without the embed (the viewer can't read the forwarded post's channel, the
/// post was deleted, permalink previews are off, or the post came from `POST /posts/ids`, which has no embeds) the
/// post is the link it is.
enum ForwardedPost {
    struct Original {
        var post: Post
        var preview: PermalinkPreview
    }

    /// The forwarded post of a plain forward (no comment, no files of its own), or nil.
    static func original(of post: Post) -> Original? {
        guard post.type.isEmpty, post.fileIds.isEmpty, post.message.contains("/pl/"), let embeds = post.metadata?.embeds, !embeds.isEmpty else {
            return nil
        }
        guard let parsed = PermalinkForward.parse(post.message), parsed.comment.isEmpty else {
            return nil
        }
        for embed in embeds where embed.type == "permalink" {
            guard let preview = embed.permalink, preview.postId == parsed.postId, let original = preview.post, original.deleteAt == 0, !original.type.hasPrefix("system_") else {
                continue
            }
            return Original(post: original, preview: preview)
        }
        return nil
    }

    /// What a post shows: the forwarded post for a plain forward, else the post itself. Its message, files, props
    /// and emoji are what the messages carry (`PostLayout`, `PostConverter`).
    static func content(of post: Post) -> Post {
        return self.original(of: post)?.post ?? post
    }

    /// A plain forward whose embed `POST /posts/ids` left out (it never has embeds): the post should be fetched on
    /// its own (`GET /posts/{id}`) before it is written, or it would lose its forwarded content.
    static func lacksPreview(_ post: Post) -> Bool {
        guard post.type.isEmpty, post.fileIds.isEmpty, post.deleteAt == 0, post.message.contains("/pl/"), let parsed = PermalinkForward.parse(post.message), parsed.comment.isEmpty else {
            return false
        }
        return !(post.metadata?.embeds ?? []).contains(where: { $0.type == "permalink" })
    }
}
