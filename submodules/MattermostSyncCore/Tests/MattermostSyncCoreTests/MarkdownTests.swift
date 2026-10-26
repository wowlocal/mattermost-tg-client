import Foundation
import XCTest
@testable import MattermostSyncCore

/// An expected entity, either at an explicit UTF-16 range or over the n-th occurrence of a
/// substring of the expected text.
private struct Expected {
    var type: TextEntityType
    var range: Range<Int>?
    var substring: String?
    var occurrence: Int

    func resolve(in text: String) -> TextEntity? {
        if let range = range {
            return TextEntity(range: range, type: type)
        }
        guard let substring = substring else {
            return nil
        }
        let string = text as NSString
        var searchFrom = 0
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0 ... occurrence {
            found = string.range(of: substring, options: [], range: NSRange(location: searchFrom, length: string.length - searchFrom))
            if found.location == NSNotFound {
                return nil
            }
            searchFrom = found.location + max(1, found.length)
        }
        return TextEntity(range: found.location ..< (found.location + found.length), type: type)
    }
}

private func on(_ type: TextEntityType, _ substring: String, _ occurrence: Int = 0) -> Expected {
    return Expected(type: type, range: nil, substring: substring, occurrence: occurrence)
}

private func at(_ type: TextEntityType, _ range: Range<Int>) -> Expected {
    return Expected(type: type, range: range, substring: nil, occurrence: 0)
}

private struct Case {
    var markdown: String
    var text: String
    var entities: [Expected]
    var line: UInt

    init(_ markdown: String, _ text: String, _ entities: [Expected] = [], line: UInt = #line) {
        self.markdown = markdown
        self.text = text
        self.entities = entities
        self.line = line
    }
}

final class MarkdownTests: XCTestCase {
    private func check(_ cases: [Case], file: StaticString = #filePath) {
        for testCase in cases {
            let result = MattermostMarkdown.parse(testCase.markdown)
            XCTAssertEqual(result.text, testCase.text, "markdown: \(testCase.markdown.debugDescription)", file: file, line: testCase.line)
            var expected: [TextEntity] = []
            for entity in testCase.entities {
                guard let resolved = entity.resolve(in: testCase.text) else {
                    XCTFail("bad expectation \(entity)", file: file, line: testCase.line)
                    continue
                }
                expected.append(resolved)
            }
            XCTAssertEqual(result.entities, FormattedText.sortedEntities(expected), "markdown: \(testCase.markdown.debugDescription)", file: file, line: testCase.line)
        }
    }

    // MARK: Inline formatting

    func testEmphasis() {
        check([
            Case("**bold**", "bold", [on(.bold, "bold")]),
            Case("__bold__", "bold", [on(.bold, "bold")]),
            Case("*italic*", "italic", [on(.italic, "italic")]),
            Case("_italic_", "italic", [on(.italic, "italic")]),
            Case("~~strike~~", "strike", [on(.strikethrough, "strike")]),
            Case("***both***", "both", [on(.bold, "both"), on(.italic, "both")]),
            Case("*italic **bold** italic*", "italic bold italic", [on(.italic, "italic bold italic"), on(.bold, "bold")]),
            Case("**bold *italic***", "bold italic", [on(.bold, "bold italic"), on(.italic, "italic")]),
            Case("x ~~a **b** c~~ y", "x a b c y", [on(.strikethrough, "a b c"), on(.bold, "b")]),
            Case("**bold**text and 2*3*4", "boldtext and 234", [on(.bold, "bold"), on(.italic, "3")]),
            Case("**bold\nacross lines**", "bold\nacross lines", [on(.bold, "bold\nacross lines")]),
            Case("file_name.txt *star*", "file_name.txt star", [on(.italic, "star")]),
        ])
    }

    func testIntrawordUnderscores() {
        check([
            Case("snake_case_name", "snake_case_name"),
            Case("snake_case_name and __init__", "snake_case_name and init", [on(.bold, "init")]),
            Case("call my_func_name_here() now", "call my_func_name_here() now"),
            Case("_emphasis_ but not_this_one", "emphasis but not_this_one", [on(.italic, "emphasis")]),
        ])
    }

