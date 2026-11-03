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
        await viewModel.checkConnection()
        XCTAssertTrue(viewModel.statusIsError)
        let failure = viewModel.displayStatusMessage
        fixture.receiver.capability = .supported

        await viewModel.checkConnection()

        XCTAssertFalse(viewModel.statusIsError)
        XCTAssertNotEqual(viewModel.displayStatusMessage, failure)
    }
}
