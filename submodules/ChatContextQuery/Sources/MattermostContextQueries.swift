import Foundation
import TelegramCore

// MATTERMOST: the composer's autocomplete triggers on a Mattermost server, in place of Telegram's
// (`textInputStateContextQueryRangeAndType` returns these while `MattermostBackend.isEnabled`):
// - `@name`: users (`[.mention]`, the range after the `@`), at the start or after a non-word character;
// - `~name`: channels (`[.mention]` as well, the range after the `~`; `inputContextQueriesForChatPresentationIntefaceState`
//   tells them apart by the `~` and asks with `ChatInputQueryMentionTypes.mattermostChannels`);
// - `:name`: emoji (`[.emojiSearch]`, the range after the `:`), at the start or after whitespace;
// - `#tag`: Telegram's recently used hashtags (`[.hashtag]`);
// - `/…` at the very start of the text while the cursor is on the first line: a slash command, the whole line
//   up to the cursor (`[.command]`, so sub-commands and arguments get suggestions too), unless the first word
//   contains another `/` (a path such as `/usr/bin`) or the text starts with `//`.
// The word triggers win inside a command line (`/msg @bo` suggests users). Inline bots, sticker suggestions for
// a lone emoji and `/` after the start don't exist on Mattermost.
public extension ChatInputQueryMentionTypes {
    /// A `~channel` mention (Mattermost).
    static let mattermostChannels = ChatInputQueryMentionTypes(rawValue: 1 << 3)
}

private func mattermostIsWhitespace(_ c: unichar) -> Bool {
    return c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0xA0
}

private func mattermostIsWordCharacter(_ c: unichar) -> Bool {
    guard let scalar = UnicodeScalar(c) else {
        return true
    }
    return CharacterSet.alphanumerics.contains(scalar) || c == 0x5F // _
}

private func mattermostQueryIsValid(_ string: NSString, range: NSRange, allowed: (unichar) -> Bool) -> Bool {
    for index in range.location ..< range.location + range.length {
        if !allowed(string.character(at: index)) {
            return false
        }
    }
    return true
}

func mattermostContextQueryRangeAndType(inputText: NSAttributedString, selectionRange: Range<Int>) -> [(NSRange, PossibleContextQueryTypes, NSRange?)] {
    if selectionRange.count != 0 {
        return []
    }
    let string = inputText.string as NSString
    let cursor = min(max(0, selectionRange.lowerBound), string.length)
    if cursor == 0 {
        return []
    }

    // The word before the cursor and its trigger.
    var wordStart = cursor
    while wordStart > 0 && !mattermostIsWhitespace(string.character(at: wordStart - 1)) {
        wordStart -= 1
    }
    var index = cursor - 1
    while index >= wordStart {
        let c = string.character(at: index)
        let query = NSRange(location: index + 1, length: cursor - index - 1)
        let previous: unichar? = index > 0 ? string.character(at: index - 1) : nil
        if c == 0x40 || c == 0x7E { // @ ~
            if let previous, mattermostIsWordCharacter(previous) {
                break
            }
            // Usernames may contain `.` and `-`, channel names `-`.
            let isUser = c == 0x40
            let valid = mattermostQueryIsValid(string, range: query, allowed: { c in
                return mattermostIsWordCharacter(c) || c == 0x2D || (isUser && c == 0x2E)
            })
            if valid {
                return [(query, [.mention], nil)]
            }
            break
        } else if c == 0x3A { // :
            if index != wordStart {
                break
            }
            let valid = mattermostQueryIsValid(string, range: query, allowed: { c in
                return (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2B || c == 0x2D
            })
            if valid && query.length >= 2 {
                return [(query, [.emojiSearch], nil)]
            }
            break
        } else if c == 0x23 { // #
            if index != wordStart {
                break
            }
            if query.length > 0 && mattermostQueryIsValid(string, range: query, allowed: mattermostIsWordCharacter) {
                return [(query, [.hashtag], nil)]
            }
            break
        }
        index -= 1
    }

    // A slash command: the first line up to the cursor.
    if string.hasPrefix("/") && !string.hasPrefix("//") {
        let line = string.substring(to: cursor)
        if line.contains("\n") {
            return []
        }
        let firstWord = line.dropFirst().prefix(while: { $0 != " " && $0 != "\t" && $0 != "\u{00A0}" })
        if firstWord.contains("/") {
            return []
        }
        return [(NSRange(location: 1, length: cursor - 1), [.command], nil)]
    }
    return []
}
