import XCTest
@testable import MattermostSyncCore

final class SearchQueryTests: XCTestCase {
    func testTokenizeModifiersPhrasesExclusions() {
        XCTAssertEqual(SearchQuery.tokenize(#"from:bob in:town-square "release notes" deploy* -staging #release @alice"#), [
            .modifier(name: "from", value: "bob"),
            .modifier(name: "in", value: "town-square"),
            .phrase("release notes"),
            .word("deploy*"),
            .excluded("staging"),
            .hashtag("release"),
            .mention("alice")
        ])
        XCTAssertEqual(SearchQuery.tokenize(#"before:2014-01-01 After:2013-01-01 on:2013-06-01 -"two words" ext:pdf"#), [
            .modifier(name: "before", value: "2014-01-01"),
            .modifier(name: "after", value: "2013-01-01"),
            .modifier(name: "on", value: "2013-06-01"),
            .excluded("two words"),
            .modifier(name: "ext", value: "pdf")
        ])
    }

    func testTokenizeEdgeCases() {
        XCTAssertEqual(SearchQuery.tokenize(""), [])
        XCTAssertEqual(SearchQuery.tokenize("   "), [])
        // Not a known modifier, an empty modifier value, a lone dash, an unterminated quote.
        XCTAssertEqual(SearchQuery.tokenize("http://x.y from: - \"open ended"), [
            .word("http://x.y"),
            .word("from:"),
            .word("-"),
            .phrase("open ended")
        ])
        XCTAssertEqual(SearchQuery.tokenize("# @ \"\""), [.word("#"), .word("@")])
        XCTAssertTrue(SearchQuery.isEmpty(" \"\" "))
        XCTAssertFalse(SearchQuery.isEmpty("from:bob"))
    }

    func testHighlightTerms() {
        XCTAssertEqual(SearchQuery.highlightTerms(#"from:bob "release notes" deploy* -staging #release"#), ["release notes", "deploy", "#release"])
        XCTAssertEqual(SearchQuery.highlightText("in:firehose before:2014-01-01 nightly"), "nightly")
        XCTAssertEqual(SearchQuery.highlightText("from:bob"), "")
    }

    func testTermsWithScope() {
        XCTAssertEqual(SearchQuery.terms(query: " deploy ", inChannels: ["c1"]), "deploy in:c1")
        XCTAssertEqual(SearchQuery.terms(query: "", inChannels: ["c1"], fromUsernames: ["bob"]), "in:c1 from:bob")
        // 2013-06-01 00:00 UTC and 2013-06-30 23:59 UTC: the days around them, both exclusive.
        XCTAssertEqual(SearchQuery.terms(query: "x", minDate: 1370044800, maxDate: 1372636740), "x after:2013-05-31 before:2013-07-01")
        // Telegram's "no upper bound".
        XCTAssertEqual(SearchQuery.terms(query: "x", minDate: 0, maxDate: Int64(Int32.max)), "x")
    }

    func testDayUsesTheSearchTimeZone() {
        // 2013-06-01 23:30 UTC is already June 2nd in UTC+2.
        XCTAssertEqual(SearchQuery.day(1370129400, secondsFromGMT: 0), "2013-06-01")
        XCTAssertEqual(SearchQuery.day(1370129400, secondsFromGMT: 7200), "2013-06-02")
    }

    func testMentionTerms() {
        XCTAssertEqual(SearchQuery.mentionTerms(username: "alice", firstName: "Alice", notifyProps: ["first_name": "false", "mention_keys": ""]), "@alice")
        XCTAssertEqual(
            SearchQuery.mentionTerms(username: "alice", firstName: "Alice", notifyProps: ["first_name": "true", "mention_keys": "relay,@alice, release team,@channel", "channel": "true"]),
            #"@alice Alice relay "release team""#
        )
        XCTAssertEqual(SearchQuery.mentionKeys(username: "", firstName: "", notifyProps: [:]), [])
    }
}
