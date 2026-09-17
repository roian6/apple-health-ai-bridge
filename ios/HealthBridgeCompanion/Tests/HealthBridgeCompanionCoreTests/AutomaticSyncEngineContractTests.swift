import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class AutomaticSyncEngineContractTests: XCTestCase {
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

    func testConcurrentTriggersUseDurableStateAndCoalesceOneLaterPass() async throws {
        let fixture = try PendingGenerationFixture()
        defer { fixture.remove() }
        try fixture.store.markPendingObserverTypeCodes(["heart_rate"])
        let observed = TypeCodeRecorder()
        let entered = BoundedAsyncValueLatch<Void>()
        let release = BoundedAsyncValueLatch<Void>()
        let engine = AutomaticSyncEngine(
            pendingStore: fixture.store,
            processType: { typeCode, _ in
                await observed.append(typeCode)
                if typeCode == "heart_rate" {
                    entered.resolve(())
                    _ = await release.wait(timeout: 1)
                }
                return .noPayload
            }
        )
        let firstRun = Task { try await engine.requestRun() }
        _ = await entered.wait(timeout: 1)
        try fixture.store.markPendingObserverTypeCodes(["weight"])

        try await engine.requestRun()
        try await engine.requestRun()
        release.resolve(())
        try await firstRun.value
        let processed = await observed.values

        XCTAssertEqual(processed, ["heart_rate", "weight"])
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
