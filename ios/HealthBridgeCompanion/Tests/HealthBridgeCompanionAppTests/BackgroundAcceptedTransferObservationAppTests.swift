import Foundation
import XCTest
@testable import HealthBridgeCompanion

@MainActor
final class BackgroundAcceptedTransferObservationAppTests: XCTestCase {
    func testPersistedCompletionReplayPreservesAcceptedObservation() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let item = try fixture.enqueueMixed()
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let generation = fixture.settings.receiverSettingsGenerationToken
        let ownership = try FileBackgroundUploadTaskOwnershipStore(
            fileURL: fixture.root.appendingPathComponent("background-tasks.json")
        )
        let completed = BackgroundUploadTaskOwnership(
            taskID: 42, itemID: item.id, receiverGeneration: generation,
            receiverBindingID: binding,
            completion: BackgroundUploadTaskCompletion(
                statusCode: 202, hadTransportError: false, sleepMinimumResetEpoch: nil
            )
        )
        let uploader = BackgroundURLSessionOutboxUploader(
            receiverSettingsStore: fixture.settings,
            acceptedTransferStore: fixture.acceptedTransferStore,
            taskOwnershipStore: ownership
        )
        try ownership.begin(completed)
        await recoverWithoutScheduling(uploader, fixture: fixture)
        let accepted = try XCTUnwrap(fixture.acceptedTransferStore.load(
            bindingID: binding, generation: generation
        ))
        XCTAssertEqual(accepted.evidenceKind, .directResponse)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        let cursors = try FileSyncCursorStore(
            fileURL: fixture.root.appendingPathComponent("sync-cursors.json")
        )
        let cursor = try cursors.cursorValue(
            receiverBindingID: binding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: GenericQuantitySyncBatchFactory.anchoredCursorKind(for: "dietary_protein")
        )
        XCTAssertEqual(cursor, fixture.anchor)
        let retained = LastAcceptedTransferObservation(
            bindingID: binding, generation: generation,
            observedAt: Date(timeIntervalSinceReferenceDate: 456_789), evidenceKind: .directResponse
        )
        fixture.acceptedTransferStore.record(retained)
        try ownership.begin(completed)

        await recoverWithoutScheduling(uploader, fixture: fixture)

        XCTAssertEqual(fixture.acceptedTransferStore.load(
            bindingID: binding, generation: generation
        ), retained)
        XCTAssertTrue(try ownership.records().isEmpty)
        XCTAssertTrue(try fixture.outbox.pendingItems().isEmpty)
        XCTAssertEqual(try cursors.cursorValue(
            receiverBindingID: binding, sourceKey: HealthBridgeAppleHealthSource.phone.sourceKey,
            cursorKind: GenericQuantitySyncBatchFactory.anchoredCursorKind(for: "dietary_protein")
        ), cursor)
        XCTAssertTrue(fixture.receiver.batches.isEmpty)
    }

    private func recoverWithoutScheduling(
        _ uploader: BackgroundURLSessionOutboxUploader, fixture: NutritionFixture
    ) async {
        do {
            _ = try await uploader.schedulePendingUploads(
                outbox: fixture.outbox,
                receiverURL: XCTUnwrap(URL(string: fixture.settings.receiverURLString)),
                bearerToken: fixture.settings.loadBearerToken(),
                receiverGeneration: fixture.settings.receiverSettingsGenerationToken,
                receiverBindingID: XCTUnwrap(fixture.settings.receiverBindingID),
                isUploadAllowed: { false }
            )
            XCTFail("Closed admission must prevent a new background task")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
