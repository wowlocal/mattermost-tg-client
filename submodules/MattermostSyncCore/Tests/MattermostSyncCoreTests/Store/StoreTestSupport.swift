import Foundation
import XCTest
@testable import MattermostSyncCore

/// A directory under the system temp directory, removed on `deinit`.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("MattermostSyncCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ name: String) -> String {
        return url.appendingPathComponent(name).path
    }
}

extension SQLiteMattermostSyncStore: InspectableMessageIdStore {
    var operationRunner: OperationRunner? {
        return { body in
            try self.transaction { _ in
                try body()
            }
        }
    }

    func reopened() throws -> any InspectableMessageIdStore {
        close()
        return try SQLiteMattermostSyncStore(path: path)
    }
}

/// The allocator scenarios against the SQLite store, each `apply` as its own transaction. Every
/// store a test created is checked, closed and reopened in `tearDown`.
final class SQLiteMessageIdAllocatorTests: MessageIdAllocatorTests {
    private var directory: TemporaryDirectory?
    private var stores: [SQLiteMattermostSyncStore] = []

    override func makeStore() throws -> any InspectableMessageIdStore {
        if directory == nil {
            directory = try TemporaryDirectory()
        }
        let store = try SQLiteMattermostSyncStore(path: directory!.path("store-\(stores.count).sqlite"))
        stores.append(store)
        return store
    }

    override func tearDownWithError() throws {
        for store in stores {
            XCTAssertNil(store.messageIdError)
            let entries = store.allEntries(channelId: channel)
            let islands = store.islands(channelId: channel)
            store.close()
            let reopened = try SQLiteMattermostSyncStore(path: store.path)
            XCTAssertEqual(reopened.allEntries(channelId: channel), entries)
            XCTAssertEqual(reopened.islands(channelId: channel), islands)
            XCTAssertEqual(reopened.validate(channelId: channel), [])
        }
        stores = []
        directory = nil
        try super.tearDownWithError()
    }
}

/// The property tests against the SQLite store, each operation as one `transaction`.
final class SQLiteMessageIdPropertyTests: MessageIdPropertyTests {
    private var directory: TemporaryDirectory?
    private var count = 0

    override func makeStore() throws -> any InspectableMessageIdStore {
        if directory == nil {
            directory = try TemporaryDirectory()
        }
        count += 1
        return try SQLiteMattermostSyncStore(path: directory!.path("store-\(count).sqlite"))
    }

    override func tearDownWithError() throws {
        directory = nil
        try super.tearDownWithError()
    }
}
