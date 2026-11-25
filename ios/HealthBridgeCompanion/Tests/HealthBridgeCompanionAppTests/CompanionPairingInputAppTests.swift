import Combine
import Foundation
import XCTest
@testable import HealthBridgeCompanion

@MainActor
final class CompanionPairingInputAppTests: XCTestCase {
    func testMalformedPasteExposesTypedErrorWithoutCommittingConnection() async throws {
        let fixture = try NutritionFixture(directPairing: false)
        defer { fixture.cleanup() }
        let viewModel = try await fixture.makeViewModel()
        viewModel.pairingImportText = "not-a-link"

        await viewModel.importPairingText()

        XCTAssertEqual(viewModel.pairingInputError, .invalidJSON)
        XCTAssertNil(fixture.settings.receiverBindingID)
        XCTAssertFalse(viewModel.hasPendingPairing)
        XCTAssertEqual(viewModel.pairingImportText, "not-a-link")
    }

    func testIncomingLinkWithoutPayloadExposesTypedError() async throws {
        let fixture = try NutritionFixture(directPairing: false)
        defer { fixture.cleanup() }
        let viewModel = try await fixture.makeViewModel()
        let link = try XCTUnwrap(URL(string: "healthbridge://pair"))

        await viewModel.importPairingURL(link)

        XCTAssertEqual(viewModel.pairingInputError, .missingPayload)
        XCTAssertNil(fixture.settings.receiverBindingID)
    }

    func testManualCodeErrorReplacesPreviousInputError() async throws {
        let fixture = try NutritionFixture(directPairing: false)
        defer { fixture.cleanup() }
        let viewModel = try await fixture.makeViewModel()
        viewModel.pairingImportText = "not-a-link"
        await viewModel.importPairingText()
        viewModel.manualPairingServer = "http://127.0.0.1:8765"
        viewModel.manualPairingCode = "bad"

        await viewModel.redeemManualPairing()

        XCTAssertEqual(viewModel.pairingInputError, .invalidInvitationCode)
        XCTAssertNil(fixture.settings.receiverBindingID)
    }

    func testSuccessfulRetryClearsInputError() async throws {
        let fixture = try NutritionFixture(directPairing: false)
        defer { fixture.cleanup() }
        let viewModel = try await fixture.makeViewModel()
        viewModel.pairingImportText = "not-a-link"
        await viewModel.importPairingText()
        XCTAssertEqual(viewModel.pairingInputError, .invalidJSON)
        viewModel.pairingImportText = legacySetupMaterial

        await viewModel.importPairingText()

        XCTAssertNil(viewModel.pairingInputError)
        XCTAssertTrue(viewModel.receiverSettingsSaved)
        XCTAssertFalse(viewModel.statusIsError)
    }

    func testLegacyReplacementShowsCleanupFailureAndClearsItOnRetry() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let originalBinding = try XCTUnwrap(fixture.settings.receiverBindingID)
        var drainCanFinish = false
        weak var observedViewModel: HealthBridgeCompanionViewModel?
        let viewModel = try await fixture.makeViewModel(terminalBackgroundPayloadDrain: {
            if drainCanFinish {
                XCTAssertNil(observedViewModel?.setupLinkReplacementFailure)
            }
            return drainCanFinish
        })
        observedViewModel = viewModel
        viewModel.pairingImportText = legacySetupMaterial

        await viewModel.importPairingText()

        XCTAssertTrue(viewModel.receiverSettingsSaved)
        XCTAssertEqual(fixture.settings.receiverBindingID, originalBinding)
        XCTAssertFalse(viewModel.hasPendingPairing)
        XCTAssertNil(viewModel.pairingInputCorrection)
        XCTAssertFalse(viewModel.isPairing)
        let failure = try XCTUnwrap(viewModel.setupLinkReplacementFailure)
        XCTAssertTrue(failure.contains("Background upload cleanup"))
        XCTAssertTrue(failure.contains("saved connection was not replaced"))
        XCTAssertFalse(failure.contains("synthetic-pairing-token"))
        XCTAssertNil(viewModel.connectionCheckNotice)

        await viewModel.checkConnection()
        XCTAssertEqual(viewModel.connectionCheckNotice?.isError, false)
        XCTAssertEqual(viewModel.setupLinkReplacementFailure, failure)

        drainCanFinish = true
        await viewModel.importPairingText()