    func testUnclosedAndStrayMarkers() {
        check([
            Case("unclosed **bold", "unclosed **bold"),
            Case("**", "**"),
            Case("*", "*"),
            Case("** not bold **", "** not bold **"),
            Case("a * b * c", "a * b * c"),
            Case("~~ not strike ~~", "~~ not strike ~~"),
            Case("x ~~~tilde~~~ y", "x ~~~tilde~~~ y"),
            Case("-", "-"),
            Case("unclosed `code", "unclosed `code"),
            Case("[not a link]", "[not a link]"),
            Case("[text](unclosed", "[text](unclosed"),
        ])
    }

    func testCode() {
        check([
            Case("`code **not bold**`", "code **not bold**", [on(.code, "code **not bold**")]),
            Case("`` a`b ``", "a`b", [on(.code, "a`b")]),
            Case("`@nobody :smile: #nohash https://x.com`", "@nobody :smile: #nohash https://x.com", [on(.code, "@nobody :smile: #nohash https://x.com")]),
            Case("```swift\nlet x = 1\n```", "let x = 1", [on(.pre(language: "swift"), "let x = 1")]),
            Case("~~~\ntilde code\n~~~", "tilde code", [on(.pre(language: nil), "tilde code")]),
            Case("```js title\nfoo()\n```", "foo()", [on(.pre(language: "js"), "foo()")]),
            Case("```\n**not bold** _x_ @nobody :smile:\n```", "**not bold** _x_ @nobody :smile:", [on(.pre(language: nil), "**not bold** _x_ @nobody :smile:")]),
            Case("```\nunclosed fence\nstill code", "unclosed fence\nstill code", [on(.pre(language: nil), "unclosed fence\nstill code")]),
            Case("    indented code\n    more", "indented code\nmore", [on(.pre(language: nil), "indented code\nmore")]),
            Case("text\n```\ncode\n```\nafter", "text\ncode\nafter", [on(.pre(language: nil), "code")]),
            Case("```\n  keep\n    indentation\n```", "  keep\n    indentation", [on(.pre(language: nil), "  keep\n    indentation")]),
        ])
    }

    // MARK: Links

    func testLinks() {
        check([
            Case("[text](https://example.com)", "text", [on(.textUrl(url: "https://example.com"), "text")]),
            Case("[**bold link**](https://example.com)", "bold link", [on(.textUrl(url: "https://example.com"), "bold link"), on(.bold, "bold link")]),
            Case("**bold [link](https://x.com) more**", "bold link more", [on(.bold, "bold link more"), on(.textUrl(url: "https://x.com"), "link")]),
            Case("[a](http://x.com \"title\")", "a", [on(.textUrl(url: "http://x.com"), "a")]),
            Case("[w](https://en.wikipedia.org/wiki/Foo_(bar))", "w", [on(.textUrl(url: "https://en.wikipedia.org/wiki/Foo_(bar)"), "w")]),
            Case("[x](<https://x.com/a b>)", "x", [on(.textUrl(url: "https://x.com/a b"), "x")]),
            Case("[](https://empty.com)", "https://empty.com", [on(.textUrl(url: "https://empty.com"), "https://empty.com")]),
            Case("[https://a.com](https://b.com)", "https://a.com", [on(.textUrl(url: "https://b.com"), "https://a.com")]),
            Case("[@user #tag](https://b.com)", "@user #tag", [on(.textUrl(url: "https://b.com"), "@user #tag")]),
            Case("![alt text](https://x.com/img.png)", "alt text", [on(.textUrl(url: "https://x.com/img.png"), "alt text")]),
            Case("[x](javascript:alert(1))", "x"),
            Case("[outer [inner](https://in.com)](https://out.com)", "[outer inner](https://out.com)", [on(.textUrl(url: "https://in.com"), "inner"), on(.url, "https://out.com")]),
        ])
    }

