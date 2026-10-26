import Foundation
import XCTest
#if canImport(HealthBridgeCompanion)
@testable import HealthBridgeCompanion
#else
@testable import HealthBridgeCompanionCore
#endif

@MainActor
final class ReceiverCapabilityResolverTests: XCTestCase {
    private func record(_ transport: ReceiverTransportKind = .mailbox, generation: UInt64 = 1) throws -> ReceiverConnectionRecordV2 {
        ReceiverConnectionRecordV2(
            localScope: ReceiverLocalConnectionScopeV1(generation: generation, bindingID: "synthetic"),
            mailboxIdentity: .available(try CapabilityTestFixture().identity), activation: .paired(activeTransport: transport),
            transportConfigurations: [
                .directHTTP(activation: transport == .directHTTP ? .active : .inactive,
                            configuration: DirectHTTPConnectionConfigurationV1(receiverURLString: "http://127.0.0.1:8765/v1/batches", bearerToken: "synthetic")),
                .mailbox(activation: transport == .mailbox ? .active : .inactive, configuration: MailboxConnectionConfigurationV1())
            ]
        )
    }

    func testMailboxNeverFallsBackToRetainedHTTP() async throws {
        let connection = try record()
        var calls = 0
        let result = try await ReceiverCapabilityResolver.resolve(
            connection: connection, currentConnection: { connection },
            readDirect: { _, _ in XCTFail("Inactive HTTP must not be consulted"); return nil },
            readMailbox: { _ in calls += 1; return nil }
        )
        XCTAssertNil(result)
        XCTAssertEqual(calls, 1)
    }

    func testDirectUsesAuthenticatedConfiguration() async throws {
        let connection = try record(.directHTTP)
        let result = try await ReceiverCapabilityResolver.resolve(
            connection: connection, currentConnection: { connection },
            readDirect: { url, token in
                XCTAssertEqual(url.absoluteString, "http://127.0.0.1:8765/v1/batches")
                XCTAssertEqual(token, "synthetic")
                return ReceiverCapabilities(nutritionSupported: false)
            }, readMailbox: { _ in XCTFail("Direct must not inspect provider"); return nil }
        )
        XCTAssertEqual(result?.nutritionSupported, false)
    }

    func testReplacementAndClosedAdmissionFenceLateSuccessAndFailure() async throws {
        for success in [true, false] {
            let connection = try record()
            let replacement = try record(generation: 2)
            var current = connection
            do {
                _ = try await ReceiverCapabilityResolver.resolve(
                    connection: connection, currentConnection: { current }, readDirect: { _, _ in nil },
                    readMailbox: { _ in current = replacement; await Task.yield(); return success ? ReceiverCapabilities(nutritionSupported: true) : nil }
                )
                XCTFail("Replacement must cancel either late result")
            } catch is CancellationError { }
            var admitted = true
            do {
                _ = try await ReceiverCapabilityResolver.resolve(
                    connection: connection, currentConnection: { connection }, readDirect: { _, _ in nil },
                    readMailbox: { _ in admitted = false; await Task.yield(); return nil },
                    validate: { if !admitted { throw CancellationError() } }
                )
                XCTFail("Closed admission must cancel")
            } catch is CancellationError { }
        }
    }

    func testCancellationFencesLateSupportedResult() async throws {
        let connection = try record()
        let task = Task { @MainActor in
            try await ReceiverCapabilityResolver.resolve(
                connection: connection, currentConnection: { connection }, readDirect: { _, _ in nil },
                readMailbox: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return ReceiverCapabilities(nutritionSupported: true)
                }
            )
        }
        do { _ = try await task.value; XCTFail("Cancelled capability cannot be used") }
        catch is CancellationError { }
    }
}
