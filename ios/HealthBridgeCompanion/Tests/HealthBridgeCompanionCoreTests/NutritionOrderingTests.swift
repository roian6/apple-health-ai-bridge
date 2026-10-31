import Foundation
import XCTest
#if canImport(HealthBridgeCompanion)
@testable import HealthBridgeCompanion
#else
@testable import HealthBridgeCompanionCore
#endif

final class NutritionOrderingTests: XCTestCase {
    @MainActor
    func testSupportedProjectionPrecedesNewerWorkoutUpdate() async throws {
        // Given an older mixed batch followed by an update to the same workout.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try FileOutbox(directory: root)
        _ = try outbox.enqueue(makeBatch(energy: 10, includesNutrition: true), receiverIdentity: "synthetic")
        _ = try outbox.enqueue(makeBatch(energy: 20, includesNutrition: false), receiverIdentity: "synthetic")
        try await outbox.prepareNutritionCompatibility()

        // When a legacy receiver receives the supported records.
        var workouts: [HealthBridgeWorkout] = []
        for _ in 0..<3 {
            guard let item = try outbox.nutritionCompatibleItems(for: "synthetic", support: .unsupported).first else { break }
            workouts += try JSONDecoder().decode(HealthBridgeBatchV1.self, from: Data(contentsOf: item.fileURL)).workouts
            try outbox.markUploaded(item)
        }

        // Then the newer value is delivered last, not overwritten by the projection.
        XCTAssertEqual(workouts.map(\.clientRecordID), ["synthetic-workout", "synthetic-workout"])
        XCTAssertEqual(workouts.map(\.energyKcal), [10, 20])
    }

    @MainActor
    func testCapabilityUpgradeDoesNotReplayAcknowledgedOlderWorkout() async throws {
        // Given acknowledged supported records followed by a newer acknowledged update.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try FileOutbox(directory: root)
        _ = try outbox.enqueue(makeBatch(energy: 10, includesNutrition: true), receiverIdentity: "synthetic")
        try await outbox.prepareNutritionCompatibility()
        for item in try outbox.nutritionCompatibleItems(for: "synthetic", support: .unsupported) {
            try outbox.markUploaded(item)
        }
        _ = try outbox.enqueue(makeBatch(energy: 20, includesNutrition: false), receiverIdentity: "synthetic")
        try await outbox.prepareNutritionCompatibility()
        for item in try outbox.nutritionCompatibleItems(for: "synthetic", support: .unsupported) {
            try outbox.markUploaded(item)
        }
        let reopened = try FileOutbox(directory: root)
        try await reopened.prepareNutritionCompatibility()

        // When nutrition becomes supported after reopening the durable queue.
        let selected = try reopened.nutritionCompatibleItems(for: "synthetic", support: .supported)
        let batches = try selected.map {
            try JSONDecoder().decode(HealthBridgeBatchV1.self, from: Data(contentsOf: $0.fileURL))
        }

        // Then nutrition is still delivered without replaying stale supported values.
        XCTAssertEqual(batches.flatMap(\.samples).map(\.value), [12])
        XCTAssertTrue(batches.flatMap(\.workouts).isEmpty)
    }

