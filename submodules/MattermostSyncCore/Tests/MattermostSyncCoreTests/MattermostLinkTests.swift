import XCTest
@testable import MattermostSyncCore

final class MattermostLinkTests: XCTestCase {
    private let postId = "3887mtmf4pdq7p9b84wazfi4ke"
    private let servers = ["http://localhost:8065", "https://chat.example.com", "https://example.org/mattermost/"]

    private func parse(_ string: String) -> MattermostLink? {
        return MattermostLink.parse(string, servers: self.servers)
    }

    func testWebPermalinks() {
        XCTAssertEqual(parse("http://localhost:8065/engineering/pl/\(postId)"), MattermostLink(serverIndex: 0, route: .post(teamName: "engineering", postId: postId)))
        XCTAssertEqual(parse("https://chat.example.com/eng/pl/\(postId)"), MattermostLink(serverIndex: 1, route: .post(teamName: "eng", postId: postId)))
        XCTAssertEqual(parse("https://CHAT.example.com/eng/pl/\(postId)?view=1#x"), MattermostLink(serverIndex: 1, route: .post(teamName: "eng", postId: postId)))
        XCTAssertEqual(parse("https://chat.example.com:443/eng/pl/\(postId)"), MattermostLink(serverIndex: 1, route: .post(teamName: "eng", postId: postId)))
        // Scheme-independent: http on the default port of an https server's host doesn't match (port 80 ≠ 443).
        XCTAssertNil(parse("http://chat.example.com/eng/pl/\(postId)"))
        XCTAssertEqual(parse("http://localhost:8065/_redirect/pl/\(postId)"), MattermostLink(serverIndex: 0, route: .post(teamName: nil, postId: postId)))
        // A server under a path.
        XCTAssertEqual(parse("https://example.org/mattermost/eng/pl/\(postId)"), MattermostLink(serverIndex: 2, route: .post(teamName: "eng", postId: postId)))
        XCTAssertNil(parse("https://example.org/eng/pl/\(postId)"))
        XCTAssertNil(parse("https://example.org/mattermostx/eng/pl/\(postId)"))
    }

    func testOtherRoutes() {
        XCTAssertEqual(parse("http://localhost:8065/engineering/channels/town-square")?.route, .channel(teamName: "engineering", channelName: "town-square"))
        XCTAssertEqual(parse("http://localhost:8065/_redirect/channels/off-topic")?.route, .channel(teamName: nil, channelName: "off-topic"))
        XCTAssertEqual(parse("http://localhost:8065/engineering/messages/@Bob")?.route, .directMessage(teamName: "engineering", username: "bob"))
        XCTAssertEqual(parse("http://localhost:8065/engineering/messages/5f2b1c0e6a7d8e9f0a1b2c3d4e5f60718293a4b5")?.route, .groupMessage(teamName: "engineering", channelName: "5f2b1c0e6a7d8e9f0a1b2c3d4e5f60718293a4b5"))
        XCTAssertEqual(parse("http://localhost:8065/engineering/threads/\(postId)")?.route, .thread(teamName: "engineering", rootId: postId))
    }

    func testNotLinksIntoTheServer() {
        XCTAssertNil(parse("https://other.example.com/eng/pl/\(postId)"))
        XCTAssertNil(parse("http://localhost:8066/engineering/pl/\(postId)"))
        XCTAssertNil(parse("http://localhost:8065/engineering/pl/short"))
        XCTAssertNil(parse("http://localhost:8065/engineering/pl/\(postId.uppercased())"))
        XCTAssertNil(parse("http://localhost:8065/api/v4/posts/\(postId)"))
        XCTAssertNil(parse("http://localhost:8065/engineering"))
        XCTAssertNil(parse("http://localhost:8065/"))
        XCTAssertNil(parse("http://localhost:8065/static/images/logo.png"))
        XCTAssertNil(parse("http://localhost:8065/Bad Team/pl/\(postId)"))
        XCTAssertNil(parse("ftp://localhost:8065/engineering/pl/\(postId)"))
        XCTAssertNil(parse("mailto:alice@example.com"))
        XCTAssertNil(parse("not a url"))
        XCTAssertNil(MattermostLink.parse("http://localhost:8065/engineering/pl/\(postId)", servers: []))
    }

    func testAppSchemeLinks() {
        XCTAssertEqual(parse("relay://localhost:8065/engineering/pl/\(postId)"), MattermostLink(serverIndex: 0, route: .post(teamName: "engineering", postId: postId)))
        XCTAssertEqual(parse("relay://chat.example.com/eng/channels/town-square"), MattermostLink(serverIndex: 1, route: .channel(teamName: "eng", channelName: "town-square")))
        XCTAssertEqual(parse("mattermost://chat.example.com/eng/pl/\(postId)"), MattermostLink(serverIndex: 1, route: .post(teamName: "eng", postId: postId)))
        XCTAssertEqual(parse("relay://example.org/mattermost/eng/messages/@alice"), MattermostLink(serverIndex: 2, route: .directMessage(teamName: "eng", username: "alice")))
        // Telegram's own app-scheme links (the widget's `relay://localpeer`, `relay://resolve?domain=`) are not ours.
        XCTAssertNil(parse("relay://localpeer?id=123"))
        XCTAssertNil(parse("relay://resolve?domain=durov"))
        XCTAssertNil(parse("relay://localhost:9999/engineering/pl/\(postId)"))
    }

    func testAppSchemeWithoutPortPrefersDefaultPortServer() {
        let servers = ["http://chat.example.com:8065", "https://chat.example.com"]
        XCTAssertEqual(MattermostLink.parse("relay://chat.example.com/eng/pl/\(postId)", servers: servers)?.serverIndex, 1)
        XCTAssertEqual(MattermostLink.parse("relay://chat.example.com:8065/eng/pl/\(postId)", servers: servers)?.serverIndex, 0)
        // The only server on that host matches even on another port.
        XCTAssertEqual(MattermostLink.parse("relay://chat.example.com/eng/pl/\(postId)", servers: ["http://chat.example.com:8065"])?.serverIndex, 0)
    }

    func testBuildingLinks() {
        XCTAssertEqual(MattermostLink.permalink(serverURL: "http://localhost:8065/", teamName: "engineering", postId: postId), "http://localhost:8065/engineering/pl/\(postId)")
        XCTAssertEqual(MattermostLink.permalink(serverURL: "https://example.org/mattermost", teamName: "eng", postId: postId), "https://example.org/mattermost/eng/pl/\(postId)")
        XCTAssertEqual(MattermostLink.appLink(webLink: "http://localhost:8065/engineering/pl/\(postId)"), "relay://localhost:8065/engineering/pl/\(postId)")
        XCTAssertEqual(MattermostLink.appLink(webLink: "https://chat.example.com:443/eng/pl/\(postId)"), "relay://chat.example.com/eng/pl/\(postId)")
        XCTAssertNil(MattermostLink.appLink(webLink: "relay://chat.example.com/eng/pl/\(postId)"))
        // Round trip: a built link parses back to its route.
        for server in servers {
            let link = MattermostLink.permalink(serverURL: server, teamName: "eng", postId: postId)
            XCTAssertEqual(MattermostLink.parse(link, servers: servers)?.route, .post(teamName: "eng", postId: postId), link)
            let app = MattermostLink.appLink(webLink: link)!
            XCTAssertEqual(MattermostLink.parse(app, servers: servers)?.route, .post(teamName: "eng", postId: postId), app)
        }
    }
}
