import Foundation
import XCTest
@testable import HealthBridgeCompanion

@MainActor
final class CompanionConnectionPresentationAppTests: XCTestCase {
    func testSavedDestinationOmitsPrivateURLPartsAndIgnoresDraftEdits() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        try fixture.settings.save(
            receiverURLString: "https://receiver.example.test:9443/private?token=synthetic-secret",
            bearerToken: "synthetic-token"
        )
        let viewModel = try await fixture.makeViewModel()

        viewModel.receiverURLString = "https://draft.invalid/v1/batches"

        XCTAssertEqual(viewModel.savedReceiverDestination, "receiver.example.test:9443")
    }

    func testSuccessfulCheckReplacesPreviousFailureFeedback() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        fixture.receiver.capability = .offline
        let viewModel = try await fixture.makeViewModel()
        let originalStatus = viewModel.statusMessage
        let originalActivity = viewModel.activityLogMessages
        let originalPhase = viewModel.syncPresentation.phase
        await viewModel.checkConnection()
        let failure = try XCTUnwrap(viewModel.connectionCheckNotice)
        XCTAssertTrue(failure.isError)
        XCTAssertTrue(failure.message.contains("offline"))
        XCTAssertFalse(viewModel.statusIsError)
        XCTAssertEqual(viewModel.statusMessage, originalStatus)
        XCTAssertEqual(viewModel.activityLogMessages, originalActivity)
        XCTAssertEqual(viewModel.syncPresentation.phase, originalPhase)
        fixture.receiver.capability = .supported

        await viewModel.checkConnection()

        let success = try XCTUnwrap(viewModel.connectionCheckNotice)
        XCTAssertFalse(success.isError)
        XCTAssertNotEqual(success.message, failure.message)
        XCTAssertFalse(viewModel.statusIsError)
        XCTAssertEqual(viewModel.statusMessage, originalStatus)
        XCTAssertEqual(viewModel.activityLogMessages, originalActivity)
        XCTAssertTrue(fixture.receiver.batches.isEmpty)
    }

    func testConnectionCheckAndSyncNowKeepTheirResultsSeparate() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let queued = try fixture.enqueueMixed()
        let viewModel = try await fixture.makeViewModel()
        let runtime = HealthBridgeCompanionApplicationRuntime(
            viewModel: viewModel, automaticSyncPlatform: .init(beginBackgroundOwner: { _ in {} })
        )

        fixture.receiver.capability = .offline
        await viewModel.checkConnection()
        let offlineNotice = try XCTUnwrap(viewModel.connectionCheckNotice)
        XCTAssertTrue(offlineNotice.isError)

        await runtime.viewModel.syncAllNow()
        XCTAssertTrue(viewModel.statusIsError)
        XCTAssertTrue(viewModel.statusMessage.contains("Sync stopped:"))
        XCTAssertTrue(fixture.receiver.batches.isEmpty)

        fixture.receiver.capability = .supported
        fixture.receiver.status = 503
        await runtime.viewModel.syncAllNow()
        XCTAssertEqual(fixture.receiver.batches.count, 1)
        XCTAssertTrue(viewModel.statusIsError)
        XCTAssertEqual(viewModel.syncPresentation.phase, .needsAttention)
        XCTAssertEqual(viewModel.connectionCheckNotice?.message, offlineNotice.message)
        XCTAssertEqual(viewModel.connectionCheckNotice?.isError, true)
        XCTAssertNotNil(try fixture.outbox.pendingItem(id: queued.id))
        let failedStatus = viewModel.statusMessage
        let failedActivity = viewModel.activityLogMessages

        await viewModel.checkConnection()

        XCTAssertEqual(viewModel.connectionCheckNotice?.isError, false)
        XCTAssertTrue(viewModel.statusIsError)
        XCTAssertEqual(viewModel.statusMessage, failedStatus)
        XCTAssertEqual(viewModel.activityLogMessages, failedActivity)
        XCTAssertEqual(viewModel.syncPresentation.phase, .needsAttention)
        XCTAssertEqual(fixture.receiver.batches.count, 1)
        XCTAssertNotNil(try fixture.outbox.pendingItem(id: queued.id))
    }

    func testMailboxFolderCheckReportsLocalReadinessWithoutClaimingDelivery() async throws {
        let fixture = try NutritionMailboxFixture(nativePairing: true)
        defer { fixture.base.cleanup() }
        let viewModel = try await fixture.base.makeViewModel(mailbox: fixture)

        await viewModel.checkConnection()

        let notice = try XCTUnwrap(viewModel.connectionCheckNotice)
        XCTAssertFalse(notice.isError)
        XCTAssertTrue(notice.message.contains("Mailbox folder is ready on this iPhone"))
        XCTAssertTrue(notice.message.contains("Receiver delivery has not been verified"))
        XCTAssertNil(viewModel.lastAcceptedTransferObservation)
        XCTAssertEqual(fixture.envelopeNumber, 0)
        XCTAssertTrue(fixture.base.receiver.batches.isEmpty)
    }

    func testDisconnectReportsRecoveryAfterCommittedRemoval() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let viewModel = try await fixture.makeViewModel()
        XCTAssertTrue(viewModel.receiverSettingsSaved)
        let cursorURL = fixture.cursors.fileURL
        try FileManager.default.removeItem(at: cursorURL)
        try FileManager.default.createDirectory(at: cursorURL, withIntermediateDirectories: false)

        let outcome = await viewModel.disconnectReceiver()

        XCTAssertEqual(outcome, .disconnectedWithRecoveryRequired)
        XCTAssertNil(fixture.settings.receiverBindingID)
        XCTAssertFalse(viewModel.receiverSettingsSaved)
        XCTAssertTrue(viewModel.hasTransientPrivateStorageFailure)
    }

    func testDisconnectDistinguishesQueuedRejectionFromOrdinarySuccess() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let queued = try fixture.enqueueMixed()
        let viewModel = try await fixture.makeViewModel()
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let generation = fixture.settings.receiverSettingsGenerationToken

        let rejection = await viewModel.disconnectReceiver()

        guard case .rejected(let message, let pendingOutboxCount, let connectionPreserved) = rejection else {
            return XCTFail("Expected queued work to block disconnect, got \(rejection)")
        }
        XCTAssertTrue(message.contains("Sync Now"))
        XCTAssertTrue(message.contains("Reset Private Sync State"))
        XCTAssertEqual(pendingOutboxCount, 1)
        XCTAssertTrue(connectionPreserved)
        XCTAssertTrue(viewModel.receiverSettingsSaved)
        XCTAssertEqual(fixture.settings.receiverBindingID, binding)
        XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, generation)
        XCTAssertNotNil(try fixture.outbox.pendingItem(id: queued.id))

        try fixture.outbox.markUploaded(queued)
        let success = await viewModel.disconnectReceiver()

        XCTAssertEqual(success, .disconnected(pendingOutboxCount: 0))
        XCTAssertFalse(viewModel.receiverSettingsSaved)
    }
}
