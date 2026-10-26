import Foundation

/// Mattermost markdown ⇄ Telegram-style plain text + entities.
public enum MattermostMarkdown {
    /// What the parser renders besides CommonMark, as Mattermost's clients do depending on server and user
    /// settings.
    public struct Options: Equatable, Sendable {
        /// Emoticons (`:)`, `;-)`, `<3`, …) become emoji, as Mattermost's clients render them unless the user's
        /// "Render emoticons as emoji" display setting (`render_emoticons_as_emoji`) is off.
        public var emoticons: Bool
        /// `$…$` inline LaTeX, shown as inline code (the server's `EnableLatex` and `EnableInlineLatex`).
        public var inlineLatex: Bool

        public init(emoticons: Bool = true, inlineLatex: Bool = false) {
            self.emoticons = emoticons
            self.inlineLatex = inlineLatex
        }

        public static let `default` = Options()
    }

    /// Parses Mattermost markdown into plain text (markdown syntax removed) and entities with
    /// UTF-16 ranges.
    ///
    /// Blocks: paragraphs (every newline is kept, as Mattermost renders soft breaks as line
    /// breaks), fenced and indented code (`pre` with the highlighter's language name), `>` quotes
    /// (`blockQuote`), headings (`heading` + `bold`), lists (`• ` / `1. ` prefixes, `☐`/`☑` for tasks,
    /// nested items and continuation lines indented by spaces as wide as the prefix), tables (an
    /// aligned monospaced `pre` block when narrow enough, else one record per row) and horizontal
    /// rules (`———`).
    public static func parse(_ markdown: String, options: Options = .default) -> FormattedText {
        let lines = splitLines(markdown)
        let blocks = BlockParser.parseBlocks(lines)
        let rendered = BlockRenderer(options: options).render(blocks, depth: 0)
        return finalize(rendered)
    }

    /// Converts composer output back to markdown. Handles the entity types the composer can
    /// produce (bold, italic, strikethrough, code, pre, textUrl); other entities are dropped and
    /// their text is kept. Plain text is passed through unescaped, because Mattermost users type
    /// markdown directly.
    public static func markdown(from formatted: FormattedText) -> String {
        return MarkdownSerializer.serialize(formatted)
    }

    // MARK: Helpers

    static func splitLines(_ text: String) -> [String] {
        // "\r\n" is a single Character in Swift, so split on Unicode scalars.
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" && previousWasCarriageReturn {
                previousWasCarriageReturn = false
                continue
            }
            previousWasCarriageReturn = scalar == "\r"
            if scalar == "\n" || scalar == "\r" {
                lines.append(expandLeadingTabs(String(current)))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        lines.append(expandLeadingTabs(String(current)))
        return lines
    }

    static func expandLeadingTabs(_ line: String) -> String {
        guard line.first == "\t" || (line.first == " " && line.contains("\t")) else {
            return line
        }
        var result = ""
        var column = 0
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if c == " " {
                result.append(" ")
                column += 1
            } else if c == "\t" {
                let width = 4 - column % 4
                result.append(String(repeating: " ", count: width))
                column += width
            } else {
                break
            }
            index = line.index(after: index)
        }
        result.append(contentsOf: line[index...])
        return result
    }

    private static func finalize(_ formatted: FormattedText) -> FormattedText {
        var text = formatted.text
        while let last = text.last, last.isWhitespace {
            text.removeLast()
        }
        let length = text.utf16.count
        var entities: [TextEntity] = []
        for entity in formatted.entities {
            let lower = max(0, entity.range.lowerBound)
            let upper = min(length, entity.range.upperBound)
            if upper > lower {
                entities.append(TextEntity(range: lower ..< upper, type: entity.type))
            }
        }
        // Drop entities nested in another entity of the same type (a bold span inside a heading,
        // a quote inside a quote: Telegram can't nest block quotes).
        let outerFirst = FormattedText.sortedEntities(entities)
        var kept: [TextEntity] = []
        for entity in outerFirst {
            let redundant = kept.contains { other in
                other.type == entity.type && other.range.lowerBound <= entity.range.lowerBound && entity.range.upperBound <= other.range.upperBound
            }
            if !redundant {
                kept.append(entity)
            }
        }
        entities = kept
        return FormattedText(text: text, entities: FormattedText.sortedEntities(entities))
    }
}

// MARK: - Blocks

private struct BlockItem {
    var block: Block
    var blankBefore: Bool
}

private struct ListItem {
    /// nil: not a task; false: `[ ]`; true: `[x]`.
    var task: Bool?
    var blocks: [BlockItem]
}

private enum TableAlignment {
    case left
    case center
    case right
}

private indirect enum Block {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, content: String)
    case quote([BlockItem])
    case list(ordered: Bool, start: Int, items: [ListItem])
    case table(rows: [[String]], alignments: [TableAlignment])
    case rule
}

