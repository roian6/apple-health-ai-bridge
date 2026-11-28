import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class MailboxSleepCompletionTests: XCTestCase {
    func testCompletionRequiresFinalizedProofForThePendingSleepTransition() throws {
        let harness = try OutboxDeliveryHarness()
        let owner = harness.ownership
        let resetEpoch = try XCTUnwrap(owner.resetEpoch)
        let pending = SleepSyncPendingTransition(
            payload: harness.fixture.payload,
            manifest: SleepSyncBatchFactory.makeManifestReservation(
                receiverSettingsGeneration: owner.receiverGeneration,
                historyDepth: .lastDays(1),
                historyStartDate: nil,
                baselineResetEpoch: resetEpoch
            ),
            receiverBindingID: owner.receiverBindingID,
            connectionGeneration: owner.receiverGeneration,
            outboxItemID: harness.fixture.item.id
        )
        let receipt = try XCTUnwrap(OutboxDeliveryCommittedReceiptV1(event: MailboxAckEvent(
            classification: .committed,
            receipt: DeliveryReceiptV1(
                result: .committed,
                payloadSHA256: String(repeating: "a", count: 64),
                receiptID: 1,
                datasetGeneration: 1,
                committedAtMS: 1,
                errorCode: nil
            ),
            handle: MailboxAckDeletionHandle(
                fileName: "synthetic.ack",
                acknowledgmentSHA256: String(repeating: "b", count: 64),
                identity: MailboxAckFileIdentity(
                    device: 1, inode: 1, size: 1,
                    modifiedSeconds: 1, modifiedNanoseconds: 0,
                    changedSeconds: 1, changedNanoseconds: 0
                ),
                envelopeID: harness.fixture.sealContext.envelopeID
            )
        )))
        let finalized = FileOutboxDeliveryStateV1.committed(
            phase: .committedFinalized, ownership: owner, receipt: receipt
        )
        let cases: [(label: String, proof: FileOutboxDeliveryStateV1?, completes: Bool)] = [
            ("matching finalized proof", finalized, true),
            ("no proof for the tracked item", nil, false),
            ("verified ACK not yet finalized", .committed(
                phase: .ackVerified, ownership: owner, receipt: receipt
            ), false),
            ("different receiver generation", finalized.assigning(
                harness.alternateOwnership(
                    receiverGeneration: "other-receiver-generation",
                    receiverBindingID: owner.receiverBindingID,
                    resetEpoch: resetEpoch
                )
            ), false),
            ("different receiver binding", finalized.assigning(
                harness.alternateOwnership(
                    receiverGeneration: owner.receiverGeneration,
                    receiverBindingID: "other-receiver-binding",
                    resetEpoch: resetEpoch
                )
            ), false),
            ("different reset epoch", finalized.assigning(
                harness.alternateOwnership(
                    receiverGeneration: owner.receiverGeneration,
                    receiverBindingID: owner.receiverBindingID,
                    resetEpoch: resetEpoch + 1
                )
            ), false),
        ]
        for row in cases {
            XCTAssertEqual(pending.hasFinalizedMailboxProof(row.proof), row.completes, row.label)
        }
    }
}
