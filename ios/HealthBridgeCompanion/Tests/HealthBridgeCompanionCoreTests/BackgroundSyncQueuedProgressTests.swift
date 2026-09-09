import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

@MainActor
final class BackgroundSyncQueuedProgressTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let cores = HealthBridgeBackgroundSync.coreWorkLanes

    func testQueuedCoreAcceptRetireReloadAdvancesEveryCoreAcrossSparseOpportunities() async throws {
        // A disk-backed synthetic transport retains its FIFO head until later acceptance.
        // Scheduler, executor, preferences, dirtiness, and delivery evidence are production code.
        for spacing in [60.0, 1_800.0] {
            let suite = "QueuedProgressTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fifo = directory.appendingPathComponent("fifo.json")
            let diagnosticsURL = directory.appendingPathComponent("diagnostics.json")
            let dirty = ["sleep_analysis", "energy", "steps", "workout", "heart_rate"]
            try BackgroundSyncSettingsStore(userDefaults: defaults).markPendingObserverTypeCodes(dirty)
            var attempted: [BackgroundSyncWorkLane] = []
            for opportunity in 0..<4 {
                let date = now.addingTimeInterval(Double(opportunity) * spacing)
                let store = BackgroundSyncSettingsStore(userDefaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
                let snapshot = try store.loadPendingObserverTypeCodeGenerations()
                let plan = HealthBridgeBackgroundSync.workPlan(
                    reason: .scheduledRefresh, availableQuantityTypeCodes: ["heart_rate"],
                    pendingObserverTypeCodes: Array(snapshot.keys),
                    continuationLaneID: store.nextScheduledWorkLaneID,
                    coreLaneLastSuccess: store.coreLaneLastSuccess, now: date
                )
                XCTAssertLessThanOrEqual(plan.attempts.count, 4)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fifo.path))
                let draft = AutomaticSyncDiagnosticDraft(reason: .scheduledRefresh)
                draft.noteAdmission(.accepted(startedAt: date))
                draft.noteRunAccepted()
                draft.notePlan(plan.attempts.map(\.lane))
                let completed = try await BackgroundSyncWorkExecutor.execute(
                    plan: plan,
                    prepare: { try store.persistNextScheduledWorkLaneID($0.nextScheduledLaneID) },
                    runLane: { lane in
                        attempted.append(lane)
                        draft.noteAttempt(lane)
                        draft.noteQuery(.records, newestSampleAge: 0, now: date)
                        let items = [UUID(), UUID()]
                        try JSONEncoder().encode(items).write(to: fifo, options: .atomic)
                        let queued = try JSONDecoder().decode([UUID].self, from: Data(contentsOf: fifo))
                        draft.noteQueued(itemIDs: queued, complete: true, now: date)
                        try store.markPendingObserverTypeCodes(["sleep_analysis"])
                        try BackgroundSyncWorkExecutor.recordQueuedCoreLaneProgress(
                            lane: lane, querySucceeded: true, laneSucceeded: true, enqueueFailed: false,
                            pendingBefore: 0, pendingAfter: queued.count,
                            validate: {}, persist: { try store.recordCoreLaneSuccess($0, at: date) }
                        )
                        // This is before queued reconciliation returns, not an acceptance callback.
                        let reloaded = BackgroundSyncSettingsStore(userDefaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
                        XCTAssertEqual(reloaded.coreLaneLastSuccess[lane.id], date)
                        XCTAssertEqual(reloaded.pendingObserverTypeCodes, dirty.sorted())
                        XCTAssertEqual(reloaded.pendingObserverTypeCodeGenerations["sleep_analysis"], snapshot["sleep_analysis"]! + 1)
                        return false // FIFO single flight: no next lane and no didComplete.
                    },
                    didComplete: { _ in XCTFail("queued work is not observer/delivery completion") }
                )
                XCTAssertTrue(completed.isEmpty)
                XCTAssertEqual(attempted.count, opportunity + 1)
                XCTAssertTrue(AutomaticSyncDiagnosticStore(fileURL: diagnosticsURL).recordFinal(draft.record))
                // A later opportunity accepts each exact FIFO item, then retires its payload.
                var queued = try JSONDecoder().decode([UUID].self, from: Data(contentsOf: fifo))
                while !queued.isEmpty {
                    let head = queued.removeFirst()
                    draft.noteDelivery(itemID: head, outcome: .accepted, now: date)
                    try JSONEncoder().encode(queued).write(to: fifo, options: .atomic)
                }
                try FileManager.default.removeItem(at: fifo)
                XCTAssertTrue(AutomaticSyncDiagnosticStore(fileURL: diagnosticsURL).recordFinal(draft.record))
                let history = AutomaticSyncDiagnosticStore(fileURL: diagnosticsURL).history
                XCTAssertEqual(history.last?.causalChain?.lanes.first?.delivery, .accepted)
            }
            XCTAssertEqual(attempted, cores, "spacing=\(spacing)")
            XCTAssertEqual(Set(BackgroundSyncSettingsStore(userDefaults: defaults).coreLaneLastSuccess.keys), Set(cores.map(\.id)))
        }
    }

    func testUnknownPartialFailedCancelledAndRetiredQueueCannotCreateProgress() async throws {
        let cases: [(Bool, Bool, Bool, Int?, Int?)] = [
            (false, true, false, 0, 1), // not-run/failed/cancelled query
            (true, false, false, 0, 1), // later encoding/store/lane failure
            (true, true, true, 0, 1), // partial or recovered failed enqueue
            (true, true, false, nil, 1), (true, true, false, 0, nil),
            (true, true, false, 1, 2), // pre-existing FIFO head
            (true, true, false, 0, 0), // rejected/retired, not queued evidence
        ]
        for (query, succeeded, failed, before, after) in cases {
            try BackgroundSyncWorkExecutor.recordQueuedCoreLaneProgress(
                lane: .sleep, querySucceeded: query, laneSucceeded: succeeded, enqueueFailed: failed,
                pendingBefore: before, pendingAfter: after,
                validate: {}, persist: { _ in XCTFail("invalid queue evidence") }
            )
        }
        try BackgroundSyncWorkExecutor.recordQueuedCoreLaneProgress(
            lane: .quantity(typeCode: "heart_rate"), querySucceeded: true, laneSucceeded: true, enqueueFailed: false,
            pendingBefore: 0, pendingAfter: 1, validate: {}, persist: { _ in XCTFail("optional is not core progress") }
        )
    }

    func testConnectionFenceAndPersistenceFailuresPropagateWithoutLaterWork() async {
        for fenceFails in [true, false] {
            var events: [String] = []
            do {
                try BackgroundSyncWorkExecutor.recordQueuedCoreLaneProgress(
                    lane: .sleep, querySucceeded: true, laneSucceeded: true, enqueueFailed: false,
                    pendingBefore: 0, pendingAfter: 1,
                    validate: {
                        events.append("fence")
                        if fenceFails { throw CancellationError() }
                    },
                    persist: { _ in events.append("persist"); throw BackgroundSyncSettingsStoreError.persistenceFailed }
                )
                XCTFail("must propagate")
            } catch {
                if fenceFails { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? BackgroundSyncSettingsStoreError, .persistenceFailed) }
            }
            XCTAssertEqual(events, fenceFails ? ["fence"] : ["fence", "persist"])
        }
    }

    func testCancellationAfterQueryBeforeQueuedProgressNeverPersists() async {
        let entered = expectation(description: "query returned and queue durable")
        let finished = expectation(description: "cancelled opportunity returned")
        var resume: CheckedContinuation<Void, Never>?
        let task = Task { @MainActor in
            defer { finished.fulfill() }
            await withCheckedContinuation { resume = $0; entered.fulfill() }
            do {
                try BackgroundSyncWorkExecutor.recordQueuedCoreLaneProgress(
                    lane: .sleep, querySucceeded: true, laneSucceeded: true, enqueueFailed: false,
                    pendingBefore: 0, pendingAfter: 1,
                    validate: {}, persist: { _ in XCTFail("cancelled progress") }
                )
                XCTFail("must throw cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(entry, .completed)
        task.cancel()
        resume?.resume()
        let finish = await XCTWaiter.fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(finish, .completed)
        guard finish == .completed else { return }
        await task.value
    }

    func testOlderOverdueCoresOutrankRepeatedObserverAffinity() async {
        for reason: AutomaticSyncReason in [.observer(typeCode: "sleep_analysis"), .observer(typeCode: "heart_rate")] {
            let plan = HealthBridgeBackgroundSync.workPlan(
                reason: reason, availableQuantityTypeCodes: ["heart_rate"],
                pendingObserverTypeCodes: reason.observerTypeCodes, continuationLaneID: "sleep",
                coreLaneLastSuccess: ["sleep": now], now: now.addingTimeInterval(1_800)
            )
            XCTAssertEqual(plan.attempts.map(\.lane), [.dailyActivity, .steps, .workouts, .sleep])
        }
    }
}