private enum BlockParser {
    struct Fence {
        var char: Character
        var count: Int
        var indent: Int
        var language: String?
    }

    struct ListMarker {
        var ordered: Bool
        var marker: Character
        var number: Int
        var contentIndent: Int
        var content: String
    }

    /// Quotes and lists nested deeper than this are kept as plain paragraphs (bounded recursion).
    static let maximumNesting = 32

    static func parseBlocks(_ lines: [String], depth: Int = 0) -> [BlockItem] {
        if depth > maximumNesting {
            let text = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
            return text.isEmpty ? [] : [BlockItem(block: .paragraph(text), blankBefore: false)]
        }
        var items: [BlockItem] = []
        var i = 0
        var blankBefore = false
        func push(_ block: Block) {
            items.append(BlockItem(block: block, blankBefore: blankBefore))
            blankBefore = false
        }

        while i < lines.count {
            let line = lines[i]
            if isBlank(line) {
                blankBefore = !items.isEmpty
                i += 1
                continue
            }
            let indent = leadingSpaces(line)

            // Indented code.
            if indent >= 4 {
                var codeLines: [String] = []
                while i < lines.count, isBlank(lines[i]) || leadingSpaces(lines[i]) >= 4 {
                    codeLines.append(isBlank(lines[i]) ? "" : dropLeadingSpaces(lines[i], 4))
                    i += 1
                }
                var trailingBlank = false
                while codeLines.last == "" {
                    codeLines.removeLast()
                    trailingBlank = true
                }
                push(.code(language: nil, content: codeLines.joined(separator: "\n")))
                blankBefore = trailingBlank
                continue
            }

            if let fence = fenceOpen(line) {
                i += 1
                var content: [String] = []
                while i < lines.count, !isFenceClose(lines[i], fence: fence) {
                    content.append(dropLeadingSpaces(lines[i], fence.indent))
                    i += 1
                }
                if i < lines.count {
                    i += 1
                }
                push(.code(language: fence.language, content: content.joined(separator: "\n")))
                continue
            }

            if let heading = atxHeading(line) {
                push(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }

            if isThematicBreak(line) {
                push(.rule)
                i += 1
                continue
            }

            if stripQuote(line) != nil {
                var quoteLines: [String] = []
                var lastWasText = false
                while i < lines.count {
                    if let inner = stripQuote(lines[i]) {
                        quoteLines.append(inner)
                        lastWasText = !isBlank(inner)
                        i += 1
                        continue
                    }
                    if lastWasText, !isBlank(lines[i]), !interruptsParagraph(lines, i) {
                        // Lazy continuation of a quoted paragraph.
                        quoteLines.append(lines[i])
                        i += 1
                        continue
                    }
                    break
                }
                push(.quote(parseBlocks(quoteLines, depth: depth + 1)))
                continue
            }

            // An empty first item ("*" or "-" alone) only starts a list when content follows under
            // it; a lone "*" in a chat message is meant literally.
            if let first = listMarker(line), !first.content.isEmpty || (i + 1 < lines.count && !isBlank(lines[i + 1]) && leadingSpaces(lines[i + 1]) >= first.contentIndent) {
                var itemLines: [[String]] = [[first.content]]
                var contentIndent = first.contentIndent
                var trailingBlanks = 0
                i += 1
                while i < lines.count {
                    let next = lines[i]
                    if isBlank(next) {
                        itemLines[itemLines.count - 1].append("")
                        trailingBlanks += 1
                        i += 1
                        continue
                    }
                    if leadingSpaces(next) >= contentIndent {
                        itemLines[itemLines.count - 1].append(dropLeadingSpaces(next, contentIndent))
                        trailingBlanks = 0
                        i += 1
                        continue
                    }
                    if !isThematicBreak(next), let marker = listMarker(next), marker.ordered == first.ordered, marker.marker == first.marker {
                        itemLines.append([marker.content])
                        contentIndent = marker.contentIndent
                        trailingBlanks = 0
                        i += 1
                        continue
                    }
                    if trailingBlanks == 0, !interruptsParagraph(lines, i) {
                        itemLines[itemLines.count - 1].append(String(next.drop(while: { $0 == " " })))
                        i += 1
                        continue
                    }
                    break
                }
                while itemLines[itemLines.count - 1].last == "" {
                    itemLines[itemLines.count - 1].removeLast()
                }
                let listItems = itemLines.map { lines -> ListItem in
                    var lines = lines
                    var task: Bool?
                    if let firstLine = lines.first {
                        for (prefix, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] where firstLine == prefix || firstLine.hasPrefix(prefix + " ") {
                            task = checked
                            lines[0] = String(firstLine.dropFirst(prefix.count).drop(while: { $0 == " " }))
                            break
                        }
                    }
                    return ListItem(task: task, blocks: parseBlocks(lines, depth: depth + 1))
                }
                push(.list(ordered: first.ordered, start: first.number, items: listItems))
                blankBefore = trailingBlanks > 0
                continue
            }

            if isTableStart(lines, i) {
                let header = splitTableRow(lines[i])
                let alignments = splitTableRow(lines[i + 1]).map { cell -> TableAlignment in
                    if cell.hasPrefix(":") && cell.hasSuffix(":") && cell.count > 1 {
                        return .center
                    }
                    return cell.hasSuffix(":") ? .right : .left
                }
                var rows: [[String]] = [header]
                i += 2
                while i < lines.count, !isBlank(lines[i]), lines[i].contains("|"), !startsOtherBlock(lines[i]) {
                    var cells = splitTableRow(lines[i])
                    if cells.count < header.count {
                        cells += Array(repeating: "", count: header.count - cells.count)
                    } else if cells.count > header.count {
                        cells = Array(cells.prefix(header.count))
                    }
                    rows.append(cells)
                    i += 1
                }
                push(.table(rows: rows, alignments: alignments))
                continue
            }

            // Paragraph (or setext heading).
            var paragraph: [String] = [line]
            var headingLevel: Int?
            i += 1
            while i < lines.count {
                let next = lines[i]
                if isBlank(next) {
                    break
                }
                if isSetextUnderline(next) {
                    headingLevel = next.trimmingCharacters(in: .whitespaces).first == "=" ? 1 : 2
                    i += 1
                    break
                }
                if interruptsParagraph(lines, i) {
                    break
                }
                paragraph.append(next)
                i += 1
            }
            let text = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            push(headingLevel.map { .heading(level: $0, text: text) } ?? .paragraph(text))
        }
        return items
    }

    // MARK: Line classification

    static func isBlank(_ line: String) -> Bool {
        return line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for c in line {
            if c == " " {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    static func dropLeadingSpaces(_ line: String, _ count: Int) -> String {
        var dropped = 0
        var index = line.startIndex
        while dropped < count, index < line.endIndex, line[index] == " " {
            index = line.index(after: index)
            dropped += 1
        }
        return String(line[index...])
    }

    static func fenceOpen(_ line: String) -> Fence? {
        let indent = leadingSpaces(line)
        guard indent <= 3 else {
            return nil
        }
        let rest = line.dropFirst(indent)
        guard let char = rest.first, char == "`" || char == "~" else {
            return nil
        }
        let count = rest.prefix(while: { $0 == char }).count
        guard count >= 3 else {
            return nil
        }
        let info = rest.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if char == "`" && info.contains("`") {
            return nil
        }
        let language = info.split(separator: " ").first.map(String.init)
        return Fence(char: char, count: count, indent: indent, language: language?.isEmpty == false ? language : nil)
    }

    static func isFenceClose(_ line: String, fence: Fence) -> Bool {
        let indent = leadingSpaces(line)
        guard indent <= 3 else {
            return false
        }
        let rest = line.dropFirst(indent)
        let count = rest.prefix(while: { $0 == fence.char }).count
        return count >= fence.count && rest.dropFirst(count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        let indent = leadingSpaces(line)
        guard indent <= 3 else {
            return nil
        }
        let rest = line.dropFirst(indent)
        let level = rest.prefix(while: { $0 == "#" }).count
        guard level >= 1 && level <= 6 else {
            return nil
        }
        let afterHashes = rest.dropFirst(level)
        guard afterHashes.isEmpty || afterHashes.first == " " || afterHashes.first == "\t" else {
            return nil
        }
        var content = afterHashes.trimmingCharacters(in: .whitespaces)
        // Optional closing sequence.
        let withoutClosing = String(content.reversed().drop(while: { $0 == "#" }).reversed())
        if withoutClosing.count < content.count && (withoutClosing.isEmpty || withoutClosing.last == " ") {
            content = withoutClosing.trimmingCharacters(in: .whitespaces)
        }
        return (level, content)
    }

    static func isThematicBreak(_ line: String) -> Bool {
        guard leadingSpaces(line) <= 3 else {
            return false
        }
        let chars = line.filter { $0 != " " && $0 != "\t" }
        guard chars.count >= 3, let first = chars.first, first == "-" || first == "*" || first == "_" else {
            return false
        }
        return chars.allSatisfy { $0 == first }
    }

    static func isSetextUnderline(_ line: String) -> Bool {
        guard leadingSpaces(line) <= 3 else {
            return false
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "=" || first == "-" else {
            return false
        }
        return trimmed.allSatisfy { $0 == first }
    }

    static func stripQuote(_ line: String) -> String? {
        let indent = leadingSpaces(line)
        guard indent <= 3 else {
            return nil
        }
        var rest = line.dropFirst(indent)
        guard rest.first == ">" else {
            return nil
        }
        rest = rest.dropFirst()
        if rest.first == " " {
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    static func listMarker(_ line: String) -> ListMarker? {
        let indent = leadingSpaces(line)
        guard indent <= 3 else {
            return nil
        }
        let rest = Array(line.dropFirst(indent))
        guard let first = rest.first else {
            return nil
        }
        var ordered = false
        var marker: Character = first
        var number = 1
        var markerWidth = 1
        if first == "-" || first == "+" || first == "*" {
            ordered = false
        } else {
            var digits = 0
            while digits < rest.count, digits < 9, rest[digits].isASCII, rest[digits].isNumber {
                digits += 1
            }
            guard digits >= 1, digits < rest.count, rest[digits] == "." || rest[digits] == ")" else {
                return nil
            }
            ordered = true
            number = Int(String(rest[0 ..< digits])) ?? 1
            marker = rest[digits]
            markerWidth = digits + 1
        }
        if rest.count == markerWidth {
            return ListMarker(ordered: ordered, marker: marker, number: number, contentIndent: indent + markerWidth + 1, content: "")
        }
        guard rest[markerWidth] == " " else {
            return nil
        }
        var spaces = 0
        while markerWidth + spaces < rest.count, rest[markerWidth + spaces] == " " {
            spaces += 1
        }
        if markerWidth + spaces == rest.count {
            return ListMarker(ordered: ordered, marker: marker, number: number, contentIndent: indent + markerWidth + 1, content: "")
        }
        if spaces > 4 {
            spaces = 1
        }
        let content = String(rest[(markerWidth + spaces)...])
        return ListMarker(ordered: ordered, marker: marker, number: number, contentIndent: indent + markerWidth + spaces, content: content)
    }

    /// Block starts that can interrupt a paragraph (CommonMark: an ordered list only when it
    /// starts at 1, and no empty list items).
    static func startsOtherBlock(_ line: String) -> Bool {
        if fenceOpen(line) != nil || atxHeading(line) != nil || isThematicBreak(line) || stripQuote(line) != nil {
            return true
        }
        if let marker = listMarker(line), !marker.content.isEmpty, !marker.ordered || marker.number == 1 {
            return true
        }
        return false
    }

    static func interruptsParagraph(_ lines: [String], _ index: Int) -> Bool {
        return startsOtherBlock(lines[index]) || isTableStart(lines, index)
    }

    // MARK: Tables

    static func isTableStart(_ lines: [String], _ index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|"), lines[index + 1].contains("|") || lines[index].hasPrefix("|") else {
            return false
        }
        let header = splitTableRow(lines[index])
        let delimiter = splitTableRow(lines[index + 1])
        guard !header.isEmpty, header.count == delimiter.count else {
            return false
        }
        return delimiter.allSatisfy { cell in
            var body = Substring(cell)
            if body.first == ":" {
                body = body.dropFirst()
            }
            if body.last == ":" {
                body = body.dropLast()
            }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    static func splitTableRow(_ line: String) -> [String] {
        var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
        if trimmed.first == "|" {
            trimmed = trimmed.dropFirst()
        }
        if trimmed.last == "|" && !trimmed.hasSuffix("\\|") {
            trimmed = trimmed.dropLast()
        }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var previous: Character?
        for c in trimmed {
            if c == "`" {
                inCode.toggle()
            }
            if c == "|" && previous != "\\" && !inCode {
                cells.append(current)
                current = ""
            } else if c == "|" && previous == "\\" {
                current.removeLast()
                current.append("|")
            } else {
                current.append(c)
            }
            previous = c
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Rendering

private struct TextBuilder {
    var text = ""
    var length = 0
    var entities: [TextEntity] = []

    mutating func append(_ string: String) {
        text += string
        length += string.utf16.count
    }

    mutating func append(_ formatted: FormattedText) {
        let base = length
        append(formatted.text)
        for entity in formatted.entities {
            entities.append(TextEntity(range: (entity.range.lowerBound + base) ..< (entity.range.upperBound + base), type: entity.type))
        }
    }

    mutating func addEntity(from start: Int, type: TextEntityType) {
        if length > start {
            entities.append(TextEntity(range: start ..< length, type: type))
        }
    }

    var formatted: FormattedText {
        return FormattedText(text: text, entities: entities)
    }
}

private struct BlockRenderer {
    let options: MattermostMarkdown.Options

    /// Tables up to this many characters per line are drawn as a monospaced grid (a `pre` block); wider ones as
    /// one record per row. A chat bubble fits about 30 monospaced characters on a phone; a wrapped grid line is
    /// unreadable.
    static let tableGridMaxWidth = 30

    /// The grid's code block language: Telegram labels a code block with its language (a header row that also
    /// holds the copy button, which would otherwise sit on the first line of a narrow block); no highlighter
    /// grammar has this name.
    static let tableLanguage = "table"

    func inline(_ text: String) -> FormattedText {
        return InlineParser.parse(text, options: self.options)
    }

    func render(_ items: [BlockItem], depth: Int) -> FormattedText {
        var builder = TextBuilder()
        for (index, item) in items.enumerated() {
            if index > 0 {
                builder.append(item.blankBefore ? "\n\n" : "\n")
            }
            switch item.block {
            case let .paragraph(text):
                builder.append(self.inline(text))
            case let .heading(level, text):
                let start = builder.length
                builder.append(self.inline(text))
                builder.addEntity(from: start, type: .bold)
                builder.addEntity(from: start, type: .heading(level: level))
            case let .code(language, content):
                let start = builder.length
                builder.append(content)
                builder.addEntity(from: start, type: .pre(language: MattermostMarkdown.codeLanguage(language)))
            case let .quote(inner):
                let start = builder.length
                builder.append(self.render(inner, depth: depth))
                builder.addEntity(from: start, type: .blockQuote)
            case let .list(ordered, start, listItems):
                for (k, listItem) in listItems.enumerated() {
                    if k > 0 {
                        builder.append("\n")
                    }
                    var prefix: String
                    if ordered {
                        prefix = "\(start + k). "
                        if let task = listItem.task {
                            prefix += task ? "☑ " : "☐ "
                        }
                    } else if let task = listItem.task {
                        prefix = task ? "☑ " : "☐ "
                    } else {
                        prefix = BlockRenderer.bullet(depth: depth) + " "
                    }
                    let content = self.render(listItem.blocks, depth: depth + 1)
                    if content.text.isEmpty {
                        builder.append(String(prefix.dropLast()))
                    } else {
                        builder.append(prefix)
                        builder.append(BlockRenderer.indentContinuationLines(content, indent: BlockRenderer.indent(matching: prefix)))
                    }
                }
            case let .table(rows, alignments):
                self.renderTable(rows: rows, alignments: alignments, into: &builder)
            case .rule:
                builder.append("———")
            }
        }
        return builder.formatted
    }

    static func bullet(depth: Int) -> String {
        switch depth {
        case 0:
            return "•"
        case 1:
            return "◦"
        default:
            return "‣"
        }
    }

    /// Whitespace about as wide as `prefix` in the system font (SF Pro), so continuation lines and nested blocks
    /// line up with the text after a bullet or number: Telegram's text layout has no hanging indents, and plain
    /// spaces are much narrower than "•" or digits. The widths scale with the font size (all em-based).
    static func indent(matching prefix: String) -> String {
        var result = ""
        for character in prefix {
            switch character {
            case "•", "◦", "‣":
                result.append("\u{2002}") // en space ≈ the bullet
            case "☐", "☑":
                result.append("\u{2002}\u{2009}\u{2009}\u{2009}") // en + 3 thin ≈ the box
            case "1":
                result.append("\u{2002}") // a narrow digit
            case "0" ... "9":
                result.append("\u{2007}") // figure space = digit width
            case ".":
                result.append("\u{2008}") // punctuation space = period width
            default:
                result.append(" ")
            }
        }
        return result
    }

    /// Indents every non-empty line after the first by `indent`, remapping entity ranges.
    static func indentContinuationLines(_ formatted: FormattedText, indent: String) -> FormattedText {
        let units = Array(formatted.text.utf16)
        let newline = UInt16(UInt8(ascii: "\n"))
        let indentUnits = Array(indent.utf16)
        let width = indentUnits.count
        // Positions where an indent is inserted: after a newline, before a non-newline character.
        var insertionPoints: [Int] = []
        for index in 0 ..< units.count where units[index] == newline && index + 1 < units.count && units[index + 1] != newline {
            insertionPoints.append(index + 1)
        }
        if insertionPoints.isEmpty || width == 0 {
            return formatted
        }
        var result: [UInt16] = []
        result.reserveCapacity(units.count + insertionPoints.count * width)
        var next = 0
        for index in 0 ..< units.count {
            if next < insertionPoints.count && insertionPoints[next] == index {
                result.append(contentsOf: indentUnits)
                next += 1
            }
            result.append(units[index])
        }
        func countPoints(_ predicate: (Int) -> Bool) -> Int {
            return insertionPoints.reduce(0) { $0 + (predicate($1) ? 1 : 0) }
        }
        let entities = formatted.entities.map { entity -> TextEntity in
            let start = entity.range.lowerBound + width * countPoints { $0 <= entity.range.lowerBound }
            let end = entity.range.upperBound + width * countPoints { $0 < entity.range.upperBound }
            return TextEntity(range: start ..< max(start, end), type: entity.type)
        }
        return FormattedText(text: String(decoding: result, as: UTF16.self), entities: entities)
    }

    // MARK: Tables

    /// A narrow table as an aligned monospaced grid; a wider one as records (the first column's value in bold,
    /// then "Column: value" lines with the cells' inline formatting), separated by blank lines, which reads well
    /// in a narrow bubble where a wrapped grid would not.
    func renderTable(rows: [[String]], alignments: [TableAlignment], into builder: inout TextBuilder) {
        let cells = rows.map { row in
            row.map { cell -> FormattedText in
                let parsed = self.inline(cell)
                return FormattedText(text: parsed.text.replacingOccurrences(of: "\n", with: " "), entities: parsed.entities)
            }
        }
        guard let header = cells.first, !header.isEmpty else {
            return
        }
        if let grid = BlockRenderer.tableGrid(cells.map { $0.map { $0.text } }, alignments: alignments) {
            let start = builder.length
            builder.append(grid)
            builder.addEntity(from: start, type: .pre(language: BlockRenderer.tableLanguage))
            return
        }
        let body = cells.dropFirst()
        if body.isEmpty {
            // Only a header row: its cells, one per line.
            for (index, cell) in header.enumerated() {
                if index > 0 {
                    builder.append("\n")
                }
                let start = builder.length
                builder.append(cell)
                builder.addEntity(from: start, type: .bold)
            }
            return
        }
        for (rowIndex, row) in body.enumerated() {
            if rowIndex > 0 {
                builder.append("\n\n")
            }
            var wroteLine = false
            for (column, cell) in row.enumerated() where column < header.count {
                if column == 0 {
                    if !cell.text.isEmpty {
                        let start = builder.length
                        builder.append(cell)
                        builder.addEntity(from: start, type: .bold)
                        wroteLine = true
                    }
                    continue
                }
                if cell.text.isEmpty {
                    continue
                }
                if wroteLine {
                    builder.append("\n")
                }
                let label = header[column].text
                if !label.isEmpty {
                    let start = builder.length
                    builder.append(label + ":")
                    builder.addEntity(from: start, type: .italic)
                    builder.append(" ")
                }
                builder.append(cell)
                wroteLine = true
            }
            if !wroteLine {
                builder.append("—")
            }
        }
    }

    /// The grid text, or nil when a line would be wider than `tableGridMaxWidth`.
    static func tableGrid(_ rows: [[String]], alignments: [TableAlignment]) -> String? {
        guard let columnCount = rows.first?.count, columnCount > 0 else {
            return nil
        }
        var widths = [Int](repeating: 0, count: columnCount)
        for row in rows {
            for (column, cell) in row.enumerated() where column < columnCount {
                widths[column] = max(widths[column], cell.count)
            }
        }
        widths = widths.map { max(1, $0) }
        let lineWidth = widths.reduce(0, +) + 3 * (columnCount - 1)
        if lineWidth > tableGridMaxWidth {
            return nil
        }
        func pad(_ cell: String, width: Int, alignment: TableAlignment) -> String {
            let missing = max(0, width - cell.count)
            switch alignment {
            case .left:
                return cell + String(repeating: " ", count: missing)
            case .right:
                return String(repeating: " ", count: missing) + cell
            case .center:
                let left = missing / 2
                return String(repeating: " ", count: left) + cell + String(repeating: " ", count: missing - left)
            }
        }
        func line(_ row: [String]) -> String {
            var cells: [String] = []
            for column in 0 ..< columnCount {
                let cell = column < row.count ? row[column] : ""
                cells.append(pad(cell, width: widths[column], alignment: column < alignments.count ? alignments[column] : .left))
            }
            var text = cells.joined(separator: " | ")
            while text.last == " " {
                text.removeLast()
            }
            return text
        }
        var lines: [String] = [line(rows[0])]
        lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "-+-"))
        for row in rows.dropFirst() {
            lines.append(line(row))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Entities → markdown

private enum MarkdownSerializer {
    enum Kind: Equatable {
        case bold
        case italic
        case strikethrough
        case code
        case textUrl(String)

        var rank: Int {
            switch self {
            case .textUrl: return 0
            case .bold: return 1
            case .italic: return 2
            case .strikethrough: return 3
            case .code: return 4
            }
        }
    }

    struct Span {
        var range: Range<Int>
        var kind: Kind
    }

    struct Active {
        var span: Span
        var closing: String
    }

    static let newline = UInt16(UInt8(ascii: "\n"))
    static let backtick = UInt16(UInt8(ascii: "`"))
    static let space = UInt16(UInt8(ascii: " "))

    static func serialize(_ formatted: FormattedText) -> String {
        let units = Array(formatted.text.utf16)
        let count = units.count

        func snap(_ offset: Int) -> Int {
            var value = max(0, min(count, offset))
            if value > 0 && value < count && UTF16.isTrailSurrogate(units[value]) {
                value -= 1
            }
            return value
        }

        var spans: [Span] = []
        var pres: [(range: Range<Int>, language: String?)] = []
        for entity in formatted.entities {
            let lower = snap(entity.range.lowerBound)
            let upper = snap(entity.range.upperBound)
            guard upper > lower else {
                continue
            }
            switch entity.type {
            case .bold:
                spans.append(Span(range: lower ..< upper, kind: .bold))
            case .italic:
                spans.append(Span(range: lower ..< upper, kind: .italic))
            case .strikethrough:
                spans.append(Span(range: lower ..< upper, kind: .strikethrough))
            case .code:
                spans.append(Span(range: lower ..< upper, kind: .code))
            case let .textUrl(url):
                spans.append(Span(range: lower ..< upper, kind: .textUrl(url)))
            case let .pre(language):
                pres.append((lower ..< upper, language))
            default:
                break
            }
        }

        // Merge overlapping pre blocks.
        pres.sort { $0.range.lowerBound < $1.range.lowerBound }
        var mergedPres: [(range: Range<Int>, language: String?)] = []
        for pre in pres {
            if let last = mergedPres.last, pre.range.lowerBound <= last.range.upperBound {
                mergedPres[mergedPres.count - 1].range = last.range.lowerBound ..< max(last.range.upperBound, pre.range.upperBound)
            } else {
                mergedPres.append(pre)
            }
        }

        var output: [UInt16] = []
        output.reserveCapacity(count + 32)
        var position = 0
        for pre in mergedPres {
            if position < pre.range.lowerBound {
                output += renderInline(units, position ..< pre.range.lowerBound, spans)
            }
            if !output.isEmpty && output.last != newline {
                output.append(newline)
            }
            var content = Array(units[pre.range])
            while content.last == newline {
                content.removeLast()
            }
            let fence = [UInt16](repeating: backtick, count: max(3, longestRun(of: backtick, in: content) + 1))
            output += fence
            if let language = pre.language, !language.isEmpty {
                output += Array(language.utf16)
            }
            output.append(newline)
            output += content
            output.append(newline)
            output += fence
            if pre.range.upperBound < count && units[pre.range.upperBound] != newline {
                output.append(newline)
            }
            position = pre.range.upperBound
        }
        if position < count {
            output += renderInline(units, position ..< count, spans)
        }
        return String(decoding: output, as: UTF16.self)
    }

    static func longestRun(of unit: UInt16, in units: [UInt16]) -> Int {
        var longest = 0
        var current = 0
        for u in units {
            if u == unit {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    static func isWhitespaceUnit(_ unit: UInt16) -> Bool {
        return unit == space || unit == newline || unit == 9 || unit == 13
    }

    static func isAlphanumericUnit(_ unit: UInt16?) -> Bool {
        guard let unit = unit else {
            return false
        }
        if unit < 128 {
            return isASCIIAlphanumeric(Unicode.Scalar(UInt8(unit)))
        }
        if UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) {
            return false
        }
        return Unicode.Scalar(unit).map { $0.properties.isAlphabetic || $0.properties.numericType != nil } ?? false
    }

    static func renderInline(_ units: [UInt16], _ range: Range<Int>, _ allSpans: [Span]) -> [UInt16] {
        // Clip to this segment.
        var spans: [Span] = allSpans.compactMap { span in
            let lower = max(span.range.lowerBound, range.lowerBound)
            let upper = min(span.range.upperBound, range.upperBound)
            return upper > lower ? Span(range: lower ..< upper, kind: span.kind) : nil
        }

        // Code is atomic: merge overlapping code spans, drop formatting inside them and widen
        // formatting that partially overlaps them.
        var codes = spans.filter { $0.kind == .code }.map { $0.range }.sorted { $0.lowerBound < $1.lowerBound }
        var mergedCodes: [Range<Int>] = []
        for code in codes {
            if let last = mergedCodes.last, code.lowerBound <= last.upperBound {
                mergedCodes[mergedCodes.count - 1] = last.lowerBound ..< max(last.upperBound, code.upperBound)
            } else {
                mergedCodes.append(code)
            }
        }
        codes = mergedCodes
        var adjusted: [Span] = codes.map { Span(range: $0, kind: .code) }
        for span in spans where span.kind != .code {
            var lower = span.range.lowerBound
            var upper = span.range.upperBound
            var insideCode = false
            for code in codes {
                if code.lowerBound <= lower && upper <= code.upperBound {
                    insideCode = true
                    break
                }
                if code.contains(lower) {
                    lower = code.lowerBound
                }
                if upper > code.lowerBound && upper < code.upperBound {
                    upper = code.upperBound
                }
            }
            if !insideCode {
                adjusted.append(Span(range: lower ..< upper, kind: span.kind))
            }
        }

        // Merge overlapping spans of the same kind.
        var byKind: [Span] = []
        for span in adjusted.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if let index = byKind.lastIndex(where: { $0.kind == span.kind && $0.range.upperBound >= span.range.lowerBound }) {
                byKind[index].range = byKind[index].range.lowerBound ..< max(byKind[index].range.upperBound, span.range.upperBound)
            } else {
                byKind.append(span)
            }
        }

        // Split at newlines (markdown emphasis can't span blocks).
        spans = []
        for span in byKind {
            if span.kind == .code {
                spans.append(span)
                continue
            }
            var start = span.range.lowerBound
            for index in span.range where units[index] == newline {
                spans.append(Span(range: start ..< index, kind: span.kind))
                start = index + 1
            }
            spans.append(Span(range: start ..< span.range.upperBound, kind: span.kind))
        }

        // Markdown can only nest, so split crossing spans, and keep whitespace outside the
        // delimiters (`**bold **` is not bold). Repeat until stable: trimming can create a crossing.
        var changed = true
        var rounds = 0
        while changed && rounds < 64 {
            changed = false
            rounds += 1
            var trimmed: [Span] = []
            for span in spans {
                var lower = span.range.lowerBound
                var upper = span.range.upperBound
                if span.kind != .code {
                    while lower < upper && isWhitespaceUnit(units[lower]) {
                        lower += 1
                    }
                    while upper > lower && isWhitespaceUnit(units[upper - 1]) {
                        upper -= 1
                    }
                }
                if lower != span.range.lowerBound || upper != span.range.upperBound {
                    changed = true
                }
                if upper > lower {
                    trimmed.append(Span(range: lower ..< upper, kind: span.kind))
                }
            }
            spans = trimmed
            crossing: for i in spans.indices {
                for j in spans.indices where i != j {
                    let a = spans[i].range
                    let b = spans[j].range
                    if a.lowerBound < b.lowerBound && b.lowerBound < a.upperBound && a.upperBound < b.upperBound {
                        let kind = spans[j].kind
                        spans[j] = Span(range: b.lowerBound ..< a.upperBound, kind: kind)
                        spans.append(Span(range: a.upperBound ..< b.upperBound, kind: kind))
                        changed = true
                        break crossing
                    }
                }
            }
        }

        spans.sort { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            if lhs.range.upperBound != rhs.range.upperBound {
                return lhs.range.upperBound > rhs.range.upperBound
            }
            return lhs.kind.rank < rhs.kind.rank
        }

        var boundaries = Set<Int>()
        for span in spans {
            boundaries.insert(span.range.lowerBound)
            boundaries.insert(span.range.upperBound)
        }

        var output: [UInt16] = []
        var stack: [Active] = []
        var position = range.lowerBound
        var nextSpan = 0
        var linkDepth = 0

        func emitText(_ upTo: Int) {
            while position < upTo {
                let unit = units[position]
                let insideCode = stack.last?.span.kind == .code
                if linkDepth > 0 && !insideCode && (unit == UInt16(UInt8(ascii: "[")) || unit == UInt16(UInt8(ascii: "]"))) {
                    output.append(UInt16(UInt8(ascii: "\\")))
                }
                output.append(unit)
                position += 1
            }
        }

        for boundary in boundaries.sorted() {
            emitText(boundary)
            // Spans are properly nested, so the ones ending here are on top of the stack.
            while let top = stack.last, top.span.range.upperBound == boundary {
                stack.removeLast()
                output += Array(top.closing.utf16)
                if case .textUrl = top.span.kind {
                    linkDepth -= 1
                }
            }
            while nextSpan < spans.count && spans[nextSpan].range.lowerBound == boundary {
                let span = spans[nextSpan]
                nextSpan += 1
                let (opening, closing) = delimiters(for: span, units: units)
                output += Array(opening.utf16)
                stack.append(Active(span: span, closing: closing))
                if case .textUrl = span.kind {
                    linkDepth += 1
                }
            }
        }
        emitText(range.upperBound)
        while let active = stack.popLast() {
            output += Array(active.closing.utf16)
        }
        return output
    }

    static func delimiters(for span: Span, units: [UInt16]) -> (String, String) {
        switch span.kind {
        case .bold:
            return ("**", "**")
        case .italic:
            // `_` reads better and can't merge with a neighbouring `**`, but doesn't work inside words.
            let before: UInt16? = span.range.lowerBound > 0 ? units[span.range.lowerBound - 1] : nil
            let after: UInt16? = span.range.upperBound < units.count ? units[span.range.upperBound] : nil
            let marker = (isAlphanumericUnit(before) || isAlphanumericUnit(after)) ? "*" : "_"
            return (marker, marker)
        case .strikethrough:
            return ("~~", "~~")
        case .code:
            let content = Array(units[span.range])
            let fence = String(repeating: "`", count: longestRun(of: backtick, in: content) + 1)
            let needsPadding = content.first == backtick || content.last == backtick
                || (content.first == space && content.last == space && content.contains(where: { $0 != space }))
            return (fence + (needsPadding ? " " : ""), (needsPadding ? " " : "") + fence)
        case let .textUrl(url):
            return ("[", "](" + formatDestination(url) + ")")
        }
    }

    static func formatDestination(_ url: String) -> String {
        var depth = 0
        var balanced = true
        for c in url {
            if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth < 0 {
                    balanced = false
                }
            }
        }
        if depth != 0 {
            balanced = false
        }
        if balanced && !url.contains(where: { $0 == " " || $0 == "<" || $0 == ">" || $0.isNewline }) {
            return url
        }
        let escaped = url.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "\n", with: "%0A")
        return "<" + escaped + ">"
    }
}
