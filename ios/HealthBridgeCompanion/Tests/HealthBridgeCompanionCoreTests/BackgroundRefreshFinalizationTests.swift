import XCTest
@testable import HealthBridgeCompanionCore

@MainActor
final class BackgroundRefreshFinalizationTests: XCTestCase {
    func testFinalizerDrainsBeforeRunReturnsAndRunsOnce() async {
        let owner = BackgroundRefreshFinalizationOwner()
        let entered = expectation(description: "finalizer entered")
        let returned = expectation(description: "run returned")
        var resume: CheckedContinuation<Void, Never>?
        var finalizations = 0
        let task = Task { @MainActor in
            await owner.run {} finalize: {
                finalizations += 1
                await withCheckedContinuation {
                    resume = $0
                    entered.fulfill()
                }
            }
            returned.fulfill()
        }

        let enteredResult = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(enteredResult, .completed)
        resume?.resume()
        let returnedResult = await XCTWaiter.fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(returnedResult, .completed)
        await task.value
        await owner.run {
            XCTFail("finalized work must not run twice")
        } finalize: {
            XCTFail("finalizer must not run twice")
        }
        XCTAssertEqual(finalizations, 1)
    }

    func testTerminalStateAndGenerationFenceBackgroundResubmission() {
        XCTAssertTrue(BackgroundRefreshFinalizationPolicy.shouldScheduleNextRefresh(
            enabled: true,
            ready: true,
            admissionOpen: true,
            capturedGeneration: "current",
            currentGeneration: "current"
        ))
        for blocked in 0..<4 {
            XCTAssertFalse(BackgroundRefreshFinalizationPolicy.shouldScheduleNextRefresh(
                enabled: blocked != 0,
                ready: blocked != 1,
                admissionOpen: blocked != 2,
                capturedGeneration: "current",
                currentGeneration: blocked == 3 ? "new" : "current"
            ))
        }
    }

    func testRequestCoalescingConsumptionGenerationAndSubmissionFailure() throws {
        let requests = BackgroundRefreshRequestCoalescer()
        var submissions = 0
        for _ in 0..<100 {
            try requests.submitIfNeeded(generation: "one") { submissions += 1 }
        }
        XCTAssertEqual(submissions, 1)
        requests.requestWasConsumed()
        try requests.submitIfNeeded(generation: "one") { submissions += 1 }
        try requests.submitIfNeeded(generation: "two") { submissions += 1 }
        XCTAssertEqual(submissions, 3)
        requests.invalidate()
        enum Failure: Error { case submit }
        XCTAssertThrowsError(
            try requests.submitIfNeeded(generation: "two") {
                throw Failure.submit
            }
        )
        try requests.submitIfNeeded(generation: "two") { submissions += 1 }
        XCTAssertEqual(submissions, 4)
    }
}