    func testAutolinks() {
        check([
            Case("<https://auto.link> and <me@x.com>", "https://auto.link and me@x.com", [on(.url, "https://auto.link"), on(.email, "me@x.com")]),
            Case("see https://example.com/a_b_c?x=1. ok", "see https://example.com/a_b_c?x=1. ok", [on(.url, "https://example.com/a_b_c?x=1")]),
            Case("go to https://x.com/a_b_c/*d*/e now", "go to https://x.com/a_b_c/*d*/e now", [on(.url, "https://x.com/a_b_c/*d*/e")]),
            Case("**https://x.com/a_b**", "https://x.com/a_b", [on(.bold, "https://x.com/a_b"), on(.url, "https://x.com/a_b")]),
            Case("_https://x.com/path_", "https://x.com/path", [on(.italic, "https://x.com/path"), on(.url, "https://x.com/path")]),
            Case("visit www.example.com, now", "visit www.example.com, now", [on(.url, "www.example.com")]),
            Case("(https://x.com/path)", "(https://x.com/path)", [on(.url, "https://x.com/path")]),
            Case("http://localhost:8065/team/pl/abc", "http://localhost:8065/team/pl/abc", [on(.url, "http://localhost:8065/team/pl/abc")]),
            Case("mail me at foo.bar@example.com.", "mail me at foo.bar@example.com.", [on(.email, "foo.bar@example.com")]),
            Case("first_last@example.co.uk", "first_last@example.co.uk", [on(.email, "first_last@example.co.uk")]),
            Case("_foo@bar.com_", "foo@bar.com", [on(.italic, "foo@bar.com"), on(.email, "foo@bar.com")]),
            Case("foo@bar is not an email", "foo@bar is not an email"),
            Case("www.nodot and http://", "www.nodot and http://"),
        ])
    }

    // MARK: Mattermost tokens

    func testMentions() {
        check([
            Case("@john", "@john", [on(.mention(username: "john"), "@john")]),
            Case("hi @john.doe, and @jane_doe. ok", "hi @john.doe, and @jane_doe. ok", [on(.mention(username: "john.doe"), "@john.doe"), on(.mention(username: "jane_doe"), "@jane_doe")]),
            Case("@John-Smith- said", "@John-Smith- said", [on(.mention(username: "john-smith"), "@John-Smith")]),
            Case("@user's thing", "@user's thing", [on(.mention(username: "user"), "@user")]),
            Case("(@user)", "(@user)", [on(.mention(username: "user"), "@user")]),
            Case("@all @Here @channel", "@all @Here @channel", [on(.specialMention(.all), "@all"), on(.specialMention(.here), "@Here"), on(.specialMention(.channel), "@channel")]),
            Case("@channels is a user", "@channels is a user", [on(.mention(username: "channels"), "@channels")]),
            Case("_@user_", "@user", [on(.italic, "@user"), on(.mention(username: "user"), "@user")]),
            Case("**@user**", "@user", [on(.bold, "@user"), on(.mention(username: "user"), "@user")]),
            Case("@123 and @_x", "@123 and @_x"),
            Case("email@example.com", "email@example.com", [on(.email, "email@example.com")]),
        ])
    }

    func testChannelMentions() {
        check([
            Case("join ~town-square please", "join ~town-square please", [on(.channelMention(name: "town-square"), "~town-square")]),
            Case("~~strike~~ vs ~off-topic.", "strike vs ~off-topic.", [on(.strikethrough, "strike"), on(.channelMention(name: "off-topic"), "~off-topic")]),
            Case("~Dev_Ops", "~Dev_Ops", [on(.channelMention(name: "dev_ops"), "~Dev_Ops")]),
            Case("a~b and ~ alone", "a~b and ~ alone"),
        ])
    }

