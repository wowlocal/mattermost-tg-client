import XCTest
import Postbox
import SwiftSignalKit
@testable import TelegramCore

/// `cleanupStaleAccountDirectories` judges the `account-*` directories against the account manager as it
/// is when they are listed. Judging them against the records view that triggered the sweep deleted a
/// new account's directory under its open database (TestFlight 1.0.0 (31868)).
final class AccountDirectoryCleanupTests: XCTestCase {
    private static let logger: Logger = {
        let path = NSTemporaryDirectory() + "account-directory-cleanup-tests-\(getpid())"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let logger = Logger(rootPath: path, basePath: path)
        logger.logToFile = false
        logger.logToConsole = false
        return logger
    }()

    private var rootPath: String!
    private var accountManager: AccountManager<TelegramAccountManagerTypes>!

    override func setUp() {
        super.setUp()
        Logger.setSharedLogger(AccountDirectoryCleanupTests.logger)
        self.rootPath = NSTemporaryDirectory() + "account-directory-cleanup-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: self.rootPath, withIntermediateDirectories: true)
        self.accountManager = AccountManager(basePath: self.rootPath + "/accounts-metadata", isTemporary: true, isReadOnly: false, useCaches: false, removeDatabaseOnError: true, accessChallenge: AccountManagerAccessChallenge(prepare: { _ in
        }, resolve: { current, _ in
            return current
        }, finishInitialization: {
        }))
    }

    override func tearDown() {
        self.accountManager = nil
        try? FileManager.default.removeItem(atPath: self.rootPath)
        super.tearDown()
    }

    private func wait<T>(_ signal: Signal<T, NoError>) -> T? {
        let result = Atomic<T?>(value: nil)
        let done = DispatchSemaphore(value: 0)
        let disposable = (signal |> take(1)).start(next: { value in
            let _ = result.swap(value)
        }, completed: {
            done.signal()
        })
        let _ = done.wait(timeout: .now() + 10.0)
        disposable.dispose()
        return result.with { $0 }
    }

    private func sweep() {
        let done = DispatchSemaphore(value: 0)
        let disposable = cleanupStaleAccountDirectories(accountManager: self.accountManager, rootPath: self.rootPath).start(completed: {
            done.signal()
        })
        XCTAssertEqual(done.wait(timeout: .now() + 10.0), .success, "the sweep did not finish")
        disposable.dispose()
    }

    /// An account directory with something in it, as a postbox leaves it.
    @discardableResult
    private func makeDirectory(_ id: AccountRecordId) -> String {
        let path = self.rootPath + "/" + accountRecordIdPathName(id)
        try? FileManager.default.createDirectory(atPath: path + "/postbox/db", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path + "/postbox/db/db_sqlite", contents: Data([1, 2, 3]))
        return path
    }

    private func exists(_ id: AccountRecordId) -> Bool {
        return FileManager.default.fileExists(atPath: self.rootPath + "/" + accountRecordIdPathName(id))
    }

    func testOnlyDirectoriesOfNoAccountAreDeleted() {
        guard let (recordId, authId) = self.wait(self.accountManager.transaction { transaction -> (AccountRecordId, AccountRecordId) in
            let recordId = transaction.createRecord([])
            let authId = transaction.createAuth([])!.id
            return (recordId, authId)
        }) else {
            XCTFail("no records")
            return
        }
        let strayId = generateAccountRecordId()
        self.makeDirectory(recordId)
        self.makeDirectory(authId)
        self.makeDirectory(strayId)

        self.sweep()

        XCTAssertTrue(self.exists(recordId), "a record's directory is kept")
        XCTAssertTrue(self.exists(authId), "the auth record's directory is kept")
        XCTAssertFalse(self.exists(strayId), "a directory of no account is deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.rootPath + "/accounts-metadata"), "the account manager's own directory is not an account directory")
    }

    /// The crash: the sweep of a view from before the auth record existed deleted the auth account's new
    /// directory. Whatever view triggers it, the sweep sees the auth record that exists when it lists.
    func testAnAccountCreatedAfterTheSweepWasTriggeredKeepsItsDirectory() {
        let sweep = cleanupStaleAccountDirectories(accountManager: self.accountManager, rootPath: self.rootPath)
        guard let authId = self.wait(self.accountManager.transaction { transaction -> AccountRecordId in
            return transaction.createAuth([])!.id
        }) else {
            XCTFail("no auth record")
            return
        }
        self.makeDirectory(authId)

        let done = DispatchSemaphore(value: 0)
        let disposable = sweep.start(completed: {
            done.signal()
        })
        XCTAssertEqual(done.wait(timeout: .now() + 10.0), .success, "the sweep did not finish")
        disposable.dispose()

        XCTAssertTrue(self.exists(authId))
    }

    func testAReservedDirectoryIsKeptUntilTheReservationEnds() {
        let id = generateAccountRecordId()
        let reservation = reserveAccountDirectory(id: id)
        self.makeDirectory(id)

        self.sweep()
        XCTAssertTrue(self.exists(id), "kept while reserved")

        let _ = self.wait(self.accountManager.transaction { transaction -> Void in
            transaction.updateRecord(id, { _ in
                return AccountRecord(id: id, attributes: [], temporarySessionId: nil)
            })
        })
        reservation.dispose()
        self.sweep()
        XCTAssertTrue(self.exists(id), "kept by the record once the reservation ends")

        let _ = self.wait(self.accountManager.transaction { transaction -> Void in
            transaction.updateRecord(id, { _ in
                return nil
            })
        })
        self.sweep()
        XCTAssertFalse(self.exists(id), "deleted once neither keeps it")
    }

    func testReservationsAreCounted() {
        let id = generateAccountRecordId()
        let first = reserveAccountDirectory(id: id)
        let second = reserveAccountDirectory(id: id)
        self.makeDirectory(id)

        first.dispose()
        first.dispose()
        self.sweep()
        XCTAssertTrue(self.exists(id), "one reservation is left, however often the other is disposed")

        second.dispose()
        self.sweep()
        XCTAssertFalse(self.exists(id))
    }

    func testRecordsOfAnotherSessionDoNotKeepTheirDirectory() {
        let ownId = generateAccountRecordId()
        let otherId = generateAccountRecordId()
        let ownSession = self.accountManager.temporarySessionId
        let _ = self.wait(self.accountManager.transaction { transaction -> Void in
            transaction.updateRecord(ownId, { _ in
                return AccountRecord(id: ownId, attributes: [], temporarySessionId: ownSession)
            })
            transaction.updateRecord(otherId, { _ in
                return AccountRecord(id: otherId, attributes: [], temporarySessionId: ownSession &+ 1)
            })
        })
        self.makeDirectory(ownId)
        self.makeDirectory(otherId)

        self.sweep()

        XCTAssertTrue(self.exists(ownId), "this session's temporary record keeps its directory")
        XCTAssertFalse(self.exists(otherId), "an earlier session's temporary record does not")
    }
}
