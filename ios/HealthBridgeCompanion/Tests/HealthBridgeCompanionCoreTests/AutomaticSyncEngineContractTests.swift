import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class AutomaticSyncEngineContractTests: XCTestCase {
    @MainActor
    func testRunUsesDeterministicSnapshotContinuesReadFailureAndPayload() async throws {
        let fixture = try PendingGenerationFixture()
        defer { fixture.remove() }
        try fixture.store.markPendingObserverTypeCodes([
            "weight", "heart_rate", "sleep_analysis", "energy",
        ])
        let observed = TypeCodeRecorder()
        let engine = AutomaticSyncEngine(
            pendingStore: fixture.store,
            processType: { typeCode, _ in
                await observed.append(typeCode)
                switch typeCode {
                case "energy":
                    return .retryableReadFailure
                case "heart_rate":
                    return .noPayload
                case "sleep_analysis":
                    return .payloadEnqueued
                default:
                    return .noPayload
                }
            }
        )

        try await engine.requestRun()
        let processed = await observed.values

        XCTAssertEqual(
            processed,
            ["energy", "heart_rate", "sleep_analysis", "weight"]
        )
        XCTAssertEqual(
            try fixture.store.loadPendingObserverTypeCodeGenerations(),
            ["energy": 1, "sleep_analysis": 1]
        )
    }

    @MainActor
    func testSecondTriggerDoesNotDuplicateAlreadyStagedGenerations() async throws {
        let fixture = try PendingGenerationFixture()
        defer { fixture.remove() }
        try fixture.store.markPendingObserverTypeCodes(["heart_rate", "weight"])
        let outboxDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticSyncEngineContractTests.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outboxDirectory) }
        let outbox = try FileOutbox(directory: outboxDirectory)
        let engine = AutomaticSyncEngine(
            pendingStore: fixture.store,
            processType: { typeCode, generations in
                guard let generation = generations[typeCode] else { return .noPayload }
                let retirements = [typeCode: generation]
                if try !outbox.hasPendingGenerationRetirements(retirements) {
                    _ = try outbox.enqueueSequence(
                        [Data("\(typeCode)@\(generation)".utf8)],
                        receiverIdentity: "receiver-a",
                        pendingGenerationRetirements: retirements
                    )
                }
                return .payloadEnqueued
            }
        )

        try await engine.requestRun()
        try await engine.requestRun()

        XCTAssertEqual(
            try outbox.pendingItems().map { try Data(contentsOf: $0.fileURL) },
            [Data("heart_rate@1".utf8), Data("weight@1".utf8)]
        )
        XCTAssertEqual(
            try fixture.store.loadPendingObserverTypeCodeGenerations(),
            ["heart_rate": 1, "weight": 1]
        )
    }

    @MainActor
    func testNewGenerationStagesBehindEarlierGenerationWithoutDuplicateLoop() async throws {
        let fixture = try PendingGenerationFixture()
        defer { fixture.remove() }
        try fixture.store.markPendingObserverTypeCodes(["heart_rate"])
        let outboxDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticSyncEngineContractTests.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outboxDirectory) }
        let outbox = try FileOutbox(directory: outboxDirectory)
        let engine = AutomaticSyncEngine(
            pendingStore: fixture.store,
            processType: { typeCode, generations in
                guard let generation = generations[typeCode] else { return .noPayload }
                let retirements = [typeCode: generation]
                if try !outbox.hasPendingGenerationRetirements(retirements) {
                    _ = try outbox.enqueueSequence(
                        [Data("\(typeCode)@\(generation)".utf8)],
                        receiverIdentity: "receiver-a",
                        pendingGenerationRetirements: retirements
                    )
                }
                return .payloadEnqueued
            }
        )

        try await engine.requestRun()
        try fixture.store.markPendingObserverTypeCodes(["heart_rate"])
        try await engine.requestRun()
        try await engine.requestRun()

        XCTAssertEqual(
            try outbox.pendingItems().map { try Data(contentsOf: $0.fileURL) },
            [Data("heart_rate@1".utf8), Data("heart_rate@2".utf8)]
        )
        XCTAssertEqual(
            try fixture.store.loadPendingObserverTypeCodeGenerations(),
            ["heart_rate": 2]
        )
    }

    @MainActor
    func testObserverBurstAcknowledgesDurableAdmissionsAndUsesOneBoundedWorkOwner() async throws {
        let fixture = try PendingGenerationFixture()
        defer { fixture.remove() }
        let observed = TypeCodeRecorder()
        let entered = BoundedAsyncValueLatch<Void>()
        let release = BoundedAsyncValueLatch<Void>()
        let finished = BoundedAsyncValueLatch<Void>()
        let waitingTriggerStarted = BoundedAsyncValueLatch<Void>()
        let typeCodes = Array(
            HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes.prefix(14)
        )
        let blockedTypeCode = try XCTUnwrap(typeCodes.first)
        XCTAssertEqual(Set(typeCodes).count, 14)
        var activeOwners = 0
        var maximumActiveOwners = 0
        var activeOwnerLeases = 0
        var maximumActiveOwnerLeases = 0
        var ownerLeaseStartCount = 0
        var ownerLeaseFinishCount = 0
        var opportunityCount = 0
        var opportunityDeliveryPhaseCount = 0
        var opportunityFinalStatusCount = 0
        var opportunityReasons: [AutomaticSyncReason] = []
        var opportunityRunIDs: [UUID] = []
        var opportunityBootstrapFlags: [Bool] = []
        let firstObserverRunID = UUID()
        let scheduledRunID = UUID()
        let engine = AutomaticSyncEngine(
            pendingStore: fixture.store,
            processType: { typeCode, _ in
                await observed.append(typeCode)
                if typeCode == blockedTypeCode {
                    entered.resolve(())
                    _ = await release.wait(timeout: 1)
                }
                return .noPayload
            },
            performOpportunity: { opportunity, processPendingTypes in
                activeOwners += 1
                maximumActiveOwners = max(maximumActiveOwners, activeOwners)
                opportunityCount += 1
                opportunityReasons.append(opportunity.reason)
                opportunityRunIDs.append(opportunity.diagnosticRunID)
                opportunityBootstrapFlags.append(opportunity.bootstrapBeforeRun)
                defer {
                    opportunityFinalStatusCount += 1
                    activeOwners -= 1
                    if opportunityFinalStatusCount == 2 {
                        finished.resolve(())
                    }
                }
                _ = try await processPendingTypes()
                opportunityDeliveryPhaseCount += 1
            },
            startOwner: { _ in
                ownerLeaseStartCount += 1
                activeOwnerLeases += 1
                maximumActiveOwnerLeases = max(
                    maximumActiveOwnerLeases,
                    activeOwnerLeases
                )
                return {
                    ownerLeaseFinishCount += 1
                    activeOwnerLeases -= 1
                }
            }
        )
        let callbackCount = typeCodes.count
        var durableAdmissions = Array(repeating: false, count: callbackCount)
        var acknowledgements = Array(repeating: 0, count: callbackCount)
        let admit: @MainActor (Int, String) async -> Void = { index, typeCode in
            await AutomaticSyncObserverEventLifecycle.process(
                startedAt: Date(timeIntervalSince1970: 1_788_000_000),
                admissionHandler: {
                    do {
                        try fixture.store.markPendingObserverTypeCodes([typeCode])
                        durableAdmissions[index] = true
                        return .continueProcessing
                    } catch {
                        XCTFail("Durable observer admission failed: \(error)")
                        return .complete(nil)
                    }
                },
                eventHandler: {
                    engine.requestRunWithoutWaiting(
                        reason: .observer(typeCode: typeCode),
                        diagnosticRunID: index == 0 ? firstObserverRunID : UUID()
                    )
                    return nil
                },
                acknowledge: {
                    XCTAssertTrue(durableAdmissions[index])
                    acknowledgements[index] += 1
                },
                persistDiagnostic: { _, _ in
                    XCTFail("Observer callbacks must not own diagnostic finalization.")
                }
            )
        }

        await admit(0, blockedTypeCode)
        guard await entered.wait(timeout: 1) != nil else {
            release.resolve(())
            XCTFail("The first automatic opportunity did not start.")
            return
        }
        for index in 1..<callbackCount {
            await admit(index, typeCodes[index])
        }
        let waitingTrigger = Task { @MainActor in
            waitingTriggerStarted.resolve(())
            try? await engine.requestRun(
                reason: .scheduledRefresh,
                diagnosticRunID: scheduledRunID,
                bootstrapBeforeRun: true
            )
        }
        guard await waitingTriggerStarted.wait(timeout: 1) != nil else {
            release.resolve(())
            XCTFail("The scheduled trigger did not join the active opportunity.")
            return
        }
        await Task.yield()
        waitingTrigger.cancel()

        XCTAssertEqual(acknowledgements, Array(repeating: 1, count: callbackCount))
        release.resolve(())
        guard await finished.wait(timeout: 1) != nil else {
            XCTFail("The bounded automatic opportunities did not finish.")
            return
        }
        await waitingTrigger.value
        let processed = await observed.values

        XCTAssertEqual(processed, typeCodes)
        XCTAssertEqual(maximumActiveOwners, 1)
        XCTAssertEqual(activeOwners, 0)
        XCTAssertEqual(ownerLeaseStartCount, 1)
        XCTAssertEqual(ownerLeaseFinishCount, 1)
        XCTAssertEqual(maximumActiveOwnerLeases, 1)
        XCTAssertEqual(activeOwnerLeases, 0)
        XCTAssertEqual(opportunityCount, 2)
        XCTAssertEqual(opportunityDeliveryPhaseCount, 2)
        XCTAssertEqual(opportunityFinalStatusCount, 2)
        XCTAssertEqual(
            opportunityReasons,
            [
                .observer(typeCode: blockedTypeCode),
                .scheduledRefresh,
            ]
        )
        XCTAssertEqual(opportunityRunIDs, [firstObserverRunID, scheduledRunID])
        XCTAssertEqual(opportunityBootstrapFlags, [false, true])
        XCTAssertTrue(
            try fixture.store.loadPendingObserverTypeCodeGenerations().isEmpty
        )
    }
}

private actor TypeCodeRecorder {
    private var recorded: [String] = []

    var values: [String] { recorded }

    func append(_ typeCode: String) {
        recorded.append(typeCode)
    }
}

@MainActor
private final class PendingGenerationFixture {
    let store: BackgroundSyncSettingsStore
    private let root: URL
    private let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        suiteName = "AutomaticSyncEngineContractTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName)
        store = BackgroundSyncSettingsStore(
            userDefaults: defaults,
            observerDirtinessStore: FileBackgroundObserverDirtinessStore(
                fileURL: root.appendingPathComponent("pending.json")
            )
        )
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