    func testHashtags() {
        check([
            Case("#hashtag #ab #a1b2 #привет #123", "#hashtag #ab #a1b2 #привет #123", [on(.hashtag, "#hashtag"), on(.hashtag, "#a1b2"), on(.hashtag, "#привет")]),
            Case("C# and issue#123 and &#39;", "C# and issue#123 and &#39;"),
            Case("#release-1.2.", "#release-1.2.", [on(.hashtag, "#release-1.2")]),
            Case("https://x.com/#anchor", "https://x.com/#anchor", [on(.url, "https://x.com/#anchor")]),
        ])
    }

    func testEmoji() {
        check([
            Case(":smile: :+1: :custom_thing: 10:30:45", "😄 👍 :custom_thing: 10:30:45", [at(.customEmoji(name: "custom_thing"), 6 ..< 20)]),
            Case(":heart: and :white_check_mark:", "\u{2764}\u{FE0F} and ✅"),
            Case(":thumbsup::-1:", "👍👎"),
            Case("a:smile: and :smile:b", "a:smile: and :smile:b"),
            Case("`:smile:`", ":smile:", [on(.code, ":smile:")]),
            Case(":100: :1234: :12345:", "💯 🔢 :12345:"),
            Case(":floppy_disk: :thinking: :thinking_face:", "💾 🤔 🤔"),
            Case(":+1_light_skin_tone: :wave_medium_dark_skin_tone:", "👍🏻 👋🏾"),
            Case(":flag-de: :man-woman-boy:", "🇩🇪 \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466}"),
            Case(":Smile:", "😄"),
            Case("**:fire: hot**", "🔥 hot", [on(.bold, "🔥 hot")]),
        ])
        XCTAssertGreaterThanOrEqual(EmojiTable.allNames.count, 3000)
        XCTAssertGreaterThanOrEqual(EmojiTable.allEmoji.count, 1800)
        for name in EmojiTable.allNames {
            let emoji = EmojiTable.unicode(forName: name) ?? ""
            XCTAssertFalse(emoji.isEmpty)
            XCTAssertFalse(emoji.unicodeScalars.allSatisfy { $0.isASCII }, name)
        }
    }

    func testEmojiNamesForUnicode() {
        XCTAssertEqual(EmojiTable.name(forUnicode: "👍"), "+1")
        XCTAssertEqual(EmojiTable.name(forUnicode: "\u{2764}\u{FE0F}"), "heart")
        XCTAssertEqual(EmojiTable.name(forUnicode: "\u{2764}"), "heart")
        // The names Mattermost clients send (checked against the 11.7 web app): `thinking_face`, not the alias.
        XCTAssertEqual(EmojiTable.name(forUnicode: "🤔"), "thinking_face")
        XCTAssertEqual(EmojiTable.name(forUnicode: "💾"), "floppy_disk")
        XCTAssertEqual(EmojiTable.name(forUnicode: "😆"), "laughing")
        XCTAssertEqual(EmojiTable.name(forUnicode: "👍🏽"), "+1_medium_skin_tone")
        XCTAssertFalse(EmojiTable.allEmoji.contains(where: { $0.emoji == "👍🏽" }), "skin tones resolve but are not listed")
        XCTAssertNil(EmojiTable.name(forUnicode: "x"))
        // Every emoji maps back to a name that maps to the same emoji.
        for (name, emoji) in EmojiTable.allEmoji {
            XCTAssertEqual(EmojiTable.name(forUnicode: emoji), name)
            XCTAssertEqual(EmojiTable.unicode(forName: name), emoji)
        }
        XCTAssertEqual(Set(EmojiTable.allEmoji.map { $0.emoji }).count, EmojiTable.allEmoji.count)
    }

    // MARK: Blocks

    func testBlockQuotes() {
        check([
            Case("> quoted\n> lines", "quoted\nlines", [on(.blockQuote, "quoted\nlines")]),
            Case("> **bold** quote", "bold quote", [on(.blockQuote, "bold quote"), on(.bold, "bold")]),
            Case("> outer\n>> inner", "outer\ninner", [on(.blockQuote, "outer\ninner")]),
            Case("before\n> quote\n\nafter", "before\nquote\n\nafter", [on(.blockQuote, "quote")]),
            Case("> quote\ncontinued lazily", "quote\ncontinued lazily", [on(.blockQuote, "quote\ncontinued lazily")]),
            Case(">no space", "no space", [on(.blockQuote, "no space")]),
        ])
    }

