import XCTest
import MattermostKit
import MattermostSyncCore
@testable import MattermostShare

final class MattermostSharePlannerTests: XCTestCase {
    private func file(_ name: String) -> MattermostShareFile {
        return MattermostShareFile(fileName: name, mimeType: "text/plain", content: .data(Data(name.utf8)))
    }

    func testTextAndLinkMakeOneMessage() {
        let posts = MattermostSharePlanner.posts(comment: " Look at this ", content: MattermostShareContent(texts: ["Release notes", "https://example.com/notes", "", "https://example.com/notes"]))
        XCTAssertEqual(posts, [MattermostSharePost(message: "Look at this\n\nRelease notes\n\nhttps://example.com/notes", files: [])])
    }

    func testFilesCarryTheMessageOnTheFirstPost() {
        let files = (1 ... 12).map { file("f\($0).txt") }
        let posts = MattermostSharePlanner.posts(comment: "batch", content: MattermostShareContent(files: files))
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].message, "batch")
        XCTAssertEqual(posts[0].files.map(\.fileName), (1 ... 10).map { "f\($0).txt" })
        XCTAssertEqual(posts[1].message, "")
        XCTAssertEqual(posts[1].files.map(\.fileName), ["f11.txt", "f12.txt"])
    }

    func testFilesWithoutText() {
        let posts = MattermostSharePlanner.posts(comment: "", content: MattermostShareContent(files: [file("a.png")]))
        XCTAssertEqual(posts, [MattermostSharePost(message: "", files: [file("a.png")])])
        XCTAssertTrue(MattermostSharePlanner.posts(comment: "  ", content: MattermostShareContent()).isEmpty)
    }

    func testLongMessageIsCut() {
        let posts = MattermostSharePlanner.posts(comment: String(repeating: "x", count: 25), content: MattermostShareContent(files: [file("a")]), maxMessageLength: 10)
        XCTAssertEqual(posts.map(\.message), ["xxxxxxxxxx", "xxxxxxxxxx", "xxxxx"])
        XCTAssertEqual(posts.map(\.files.count), [0, 0, 1])
    }

    func testFileSize() throws {
        XCTAssertEqual(file("abc").size, 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("share-size-\(UUID().uuidString).bin")
        try Data(count: 1234).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(MattermostShareFile(fileName: "b", mimeType: "application/octet-stream", content: .file(url)).size, 1234)
    }
}

final class MattermostShareResolverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MattermostShareTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(accountId: Int64) throws -> SQLiteMattermostSyncStore {
        let path = root.path + "/" + MattermostShareAccounts.directoryName(accountId: accountId) + "/mattermost/sync.sqlite"
        return try SQLiteMattermostSyncStore(path: path)
    }

    func testAccountsAreReadFromTheirStores() throws {
        let negative: Int64 = -5210620941853878407
        let store = try makeStore(accountId: negative)
        try store.setServerInfo(MattermostServerInfo(url: "http://localhost:8065", userId: "alice-id", siteName: "Dev"))
        try store.setCursor("own_username", "alice")
        store.close()
        let other = try makeStore(accountId: 42)
        try other.setServerInfo(MattermostServerInfo(url: "https://mm.example.com", userId: "bob-id"))
        other.close()
        // A Telegram account directory without a Mattermost store.
        try FileManager.default.createDirectory(atPath: root.path + "/account-7/postbox", withIntermediateDirectories: true)

        XCTAssertEqual(MattermostShareAccounts.directoryName(accountId: negative), "account-13236123131855673209")
        let accounts = MattermostShareAccounts.all(rootPath: root.path)
        XCTAssertEqual(accounts.map(\.accountId), [negative, 42])
        XCTAssertEqual(accounts[0].userId, "alice-id")
        XCTAssertEqual(accounts[0].username, "alice")
        XCTAssertEqual(accounts[0].siteName, "Dev")
        XCTAssertNil(MattermostShareAccounts.account(rootPath: root.path, accountId: 7))
    }

    func testTargets() throws {
        let store = try makeStore(accountId: 1)
        let channel = try store.allocatePeer(mattermostId: "chan-1", kind: .channel, teamId: "team-1")
        let gm = try store.allocatePeer(mattermostId: "gm-1", kind: .groupMessage)
        let carol = try store.allocatePeer(mattermostId: "carol-id", kind: .user)
        let dave = try store.allocatePeer(mattermostId: "dave-id", kind: .user)
        try store.setDirectChannel(channelId: "dm-carol", userId: "carol-id")

        XCTAssertEqual(MattermostShareResolver.target(namespace: .channel, peerIdValue: channel.peerId, store: store), .channel(id: "chan-1"))
        XCTAssertEqual(MattermostShareResolver.target(namespace: .channel, peerIdValue: gm.peerId, store: store), .channel(id: "gm-1"))
        XCTAssertEqual(MattermostShareResolver.target(namespace: .user, peerIdValue: carol.peerId, store: store), .channel(id: "dm-carol"))
        XCTAssertEqual(MattermostShareResolver.target(namespace: .user, peerIdValue: dave.peerId, store: store), .directMessage(userId: "dave-id"))
        XCTAssertNil(MattermostShareResolver.target(namespace: .user, peerIdValue: 999_999, store: store))
        store.close()
    }

    func testThreadRoot() throws {
        var store = try makeStore(accountId: 2)
        let allocator = MessageIdAllocator()
        let keys = [PostOrderKey(createAt: 1000, postId: "root-post"), PostOrderKey(createAt: 2000, postId: "reply-post")]
        try store.transaction { store in
            for key in keys {
                _ = try allocator.insertPost(key, channelId: "chan-1", store: &store)
            }
        }
        let entries = store.entries(channelId: "chan-1", postIds: ["root-post", "reply-post"])
        let rootLocalId = try XCTUnwrap(entries["root-post"]).localId
        XCTAssertEqual(MattermostShareResolver.rootPostId(channelId: "chan-1", threadLocalId: Int64(rootLocalId), store: store), "root-post")
        XCTAssertNil(MattermostShareResolver.rootPostId(channelId: "chan-1", threadLocalId: Int64(rootLocalId) - 1, store: store), "an id without a post")
        XCTAssertNil(MattermostShareResolver.rootPostId(channelId: "chan-1", threadLocalId: Int64(Int32.max) + 1, store: store))
        store.close()
    }
}

