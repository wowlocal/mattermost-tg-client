import Foundation

/// Mattermost's "Forward" (web app 11.7, `forwardPost`): a new post whose message is the permalink of the forwarded
/// post (`<site URL>/<team>/pl/<post id>`), after an optional comment and a newline; no files are copied. The server
/// adds a `permalink` embed with the forwarded post, which every client renders as a preview. Posts of private
/// channels, DMs and GMs can only be forwarded into their own channel (others couldn't see the preview).
public enum PermalinkForward {
    public struct Message: Equatable, Sendable {
        /// Text before the permalink (empty for a plain forward).
        public var comment: String
        public var url: String
        public var postId: String
    }

    /// The message of a forward of `postId` (`permalink` built by the caller), as the web app writes it.
    public static func message(permalink: String, comment: String = "") -> String {
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return comment.isEmpty ? permalink : comment + "\n" + permalink
    }

    /// Splits a post's message into its comment and the permalink it ends with; nil unless the last line is a
    /// permalink (`http(s)://…/<team>/pl/<26-character id>`, nothing after it).
    public static func parse(_ message: String) -> Message? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let lastLine: Substring
        let comment: String
        if let newline = trimmed.lastIndex(of: "\n") {
            lastLine = trimmed[trimmed.index(after: newline)...]
            comment = String(trimmed[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            lastLine = trimmed[...]
            comment = ""
        }
        let url = lastLine.trimmingCharacters(in: .whitespaces)
        let lowercased = url.lowercased()
        guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://"), !url.contains(" ") else {
            return nil
        }
        let parts = url.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 6, parts[parts.count - 2] == "pl" else {
            return nil
        }
        let postId = String(parts[parts.count - 1])
        guard postId.count == 26, postId.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }) else {
            return nil
        }
        return Message(comment: comment, url: url, postId: postId)
    }

    /// Whether a post of a channel of `sourceChannelType` (`O`, `P`, `D`, `G`) may be forwarded into another
    /// channel: only public channels' posts (the web app offers the post's own channel only for the others).
    public static func canForward(sourceChannelType: String, sourceChannelId: String, targetChannelId: String) -> Bool {
        return sourceChannelType == "O" || sourceChannelId == targetChannelId
    }
}
