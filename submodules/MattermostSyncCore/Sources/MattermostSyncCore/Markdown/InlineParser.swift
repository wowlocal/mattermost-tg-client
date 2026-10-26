import Foundation

/// Parses the inline content of one block (paragraph, heading, list item text, table cell).
///
/// Follows CommonMark's inline algorithm: code spans, autolinks and Mattermost tokens (bare URLs,
/// emails, `@mentions`, `~channels`, `#hashtags`, `:emoji:`, emoticons, `$inline latex$`) are atomic;
/// `*`, `_` and `~~` runs are paired with the delimiter-stack algorithm (including the `_` intraword and
/// "multiple of 3" rules); `[text](url)` links use the bracket stack.
struct InlineParser {
    private struct Node {
        var text: String = ""
        /// Entity covering `text` (atoms).
        var entity: TextEntityType?
        /// URL / email / mention / channel / hashtag entities, dropped inside link text.
        var isAutoEntity = false
        /// For delimiter runs: the run character and the number of characters left unmatched.
        var delimiterChar: Unicode.Scalar?
        var delimiterCount = 0
        /// Entities starting right after this node's text.
        var opens: [(id: Int, type: TextEntityType)] = []
        /// Entities ending right before this node's text.
        var closes: [Int] = []
    }

    private struct Delimiter {
        var nodeIndex: Int
        var char: Unicode.Scalar
        var originalCount: Int
        var canOpen: Bool
        var canClose: Bool
        var active = true
    }

    private struct Bracket {
        var nodeIndex: Int
        var delimiterBottom: Int
        var isImage: Bool
        var active = true
    }

    private struct OpenerKey: Hashable {
        var char: Unicode.Scalar
        var lengthModulo: Int
        var closerCanOpen: Bool
    }

    private let scalars: [Unicode.Scalar]
    private let options: MattermostMarkdown.Options
    private var position = 0
    private var nodes: [Node] = []
    private var delimiters: [Delimiter] = []
    private var brackets: [Bracket] = []
    private var pendingText = String.UnicodeScalarView()
    private var nextMarkerId = 0
    /// Start of the last backtick run of each length, so an unmatched opener fails in O(1).
    private let lastBacktickRunStart: [Int: Int]

    static func parse(_ text: String, options: MattermostMarkdown.Options = .default) -> FormattedText {
        var parser = InlineParser(scalars: Array(text.unicodeScalars), options: options)
        return parser.run()
    }

    private init(scalars: [Unicode.Scalar], options: MattermostMarkdown.Options) {
        self.scalars = scalars
        self.options = options
        var lastRuns: [Int: Int] = [:]
        var index = 0
        while index < scalars.count {
            if scalars[index] == "`" {
                let start = index
                while index < scalars.count && scalars[index] == "`" {
                    index += 1
                }
                lastRuns[index - start] = start
            } else {
                index += 1
            }
        }
        self.lastBacktickRunStart = lastRuns
    }

    // MARK: Main loop

    private mutating func run() -> FormattedText {
        while position < scalars.count {
            let c = scalars[position]
            switch c {
            case "\\":
                handleBackslash()
            case "`":
                handleBackticks()
            case "*", "_":
                handleDelimiterRun(c)
            case "~":
                handleTilde()
            case "[":
                flushText()
                nodes.append(Node(text: "["))
                brackets.append(Bracket(nodeIndex: nodes.count - 1, delimiterBottom: delimiters.count, isImage: false))
                position += 1
            case "!" where peek(1) == "[":
                flushText()
                nodes.append(Node(text: "!["))
                brackets.append(Bracket(nodeIndex: nodes.count - 1, delimiterBottom: delimiters.count, isImage: true))
                position += 2
            case "]":
                handleCloseBracket()
            case "<":
                if !handleEmoticon() && !handleAngleAutolink() {
                    appendText(c)
                }
            case "@":
                if !handleMention() {
                    appendText(c)
                }
            case "#":
                if !handleHashtag() {
                    appendText(c)
                }
            case ":":
                if !handleEmoji() && !handleEmoticon() {
                    appendText(c)
                }
            case ";":
                if !handleEmoticon() {
                    appendText(c)
                }
            case "$":
                if !handleInlineLatex() {
                    appendText(c)
                }
            default:
                if c.isASCII, isASCIIAlphanumeric(c), !isASCIIAlphanumeric(peek(-1)) {
                    if (c == "x" || c == "X") && handleEmoticon() {
                        continue
                    }
                    if tryBareURL() || tryEmail() {
                        continue
                    }
                }
                appendText(c)
            }
        }
        flushText()
        processEmphasis(stackBottom: 0)
        return emit()
    }

