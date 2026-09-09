import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

@MainActor
final class BackgroundRefreshFinalizationTests: XCTestCase {
    func testCancellationBeforeLaneStartFinalizesBeforeReturn() async throws {
        try await exerciseCancellation(at: .beforeLane)
    }

    func testCancellationDuringLanePreservesDurableFIFOAndNewGeneration() async throws {
        try await exerciseCancellation(at: .duringLane)
    }

    func testCancellationAfterWorkStillResubmitsWithoutReplayingCompletedLane() async throws {
        try await exerciseCancellation(at: .afterWork)
    }

    func testCancellationAfterOneLaneDoesNotReplayItsCompletedGeneration() async throws {
        try await exerciseCancellation(at: .duringSecondLane)
    }

    func testTerminalChangesDuringFinalizationPreventResubmission() async {
        for blocked in 0..<4 {
            let owner = BackgroundRefreshFinalizationOwner()
            let entered = expectation(description: "finalizer suspended")
            let returned = expectation(description: "finalizer drained")
            var resume: CheckedContinuation<Void, Never>?
            var terminalChange = false
            var scheduled = 0
            let task = Task { @MainActor in
                await owner.run {} finalize: {
                    await withCheckedContinuation { resume = $0; entered.fulfill() }
                    let eligible = BackgroundRefreshFinalizationPolicy.shouldScheduleNextRefresh(
                        enabled: !(terminalChange && blocked == 0),
                        ready: !(terminalChange && blocked == 1),
                        admissionOpen: !(terminalChange && blocked == 2),
                        capturedGeneration: "old",
                        currentGeneration: terminalChange && blocked == 3 ? "new" : "old"
                    )
                    if eligible { scheduled += 1 }
                }
                returned.fulfill()
            }
            let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
            XCTAssertEqual(entry, .completed)
            guard entry == .completed else { task.cancel(); return }
            task.cancel()
            terminalChange = true
            resume?.resume()
            let exit = await XCTWaiter.fulfillment(of: [returned], timeout: 2)
            XCTAssertEqual(exit, .completed)
            guard exit == .completed else { return }
            await task.value
            XCTAssertEqual(scheduled, 0)
        }
    }

    func testReleasedAdmissionCannotFinishAnotherRun() async {
        let owner = BackgroundRefreshFinalizationOwner()
        let gate = BackgroundSyncRunGate(minimumSpacing: 0)
        _ = await gate.beginRun(reason: .observer(typeCode: "steps"))
        owner.admit(["steps": 1])
        XCTAssertTrue(owner.takeAdmission())
        _ = await gate.finishRun(.succeeded)
        _ = await gate.beginRun(reason: .observer(typeCode: "sleep_analysis"))
        await owner.run {} finalize: {
            if owner.takeAdmission() { _ = await gate.finishRun(.interrupted) }
        }
        let active = await gate.hasActiveRun()
        XCTAssertTrue(active)
        let pending = await gate.finishRun(.interrupted)
        XCTAssertEqual(pending, ["sleep_analysis"])
    }

    func testCancellationRetryEligibilityDoesNotRequireObserverDirtiness() async {
        XCTAssertTrue(BackgroundRefreshFinalizationPolicy.shouldScheduleNextRefresh(
            enabled: true, ready: true, admissionOpen: true,
            capturedGeneration: "current", currentGeneration: "current"
        ))
        for blocked in 0..<4 {
            XCTAssertFalse(BackgroundRefreshFinalizationPolicy.shouldScheduleNextRefresh(
                enabled: blocked != 0, ready: blocked != 1, admissionOpen: blocked != 2,
                capturedGeneration: "current", currentGeneration: blocked == 3 ? "new" : "current"
            ))
        }
    }

    func testRequestCoalescingConsumptionGenerationAndSubmissionFailure() async throws {
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
        XCTAssertThrowsError(try requests.submitIfNeeded(generation: "two") { throw Failure.submit })
        try requests.submitIfNeeded(generation: "two") { submissions += 1 }
        XCTAssertEqual(submissions, 4)
    }

    private enum Boundary { case beforeLane, duringLane, duringSecondLane, afterWork }