    @MainActor
    func testSplitCheckpointWaitsForBothChildAcceptances() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        let cursors = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: "synthetic", sourceKey: "synthetic.phone",
            cursorKind: "dietary_protein", cursorValue: "accepted"
        )
        _ = try outbox.enqueueSequence(
            [makeBatch(energy: 10, includesNutrition: true)],
            receiverIdentity: "synthetic", cursorCheckpoint: checkpoint
        )
        let finalizer = OutboxDeliveryCursorFinalizer(outbox: outbox, cursorStore: cursors)
        try await outbox.prepareNutritionCompatibility()
        let supported = try XCTUnwrap(outbox.nutritionCompatibleItems(for: "synthetic", support: .unknown).first)

        XCTAssertFalse(try finalizer.recordDirectReceiverAcceptance(
            itemID: supported.id, receiverBindingID: "synthetic"
        ))
        XCTAssertNil(try cursors.cursorValue(
            receiverBindingID: "synthetic", sourceKey: "synthetic.phone", cursorKind: "dietary_protein"
        ))
        let remainder = try XCTUnwrap(outbox.nutritionCompatibleItems(for: "synthetic", support: .supported).first)
        XCTAssertTrue(try finalizer.recordDirectReceiverAcceptance(
            itemID: remainder.id, receiverBindingID: "synthetic"
        ))

        XCTAssertEqual(try cursors.cursorValue(
            receiverBindingID: "synthetic", sourceKey: "synthetic.phone", cursorKind: "dietary_protein"
        ), "accepted")
        XCTAssertTrue(try FileOutbox(directory: outbox.directoryURL).pendingItems().isEmpty)
    }

    @MainActor
    func testOrdinaryFinalEntryCompletesTransactionAfterSplitAcceptance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try FileOutbox(directory: root.appendingPathComponent("outbox"))
        let cursors = try FileSyncCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
        _ = try outbox.enqueueSequence(
            [makeBatch(energy: 10, includesNutrition: true), makeBatch(energy: 20, includesNutrition: false)],
            receiverIdentity: "synthetic",
            cursorCheckpoint: FileOutboxCursorCheckpoint(
                receiverIdentity: "synthetic", sourceKey: "synthetic.phone",
                cursorKind: "dietary_protein", cursorValue: "complete"
            )
        )
        let finalizer = OutboxDeliveryCursorFinalizer(outbox: outbox, cursorStore: cursors)
        try await outbox.prepareNutritionCompatibility()
        let supported = try XCTUnwrap(outbox.nutritionCompatibleItems(for: "synthetic", support: .unknown).first)
        XCTAssertFalse(try finalizer.recordDirectReceiverAcceptance(
            itemID: supported.id, receiverBindingID: "synthetic"
        ))
        let remainder = try XCTUnwrap(outbox.nutritionCompatibleItems(for: "synthetic", support: .supported).first)
        XCTAssertFalse(try finalizer.recordDirectReceiverAcceptance(
            itemID: remainder.id, receiverBindingID: "synthetic"
        ))
        let last = try XCTUnwrap(outbox.nutritionCompatibleItems(for: "synthetic", support: .supported).first)

        let finalized = try finalizer.recordDirectReceiverAcceptance(itemID: last.id, receiverBindingID: "synthetic")

        XCTAssertTrue(finalized)
        XCTAssertEqual(try cursors.cursorValue(
            receiverBindingID: "synthetic", sourceKey: "synthetic.phone", cursorKind: "dietary_protein"
        ), "complete")
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
    }

    @MainActor
    func testSplitRecoversEveryPersistedBoundaryWithoutParentReplay() async throws {
        enum Interrupted: Error { case boundary }
        for boundary in NutritionSplitBoundary.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let outbox = try FileOutbox(directory: root)
            let bytes = try makeBatch(energy: 10, includesNutrition: true)
            let parent = try outbox.enqueue(bytes, receiverIdentity: "synthetic")
            var interrupted = false
            var received: [HealthBridgeBatchV1] = []
            outbox.nutritionSplitFault = {
                if $0 == boundary { interrupted = true; throw Interrupted.boundary }
            }
            do {
                try await outbox.prepareNutritionCompatibility()
                for support: NutritionSupport in [.unsupported, .supported] {
                    if let item = try outbox.nutritionCompatibleItems(for: "synthetic", support: support).first {
                        XCTAssertNotEqual(item.id, parent.id)
                        received.append(try JSONDecoder().decode(
                            HealthBridgeBatchV1.self, from: Data(contentsOf: item.fileURL)
                        ))
                        try outbox.markUploaded(item)
                    }
                }
                XCTFail("Did not reach \(boundary)")
            } catch Interrupted.boundary {}
            XCTAssertTrue(interrupted)
            if FileManager.default.fileExists(atPath: parent.fileURL.path) {
                XCTAssertEqual(try Data(contentsOf: parent.fileURL), bytes)
            }
            let reopened = try FileOutbox(directory: root)
            try await reopened.prepareNutritionCompatibility()
            for _ in 0..<3 {
                guard let item = try reopened.nutritionCompatibleItems(for: "synthetic", support: .supported).first else { break }
                XCTAssertNotEqual(item.id, parent.id)
                received.append(try JSONDecoder().decode(
                    HealthBridgeBatchV1.self, from: Data(contentsOf: item.fileURL)
                ))
                try reopened.markUploaded(item)
            }
            XCTAssertEqual(received.flatMap(\.workouts).map(\.energyKcal), [10], "\(boundary)")
            XCTAssertEqual(received.flatMap(\.samples).map(\.value), [12], "\(boundary)")
            XCTAssertTrue(try reopened.pendingItems().isEmpty, "\(boundary)")
        }
    }

    @MainActor
    func testLegacyMixedQueueIsHeldWithoutDeletingOriginal() async throws {
        struct Entry: Codable {
            let sequence: UInt64
            let id: String
            let receiverIdentity: String
        }
        struct Manifest: Codable {
            let version: Int
            let nextSequence: UInt64
            let entries: [Entry]
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try FileOutbox(directory: root)
        let bytes = try makeBatch(energy: 10, includesNutrition: true)
        let original = try outbox.enqueue(bytes, receiverIdentity: "synthetic")
        let manifestURL = root.appendingPathComponent(".fifo-sequence")
        let legacy = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        try JSONEncoder().encode(legacy).write(to: manifestURL, options: .atomic)
        let reopened = try FileOutbox(directory: root)
        try await reopened.prepareNutritionCompatibility()

        for support: NutritionSupport in [.unknown, .supported] {
            XCTAssertThrowsError(try reopened.nutritionCompatibleItems(for: "synthetic", support: support)) {
                guard case FileOutboxNutritionError.legacyProjectionRequiresRecovery = $0 else {
                    return XCTFail("Unexpected error: \($0)")
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: original.fileURL), bytes)
        XCTAssertEqual(try reopened.pendingItems().map(\.id), [original.id])
    }

    @MainActor
    func testSplitRejectsPayloadTamperingAndOldReader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = try FileOutbox(directory: root)
        _ = try outbox.enqueue(makeBatch(energy: 10, includesNutrition: true), receiverIdentity: "synthetic")
        try await outbox.prepareNutritionCompatibility()
        let supported = try XCTUnwrap(outbox.nutritionCompatibleItems(for: "synthetic", support: .unknown).first)
        XCTAssertThrowsError(try FileOutbox.assertReadableByLegacyV3Reader(directory: root))

        try makeBatch(energy: 99, includesNutrition: false).write(to: supported.fileURL, options: .atomic)

        XCTAssertThrowsError(try FileOutbox(directory: root)) {
            guard case FileOutboxNutritionError.invalidSplit = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    private func makeBatch(energy: Double, includesNutrition: Bool) throws -> Data {
        let window = HealthBridgeTimeWindow(
            startTime: "2026-10-01T00:00:00Z", endTime: "2026-10-02T00:00:00Z"
        )
        let nutrition = HealthBridgeHealthType(
            typeCode: "dietary_protein", displayName: "Protein", category: .nutrition,
            defaultUnit: "g", sensitivity: .moderate, aliases: []
        )
        let workout = HealthBridgeHealthType(
            typeCode: "workout", displayName: "Workout", category: .workout,
            defaultUnit: "s", sensitivity: .moderate, aliases: []
        )
        let batch = HealthBridgeBatchV1(
            generatedAt: window.endTime, exportWindow: window,
            sources: [HealthBridgeSource(sourceKey: "synthetic.phone", name: "Synthetic Phone", kind: .phone)],
            healthTypes: includesNutrition ? [workout, nutrition] : [workout],
            samples: includesNutrition ? [HealthBridgeSample(
                clientRecordID: "synthetic-protein", sourceKey: "synthetic.phone", typeCode: "dietary_protein",
                startTime: window.startTime, endTime: window.endTime, value: 12, unit: "g"
            )] : [],
            workouts: [HealthBridgeWorkout(
                clientRecordID: "synthetic-workout", sourceKey: "synthetic.phone", workoutType: "running",
                startTime: window.startTime, endTime: window.endTime,
                durationSeconds: 60, energyKcal: energy
            )],
            sleepSessions: [], deletedRecords: [],
            sync: HealthBridgeSyncContext(syncWindow: window, cursors: [])
        )
        return try JSONEncoder().encode(batch)
    }
}