    // MARK: Character helpers

    private func peek(_ offset: Int) -> Unicode.Scalar? {
        let index = position + offset
        if index < 0 || index >= scalars.count {
            return nil
        }
        return scalars[index]
    }

    private func scalar(at index: Int) -> Unicode.Scalar? {
        if index < 0 || index >= scalars.count {
            return nil
        }
        return scalars[index]
    }

    private mutating func appendText(_ c: Unicode.Scalar) {
        pendingText.append(c)
        position += 1
    }

    private mutating func flushText() {
        if !pendingText.isEmpty {
            nodes.append(Node(text: String(pendingText)))
            pendingText = String.UnicodeScalarView()
        }
    }

    private mutating func appendAtom(_ text: String, entity: TextEntityType?, isAutoEntity: Bool) {
        flushText()
        nodes.append(Node(text: text, entity: entity, isAutoEntity: isAutoEntity))
    }

    private func string(_ range: Range<Int>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[range])
        return String(view)
    }

    // MARK: Escapes and code spans

    private mutating func handleBackslash() {
        if let next = peek(1) {
            if next == "\n" {
                // Hard line break: Mattermost keeps every newline anyway.
                appendText("\n")
                position += 1
                return
            }
            if isASCIIPunctuation(next) {
                pendingText.append(next)
                position += 2
                return
            }
        }
        appendText("\\")
    }

    private mutating func handleBackticks() {
        let start = position
        var count = 0
        while scalar(at: start + count) == "`" {
            count += 1
        }
        // Find a closing run of exactly `count` backticks.
        var index = start + count
        let lastCandidate = lastBacktickRunStart[count] ?? -1
        while lastCandidate > start && index < scalars.count {
            if scalars[index] == "`" {
                var run = 0
                while scalar(at: index + run) == "`" {
                    run += 1
                }
                if run == count {
                    var content = Array(scalars[(start + count) ..< index]).map { $0 == "\n" ? " " : $0 }
                    if content.count >= 2, content.first == " ", content.last == " ", content.contains(where: { $0 != " " }) {
                        content.removeFirst()
                        content.removeLast()
                    }
                    var view = String.UnicodeScalarView()
                    view.append(contentsOf: content)
                    appendAtom(String(view), entity: .code, isAutoEntity: false)
                    position = index + run
                    return
                }
                index += run
            } else {
                index += 1
            }
        }
        for _ in 0 ..< count {
            pendingText.append("`")
        }
        position += count
    }

    // MARK: Emphasis

    private mutating func handleDelimiterRun(_ c: Unicode.Scalar) {
        let start = position
        var count = 0
        while scalar(at: start + count) == c {
            count += 1
        }
        let before = scalar(at: start - 1)
        let after = scalar(at: start + count)
        let (left, right) = flanking(before: before, after: after)
        let canOpen: Bool
        let canClose: Bool
        if c == "_" {
            canOpen = left && (!right || isPunctuation(before))
            canClose = right && (!left || isPunctuation(after))
        } else {
            canOpen = left
            canClose = right
        }
        flushText()
        nodes.append(Node(delimiterChar: c, delimiterCount: count))
        delimiters.append(Delimiter(nodeIndex: nodes.count - 1, char: c, originalCount: count, canOpen: canOpen, canClose: canClose))
        position += count
    }

    private mutating func handleTilde() {
        let start = position
        var count = 0
        while scalar(at: start + count) == "~" {
            count += 1
        }
        if count == 2 {
            let before = scalar(at: start - 1)
            let after = scalar(at: start + 2)
            let (left, right) = flanking(before: before, after: after)
            flushText()
            nodes.append(Node(delimiterChar: "~", delimiterCount: 2))
            delimiters.append(Delimiter(nodeIndex: nodes.count - 1, char: "~", originalCount: 2, canOpen: left, canClose: right))
            position += 2
            return
        }
        if count == 1, !isASCIIAlphanumeric(peek(-1)), let next = peek(1), isASCIIAlphanumeric(next) {
            var end = position + 1
            while let s = scalar(at: end), isASCIIAlphanumeric(s) || s == "-" || s == "_" || s == "." {
                end += 1
            }
            while end > position + 1, let s = scalar(at: end - 1), s == "-" || s == "_" || s == "." {
                end -= 1
            }
            let name = string((position + 1) ..< end)
            appendAtom("~" + name, entity: .channelMention(name: name.lowercased()), isAutoEntity: true)
            position = end
            return
        }
        for _ in 0 ..< count {
            pendingText.append("~")
        }
        position += count
    }

    private func flanking(before: Unicode.Scalar?, after: Unicode.Scalar?) -> (left: Bool, right: Bool) {
        let left = !isWhitespace(after) && (!isPunctuation(after) || isWhitespace(before) || isPunctuation(before))
        let right = !isWhitespace(before) && (!isPunctuation(before) || isWhitespace(after) || isPunctuation(after))
        return (left, right)
    }

    private mutating func processEmphasis(stackBottom: Int) {
        var openersBottom: [OpenerKey: Int] = [:]
        var current = stackBottom
        while current < delimiters.count {
            let closer = delimiters[current]
            if !closer.active || !closer.canClose || nodes[closer.nodeIndex].delimiterCount == 0 {
                current += 1
                continue
            }
            let key = OpenerKey(char: closer.char, lengthModulo: closer.originalCount % 3, closerCanOpen: closer.canOpen)
            let bottom = max(stackBottom, openersBottom[key] ?? stackBottom)
            var openerIndex: Int?
            var j = current - 1
            while j >= bottom {
                let opener = delimiters[j]
                if opener.active, opener.char == closer.char, opener.canOpen, nodes[opener.nodeIndex].delimiterCount > 0 {
                    if closer.char == "~" {
                        openerIndex = j
                        break
                    }
                    let oddMatch = (opener.canClose || closer.canOpen)
                        && (opener.originalCount + closer.originalCount) % 3 == 0
                        && !(opener.originalCount % 3 == 0 && closer.originalCount % 3 == 0)
                    if !oddMatch {
                        openerIndex = j
                        break
                    }
                }
                j -= 1
            }

            guard let opener = openerIndex else {
                openersBottom[key] = current
                if !closer.canOpen {
                    delimiters[current].active = false
                }
                current += 1
                continue
            }

            let openerNode = delimiters[opener].nodeIndex
            let closerNode = closer.nodeIndex
            let used: Int
            let type: TextEntityType
            if closer.char == "~" {
                used = 2
                type = .strikethrough
            } else if nodes[openerNode].delimiterCount >= 2 && nodes[closerNode].delimiterCount >= 2 {
                used = 2
                type = .bold
            } else {
                used = 1
                type = .italic
            }
            let id = nextMarkerId
            nextMarkerId += 1
            nodes[openerNode].delimiterCount -= used
            nodes[openerNode].opens.append((id, type))
            nodes[closerNode].delimiterCount -= used
            nodes[closerNode].closes.append(id)
            for k in (opener + 1) ..< current {
                delimiters[k].active = false
            }
            if nodes[openerNode].delimiterCount == 0 {
                delimiters[opener].active = false
            }
            if nodes[closerNode].delimiterCount == 0 {
                delimiters[current].active = false
                current += 1
            }
        }
    }

    // MARK: Links

    private mutating func handleCloseBracket() {
        flushText()
        guard let bracket = brackets.last else {
            appendText("]")
            return
        }
        if !bracket.active {
            brackets.removeLast()
            appendText("]")
            return
        }
        guard let (destination, end) = parseLinkTarget(at: position + 1) else {
            brackets.removeLast()
            appendText("]")
            return
        }

        processEmphasis(stackBottom: bracket.delimiterBottom)
        if delimiters.count > bracket.delimiterBottom {
            delimiters.removeSubrange(bracket.delimiterBottom...)
        }
        var hasText = false
        for k in (bracket.nodeIndex + 1) ..< nodes.count {
            if nodes[k].isAutoEntity {
                nodes[k].entity = nil
            }
            if !nodes[k].text.isEmpty || nodes[k].delimiterCount > 0 {
                hasText = true
            }
        }
        let url = InlineParser.sanitizedURL(destination)
        let id = nextMarkerId
        nextMarkerId += 1
        nodes[bracket.nodeIndex].text = ""
        if let url = url {
            nodes[bracket.nodeIndex].opens.append((id, .textUrl(url: url)))
        }
        if !hasText {
            nodes.append(Node(text: destination))
        }
        var closeNode = Node()
        if url != nil {
            closeNode.closes.append(id)
        }
        nodes.append(closeNode)
        brackets.removeLast()
        if !bracket.isImage {
            // Links can't contain links.
            for index in brackets.indices where !brackets[index].isImage {
                brackets[index].active = false
            }
        }
        position = end
    }

    /// Parses `(destination "title")` starting at `index`. Returns the destination and the index
    /// after the closing parenthesis.
    private func parseLinkTarget(at index: Int) -> (String, Int)? {
        guard scalar(at: index) == "(" else {
            return nil
        }
        var i = index + 1
        func skipWhitespace() {
            while let s = scalar(at: i), s == " " || s == "\t" || s == "\n" {
                i += 1
            }
        }
        skipWhitespace()
        var destination = String.UnicodeScalarView()
        if scalar(at: i) == "<" {
            i += 1
            while let s = scalar(at: i), s != ">" {
                if s == "\n" || s == "<" {
                    return nil
                }
                if s == "\\", let next = scalar(at: i + 1), isASCIIPunctuation(next) {
                    destination.append(next)
                    i += 2
                    continue
                }
                destination.append(s)
                i += 1
            }
            guard scalar(at: i) == ">" else {
                return nil
            }
            i += 1
        } else {
            var depth = 0
            while let s = scalar(at: i) {
                if s == " " || s == "\t" || s == "\n" || s.properties.generalCategory == .control {
                    break
                }
                if s == "\\", let next = scalar(at: i + 1), isASCIIPunctuation(next) {
                    destination.append(next)
                    i += 2
                    continue
                }
                if s == "(" {
                    depth += 1
                } else if s == ")" {
                    if depth == 0 {
                        break
                    }
                    depth -= 1
                }
                destination.append(s)
                i += 1
            }
            if depth != 0 {
                return nil
            }
        }
        let afterDestination = i
        skipWhitespace()
        if i > afterDestination, let open = scalar(at: i), open == "\"" || open == "'" || open == "(" {
            let close: Unicode.Scalar = open == "(" ? ")" : open
            i += 1
            while let s = scalar(at: i), s != close {
                if s == "\\" {
                    i += 1
                }
                i += 1
            }
            guard scalar(at: i) == close else {
                return nil
            }
            i += 1
            skipWhitespace()
        }
        guard scalar(at: i) == ")" else {
            return nil
        }
        return (String(destination), i + 1)
    }

    static func sanitizedURL(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return nil
        }
        if let colon = trimmed.firstIndex(of: ":") {
            let scheme = trimmed[trimmed.startIndex ..< colon].lowercased()
            if ["javascript", "vbscript", "data", "file"].contains(scheme) {
                return nil
            }
        }
        return trimmed
    }

    // MARK: Autolinks

    private mutating func handleAngleAutolink() -> Bool {
        var i = position + 1
        // URI autolink: scheme ":" then no spaces, "<" or ">".
        var schemeLength = 0
        while let s = scalar(at: i + schemeLength), isASCIIAlphanumeric(s) || s == "+" || s == "." || s == "-" {
            schemeLength += 1
        }
        if schemeLength >= 2, schemeLength <= 32, let first = scalar(at: i), isASCIILetter(first), scalar(at: i + schemeLength) == ":" {
            var end = i + schemeLength + 1
            while let s = scalar(at: end), s != ">", s != "<", !isWhitespace(s), s.properties.generalCategory != .control {
                end += 1
            }
            if scalar(at: end) == ">" {
                let url = string(i ..< end)
                if InlineParser.sanitizedURL(url) != nil {
                    appendAtom(url, entity: .url, isAutoEntity: true)
                } else {
                    appendAtom(url, entity: nil, isAutoEntity: false)
                }
                position = end + 1
                return true
            }
        }
        // Email autolink.
        i = position + 1
        if let length = matchEmail(at: i), scalar(at: i + length) == ">" {
            appendAtom(string(i ..< (i + length)), entity: .email, isAutoEntity: true)
            position = i + length + 1
            return true
        }
        return false
    }

    private static let urlPrefixes: [String] = ["https://", "http://", "ftp://", "www."]

    private mutating func tryBareURL() -> Bool {
        if let previous = peek(-1), !(isWhitespace(previous) || "*_~([\"'".unicodeScalars.contains(previous)) {
            return false
        }
        var prefixLength = 0
        for prefix in InlineParser.urlPrefixes {
            let prefixScalars = Array(prefix.unicodeScalars)
            var matches = true
            for (k, p) in prefixScalars.enumerated() {
                guard let s = scalar(at: position + k), String(s).lowercased() == String(p) else {
                    matches = false
                    break
                }
            }
            if matches {
                prefixLength = prefixScalars.count
                break
            }
        }
        if prefixLength == 0 {
            return false
        }
        var end = position + prefixLength
        while let s = scalar(at: end), !isWhitespace(s), s != "<" {
            if s == "]" && !brackets.isEmpty {
                break
            }
            end += 1
        }
        // Trailing punctuation is not part of the URL; nor is an unbalanced ")".
        while end > position + prefixLength {
            let last = scalars[end - 1]
            if "?!.,:*_~'\";".unicodeScalars.contains(last) {
                end -= 1
                continue
            }
            if last == ")" {
                var open = 0
                var close = 0
                for s in scalars[position ..< end] {
                    if s == "(" {
                        open += 1
                    } else if s == ")" {
                        close += 1
                    }
                }
                if close > open {
                    end -= 1
                    continue
                }
            }
            break
        }
        let host = scalars[(position + prefixLength) ..< end]
        guard let firstHost = host.first, isASCIIAlphanumeric(firstHost) || !firstHost.isASCII else {
            return false
        }
        if prefixLength == 4 && !host.contains(".") {
            // "www." needs a real domain.
            return false
        }
        appendAtom(string(position ..< end), entity: .url, isAutoEntity: true)
        position = end
        return true
    }

    private mutating func tryEmail() -> Bool {
        if let previous = peek(-1), isASCIIAlphanumeric(previous) || previous == "." || previous == "+" || previous == "-" || previous == "@" {
            return false
        }
        guard let length = matchEmail(at: position) else {
            return false
        }
        appendAtom(string(position ..< (position + length)), entity: .email, isAutoEntity: true)
        position += length
        return true
    }

    /// Length of an email address starting at `start`, if any.
    private func matchEmail(at start: Int) -> Int? {
        var i = start
        while let s = scalar(at: i), isASCIIAlphanumeric(s) || s == "." || s == "_" || s == "+" || s == "-" {
            i += 1
        }
        guard i > start, scalar(at: i) == "@", scalar(at: i - 1) != "." else {
            return nil
        }
        i += 1
        let domainStart = i
        while let s = scalar(at: i), isASCIIAlphanumeric(s) || s == "-" || s == "." {
            i += 1
        }
        // Trailing "." and "-" are not part of the domain.
        while i > domainStart, let s = scalar(at: i - 1), s == "." || s == "-" {
            i -= 1
        }
        let domain = scalars[domainStart ..< i]
        guard domain.contains("."), let first = domain.first, isASCIIAlphanumeric(first) else {
            return nil
        }
        if domain.split(separator: ".", omittingEmptySubsequences: false).contains(where: { $0.isEmpty }) {
            return nil
        }
        if let s = scalar(at: i), isASCIIAlphanumeric(s) {
            return nil
        }
        return i - start
    }

    // MARK: Mattermost tokens

    private mutating func handleMention() -> Bool {
        if let previous = peek(-1), isASCIIAlphanumeric(previous) || previous == "@" {
            return false
        }
        guard let first = peek(1), isASCIILetter(first) else {
            return false
        }
        var end = position + 2
        while let s = scalar(at: end), isASCIIAlphanumeric(s) || s == "." || s == "_" || s == "-" {
            end += 1
        }
        while end > position + 2, let s = scalar(at: end - 1), s == "." || s == "_" || s == "-" {
            end -= 1
        }
        let name = string((position + 1) ..< end)
        let lowercased = name.lowercased()
        if let special = SpecialMentionKind(rawValue: lowercased) {
            appendAtom("@" + name, entity: .specialMention(special), isAutoEntity: true)
        } else {
            appendAtom("@" + name, entity: .mention(username: lowercased), isAutoEntity: true)
        }
        position = end
        return true
    }

    private mutating func handleHashtag() -> Bool {
        if let previous = peek(-1), isASCIIAlphanumeric(previous) || previous == "&" || previous == "#" || previous.properties.isAlphabetic {
            return false
        }
        guard let first = peek(1), first.properties.isAlphabetic else {
            return false
        }
        var end = position + 2
        while let s = scalar(at: end), s.properties.isAlphabetic || s.properties.numericType != nil || s.properties.generalCategory == .nonspacingMark || s == "_" || s == "-" || s == "." {
            end += 1
        }
        while end > position + 2, let s = scalar(at: end - 1), s == "." || s == "_" || s == "-" {
            end -= 1
        }
        if end - (position + 1) < 3 {
            return false
        }
        appendAtom(string(position ..< end), entity: .hashtag, isAutoEntity: true)
        position = end
        return true
    }

    private mutating func handleEmoji() -> Bool {
        if let previous = peek(-1), isASCIIAlphanumeric(previous) {
            return false
        }
        var end = position + 1
        while let s = scalar(at: end), isASCIIAlphanumeric(s) || s == "_" || s == "+" || s == "-" {
            end += 1
            if end - position > 65 {
                return false
            }
        }
        guard end > position + 1, scalar(at: end) == ":" else {
            return false
        }
        if let next = scalar(at: end + 1), isASCIIAlphanumeric(next) {
            return false
        }
        let name = string((position + 1) ..< end)
        let lowercased = name.lowercased()
        if let emoji = EmojiTable.unicode(forName: lowercased) {
            appendAtom(emoji, entity: nil, isAutoEntity: false)
        } else {
            guard name.unicodeScalars.contains(where: { isASCIILetter($0) }) else {
                return false
            }
            appendAtom(":" + name + ":", entity: .customEmoji(name: lowercased), isAutoEntity: false)
        }
        position = end + 1
        return true
    }

    // MARK: Emoticons and inline LaTeX

    /// Emoticons Mattermost's clients render as emoji (webapp `utils/emoticons`), longest first; `ignoresCase`:
    /// letters match in either case.
    private static let emoticons: [(text: [Unicode.Scalar], name: String, ignoresCase: Bool)] = [
        (":-)", "slightly_smiling_face", false), (":)", "slightly_smiling_face", false),
        (";-)", "wink", false), (";)", "wink", false),
        (":-o", "scream", true), (":o", "open_mouth", true),
        (":-]", "smirk", false), (":]", "smirk", false),
        (":-d", "smile", true), (":d", "smile", true),
        ("x-d", "stuck_out_tongue_closed_eyes", true),
        (":-p", "stuck_out_tongue", true), (":p", "stuck_out_tongue", true),
        (":-@", "rage", false), (":@", "rage", false), (":-[", "rage", false), (":[", "rage", false),
        (":-(", "slightly_frowning_face", false), (":(", "slightly_frowning_face", false),
        (":`-(", "cry", false), (":'-(", "cry", false), (":\u{2019}-(", "cry", false),
        (":`(", "cry", false), (":'(", "cry", false), (":\u{2019}(", "cry", false),
        (":-/", "confused", false), (":/", "confused", false),
        (":-s", "confounded", true), (":s", "confounded", true),
        (":-|", "neutral_face", false), (":|", "neutral_face", false),
        (":-$", "flushed", false), (":$", "flushed", false),
        (":-x", "mask", true),
        ("</3", "broken_heart", false), ("<3", "heart", false),
    ].map { (Array($0.0.unicodeScalars), $0.1, $0.2) }

    /// An emoticon at the position: only between non-word characters (the webapp's `(^|\B)…($|\B)` patterns),
    /// so `http://`, `10:30` or `Note:D` stay text.
    private mutating func handleEmoticon() -> Bool {
        guard options.emoticons, !isWordCharacter(peek(-1)) else {
            return false
        }
        for emoticon in InlineParser.emoticons {
            let candidate = emoticon.text
            guard position + candidate.count <= scalars.count else {
                continue
            }
            var matches = true
            for (offset, expected) in candidate.enumerated() {
                var actual = scalars[position + offset]
                if emoticon.ignoresCase, actual.value >= 65, actual.value <= 90, let lowered = Unicode.Scalar(actual.value + 32) {
                    actual = lowered
                }
                if actual != expected {
                    matches = false
                    break
                }
            }
            guard matches, !isWordCharacter(scalar(at: position + candidate.count)), let emoji = EmojiTable.unicode(forName: emoticon.name) else {
                continue
            }
            appendAtom(emoji, entity: nil, isAutoEntity: false)
            position += candidate.count
            return true
        }
        return false
    }

    private func isWordCharacter(_ s: Unicode.Scalar?) -> Bool {
        guard let s = s else {
            return false
        }
        return isASCIIAlphanumeric(s) || s == "_"
    }

    /// `$x^2$` (with the server's inline LaTeX on) as inline code without the dollars: the app doesn't typeset
    /// TeX. Like Mattermost: no space just inside the dollars, one line, and no digit right after the closing one,
    /// so "$5 and $10" stays text.
    private mutating func handleInlineLatex() -> Bool {
        guard options.inlineLatex, !isASCIIAlphanumeric(peek(-1)), peek(-1) != "\\", let first = peek(1), first != "$", !first.properties.isWhitespace else {
            return false
        }
        var end = position + 1
        while let s = scalar(at: end), s != "$" {
            if s == "\n" {
                return false
            }
            end += 1
        }
        guard end < scalars.count, let last = scalar(at: end - 1), !last.properties.isWhitespace, last != "\\" else {
            return false
        }
        if let next = scalar(at: end + 1), next.properties.numericType != nil {
            return false
        }
        appendAtom(string((position + 1) ..< end), entity: .code, isAutoEntity: false)
        position = end + 1
        return true
    }

    // MARK: Output

    private func emit() -> FormattedText {
        var output = String.UnicodeScalarView()
        var offset = 0
        var starts: [Int: (Int, TextEntityType)] = [:]
        var entities: [TextEntity] = []
        for node in nodes {
            for id in node.closes {
                if let (start, type) = starts.removeValue(forKey: id), offset > start {
                    entities.append(TextEntity(range: start ..< offset, type: type))
                }
            }
            let start = offset
            if let char = node.delimiterChar {
                for _ in 0 ..< node.delimiterCount {
                    output.append(char)
                    offset += char.utf16.count
                }
            } else {
                output.append(contentsOf: node.text.unicodeScalars)
                offset += node.text.utf16.count
            }
            if let entity = node.entity, offset > start {
                entities.append(TextEntity(range: start ..< offset, type: entity))
            }
            for (id, type) in node.opens {
                starts[id] = (offset, type)
            }
        }
        return FormattedText(text: String(output), entities: entities)
    }
}