    private func exerciseCancellation(at boundary: Boundary) async throws {
        let suite = "BackgroundRefreshFinalizationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BackgroundSyncSettingsStore(userDefaults: defaults)
        try store.markPendingObserverTypeCodes(["sleep_analysis", "steps"])
        let snapshot = try store.loadPendingObserverTypeCodeGenerations()
        let owner = BackgroundRefreshFinalizationOwner()
        let gate = BackgroundSyncRunGate(minimumSpacing: 0)
        let admission = await gate.beginRun(reason: .observerBatch(typeCodes: Array(snapshot.keys)))
        XCTAssertTrue(admission.shouldRun)
        owner.admit(snapshot)
        let plan = HealthBridgeBackgroundSync.workPlan(
            reason: .scheduledRefresh, availableQuantityTypeCodes: [],
            pendingObserverTypeCodes: Array(snapshot.keys), continuationLaneID: nil
        )
        let suspended = expectation(description: "exact cancellation boundary")
        let finalizing = expectation(description: "finalizer entered")
        let returned = expectation(description: "handler returned after finalization")
        var resumeWork: CheckedContinuation<Void, Never>?
        var resumeFinalizer: CheckedContinuation<Void, Never>?
        var attempts = 0
        var scheduled = 0
        var finalizations = 0
        var handlerReturned = false
        // A durable FIFO sentinel is not owned by the finalizer. Production outbox
        // integration uses the same executor stop boundary and transfer gate.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("pending-fifo")
        let payload = Data("synthetic-durable-fifo-head".utf8)
        try payload.write(to: fifo)
        let task = Task { @MainActor in
            await owner.run {
                if boundary == .beforeLane {
                    await withCheckedContinuation { resumeWork = $0; suspended.fulfill() }
                }
                do {
                    _ = try await BackgroundSyncWorkExecutor.execute(
                        plan: plan,
                        prepare: { try store.persistNextScheduledWorkLaneID($0.nextScheduledLaneID) },
                        runLane: { _ in
                            attempts += 1
                            if boundary == .duringLane || (boundary == .duringSecondLane && attempts == 2) {
                                await withCheckedContinuation { resumeWork = $0; suspended.fulfill() }
                            }
                            return true
                        },
                        didComplete: { attempt in
                            try store.clearPendingObserverTypeCodes(matching: snapshot, typeCodes: attempt.coveredObserverTypeCodes)
                            owner.complete(attempt.coveredObserverTypeCodes)
                            await gate.completeActiveObserverTypeCodes(attempt.coveredObserverTypeCodes)
                        }
                    )
                } catch { XCTAssertTrue(error is CancellationError) }
                if boundary == .afterWork {
                    await withCheckedContinuation { resumeWork = $0; suspended.fulfill() }
                }
            } finalize: {
                finalizations += 1
                XCTAssertTrue(Task.isCancelled)
                if owner.takeAdmission() {
                    let pending = await gate.finishRun(.interrupted)
                    let recovery = BackgroundSyncFailureRecoveryPolicy.plan(
                        admittedPendingTypeCodes: Array(owner.remainingGenerations.keys),
                        gatePendingTypeCodes: pending,
                        durablePendingState: .available(typeCodes: store.pendingObserverTypeCodes),
                        retryRequested: false, automaticSyncReady: true,
                        backgroundSyncEnabled: true, payloadAdmissionOpen: true
                    )
                    await gate.retainObserverTypeCodes(recovery.pendingTypeCodes)
                }
                await withCheckedContinuation { resumeFinalizer = $0; finalizing.fulfill() }
                if BackgroundRefreshFinalizationPolicy.shouldScheduleNextRefresh(
                    enabled: true, ready: true, admissionOpen: true,
                    capturedGeneration: "same", currentGeneration: "same"
                ) { scheduled += 1 }
            }
            handlerReturned = true
            returned.fulfill()
        }
        let entry = await XCTWaiter.fulfillment(of: [suspended], timeout: 2)
        XCTAssertEqual(entry, .completed)
        guard entry == .completed else { task.cancel(); return }
        try store.markPendingObserverTypeCodes(["sleep_analysis"])
        task.cancel()
        resumeWork?.resume()
        let finalizerEntry = await XCTWaiter.fulfillment(of: [finalizing], timeout: 2)
        XCTAssertEqual(finalizerEntry, .completed)
        if finalizerEntry == .completed {
            XCTAssertFalse(handlerReturned)
            resumeFinalizer?.resume()
        }
        let exit = await XCTWaiter.fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(exit, .completed)
        guard exit == .completed else { return }
        await task.value
        XCTAssertEqual(finalizations, 1)
        XCTAssertEqual(scheduled, 1)
        XCTAssertEqual(attempts, boundary == .beforeLane ? 0 : boundary == .duringLane ? 1 : boundary == .duringSecondLane ? 2 : 4)
        XCTAssertEqual(try Data(contentsOf: fifo), payload)
        XCTAssertEqual(store.pendingObserverTypeCodes, boundary == .afterWork ? ["sleep_analysis"] : ["sleep_analysis", "steps"])
        let firstLaneCompleted = boundary == .afterWork || boundary == .duringSecondLane
        XCTAssertEqual(store.pendingObserverTypeCodeGenerations["sleep_analysis"], firstLaneCompleted ? 1 : 2)
        XCTAssertEqual(owner.remainingGenerations["sleep_analysis"], firstLaneCompleted ? nil : 1)
        XCTAssertEqual(store.nextScheduledWorkLaneID, boundary == .beforeLane ? nil : boundary == .duringLane ? "daily_activity" : boundary == .duringSecondLane ? "steps" : "sleep")
        let running = await gate.hasActiveRun()
        XCTAssertFalse(running)
        await owner.run { XCTFail("finalized run must not execute again") } finalize: { XCTFail("only one finalizer") }
    }
}
