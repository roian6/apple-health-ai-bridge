import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class OutboxPendingGenerationFinalizationTests: XCTestCase {
    func testIndependentStagedSequencesFinalizeOwnProgressInFIFOOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutboxPendingGenerationTests-\(UUID().uuidString)")
        let outboxDirectory = root.appendingPathComponent("outbox")
        let cursorURL = root.appendingPathComponent("cursors.json")
        let pendingURL = root.appendingPathComponent("pending.json")
        let suiteName = "OutboxPendingGenerationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let pendingStore = BackgroundSyncSettingsStore(
            userDefaults: defaults,
            observerDirtinessStore: FileBackgroundObserverDirtinessStore(fileURL: pendingURL)
        )
        try pendingStore.markPendingObserverTypeCodes(["heart_rate", "steps"])
        let generations = try pendingStore.loadPendingObserverTypeCodeGenerations()
        let stepsCheckpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: "receiver-a",
            sourceKey: "synthetic-source",
            cursorKind: "steps-anchor",
            cursorValue: "steps-v1"
        )
        let heartCheckpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: "receiver-a",
            sourceKey: "synthetic-source",
            cursorKind: "heart-anchor",
            cursorValue: "heart-v1"
        )
        let outbox = try FileOutbox(directory: outboxDirectory)
        let stepsItem = try XCTUnwrap(outbox.enqueueSequence(
            [Data("steps".utf8)],
            receiverIdentity: "receiver-a",
            cursorCheckpoint: stepsCheckpoint,
            pendingGenerationRetirements: ["steps": try XCTUnwrap(generations["steps"])]
        ).first)
        let heartItem = try XCTUnwrap(outbox.enqueueSequence(
            [Data("heart".utf8)],
            receiverIdentity: "receiver-a",
            cursorCheckpoint: heartCheckpoint,
            pendingGenerationRetirements: [
                "heart_rate": try XCTUnwrap(generations["heart_rate"]),
            ]
        ).first)
        XCTAssertEqual(try outbox.pendingItems().map(\.id), [stepsItem.id, heartItem.id])
        XCTAssertTrue(try outbox.hasPendingGenerationRetirements([
            "steps": try XCTUnwrap(generations["steps"]),
        ]))
        XCTAssertFalse(try outbox.hasPendingGenerationRetirements(["steps": 2]))

        let cursorStore = try FileSyncCursorStore(fileURL: cursorURL)
        let finalizer = OutboxDeliveryCursorFinalizer(
            outbox: try FileOutbox(directory: outboxDirectory),
            cursorStore: cursorStore,
            pendingGenerationStore: pendingStore
        )
        XCTAssertFalse(try finalizer.recordDirectReceiverAcceptance(
            itemID: heartItem.id,
            receiverBindingID: "receiver-a"
        ))
        XCTAssertNil(try cursorStore.cursorValue(
            receiverBindingID: "receiver-a",
            sourceKey: "synthetic-source",
            cursorKind: "heart-anchor"
        ))
        XCTAssertTrue(try finalizer.recordDirectReceiverAcceptance(
            itemID: stepsItem.id,
            receiverBindingID: "receiver-a"
        ))
        XCTAssertEqual(
            try cursorStore.cursorValue(
                receiverBindingID: "receiver-a",
                sourceKey: "synthetic-source",
                cursorKind: "steps-anchor"
            ),
            "steps-v1"
        )
        XCTAssertNil(try cursorStore.cursorValue(
            receiverBindingID: "receiver-a",
            sourceKey: "synthetic-source",
            cursorKind: "heart-anchor"
        ))
        XCTAssertEqual(
            try pendingStore.loadPendingObserverTypeCodeGenerations(),
            ["heart_rate": try XCTUnwrap(generations["heart_rate"])]
        )

        XCTAssertTrue(try finalizer.finalizeDirectAcknowledgments(
            receiverBindingID: "receiver-a"
        ))
        XCTAssertEqual(
            try cursorStore.cursorValue(
                receiverBindingID: "receiver-a",
                sourceKey: "synthetic-source",
                cursorKind: "heart-anchor"
            ),
            "heart-v1"
        )
        XCTAssertTrue(try pendingStore.loadPendingObserverTypeCodeGenerations().isEmpty)
        XCTAssertTrue(try outbox.pendingItems().isEmpty)
    }

    func testRetirementTokensSurviveRelaunchWithoutCursorAndBecomeReadyAfterWholeSequence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutboxPendingGenerationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let retirements = ["heart_rate": 7]
        let initial = try FileOutbox(directory: directory)
        let items = try initial.enqueueSequence(
            [Data("one".utf8), Data("two".utf8)],
            receiverIdentity: "receiver-a",
            pendingGenerationRetirements: retirements
        )

        let firstAcceptance = try FileOutbox(directory: directory)
            .recordDirectUploadAccepted(
                itemID: items[0].id,
                receiverIdentity: "receiver-a"
            )
        XCTAssertNil(firstAcceptance)

        let finalAcceptance = try XCTUnwrap(
            FileOutbox(directory: directory).recordDirectUploadAccepted(
                itemID: items[1].id,
                receiverIdentity: "receiver-a"
            )
        )
        XCTAssertNil(finalAcceptance.cursorCheckpoint)
        XCTAssertEqual(finalAcceptance.pendingGenerationRetirements, retirements)
    }

    func testFinalizerCommitsProgressRetiresOnlyMatchingGenerationsAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutboxPendingGenerationTests-\(UUID().uuidString)")
        let outboxDirectory = root.appendingPathComponent("outbox")
        let cursorURL = root.appendingPathComponent("cursors.json")
        let pendingURL = root.appendingPathComponent("pending.json")
        let suiteName = "OutboxPendingGenerationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let pendingStore = BackgroundSyncSettingsStore(
            userDefaults: defaults,
            observerDirtinessStore: FileBackgroundObserverDirtinessStore(fileURL: pendingURL)
        )
        try pendingStore.markPendingObserverTypeCodes([
            "heart_rate", "oxygen_saturation",
        ])
        let retirements = try pendingStore.loadPendingObserverTypeCodeGenerations()
        let checkpoint = FileOutboxCursorCheckpoint(
            receiverIdentity: "receiver-a",
            sourceKey: "synthetic-source",
            cursorKind: "synthetic-anchor",
            cursorValue: "anchor-v2",
            coreLaneUploadProof: .steps
        )
        let outbox = try FileOutbox(directory: outboxDirectory)
        let item = try XCTUnwrap(outbox.enqueueSequence(
            [Data("payload".utf8)],
            receiverIdentity: "receiver-a",
            cursorCheckpoint: checkpoint,
            pendingGenerationRetirements: retirements
        ).first)
        try pendingStore.markPendingObserverTypeCodes(["heart_rate"])

        let cursorStore = try FileSyncCursorStore(fileURL: cursorURL)
        let finalizer = OutboxDeliveryCursorFinalizer(
            outbox: try FileOutbox(directory: outboxDirectory),
            cursorStore: cursorStore,
            proofStore: CoreLaneUploadProofStore(userDefaults: defaults),
            pendingGenerationStore: pendingStore
        )
        XCTAssertTrue(try finalizer.recordDirectReceiverAcceptance(
            itemID: item.id,
            receiverBindingID: "receiver-a"
        ))

        XCTAssertEqual(
            try cursorStore.cursorValue(
                receiverBindingID: checkpoint.receiverIdentity,
                sourceKey: checkpoint.sourceKey,
                cursorKind: checkpoint.cursorKind
            ),
            checkpoint.cursorValue
        )
        XCTAssertTrue(
            CoreLaneUploadProofStore(userDefaults: defaults).hasUploadedRecords(
                lane: .steps,
                receiverBindingID: checkpoint.receiverIdentity
            )
        )
        XCTAssertEqual(
            try pendingStore.loadPendingObserverTypeCodeGenerations(),
            ["heart_rate": 2]
        )

        let relaunched = OutboxDeliveryCursorFinalizer(
            outbox: try FileOutbox(directory: outboxDirectory),
            cursorStore: cursorStore,
            proofStore: CoreLaneUploadProofStore(userDefaults: defaults),
            pendingGenerationStore: pendingStore
        )
        XCTAssertFalse(try relaunched.recordDirectReceiverAcceptance(
            itemID: item.id,
            receiverBindingID: "receiver-a"
        ))
        XCTAssertEqual(
            try pendingStore.loadPendingObserverTypeCodeGenerations(),
            ["heart_rate": 2]
        )
    }
}
