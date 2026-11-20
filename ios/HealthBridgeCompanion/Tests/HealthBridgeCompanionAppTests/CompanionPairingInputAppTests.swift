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