// MARK: - Character classes

@inline(__always)
func isASCIILetter(_ s: Unicode.Scalar?) -> Bool {
    guard let s = s else {
        return false
    }
    return (s >= "a" && s <= "z") || (s >= "A" && s <= "Z")
}

@inline(__always)
func isASCIIAlphanumeric(_ s: Unicode.Scalar?) -> Bool {
    guard let s = s else {
        return false
    }
    return isASCIILetter(s) || (s >= "0" && s <= "9")
}

func isASCIIPunctuation(_ s: Unicode.Scalar?) -> Bool {
    guard let s = s, s.isASCII else {
        return false
    }
    let v = s.value
    return (v >= 0x21 && v <= 0x2F) || (v >= 0x3A && v <= 0x40) || (v >= 0x5B && v <= 0x60) || (v >= 0x7B && v <= 0x7E)
}

/// nil (start or end of text) counts as whitespace, as in CommonMark.
func isWhitespace(_ s: Unicode.Scalar?) -> Bool {
    guard let s = s else {
        return true
    }
    return s.properties.isWhitespace
}

/// CommonMark "Unicode punctuation": ASCII punctuation or general category P* / S*.
func isPunctuation(_ s: Unicode.Scalar?) -> Bool {
    guard let s = s else {
        return false
    }
    if s.isASCII {
        return isASCIIPunctuation(s)
    }
    switch s.properties.generalCategory {
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation,
         .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
        return true
    default:
        return false
    }
}