    func testEscaping() {
        check([
            Case("\\*not italic\\*", "*not italic*"),
            Case("\\@user \\#tag \\:smile:", "@user #tag :smile:"),
            Case("\\[not\\](a link)", "[not](a link)"),
            Case("a \\\\ b", "a \\ b"),
            Case("\\a stays", "\\a stays"),
            Case("\\# not a heading", "# not a heading"),
        ])
    }

    func testHeadings() {
        check([
            Case("# Heading\ntext", "Heading\ntext", [on(.bold, "Heading")]),
            Case("## **Big** title ##", "Big title", [on(.bold, "Big title")]),
            Case("### Heading with [link](https://x.com)", "Heading with link", [on(.bold, "Heading with link"), on(.textUrl(url: "https://x.com"), "link")]),
            Case("#hashtag at start", "#hashtag at start", [on(.hashtag, "#hashtag")]),
            Case("Title\n===\nbody", "Title\nbody", [on(.bold, "Title")]),
            Case("Subtitle\n---", "Subtitle", [on(.bold, "Subtitle")]),
            Case("####### seven", "####### seven"),
        ])
    }

    func testLists() {
        check([
            Case("- one\n- two\n  - nested\n- three", "• one\n• two\n  ◦ nested\n• three"),
            Case("* **bold** item\n+ other", "• bold item\n• other", [on(.bold, "bold")]),
            Case("1. a\n2. b\n3. c", "1. a\n2. b\n3. c"),
            Case("3. a\n4. b", "3. a\n4. b"),
            Case("1) paren\n1) again", "1. paren\n2. again"),
            Case("- [ ] todo\n- [x] done", "☐ todo\n☑ done"),
            Case("- item with\n  continuation", "• item with\n  continuation"),
            Case("Steps:\n1. first\n2. second", "Steps:\n1. first\n2. second"),
            Case("1. one\n   - sub\n2. two", "1. one\n   ◦ sub\n2. two"),
            Case("- `code` item", "• code item", [on(.code, "code")]),
            Case("-not a list", "-not a list"),
            Case("2020. A good year", "2020. A good year"),
        ])
    }

    func testTables() {
        check([
            Case("| a | b |\n|---|:-:|\n| 1 | 22 |\n| 333 | 4 |", "a   | b\n----+---\n1   | 22\n333 | 4", [on(.pre(language: nil), "a   | b\n----+---\n1   | 22\n333 | 4")]),
            Case("| **a** | `b` |\n|--|--|\n| c | d |", "a | b\n--+--\nc | d", [on(.pre(language: nil), "a | b\n--+--\nc | d")]),
            Case("Name | Value\n--- | ---\nx | 1\n\nafter", "Name | Value\n-----+------\nx    | 1\n\nafter", [on(.pre(language: nil), "Name | Value\n-----+------\nx    | 1")]),
            Case("a | b\nnot a table", "a | b\nnot a table"),
        ])
    }

    func testHorizontalRules() {
        check([
            Case("above\n\n---\n\nbelow", "above\n\n———\n\nbelow"),
            Case("***", "———"),
            Case("- - -", "———"),
            Case("___", "———"),
        ])
    }

    func testWhitespaceAndLineBreaks() {
        check([
            Case("Line one\nLine two", "Line one\nLine two"),
            Case("a\r\nb\r\n\r\n\r\nc", "a\nb\n\nc"),
            Case("  hi  ", "hi"),
            Case("a  \nb", "a\nb"),
            Case("a\\\nb", "a\nb"),
            Case("\n\nleading blank lines", "leading blank lines"),
            Case("tab\tinside", "tab\tinside"),
            Case("", ""),
        ])
    }

    // MARK: UTF-16 offsets

