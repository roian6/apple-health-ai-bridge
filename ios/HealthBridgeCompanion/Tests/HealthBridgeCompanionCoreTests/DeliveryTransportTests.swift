import CryptoKit
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

@MainActor
final class DeliveryTransportTests: XCTestCase {
    func testDirectTransportReceivesExactPersistedBytesWithoutFinalizing() async throws {
        let encoder = EncoderInvocationCounter()
        let payload = encoder.encode(
            Data(#"{ "synthetic": 42, "ordering": [3, 2, 1] }"#.utf8)
        )
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try FileOutbox(directory: directory)
        let item = try outbox.enqueue(payload, receiverIdentity: "binding-current")
        XCTAssertEqual(encoder.invocationCount, 1)
        let input = try DeliveryTransportInput(item: item)
        let capture = DirectPlanCapture()
        let transport: any DeliveryTransport = makeDirectTransport { plan in
            capture.record(plan)
        }

        let result = try transport.deliver(input)

        let plan = try XCTUnwrap(capture.plan)
        let uploadBody = try Data(contentsOf: plan.fileURL)
        let payloadHash = todo10SHA256(payload)
        let fileHash = todo10SHA256(try Data(contentsOf: item.fileURL))
        let requestBodyHash = todo10SHA256(uploadBody)
        XCTAssertEqual(result, .published)
        XCTAssertEqual(plan.itemID, item.id)
        XCTAssertEqual(plan.receiverGeneration, "g2")
        XCTAssertEqual(plan.receiverBindingID, "binding-current")
        XCTAssertEqual(plan.fileURL, item.fileURL)
        XCTAssertEqual(uploadBody, payload)
        XCTAssertEqual(uploadBody, input.persistedBytes)
        XCTAssertEqual(try Data(contentsOf: item.fileURL), payload)
        XCTAssertEqual(requestBodyHash, payloadHash)
        XCTAssertEqual(fileHash, payloadHash)
        XCTAssertEqual(encoder.invocationCount, 1)
        XCTAssertNotNil(try outbox.pendingItem(id: item.id))
        print(
            "TODO10_DIRECT_INPUT bytes=\(payload.count) "
                + "payload_sha256=\(payloadHash) "
                + "request_body_sha256=\(requestBodyHash) "
                + "post_enqueue_encoder_invocations=\(encoder.invocationCount - 1) "
                + "exact=true pending_after_publish=true"
        )
    }

    func testTransportResultStatesAreClosedAndTyped() {
        let expected: [DeliveryTransportResult] = [
            .collected,
            .published,
            .observed,
            .committed,
            .terminal,
            .retryable,
        ]
        XCTAssertEqual(
            DeliveryTransportResult.allCases,
            expected
        )
        print("TODO10_RESULT_STATES count=\(expected.count) exact_order=true")
    }

    func testCurrentDirectSuccessRetiresOnlyThroughExistingDirectFinalizer() async throws {
        let payload = Data(#"{"synthetic":"current-success"}"#.utf8)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try FileOutbox(directory: directory)
        let item = try outbox.enqueue(payload, receiverIdentity: "binding-current")
        let payloadHash = todo10SHA256(payload)
        let transport = makeDirectTransport()

        let deliveryResult = try transport.deliver(
            DeliveryTransportInput(item: item)
        )
        XCTAssertEqual(deliveryResult, .published)
        XCTAssertNotNil(try outbox.pendingItem(id: item.id))
        XCTAssertEqual(todo10SHA256(try Data(contentsOf: item.fileURL)), payloadHash)

        var directRetirementCount = 0
        var recoveryCount = 0
        let outcome = try DirectUploadFinalizer.finish(
            descriptor: DirectUploadCompletionDescriptor(
                itemID: item.id,
                receiverGeneration: "g2",
                receiverBindingID: "binding-current"
            ),
            completion: BackgroundUploadTaskCompletion(
                statusCode: 202,
                hadTransportError: false,
                sleepMinimumResetEpoch: nil
            ),
            currentReceiverGeneration: "g2",
            currentReceiverBindingID: "binding-current",
            recoverSleepBaseline: { _, _ in recoveryCount += 1 },
            retire: { itemID, receiverBindingID in
                let pendingItem = try XCTUnwrap(outbox.pendingItem(id: itemID))
                XCTAssertEqual(pendingItem.receiverIdentity, receiverBindingID)
                try outbox.markUploaded(pendingItem)
                directRetirementCount += 1
            }
        )

        XCTAssertEqual(outcome, .retired)
        XCTAssertEqual(directRetirementCount, 1)
        XCTAssertEqual(recoveryCount, 0)
        XCTAssertNil(try outbox.pendingItem(id: item.id))
        print(
            "TODO10_CURRENT_CALLBACK direct_retirements=\(directRetirementCount) "
                + "mailbox_mutations=0 "
                + "payload_sha256=\(payloadHash)"
        )
    }

    func testStaleOrCancelledDirectCallbackCannotRetireOrMutateMailboxState() async throws {
        let payload = Data(#"{"synthetic":"stale-callback"}"#.utf8)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try FileOutbox(directory: directory)
        let item = try outbox.enqueue(payload, receiverIdentity: "binding-current")
        let payloadHashBeforeCallback = todo10SHA256(try Data(contentsOf: item.fileURL))
        let transport = makeDirectTransport(receiverGeneration: "g3")

        let deliveryResult = try transport.deliver(
            DeliveryTransportInput(item: item)
        )
        XCTAssertEqual(deliveryResult, .published)

        var directRetirementCount = 0
        var recoveryCount = 0
        let retire: (String, String) throws -> Void = { itemID, receiverBindingID in
            let pendingItem = try XCTUnwrap(outbox.pendingItem(id: itemID))
            XCTAssertEqual(pendingItem.receiverIdentity, receiverBindingID)
            try outbox.markUploaded(pendingItem)
            directRetirementCount += 1
        }
        let recover: (String, UInt64) throws -> Void = { _, _ in recoveryCount += 1 }
        let success = BackgroundUploadTaskCompletion(
            statusCode: 202,
            hadTransportError: false,
            sleepMinimumResetEpoch: nil
        )
        let staleOutcome = try DirectUploadFinalizer.finish(
            descriptor: DirectUploadCompletionDescriptor(
                itemID: item.id,
                receiverGeneration: "g2",
                receiverBindingID: "binding-current"
            ),
            completion: success,
            currentReceiverGeneration: "g3",
            currentReceiverBindingID: "binding-current",
            recoverSleepBaseline: recover,
            retire: retire
        )
        let bindingDriftOutcome = try DirectUploadFinalizer.finish(
            descriptor: DirectUploadCompletionDescriptor(
                itemID: item.id,
                receiverGeneration: "g3",
                receiverBindingID: "binding-previous"
            ),
            completion: success,
            currentReceiverGeneration: "g3",
            currentReceiverBindingID: "binding-current",
            recoverSleepBaseline: recover,
            retire: retire
        )
        let cancelledOutcome = try DirectUploadFinalizer.finish(
            descriptor: DirectUploadCompletionDescriptor(
                itemID: item.id,
                receiverGeneration: "g3",
                receiverBindingID: "binding-current"
            ),
            completion: BackgroundUploadTaskCompletion(
                statusCode: 202,
                hadTransportError: true,
                sleepMinimumResetEpoch: nil
            ),
            currentReceiverGeneration: "g3",
            currentReceiverBindingID: "binding-current",
            recoverSleepBaseline: recover,
            retire: retire
        )

        XCTAssertEqual(staleOutcome, .stale)
        XCTAssertEqual(bindingDriftOutcome, .stale)
        XCTAssertEqual(cancelledOutcome, .retained)
        XCTAssertEqual(directRetirementCount, 0)
        XCTAssertEqual(recoveryCount, 0)
        let pendingItem = try XCTUnwrap(outbox.pendingItem(id: item.id))
        XCTAssertNil(pendingItem.mailboxBinding)
        let payloadHashAfterCallback = todo10SHA256(try Data(contentsOf: pendingItem.fileURL))
        XCTAssertEqual(payloadHashAfterCallback, payloadHashBeforeCallback)
        print(
            "TODO10_STALE_CALLBACK direct_retirements=\(directRetirementCount) "
                + "mailbox_mutations=0 pending=true "
                + "payload_sha256_before=\(payloadHashBeforeCallback) "
                + "payload_sha256_after=\(payloadHashAfterCallback) "
                + "generation_stale=true binding_stale=true cancelled=true"
        )
    }

    func testDirectFinalizerRoutesConflictRecoveryWithoutRetirement() throws {
        let payload = Data(#"{"synthetic":"conflict-recovery"}"#.utf8)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = try FileOutbox(directory: directory)
        let item = try outbox.enqueue(payload, receiverIdentity: "binding-current")
        let payloadHashBeforeCallback = todo10SHA256(try Data(contentsOf: item.fileURL))
        var recoveredItemID: String?
        var recoveredEpoch: UInt64?
        var directRetirementCount = 0

        let outcome = try DirectUploadFinalizer.finish(
            descriptor: DirectUploadCompletionDescriptor(
                itemID: item.id,
                receiverGeneration: "g4",
                receiverBindingID: "binding-current"
            ),
            completion: BackgroundUploadTaskCompletion(
                statusCode: 409,
                hadTransportError: false,
                sleepMinimumResetEpoch: 7
            ),
            currentReceiverGeneration: "g4",
            currentReceiverBindingID: "binding-current",
            recoverSleepBaseline: { itemID, minimumResetEpoch in
                recoveredItemID = itemID
                recoveredEpoch = minimumResetEpoch
            },
            retire: { itemID, receiverBindingID in
                let pendingItem = try XCTUnwrap(outbox.pendingItem(id: itemID))
                XCTAssertEqual(pendingItem.receiverIdentity, receiverBindingID)
                try outbox.markUploaded(pendingItem)
                directRetirementCount += 1
            }
        )

        XCTAssertEqual(outcome, .recovered)
        XCTAssertEqual(recoveredItemID, item.id)
        XCTAssertEqual(recoveredEpoch, 7)
        XCTAssertEqual(directRetirementCount, 0)
        let pendingItem = try XCTUnwrap(outbox.pendingItem(id: item.id))
        XCTAssertNil(pendingItem.mailboxBinding)
        let payloadHashAfterCallback = todo10SHA256(try Data(contentsOf: pendingItem.fileURL))
        XCTAssertEqual(payloadHashAfterCallback, payloadHashBeforeCallback)
        print(
            "TODO10_CONFLICT_FINALIZER recovery=1 direct_retirements=0 epoch=7 "
                + "pending=true mailbox_mutations=0 "
                + "payload_sha256_before=\(payloadHashBeforeCallback) "
                + "payload_sha256_after=\(payloadHashAfterCallback)"
        )
    }
}

@MainActor
private final class DirectPlanCapture {
    var plan: BackgroundOutboxUploadPlan?

    func record(_ plan: BackgroundOutboxUploadPlan) {
        self.plan = plan
    }
}

@MainActor
private final class EncoderInvocationCounter {
    private(set) var invocationCount = 0

    func encode(_ data: Data) -> Data {
        invocationCount += 1
        return data
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HealthBridgeDeliveryTransportTests")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
private func makeDirectTransport(
    receiverGeneration: String = "g2",
    schedule: @escaping DirectHTTPTransport.Schedule = { _ in }
) -> DirectHTTPTransport {
    DirectHTTPTransport(
        receiverURL: URL(string: "https://receiver.invalid/v1/ingest")!,
        bearerToken: "synthetic-token",
        receiverGeneration: receiverGeneration,
        receiverBindingID: "binding-current",
        alreadyScheduledItemIDs: [],
        schedule: schedule
    )
}

private func todo10SHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
