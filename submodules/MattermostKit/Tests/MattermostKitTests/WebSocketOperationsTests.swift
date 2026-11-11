import XCTest
@testable import MattermostKit

final class WebSocketOperationsTests: XCTestCase {
    func testCloseUnblocksIOThatDoesNotAcknowledgeCancellation() async throws {
        let operations = WebSocketOperations()
        let suspended = Locked<CheckedContinuation<Int, Never>?>(nil)
        let pending = Task {
            try await operations.perform {
                await withCheckedContinuation { suspended.set($0) }
            }
        }
        for _ in 0..<1000 where suspended.current == nil { await Task.yield() }
        let release = try XCTUnwrap(suspended.current)
        defer { release.resume(returning: 7) }
        operations.close()
        do { _ = try await pending.value; XCTFail("Closed I/O must fail") }
        catch { XCTAssertEqual(error as? MattermostWebSocketError, .connectionClosed) }
        do {
            _ = try await operations.perform { XCTFail("A closed connection must not start I/O"); return 1 }
        } catch { XCTAssertEqual(error as? MattermostWebSocketError, .connectionClosed) }
    }

    func testCompletedIOIsReturnedBeforeClose() async throws {
        let operations = WebSocketOperations()
        let value = try await operations.perform { 42 }
        XCTAssertEqual(value, 42)
        operations.close()
        operations.close()
    }
}
