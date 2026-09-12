import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

@MainActor
final class BackgroundRefreshBoundedRecoveryTests: XCTestCase {
    func testAcceptedRunWithNonReturningWorkReachesBoundedTerminalOutcome() async throws {
        let suite = "BackgroundRefreshBoundedRecoveryTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BackgroundSyncSettingsStore(userDefaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for lane in HealthBridgeBackgroundSync.coreWorkLanes {
            try store.recordCoreLaneSuccess(lane, at: now)
        }
        try store.markPendingObserverTypeCodes(["sleep_analysis"])
        let admittedSnapshot = try store.loadPendingObserverTypeCodeGenerations()
        let owner = BackgroundRefreshFinalizationOwner()
        let gate = BackgroundSyncRunGate(minimumSpacing: 0)
        let admission = await gate.beginRun(
            reason: .observer(typeCode: "sleep_analysis"),
            now: now
        )
        XCTAssertTrue(admission.shouldRun)
        owner.admit(admittedSnapshot)

        let dependencyEntered = expectation(description: "non-returning dependency entered")
        let terminalOutcomeRecorded = expectation(description: "accepted run reached terminal outcome")
        let dependency = BoundedAsyncValueLatch<Void>()
        var finalizationCount = 0
        var terminalCompletion: BackgroundSyncRunCompletion?
        let handler = Task { @MainActor in
            await owner.run {
                dependencyEntered.fulfill()
                _ = await dependency.wait(timeout: 60)
            } finalize: {
                finalizationCount += 1
                if owner.takeAdmission() {
                    terminalCompletion = .interrupted
                    let pending = await gate.finishRun(.interrupted)
                    await gate.retainObserverTypeCodes(pending)
                }
                terminalOutcomeRecorded.fulfill()
            }
        }

        let entry = await XCTWaiter.fulfillment(of: [dependencyEntered], timeout: 2)
        XCTAssertEqual(entry, .completed)
        guard entry == .completed else {
            handler.cancel()
            dependency.resolve(())
            await handler.value
            return
        }

        handler.cancel()
        let terminal = await XCTWaiter.fulfillment(
            of: [terminalOutcomeRecorded],
            timeout: 1
        )
        let retainedPending = await gate.pendingObserverTypeCodesSnapshot()
        let nextAdmission = await gate.beginRun(
            reason: .observerBatch(typeCodes: retainedPending),
            now: now.addingTimeInterval(1)
        )
        let nextPlan = HealthBridgeBackgroundSync.workPlan(
            reason: .observerBatch(typeCodes: retainedPending),
            availableQuantityTypeCodes: [],
            pendingObserverTypeCodes: retainedPending,
            continuationLaneID: store.nextScheduledWorkLaneID,
            coreLaneLastSuccess: store.coreLaneLastSuccess,
            now: now.addingTimeInterval(1)
        )

        dependency.resolve(())
        await handler.value
        if nextAdmission.shouldRun {
            _ = await gate.finishRun(.interrupted)
        }

        XCTAssertEqual(terminal, .completed)
        XCTAssertEqual(finalizationCount, 1)
        XCTAssertEqual(terminalCompletion, .interrupted)
        XCTAssertEqual(retainedPending, ["sleep_analysis"])
        XCTAssertEqual(
            try store.loadPendingObserverTypeCodeGenerations(),
            admittedSnapshot
        )
        XCTAssertTrue(nextAdmission.shouldRun)
        XCTAssertEqual(nextPlan.lane, .sleep)
    }
}