    func testUTF16OffsetsWithNonBMPCharacters() {
        check([
            // 👍🏽 is two scalars of two UTF-16 units each.
            Case("👍🏽 **hi**", "👍🏽 hi", [at(.bold, 5 ..< 7)]),
            Case("Привет, **мир**!", "Привет, мир!", [at(.bold, 8 ..< 11)]),
            Case("𝒳 *a* 😀 `b`", "𝒳 a 😀 b", [at(.italic, 3 ..< 4), at(.code, 8 ..< 9)]),
            // A ZWJ family is 8 UTF-16 units.
            Case("**bold** 👨‍👩‍👧 [link](https://x.com)", "bold 👨‍👩‍👧 link", [at(.bold, 0 ..< 4), at(.textUrl(url: "https://x.com"), 14 ..< 18)]),
            Case(":smile: @bob", "😄 @bob", [at(.mention(username: "bob"), 3 ..< 7)]),
            Case("> 🇺🇦 **так**", "🇺🇦 так", [at(.blockQuote, 0 ..< 8), at(.bold, 5 ..< 8)]),
            Case("- 😀 item\n- **b**", "• 😀 item\n• b", [at(.bold, 12 ..< 13)]),
        ])
        // Cross-check every offset with NSString.
        let result = MattermostMarkdown.parse("🎉 **Привет** _мир_ 👍🏽 [ссылка](https://x.com) @user")
        let string = result.text as NSString
        let covered = result.entities.map { string.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
        XCTAssertEqual(covered, ["Привет", "мир", "ссылка", "@user"])
    }

    // MARK: Robustness

    func testPathologicalInputsStayFast() {
        let manyOpeners = String(repeating: "**a ", count: 3000)
        let manyBackticks = String(repeating: "`a ``b ", count: 2000)
        let manyBrackets = String(repeating: "[", count: 3000) + String(repeating: "]", count: 3000)
        let unmatchedBackticks = String(repeating: "`` x ", count: 3000) + "`"
        let veryDeepQuotes = String(repeating: ">", count: 5000) + " deep"
        let veryDeepLists = String(repeating: "- ", count: 2000) + "x"
        let start = Date()
        for input in [manyOpeners, manyBackticks, manyBrackets, unmatchedBackticks, veryDeepQuotes, veryDeepLists] {
            let result = MattermostMarkdown.parse(input)
            XCTAssertFalse(result.text.isEmpty)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        // Nested quotes below the nesting cap flatten to one block quote.
        let deepQuotes = String(repeating: ">", count: 20) + " deep"
        XCTAssertEqual(MattermostMarkdown.parse(deepQuotes), FormattedText(text: "deep", entities: [TextEntity(range: 0 ..< 4, type: .blockQuote)]))
    }

    func testEntitiesAreValidForRandomInput() {
        var rng = SeededGenerator(seed: 42)
        let alphabet = Array("ab _*~`[]()<>@#:!\\\n>-|1.😀й")
        for _ in 0 ..< 2000 {
            let length = Int(rng.next() % 40)
            let input = String((0 ..< length).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
            let result = MattermostMarkdown.parse(input)
            let count = result.text.utf16.count
            for entity in result.entities {
                XCTAssertTrue(entity.range.lowerBound >= 0 && entity.range.upperBound <= count && !entity.range.isEmpty, "\(input.debugDescription) → \(result)")
            }
            XCTAssertEqual(result.entities, FormattedText.sortedEntities(result.entities))
        }
    }

    // MARK: Entities → markdown

    func testComposerEntitiesToMarkdown() {
        let cases: [(FormattedText, String, UInt)] = [
            (FormattedText(text: "hello bold world", entities: [TextEntity(range: 6 ..< 10, type: .bold)]), "hello **bold** world", #line),
            (FormattedText(text: "snakecase", entities: [TextEntity(range: 5 ..< 9, type: .italic)]), "snake*case*", #line),
            (FormattedText(text: "an italic word", entities: [TextEntity(range: 3 ..< 9, type: .italic)]), "an _italic_ word", #line),
            (FormattedText(text: "a b c", entities: [TextEntity(range: 0 ..< 5, type: .bold), TextEntity(range: 2 ..< 3, type: .italic)]), "**a _b_ c**", #line),
            (FormattedText(text: "gone", entities: [TextEntity(range: 0 ..< 4, type: .strikethrough)]), "~~gone~~", #line),
            (FormattedText(text: "run code now", entities: [TextEntity(range: 4 ..< 8, type: .code)]), "run `code` now", #line),
            (FormattedText(text: "tick`in", entities: [TextEntity(range: 0 ..< 7, type: .code)]), "``tick`in``", #line),
            (FormattedText(text: "`x`", entities: [TextEntity(range: 0 ..< 3, type: .code)]), "`` `x` ``", #line),
            (FormattedText(text: "intro\nlet x = 1\nouter", entities: [TextEntity(range: 6 ..< 15, type: .pre(language: "swift"))]), "intro\n```swift\nlet x = 1\n```\nouter", #line),
            (FormattedText(text: "inline pre here", entities: [TextEntity(range: 7 ..< 10, type: .pre(language: nil))]), "inline \n```\npre\n```\n here", #line),
            (FormattedText(text: "has ``` fence", entities: [TextEntity(range: 0 ..< 13, type: .pre(language: nil))]), "````\nhas ``` fence\n````", #line),
            (FormattedText(text: "click here please", entities: [TextEntity(range: 6 ..< 10, type: .textUrl(url: "https://x.com/a_(b)")), TextEntity(range: 6 ..< 10, type: .bold)]), "click [**here**](https://x.com/a_(b)) please", #line),
            (FormattedText(text: "odd link", entities: [TextEntity(range: 0 ..< 3, type: .textUrl(url: "https://x.com/a b)"))]), "[odd](<https://x.com/a b)>) link", #line),
            (FormattedText(text: "[x] link", entities: [TextEntity(range: 0 ..< 8, type: .textUrl(url: "https://x.com"))]), "[\\[x\\] link](https://x.com)", #line),
            (FormattedText(text: "bold \nnext", entities: [TextEntity(range: 0 ..< 10, type: .bold)]), "**bold** \n**next**", #line),
            (FormattedText(text: "👍🏽 hi", entities: [TextEntity(range: 5 ..< 7, type: .bold)]), "👍🏽 **hi**", #line),
            (FormattedText(text: "plain **typed** markdown", entities: []), "plain **typed** markdown", #line),
            (FormattedText(text: "under @bob", entities: [TextEntity(range: 0 ..< 5, type: .underline), TextEntity(range: 6 ..< 10, type: .mention(username: "bob"))]), "under @bob", #line),
            (FormattedText(text: "overlap here", entities: [TextEntity(range: 0 ..< 7, type: .bold), TextEntity(range: 3 ..< 12, type: .italic)]), "**ove*rlap*** _here_", #line),
            (FormattedText(text: "split", entities: [TextEntity(range: 0 ..< 1, type: .bold), TextEntity(range: 1 ..< 5, type: .italic)]), "**s***plit*", #line),
        ]
        for (formatted, markdown, line) in cases {
            XCTAssertEqual(MattermostMarkdown.markdown(from: formatted), markdown, line: line)
        }
    }

    func testRoundTripThroughMarkdown() {
        let inputs = [
            "hello **bold** world",
            "*italic* text and _more_",
            "~~gone~~ for good",
            "run `code` now",
            "``a`b``",
            "```swift\nlet x = 1\n```",
            "before\n```\ncode\n```\nafter",
            "[link](https://example.com) and [other](https://x.com/a_(b))",
            "**bold _italic_ bold**",
            "[**bold link**](https://x.com/path)",
            "**[bold link](https://x.com/path)**",
            "snake*case* and snake_case_name",
            "Привет **мир** 👍🏽 *ok*",
            "multi\nline **bold**\n_end_",
            "***both***",
            "**a** *b* ~~c~~ `d`",
            "mention @bob and #tag and https://plain.url stay",
        ]
        for input in inputs {
            let parsed = MattermostMarkdown.parse(input)
            let markdown = MattermostMarkdown.markdown(from: parsed)
            let reparsed = MattermostMarkdown.parse(markdown)
            XCTAssertEqual(reparsed, parsed, "\(input.debugDescription) → \(markdown.debugDescription)")
        }

        // Random composer output: bold/italic/strike/code/link over words of random text.
        var rng = SeededGenerator(seed: 7)
        let words = ["alpha", "beta", "гамма", "😀", "delta", "ok", "x1", "snake_case"]
        let kinds: [TextEntityType] = [.bold, .italic, .strikethrough, .code, .textUrl(url: "https://example.com/p")]
        for _ in 0 ..< 500 {
            let count = 1 + Int(rng.next() % 6)
            var text = ""
            var wordRanges: [Range<Int>] = []
            for index in 0 ..< count {
                if index > 0 {
                    text += " "
                }
                let word = words[Int(rng.next() % UInt64(words.count))]
                let start = text.utf16.count
                text += word
                wordRanges.append(start ..< text.utf16.count)
            }
            // Non-overlapping word-aligned entities, possibly two kinds on the same words.
            var entities: [TextEntity] = []
            var index = 0
            while index < wordRanges.count {
                let length = 1 + Int(rng.next() % 2)
                let end = min(wordRanges.count, index + length)
                if rng.next() % 2 == 0 {
                    let range = wordRanges[index].lowerBound ..< wordRanges[end - 1].upperBound
                    let kind = kinds[Int(rng.next() % UInt64(kinds.count))]
                    entities.append(TextEntity(range: range, type: kind))
                    if kind != .code && rng.next() % 3 == 0 {
                        let inner: [TextEntityType] = [.bold, .italic, .strikethrough].filter { $0 != kind }
                        entities.append(TextEntity(range: range, type: inner[Int(rng.next() % UInt64(inner.count))]))
                    }
                }
                index = end
            }
            let formatted = FormattedText(text: text, entities: FormattedText.sortedEntities(entities))
            let markdown = MattermostMarkdown.markdown(from: formatted)
            let reparsed = MattermostMarkdown.parse(markdown)
            XCTAssertEqual(reparsed.text, formatted.text, markdown)
            let composerTypes = reparsed.entities.filter { entity in
                switch entity.type {
                case .bold, .italic, .strikethrough, .code, .textUrl:
                    return true
                default:
                    return false
                }
            }
            XCTAssertEqual(composerTypes, formatted.entities, markdown)
        }
    }
}

final class EmojiSearchTests: XCTestCase {
    func testRanksExactThenPrefixThenSubstring() {
        let results = EmojiTable.search("smile")
        XCTAssertEqual(results.first?.name, "smile")
        XCTAssertEqual(results.first?.emoji, "😄")
        let names = results.map(\.name)
        // `smiley` starts with the query; `sweat_smile` only contains it.
        let prefix = try! XCTUnwrap(names.firstIndex(of: "smiley"))
        let substring = try! XCTUnwrap(names.firstIndex(of: "sweat_smile"))
        XCTAssertLessThan(prefix, substring)
    }

    func testOneEntryPerEmojiAndNoSkinTones() {
        let results = EmojiTable.search("thumbs")
        XCTAssertEqual(Set(results.map(\.emoji)).count, results.count)
        XCTAssertFalse(results.contains(where: { $0.name.contains("skin_tone") }))
        // 👍's first name is `+1`; the matching alias is the one shown.
        XCTAssertTrue(results.contains(where: { $0.name == "thumbsup" && $0.emoji == "👍" }))
    }

    func testLimitCaseAndEmptyQuery() {
        XCTAssertEqual(EmojiTable.search("a", limit: 5).count, 5)
        XCTAssertEqual(EmojiTable.search("SMILE").first?.name, "smile")
        XCTAssertTrue(EmojiTable.search("").isEmpty)
        XCTAssertTrue(EmojiTable.search("zzzzqqq").isEmpty)
    }
}