        XCTAssertNil(viewModel.setupLinkReplacementFailure)
        XCTAssertTrue(viewModel.receiverSettingsSaved)
        XCTAssertNotEqual(try XCTUnwrap(fixture.settings.receiverBindingID), originalBinding)
    }

    func testLegacyReplacementDoesNotPromoteSupersededCommit() async throws {
        try await assertReplacementDoesNotPromoteSupersededCommit(legacySetupMaterial)
    }

    func testConfirmedPrivateResetClearsReplacementWarningAndKeepsSavedReceiver() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        var drainCanFinish = false
        weak var observedViewModel: HealthBridgeCompanionViewModel?
        let (viewModel, warning) = try await makeReplacementWarning(fixture) {
            if drainCanFinish {
                XCTAssertNotNil(observedViewModel?.setupLinkReplacementFailure)
            }
            return drainCanFinish
        }
        observedViewModel = viewModel
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let generation = fixture.settings.receiverSettingsGenerationToken
        let payload = try fixture.enqueueMixed()
        XCTAssertEqual(viewModel.setupLinkReplacementFailure, warning)

        drainCanFinish = true
        await viewModel.clearPendingOutbox()

        XCTAssertFalse(viewModel.statusIsError)
        XCTAssertTrue(viewModel.statusMessage.contains("Cleared 1 queued upload(s)"))
        let reopened = try FileOutbox(directory: fixture.outbox.directoryURL)
        XCTAssertNil(try reopened.pendingItem(id: payload.id))
        XCTAssertFalse(reopened.destructiveRecoveryIsRequested)
        XCTAssertTrue(viewModel.receiverSettingsSaved)
        XCTAssertEqual(fixture.settings.receiverBindingID, binding)
        XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, generation)
        XCTAssertNil(viewModel.pairingInputCorrection)
        XCTAssertNil(viewModel.setupLinkReplacementFailure)
    }

    func testFailedPrivateResetKeepsReplacementWarning() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        var drainCanFinish = false
        let (viewModel, warning) = try await makeReplacementWarning(fixture) { drainCanFinish }
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let payload = try fixture.enqueueMixed()
        let bytes = try Data(contentsOf: payload.fileURL)
        // A file occupying the reset-epoch directory prevents durable transfer-evidence invalidation.
        try Data().write(to: fixture.acceptedTransferResetEpochURL.deletingLastPathComponent())

        drainCanFinish = true
        await viewModel.clearPendingOutbox()

        XCTAssertTrue(viewModel.statusIsError)
        XCTAssertTrue(viewModel.statusMessage.contains("Clearing queued uploads failed"))
        XCTAssertTrue(FileOutbox.destructiveRecoveryIsRequested(directory: fixture.outbox.directoryURL))
        XCTAssertEqual(try Data(contentsOf: payload.fileURL), bytes)
        XCTAssertTrue(viewModel.receiverSettingsSaved)
        XCTAssertEqual(fixture.settings.receiverBindingID, binding)
        XCTAssertEqual(viewModel.setupLinkReplacementFailure, warning)
    }

    func testDeferredPrivateResetKeepsReplacementWarning() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let (viewModel, warning) = try await makeReplacementWarning(fixture) { false }
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let payload = try fixture.enqueueMixed()
        let bytes = try Data(contentsOf: payload.fileURL)

        await viewModel.clearPendingOutbox()

        XCTAssertTrue(viewModel.statusIsError)
        XCTAssertTrue(viewModel.statusMessage.contains("iOS is still finalizing a background transfer"))
        XCTAssertTrue(FileOutbox.destructiveRecoveryIsRequested(directory: fixture.outbox.directoryURL))
        XCTAssertEqual(try Data(contentsOf: payload.fileURL), bytes)
        XCTAssertTrue(viewModel.receiverSettingsSaved)
        XCTAssertEqual(fixture.settings.receiverBindingID, binding)
        XCTAssertEqual(viewModel.setupLinkReplacementFailure, warning)
    }

    func testBootstrapFinishesDeferredResetAndClearsReplacementWarning() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        var drainCanFinish = false
        let (viewModel, warning) = try await makeReplacementWarning(fixture) { drainCanFinish }
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let generation = fixture.settings.receiverSettingsGenerationToken
        let payload = try fixture.enqueueMixed()

        await viewModel.clearPendingOutbox()
        XCTAssertTrue(FileOutbox.destructiveRecoveryIsRequested(directory: fixture.outbox.directoryURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.fileURL.path))
        XCTAssertEqual(viewModel.setupLinkReplacementFailure, warning)

        drainCanFinish = true
        await viewModel.retryPrivateStorage()

        XCTAssertFalse(viewModel.statusIsError)
        XCTAssertTrue(viewModel.statusMessage.contains("Finished the interrupted deletion of 1 queued upload(s)"))
        let reopened = try FileOutbox(directory: fixture.outbox.directoryURL)
        XCTAssertNil(try reopened.pendingItem(id: payload.id))
        XCTAssertFalse(reopened.destructiveRecoveryIsRequested)
        XCTAssertTrue(viewModel.receiverSettingsSaved)
        XCTAssertEqual(fixture.settings.receiverBindingID, binding)
        XCTAssertEqual(fixture.settings.receiverSettingsGenerationToken, generation)
        XCTAssertNil(viewModel.setupLinkReplacementFailure)
    }

    func testUnconfirmedPrivateResetLeavesReplacementWarningAndQueueIntact() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        var drains = 0
        let (viewModel, warning) = try await makeReplacementWarning(fixture) {
            drains += 1
            return false
        }
        let binding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let payload = try fixture.enqueueMixed()

        // Dismissing the Settings dialog never calls clearPendingOutbox().
        // Ordinary recovery and connection actions must not infer confirmation.
        await viewModel.retryPrivateStorage()
        await viewModel.checkConnection()

        XCTAssertEqual(drains, 1, "Only the attempted replacement may drain")
        XCTAssertFalse(FileOutbox.destructiveRecoveryIsRequested(directory: fixture.outbox.directoryURL))
        XCTAssertNotNil(try fixture.outbox.pendingItem(id: payload.id))
        XCTAssertTrue(viewModel.receiverSettingsSaved)
        XCTAssertEqual(fixture.settings.receiverBindingID, binding)
        XCTAssertEqual(viewModel.setupLinkReplacementFailure, warning)
    }

    private func makeReplacementWarning(
        _ fixture: NutritionFixture,
        drain: @escaping @MainActor () async -> Bool
    ) async throws -> (HealthBridgeCompanionViewModel, String) {
        let viewModel = try await fixture.makeViewModel(terminalBackgroundPayloadDrain: drain)
        viewModel.pairingImportText = legacySetupMaterial
        await viewModel.importPairingText()
        let warning = try XCTUnwrap(viewModel.setupLinkReplacementFailure)
        XCTAssertTrue(warning.contains("saved connection was not replaced"))
        XCTAssertTrue(viewModel.receiverSettingsSaved)
        XCTAssertNil(viewModel.pairingInputCorrection)
        return (viewModel, warning)
    }

    func testInvitationReplacementDoesNotPromoteSupersededCommit() async throws {
        try await assertReplacementDoesNotPromoteSupersededCommit("""
        {
          "schema_id": "health_bridge.receiver_pairing_invitation.v2",
          "schema_version": "2.0.0",
          "label": "Synthetic receiver",
          "receiver_url": "http://127.0.0.1:8766/v1/batches",
          "redeem_url": "http://127.0.0.1:8766/v1/pairing/redeem",
          "invitation_secret": "synthetic-invitation-credential",
          "expires_at": "2099-01-01T00:00:00Z"
        }
        """)
    }

    private func assertReplacementDoesNotPromoteSupersededCommit(_ material: String) async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let viewModel = try await fixture.makeViewModel(terminalBackgroundPayloadDrain: { true })
        let originalBinding = try XCTUnwrap(fixture.settings.receiverBindingID)
        let originalURL = viewModel.receiverURLString
        let originalBearer = viewModel.bearerToken
        var committedGeneration: String?
        // The barrier refreshes published state after capturing the committed generation.
        // Advance it synchronously in that window, before pairing can publish the connection.
        let subscription = viewModel.$historicalBackfillState.dropFirst().sink { _ in
            guard committedGeneration == nil,
                  let binding = fixture.settings.receiverBindingID,
                  binding != originalBinding else { return }
            committedGeneration = fixture.settings.receiverSettingsGenerationToken
            do {
                try fixture.settings.invalidateReceiverSettingsGeneration()
            } catch {
                XCTFail("Could not supersede the committed pairing generation: \(error)")
            }
        }
        defer { subscription.cancel() }
        viewModel.pairingImportText = material

        await viewModel.importPairingText()

        XCTAssertEqual(fixture.settings.receiverURLString, "http://127.0.0.1:8766/v1/batches")
        XCTAssertNotEqual(
            fixture.settings.receiverSettingsGenerationToken,
            try XCTUnwrap(committedGeneration)
        )
        XCTAssertEqual(viewModel.receiverURLString, originalURL)
        XCTAssertEqual(viewModel.bearerToken, originalBearer)
        XCTAssertEqual(viewModel.pairingImportText, material)
        XCTAssertTrue(viewModel.statusIsError)
    }

    private let legacySetupMaterial = """
    {
      "schema_id": "health_bridge.receiver_pairing.v1",
      "schema_version": "1.0.0",
      "label": "Synthetic receiver",
      "receiver_url": "http://127.0.0.1:8766/v1/batches",
      "bearer_token": "synthetic-pairing-token",
      "token_prefix": "synthetic",
      "created_at": "2026-11-02T00:00:00Z",
      "warning": "Synthetic test fixture only."
    }
    """

    func testConnectionCheckReplacesStaleInputFeedback() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let viewModel = try await fixture.makeViewModel()
        viewModel.pairingImportText = "not-a-link"
        await viewModel.importPairingText()
        XCTAssertEqual(viewModel.pairingInputError, .invalidJSON)
        let previousStatus = viewModel.statusMessage
        let previousStatusIsError = viewModel.statusIsError

        await viewModel.checkConnection()

        XCTAssertNil(viewModel.pairingInputError)
        XCTAssertEqual(viewModel.connectionCheckNotice?.isError, false)
        XCTAssertEqual(viewModel.statusMessage, previousStatus)
        XCTAssertEqual(viewModel.statusIsError, previousStatusIsError)
    }
}
