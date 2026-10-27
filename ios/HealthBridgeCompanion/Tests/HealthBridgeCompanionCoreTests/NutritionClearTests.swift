import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class NutritionClearTests: XCTestCase {
    @MainActor
    func testDirectSplitClearRemovesPayloadsAndReopensWithoutReplay() async throws {
        let outbox = try fixture()
        defer { try? FileManager.default.removeItem(at: outbox.directoryURL) }
        try await outbox.prepareNutritionCompatibility()
        _ = try outbox.nutritionCompatibleItems(for: "synthetic", support: .unsupported)
        XCTAssertEqual(try outbox.pendingItems().count, 3)
        XCTAssertThrowsError(try FileOutbox.assertReadableByLegacyV3Reader(directory: outbox.directoryURL))

        let removed = try outbox.clearPending()

        XCTAssertEqual(removed, 3)
        let reopened = try FileOutbox(directory: outbox.directoryURL)
        XCTAssertTrue(try reopened.pendingItems().isEmpty)
        XCTAssertNil(try reopened.directFinalizationRecordReady(receiverIdentity: "synthetic"))
        XCTAssertNoThrow(try FileOutbox.assertReadableByLegacyV3Reader(directory: outbox.directoryURL))
        XCTAssertFalse(reopened.clearIntentIsActive)
    }

    @MainActor
    func testInterruptedSplitClearResumesWithoutRecoveringDeletedPayloads() async throws {
        let fileManager = InterruptedRemoval()
        let outbox = try fixture(fileManager: fileManager)
        defer { try? FileManager.default.removeItem(at: outbox.directoryURL) }
        try await outbox.prepareNutritionCompatibility()
        _ = try outbox.nutritionCompatibleItems(for: "synthetic", support: .unsupported)
        fileManager.interrupt = true

        XCTAssertThrowsError(try outbox.clearPending()) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteUnknown)
        }
        XCTAssertTrue(outbox.clearIntentIsActive)
        let reopened = try FileOutbox(directory: outbox.directoryURL)
        XCTAssertThrowsError(try reopened.requireUploadAdmission())
        XCTAssertEqual(try reopened.clearPendingWhileIntentIsActive(), 3)
        try reopened.finishClearIntent()

        XCTAssertTrue(try FileOutbox(directory: outbox.directoryURL).pendingItems().isEmpty)
        XCTAssertNil(try reopened.directFinalizationRecordReady(receiverIdentity: "synthetic"))
    }

    @MainActor
    func testClearDiscardsUninstalledSplitIntentWithoutCreatingChildren() async throws {
        enum Interrupted: Error { case split }
        let outbox = try fixture()
        defer { try? FileManager.default.removeItem(at: outbox.directoryURL) }
        try await outbox.prepareNutritionCompatibility()
        outbox.nutritionSplitFault = { if $0 == .intentPersisted { throw Interrupted.split } }
        XCTAssertThrowsError(try outbox.nutritionCompatibleItems(for: "synthetic", support: .unsupported))
        try FileOutbox.beginDestructiveRecovery(directory: outbox.directoryURL)
        let reopened = try FileOutbox(directory: outbox.directoryURL)

        let removed = try reopened.clearPendingWhileIntentIsActive()
        try reopened.finishClearIntent()

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(try FileOutbox(directory: outbox.directoryURL).pendingItems().isEmpty)
        XCTAssertNoThrow(try FileOutbox.assertReadableByLegacyV3Reader(directory: outbox.directoryURL))
    }

    @MainActor
    func testExplicitDirectDestructiveRecoveryAcceptsNutritionManifest() async throws {
        let outbox = try fixture()
        defer { try? FileManager.default.removeItem(at: outbox.directoryURL) }
        try await outbox.prepareNutritionCompatibility()
        _ = try outbox.nutritionCompatibleItems(for: "synthetic", support: .unsupported)
        try FileOutbox.beginDestructiveRecovery(directory: outbox.directoryURL)

        let recovery = try FileOutbox.completeDestructiveRecovery(directory: outbox.directoryURL)

        XCTAssertEqual(recovery.removedPayloadCount, 3)
        XCTAssertTrue(try recovery.outbox.pendingItems().isEmpty)
        XCTAssertFalse(recovery.outbox.clearIntentIsActive)
    }

    @MainActor
    func testMailboxAndFutureNutritionManifestsStillHoldDirectClear() async throws {
        let outbox = try fixture()
        defer { try? FileManager.default.removeItem(at: outbox.directoryURL) }
        try await outbox.prepareNutritionCompatibility()
        let supported = try XCTUnwrap(
            outbox.nutritionCompatibleItems(for: "synthetic", support: .unsupported).first
        )
        let bytes = try Data(contentsOf: supported.fileURL)
        _ = try outbox.compareAndSetDeliveryState(
            itemID: supported.id, expected: nil, updated: .stable(.collected, ownership: nil)
        )
        XCTAssertThrowsError(try outbox.clearPending()) {
            XCTAssertEqual($0 as? FileOutboxMailboxError, .mailboxArtifactsRequireHold)
        }
        try Data(#"{"version":7}"#.utf8).write(
            to: outbox.directoryURL.appendingPathComponent(".fifo-sequence"), options: .atomic
        )

        XCTAssertThrowsError(try outbox.clearPending()) {
            XCTAssertEqual($0 as? FileOutboxMailboxError, .mailboxArtifactsRequireHold)
        }
        XCTAssertFalse(outbox.clearIntentIsActive)
        XCTAssertEqual(try Data(contentsOf: supported.fileURL), bytes)
    }

    @MainActor
    private func fixture(fileManager: FileManager = .default) throws -> FileOutbox {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outbox = try FileOutbox(directory: directory, fileManager: fileManager)
        let window = HealthBridgeTimeWindow(
            startTime: "2026-10-01T00:00:00Z", endTime: "2026-10-02T00:00:00Z"
        )
        let batch = HealthBridgeBatchV1(
            generatedAt: window.endTime, exportWindow: window,
            sources: [HealthBridgeSource(sourceKey: "synthetic.phone", name: "Synthetic Phone", kind: .phone)],
            healthTypes: [
                HealthBridgeHealthType(typeCode: "workout", displayName: "Workout", category: .workout,
                                       defaultUnit: "s", sensitivity: .moderate, aliases: []),
                HealthBridgeHealthType(typeCode: "dietary_protein", displayName: "Protein", category: .nutrition,
                                       defaultUnit: "g", sensitivity: .moderate, aliases: []),
            ],
            samples: [HealthBridgeSample(
                clientRecordID: "synthetic-protein", sourceKey: "synthetic.phone", typeCode: "dietary_protein",
                startTime: window.startTime, endTime: window.endTime, value: 12, unit: "g"
            )],
            workouts: [HealthBridgeWorkout(
                clientRecordID: "synthetic-workout", sourceKey: "synthetic.phone", workoutType: "running",
                startTime: window.startTime, endTime: window.endTime, durationSeconds: 60, energyKcal: 10
            )],
            sleepSessions: [], deletedRecords: [], sync: HealthBridgeSyncContext(syncWindow: window, cursors: [])
        )
        _ = try outbox.enqueueSequence(
            [JSONEncoder().encode(batch)], receiverIdentity: "synthetic",
            cursorCheckpoint: FileOutboxCursorCheckpoint(
                receiverIdentity: "synthetic", sourceKey: "synthetic.phone",
                cursorKind: "dietary_protein", cursorValue: "unaccepted"
            )
        )
        return outbox
    }
}

private final class InterruptedRemoval: FileManager, @unchecked Sendable {
    var interrupt = false

    override func removeItem(at url: URL) throws {
        if interrupt && url.pathExtension == "json" {
            interrupt = false
            throw CocoaError(.fileWriteUnknown)
        }
        try super.removeItem(at: url)
    }
}
