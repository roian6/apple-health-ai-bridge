import XCTest
@testable import HealthBridgeCompanionCore

final class AsyncCompletionBarrierTests: XCTestCase {
    actor CompletionProbe {
        private(set) var finished = false

        func markFinished() {
            finished = true
        }
    }

    func testWaitResumesOnlyAfterEveryTaskCompletes() async {
        let barrier = AsyncCompletionBarrier<Int>()
        let probe = CompletionProbe()
        let waitTask = Task {
            await barrier.wait(for: [11, 12])
            await probe.markFinished()
        }

        await barrier.complete(11)
        await Task.yield()
        let finishedAfterFirstCompletion = await probe.finished
        XCTAssertFalse(finishedAfterFirstCompletion)

        await barrier.complete(12)
        await waitTask.value
        let finishedAfterAllCompletions = await probe.finished
        XCTAssertTrue(finishedAfterAllCompletions)
    }

    func testCompletionBeforeWaitRegistrationStillResumes() async {
        let barrier = AsyncCompletionBarrier<Int>()
        await barrier.complete([21, 22])

        await barrier.wait(for: [21, 22])

        await barrier.complete(23)
        await barrier.wait(for: [23])
    }

    func testMoreThan4096EarlyCompletionsRemainAvailableToLateWaiter() async {
        let barrier = AsyncCompletionBarrier<Int>()
        let completedIDs = Set(0 ..< 5_000)

        await barrier.complete(completedIDs)

        let completed = await barrier.wait(for: completedIDs, timeout: 0.01)
        XCTAssertTrue(completed)
    }

    func testRetainCompletionsPrunesOnlyUnneededHistory() async {
        let barrier = AsyncCompletionBarrier<Int>()
        await barrier.complete(Set(0 ..< 5_000))

        await barrier.retainCompletions(for: [41, 42])

        let retainedCount = await barrier.retainedCompletionCountForTesting()
        let retainedWait = await barrier.wait(for: [41, 42], timeout: 0.01)
        let prunedWait = await barrier.wait(for: [43], timeout: 0.001)
        XCTAssertEqual(retainedCount, 2)
        XCTAssertTrue(retainedWait)
        XCTAssertFalse(prunedWait)
    }

    func testSameCompletionCanReleaseConcurrentAndLateWaiters() async {
        let barrier = AsyncCompletionBarrier<Int>()
        let firstWaiter = Task {
            await barrier.wait(for: [31])
        }
        let secondWaiter = Task {
            await barrier.wait(for: [31])
        }

        await barrier.complete(31)
        await firstWaiter.value
        await secondWaiter.value
        await barrier.wait(for: [31])
    }

    func testTimedWaitReturnsFalseAndLateCompletionRemainsSafe() async {
        let barrier = AsyncCompletionBarrier<Int>()

        let completedInTime = await barrier.wait(for: [41], timeout: 0.01)

        XCTAssertFalse(completedInTime)
        await barrier.complete(41)
        let lateWait = await barrier.wait(for: [41], timeout: 0.01)
        XCTAssertTrue(lateWait)
    }

    func testTimedOutAndThenCancelledWaitersDoNotRetainBookkeeping() async {
        let barrier = AsyncCompletionBarrier<Int>()

        for id in 100 ..< 200 {
            let waiter = Task {
                await barrier.wait(for: [id], timeout: 0.001)
            }
            _ = await waiter.value
            waiter.cancel()
        }
        await Task.yield()

        let retainedBookkeeping = await barrier.retainedWaiterBookkeepingCountForTesting()
        XCTAssertEqual(retainedBookkeeping, 0)
    }

    func testExclusiveAccessGateDoesNotAdmitSecondTransferUntilRelease() async {
        let gate = AsyncExclusiveAccessGate()
        let probe = CompletionProbe()

        try? await gate.acquire()
        let waiter = Task {
            try await gate.acquire()
            await probe.markFinished()
            await gate.release()
        }

        await Task.yield()
        let finishedBeforeRelease = await probe.finished
        XCTAssertFalse(finishedBeforeRelease)

        await gate.release()
        _ = try? await waiter.value
        let finishedAfterRelease = await probe.finished
        XCTAssertTrue(finishedAfterRelease)
    }

    func testExclusiveAccessGateRemovesCancelledWaiter() async {
        let gate = AsyncExclusiveAccessGate()
        try? await gate.acquire()
        let cancelledWaiter = Task {
            do {
                try await gate.acquire()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        await Task.yield()
        cancelledWaiter.cancel()
        let waiterWasCancelled = await cancelledWaiter.value
        XCTAssertTrue(waiterWasCancelled)

        await gate.release()
        do {
            try await gate.acquire()
        } catch {
            XCTFail("A cancelled waiter must not block the next acquire: \(error)")
        }
        await gate.release()
    }

    func testExclusiveAccessGateCancellationRacingReleaseDoesNotTransferOwnership() async {
        for _ in 0 ..< 100 {
            let gate = AsyncExclusiveAccessGate()
            try? await gate.acquire()
            let cancelledWaiter = Task {
                try await gate.acquire()
            }
            await Task.yield()

            cancelledWaiter.cancel()
            await gate.release()

            do {
                try await cancelledWaiter.value
                XCTFail("A cancelled waiter must not acquire the gate")
            } catch is CancellationError {
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }
            do {
                try await gate.acquire()
            } catch {
                XCTFail("Cancellation must release transferred ownership: \(error)")
            }
            await gate.release()
        }
    }

    func testPairingOperationSequencingRunsNewColdLaunchLinkAfterBootstrap() {
        XCTAssertTrue(
            PairingOperationSequencingPolicy.shouldRunAfterWaiting(
                existing: .bootstrapRecovery,
                requested: .userInitiated,
                matchesPendingBootstrapInvitation: false
            )
        )
    }

    func testPairingOperationSequencingDeduplicatesSamePendingAndUserConcurrency() {
        XCTAssertFalse(
            PairingOperationSequencingPolicy.shouldRunAfterWaiting(
                existing: .bootstrapRecovery,
                requested: .userInitiated,
                matchesPendingBootstrapInvitation: true
            )
        )
        XCTAssertFalse(
            PairingOperationSequencingPolicy.shouldRunAfterWaiting(
                existing: .userInitiated,
                requested: .userInitiated,
                matchesPendingBootstrapInvitation: false
            )
        )
    }
}
