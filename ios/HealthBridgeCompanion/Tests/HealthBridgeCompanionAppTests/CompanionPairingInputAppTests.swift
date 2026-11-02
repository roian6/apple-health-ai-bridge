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
        viewModel.pairingImportText = """
        {
          "schema_id": "health_bridge.receiver_pairing.v1",
          "schema_version": "1.0.0",
          "label": "Synthetic receiver",
          "receiver_url": "http://127.0.0.1:8765/v1/batches",
          "bearer_token": "synthetic-pairing-token",
          "token_prefix": "synthetic",
          "created_at": "2026-11-02T00:00:00Z",
          "warning": "Synthetic test fixture only."
        }
        """

        await viewModel.importPairingText()

        XCTAssertNil(viewModel.pairingInputError)
        XCTAssertTrue(viewModel.receiverSettingsSaved)
        XCTAssertFalse(viewModel.statusIsError)
    }

    func testConnectionCheckReplacesStaleInputFeedback() async throws {
        let fixture = try NutritionFixture()
        defer { fixture.cleanup() }
        let viewModel = try await fixture.makeViewModel()
        viewModel.pairingImportText = "not-a-link"
        await viewModel.importPairingText()
        XCTAssertEqual(viewModel.pairingInputError, .invalidJSON)

        await viewModel.checkConnection()

        XCTAssertNil(viewModel.pairingInputError)
        XCTAssertFalse(viewModel.statusIsError)
    }
}