/// Against the local dev server. Skipped unless `MM_INTEGRATION=1` (password from `infra/dev-server/.env`).
/// Shares as dave into ~relay-3f-share (created and joined if missing): a text with a link, two files, a reply in the
/// thread of the shared post, and a DM to carol (created if needed).
final class MattermostShareIntegrationTests: XCTestCase {
    private func devServerPassword() throws -> String {
        let envFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("infra/dev-server/.env")
        let contents = try String(contentsOf: envFile, encoding: .utf8)
        for line in contents.split(separator: "\n") where line.hasPrefix("SEED_USER_PASSWORD=") {
            return String(line.dropFirst("SEED_USER_PASSWORD=".count))
        }
        throw XCTSkip("no SEED_USER_PASSWORD")
    }

    func testShareTextFilesThreadAndDirectMessage() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MM_INTEGRATION"] == "1", "Set MM_INTEGRATION=1 to run against a live server")
        let client = MattermostClient(serverURL: URL(string: ProcessInfo.processInfo.environment["MM_URL"] ?? "http://localhost:8065")!, userAgent: "MattermostShareTests")
        let login = try await client.login(loginId: "dave", password: try devServerPassword())
        let sender = MattermostShareSender(client: client, userId: login.user.id)
        let teams = try await client.teams()
        let team = try XCTUnwrap(teams.first(where: { $0.name == "engineering" }))
        let sandbox: Channel
        if let existing = try? await client.channel(teamId: team.id, name: "relay-3f-share") {
            sandbox = existing
            _ = try? await client.addChannelMember(channelId: existing.id, userId: login.user.id)
        } else {
            sandbox = try await client.createChannel(ChannelDraft(teamId: team.id, name: "relay-3f-share", displayName: "3F Share"))
        }

        let stamp = Int(Date().timeIntervalSince1970)
        let content = MattermostShareContent(texts: ["3F share test \(stamp)", "https://example.com/\(stamp)"], files: [
            MattermostShareFile(fileName: "share-\(stamp).txt", mimeType: "text/plain", content: .data(Data("shared text file \(stamp)".utf8))),
            MattermostShareFile(fileName: "share-\(stamp).csv", mimeType: "text/csv", content: .data(Data("a,b\n1,2\n".utf8)))
        ])
        let progress = ProgressRecorder()
        let posts = try await sender.send(MattermostSharePlanner.posts(comment: "", content: content), channelId: try await sender.channelId(for: .channel(id: sandbox.id)), progress: { progress.add($0) })
        XCTAssertEqual(posts.count, 1)
        let post = try await client.post(id: posts[0].id)
        XCTAssertEqual(post.channelId, sandbox.id)
        XCTAssertEqual(post.message, "3F share test \(stamp)\n\nhttps://example.com/\(stamp)")
        XCTAssertEqual(post.fileIds.count, 2)
        XCTAssertEqual(progress.values.last, 1.0)

        let replies = try await sender.send([MattermostSharePost(message: "reply \(stamp)", files: [])], channelId: sandbox.id, rootId: post.id)
        let reply = try await client.post(id: replies[0].id)
        XCTAssertEqual(reply.rootId, post.id)

        let carol = try await client.users(usernames: ["carol"]).first
        let dm = try await sender.channelId(for: .directMessage(userId: try XCTUnwrap(carol).id))
        let dmPosts = try await sender.send([MattermostSharePost(message: "dm \(stamp)", files: [])], channelId: dm)
        let dmPost = try await client.post(id: dmPosts[0].id)
        XCTAssertEqual(dmPost.channelId, dm)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    func add(_ value: Double) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
