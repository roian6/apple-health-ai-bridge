import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

@MainActor
final class AnchoredSleepSyncPreparationTests: XCTestCase {
    func testPreparationKeepsMainActorResponsiveWhileProcessingRetainedHistory() async throws {
        let fixture = try makeEstablishedHistory()
        let barrier = SleepPreparationResponsivenessBarrier()
        let preparer = AnchoredSleepSyncPreparer(beforePreparation: {
            barrier.blockPreparation()
        })
        barrier.startDriver()

        let preparation = try await preparer.prepare(
            plan: fixture.plan,
            changes: fixture.changes,
            receiverSettingsGeneration: "synthetic-generation",
            historyDepth: .allAvailable,
            generatedAt: fixture.changes.receivedAt
        )

        await barrier.joinDriver()
        let observation = barrier.observation()
        XCTAssertTrue(observation.entered, "Exercise the real transition and encoding boundary.")
        XCTAssertTrue(observation.heartbeatBeforeRelease, "The UI executor must remain available during preparation.")
        let result = try XCTUnwrap(preparation)
        XCTAssertTrue(result.transition.batch.sleepSessions.isEmpty)
        XCTAssertTrue(result.transition.batch.deletedRecords.isEmpty)
        XCTAssertEqual(result.transition.manifest.activeChildSamples, fixture.manifest.activeChildSamples)
        XCTAssertEqual(result.transition.manifest.publishedSessions, fixture.manifest.publishedSessions)
        XCTAssertEqual(result.transition.manifest.nextRevisionSequence, fixture.manifest.nextRevisionSequence)
        XCTAssertEqual(result.transition.manifest.anchorCursorValue, "synthetic-next-anchor")
        XCTAssertEqual(
            try JSONDecoder().decode(HealthBridgeBatchV1.self, from: result.payload),
            result.transition.batch
        )
    }

    func testCancellationDuringPreparationDoesNotReturnAPreparedTransition() async throws {
        let fixture = try makeEstablishedHistory()
        let barrier = SleepPreparationResponsivenessBarrier()
        let preparer = AnchoredSleepSyncPreparer(beforePreparation: {
            barrier.blockPreparation()
        })
        let operation = Task {
            try await preparer.prepare(
                plan: fixture.plan,
                changes: fixture.changes,
                receiverSettingsGeneration: "synthetic-generation",
                historyDepth: .allAvailable,
                generatedAt: fixture.changes.receivedAt
            )
        }
        barrier.startDriver(onHeartbeat: { operation.cancel() })

        do {
            _ = try await operation.value
            XCTFail("Cancellation must not return a transition for the caller to commit.")
        } catch is CancellationError {
            // The caller retains its previously committed manifest and delivery state.
        }

        await barrier.joinDriver()
        XCTAssertTrue(barrier.observation().entered)
        XCTAssertTrue(barrier.observation().heartbeatBeforeRelease)
    }

    func testForcedBaselinePreservesSessionIdentitiesAndResetCursor() async throws {
        let fixture = try makeEstablishedHistory()
        let plan = AnchoredSleepManifestPlan(
            previousManifest: fixture.manifest,
            anchorCursorValue: nil,
            historyStartDate: nil,
            forceRepublishAll: true
        )
        let result = try await AnchoredSleepSyncPreparer().prepare(
            plan: plan,
            changes: HealthKitAnchoredSleepChanges(
                addedSamples: fixture.manifest.activeChildSamples,
                deletedSamples: [],
                anchorCursorValue: "synthetic-baseline-anchor",
                receivedAt: fixture.changes.receivedAt
            ),
            receiverSettingsGeneration: "synthetic-generation",
            historyDepth: .allAvailable,
            generatedAt: fixture.changes.receivedAt
        )

        let preparation = try XCTUnwrap(result)
        XCTAssertEqual(preparation.transition.batch.sleepSessions, fixture.manifest.publishedSessions)
        XCTAssertTrue(preparation.transition.batch.deletedRecords.isEmpty)
        XCTAssertEqual(preparation.transition.batch.sync.cursors.map(\.cursorKind), [
            "anchored_sleep_sync", "anchored_sleep_baseline_reset",
        ])
        XCTAssertEqual(preparation.transition.batch.sync.cursors.map(\.cursorValue), [
            "synthetic-baseline-anchor", "v2:1",
        ])
        XCTAssertEqual(preparation.transition.manifest.nextRevisionSequence, fixture.manifest.nextRevisionSequence)
    }

