import Foundation

/// Which composer texts run as Mattermost slash commands (`POST /commands/execute`) instead of being posted.
///
/// As in Mattermost's own clients, a message whose first character is `/` is a command, with these
/// exceptions, which are posted as text:
/// - `//…` (the escape for a message that starts with a slash);
/// - a first word with another `/` in it: a path such as `/usr/bin/env` or `/path/to/file`;
/// - a lone `/` or a slash followed by whitespace.
/// A command the server doesn't know (`api.command.execute_command.not_found.app_error`) can still be posted
/// as text when the user confirms.
public enum SlashCommand {
    public struct Parsed: Equatable {
        /// The trigger without the slash, lowercased (`away` for `/Away`).
        public var trigger: String
        /// The text after the trigger, without leading whitespace.
        public var arguments: String
    }

    public static func parse(_ text: String) -> Parsed? {
        guard text.hasPrefix("/"), !text.hasPrefix("//") else {
            return nil
        }
        let body = text.dropFirst()
        let firstWord = body.prefix(while: { !$0.isWhitespace })
        if firstWord.isEmpty || firstWord.contains("/") {
            return nil
        }
        let rest = body.dropFirst(firstWord.count).drop(while: { $0.isWhitespace })
        return Parsed(trigger: firstWord.lowercased(), arguments: String(rest))
    }

    /// The server's error id for an unknown trigger.
    public static let notFoundErrorId = "api.command.execute_command.not_found.app_error"
}
