import XCTest
@testable import HealthBridgeCompanionCore

final class BoundedAsyncValueLatchTests: XCTestCase {
    func testCancellationUnblocksWaitWhenCallbackNeverArrives() async {
        let latch = BoundedAsyncValueLatch<Int>()
        let entered = expectation(description: "wait entered")
        let returned = expectation(description: "cancelled wait returned")
        let task = Task {
            entered.fulfill()
            let value = await latch.wait(timeout: 60)
            XCTAssertNil(value)
            returned.fulfill()
        }

        let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(entry, .completed)
        task.cancel()
        let exit = await XCTWaiter.fulfillment(of: [returned], timeout: 1)
        XCTAssertEqual(exit, .completed)
        await task.value
    }

    func testTimeoutReturnsNilAndIgnoresLateCallback() async {
        let latch = BoundedAsyncValueLatch<Int>()

        let value = await latch.wait(timeout: 0.02)
        latch.resolve(42)
        let repeatedWait = await latch.wait(timeout: 0)

        XCTAssertNil(value)
        XCTAssertNil(repeatedWait)
    }

    func testCompletionBeforeWaitReturnsTheValue() async {
        let latch = BoundedAsyncValueLatch<Int>()
        latch.resolve(42)

        let value = await latch.wait(timeout: 1)

        XCTAssertEqual(value, 42)
    }
}