    func testEmptyForcedBaselineKeepsFullReadPendingWithoutInferringDeletions() async throws {
        let fixture = try makeEstablishedHistory()
        let result = try await AnchoredSleepSyncPreparer().prepare(
            plan: AnchoredSleepManifestPlan(
                previousManifest: fixture.manifest,
                anchorCursorValue: nil,
                historyStartDate: nil,
                forceRepublishAll: true
            ),
            changes: fixture.changes,
            receiverSettingsGeneration: "synthetic-generation",
            historyDepth: .allAvailable,
            generatedAt: fixture.changes.receivedAt
        )

        let preparation = try XCTUnwrap(result)
        XCTAssertTrue(preparation.transition.manifest.baselineResetPending == true)
        XCTAssertTrue(preparation.transition.batch.sleepSessions.isEmpty)
        XCTAssertTrue(preparation.transition.batch.deletedRecords.isEmpty)
        XCTAssertEqual(preparation.transition.manifest.publishedSessions, fixture.manifest.publishedSessions)
    }

    private func makeEstablishedHistory() throws -> (
        manifest: SleepSyncManifest,
        plan: AnchoredSleepManifestPlan,
        changes: HealthKitAnchoredSleepChanges
    ) {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let children = try (0..<288).map { index in
            let day = index / 24
            let intervalStart = start.addingTimeInterval(Double(day * 86_400 + (index % 24) * 1_200))
            return HealthKitSleepChildSample(
                uuid: try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))),
                stage: index.isMultiple(of: 2) ? "core" : "deep",
                start: intervalStart,
                end: intervalStart.addingTimeInterval(1_200)
            )
        }
        let receivedAt = start.addingTimeInterval(13 * 86_400)
        let initial = try XCTUnwrap(SleepSyncBatchFactory.makeAnchoredSleepTransition(
            previousManifest: nil,
            changes: HealthKitAnchoredSleepChanges(
                addedSamples: children,
                deletedSamples: [],
                anchorCursorValue: "synthetic-initial-anchor",
                receivedAt: receivedAt
            ),
            receiverSettingsGeneration: "synthetic-generation",
            historyDepth: .allAvailable,
            historyStartDate: nil,
            generatedAt: receivedAt
        ))
        XCTAssertEqual(initial.manifest.publishedSessions.count, 12)

        return (
            initial.manifest,
            SleepSyncBatchFactory.manifestPlan(
                initial.manifest,
                receiverSettingsGeneration: "synthetic-generation",
                historyDepth: .allAvailable,
                requestedHistoryStartDate: nil
            ),
            HealthKitAnchoredSleepChanges(
                addedSamples: [],
                deletedSamples: [],
                anchorCursorValue: "synthetic-next-anchor",
                receivedAt: receivedAt.addingTimeInterval(60)
            )
        )
    }
}

private final class SleepPreparationResponsivenessBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let heartbeat = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let driver = DispatchGroup()
    private var didEnter = false
    private var released = false
    private var heartbeatBeforeRelease = false
    private var heartbeatTask: Task<Void, Never>?

    func blockPreparation() {
        lock.withLock { didEnter = true }
        entered.signal()
        release.wait()
    }

    func startDriver(onHeartbeat: @escaping @MainActor @Sendable () -> Void = {}) {
        driver.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { driver.leave() }

            if entered.wait(timeout: .now() + 5) == .success {
                let task = Task { @MainActor [self] in
                    lock.withLock { heartbeatBeforeRelease = !released }
                    onHeartbeat()
                    heartbeat.signal()
                }
                lock.withLock { heartbeatTask = task }
                _ = heartbeat.wait(timeout: .now() + 2)
            }

            lock.withLock { released = true }
            release.signal()
        }
    }

    func joinDriver() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            driver.notify(queue: .global()) { continuation.resume() }
        }
        let task = lock.withLock { heartbeatTask }
        await task?.value
    }

    func observation() -> (entered: Bool, heartbeatBeforeRelease: Bool) {
        lock.withLock { (didEnter, heartbeatBeforeRelease) }
    }
}
