import XCTest
@testable import MattermostSyncCore

final class DirectMessageReadReceiptTests: XCTestCase {
    func testRequiresBothCountersCaughtUp() {
        XCTAssertTrue(DirectMessageReadReceipt.isCaughtUp(total: 21, totalRoots: 17, viewed: 21, viewedRoots: 17))
        XCTAssertFalse(DirectMessageReadReceipt.isCaughtUp(total: 21, totalRoots: 17, viewed: 20, viewedRoots: 17))
        XCTAssertFalse(DirectMessageReadReceipt.isCaughtUp(total: 21, totalRoots: 17, viewed: 21, viewedRoots: 16))
        XCTAssertFalse(DirectMessageReadReceipt.isCaughtUp(total: 21, totalRoots: 17, viewed: 22, viewedRoots: 17))
        XCTAssertFalse(DirectMessageReadReceipt.isCaughtUp(total: 0, totalRoots: 0, viewed: 0, viewedRoots: 0))
        XCTAssertFalse(DirectMessageReadReceipt.isCaughtUp(total: 10, totalRoots: 11, viewed: 10, viewedRoots: 11))
    }

    func testOnlyCountedDirectMessageRootsAreEligible() {
        XCTAssertTrue(DirectMessageReadReceipt.isEligible(isDirect: true, rootId: "", type: "", silent: false, forceNotification: false))
        XCTAssertTrue(DirectMessageReadReceipt.isEligible(isDirect: true, rootId: "", type: "me", silent: false, forceNotification: false))
        XCTAssertFalse(DirectMessageReadReceipt.isEligible(isDirect: false, rootId: "", type: "", silent: false, forceNotification: false))
        XCTAssertFalse(DirectMessageReadReceipt.isEligible(isDirect: true, rootId: "root", type: "", silent: false, forceNotification: false))
        XCTAssertFalse(DirectMessageReadReceipt.isEligible(isDirect: true, rootId: "", type: "system_join_channel", silent: false, forceNotification: false))
        XCTAssertFalse(DirectMessageReadReceipt.isEligible(isDirect: true, rootId: "", type: "", silent: true, forceNotification: false))
        XCTAssertTrue(DirectMessageReadReceipt.isEligible(isDirect: true, rootId: "", type: "", silent: true, forceNotification: true))
    }

    func testCheckpointKeepsPostIdentityAcrossRenumberingAndRelaunch() throws {
        let key = PostOrderKey(createAt: 1234, postId: "post#02")
        let encoded = try JSONEncoder().encode(DirectMessageReadCheckpoint(key: key))
        XCTAssertEqual(try JSONDecoder().decode(DirectMessageReadCheckpoint.self, from: encoded).key, key)
    }
}
