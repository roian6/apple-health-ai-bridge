import CryptoKit
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class MailboxAckScannerTests: XCTestCase {
    func testPythonProducedCommittedAckEmitsExactlyOneEvent() throws {
        let fixture = try MailboxAckScannerFixture()
        try fixture.publish(fixture.pythonAck())

        let report = try fixture.scanner().scan()

        XCTAssertEqual(report.events.map(\.classification), [.committed])
        XCTAssertEqual(report.events.first?.receipt, committedReceipt(payload: fixture.transport.payload))
        XCTAssertTrue(report.quarantine.records.isEmpty)
    }

    func testLookupBeginsOnlyAfterSignatureVerification() throws {
        let fixture = try MailboxAckScannerFixture()
        var malformed = try fixture.pythonAck()
        malformed[malformed.startIndex] ^= 0x01
        try fixture.publish(malformed)
        let spy = SpyMailboxAckLookup(.unknown)

        let report = try fixture.scanner(lookup: spy).scan()

        XCTAssertEqual(spy.callCount, 0)
        XCTAssertTrue(report.events.isEmpty)
        XCTAssertEqual(report.quarantine.records, [.authenticationFailed])
    }

    func testWrongSignatureKeyReceiverDeviceAndGenerationFailBeforeLookup() throws {
        let fixture = try MailboxAckScannerFixture()
        let base = try DeliveryProtocolV1TestSupport.ackSeal("python")
        let otherSigning = try DeliveryProtocolV1TestSupport.signingKey("synthetic-other-signing")
        let otherAgreement = try DeliveryProtocolV1TestSupport.agreementKey("synthetic-other-agreement")
        let cases = [
            alternateAckSealContext(base, receiverSigningPrivateKey: otherSigning),
            alternateAckSealContext(base, deviceAgreementPublicKey: otherAgreement.publicKey),
            alternateAckSealContext(base, receiverID: Data(repeating: 0x31, count: 16)),
            alternateAckSealContext(base, deviceID: Data(repeating: 0x32, count: 16)),
            alternateAckSealContext(base, connectionGeneration: base.connectionGeneration + 1),
        ]

        for (index, sealContext) in cases.enumerated() {
            let spy = SpyMailboxAckLookup(.unknown)
            let bytes = try fixture.sealAck(
                committedReceipt(payload: fixture.transport.payload),
                context: sealContext
            )
            try fixture.publish(bytes, identifier: String(format: "%032x", index + 1))
            _ = try fixture.scanner(lookup: spy).scan()
            XCTAssertEqual(spy.callCount, 0, "case \(index)")
            try FileManager.default.removeItem(
                at: fixture.ackLane.appendingPathComponent(String(format: "%032x.hba", index + 1))
            )
        }
    }

    func testWrongEnvelopeDigestBindingStaleAndUnknownFailClosed() throws {
        let fixture = try MailboxAckScannerFixture()
        let wrongDigest = DeliveryReceiptV1(
            result: .committed,
            payloadSHA256: String(repeating: "0", count: 64),
            receiptID: 9,
            datasetGeneration: 4,
            committedAtMS: 1_782_000_000_456,
            errorCode: nil
        )
        let mismatchedBinding = try MailboxAckScannerFixture(
            receiverBindingID: "synthetic-other-binding"
        )
        let base = try DeliveryProtocolV1TestSupport.ackSeal("python")
        let cases: [(MailboxAckScannerFixture, Data, any MailboxAckOutboxLookingUp)] = [
            (fixture, try fixture.sealAck(wrongDigest), fixture.lookup),
            (
                fixture,
                try fixture.sealAck(
                    committedReceipt(payload: fixture.transport.payload),
                    context: alternateAckSealContext(
                        base,
                        envelopeID: Data(repeating: 0x45, count: 16)
                    )
                ),
                fixture.lookup
            ),
            (mismatchedBinding, try mismatchedBinding.pythonAck(), mismatchedBinding.lookup),
            (fixture, try fixture.pythonAck(), SpyMailboxAckLookup(.stale)),
            (fixture, try fixture.pythonAck(), SpyMailboxAckLookup(.unknown)),
        ]

        for (index, value) in cases.enumerated() {
            try value.0.publish(value.1, identifier: String(format: "%032x", index + 20))
            let report = try value.0.scanner(lookup: value.2).scan()
            XCTAssertTrue(report.events.allSatisfy { $0.classification == .conflict })
            XCTAssertFalse(report.events.contains { $0.classification == .committed })
        }
    }

    func testRetryableAndTerminalNacksClassifyWithoutMutation() throws {
        for (receipt, expected) in [
            (retryableReceipt(payload: try DeliveryProtocolV1TestSupport.data(
                DeliveryProtocolV1TestSupport.fixture("python").plaintext
            )), MailboxAckClassification.retryableNack),
            (terminalReceipt(payload: try DeliveryProtocolV1TestSupport.data(
                DeliveryProtocolV1TestSupport.fixture("python").plaintext
            )), MailboxAckClassification.terminalNack),
        ] {
            let fixture = try MailboxAckScannerFixture()
            let before = try fixture.snapshotLocalState()
            try fixture.publish(try fixture.sealAck(receipt))

            let report = try fixture.scanner().scan()

            XCTAssertEqual(report.events.map(\.classification), [expected])
            XCTAssertEqual(try fixture.snapshotLocalState(), before)
        }
    }

    func testMalformedTrailingAndOversizeAreRejectedWithoutLookup() throws {
        let fixture = try MailboxAckScannerFixture()
        let spy = SpyMailboxAckLookup(.unknown)
        try fixture.publish(Data("{".utf8), identifier: String(repeating: "1", count: 32))
        try fixture.publish(
            try fixture.pythonAck() + Data("x".utf8),
            identifier: String(repeating: "2", count: 32)
        )
        try fixture.publish(
            Data(repeating: 0x41, count: Int(MailboxLayoutV1.maximumMetadataBytes) + 1),
            identifier: String(repeating: "3", count: 32)
        )

        let report = try fixture.scanner(lookup: spy).scan()

        XCTAssertEqual(spy.callCount, 0)
        XCTAssertTrue(report.events.isEmpty)
        XCTAssertEqual(Set(report.quarantine.records), [.authenticationFailed, .oversize])
    }

    func testDuplicateIdenticalAndConflictingValidAcksAreDeterministic() throws {
        let duplicate = try MailboxAckScannerFixture()
        let committed = try duplicate.pythonAck()
        try duplicate.publish(committed, identifier: String(repeating: "1", count: 32))
        try duplicate.publish(committed, identifier: String(repeating: "2", count: 32))
        XCTAssertEqual(
            try duplicate.scanner().scan().events.map(\.classification),
            [.committed, .duplicateIdentical]
        )

        let conflict = try MailboxAckScannerFixture()
        try conflict.publish(committed, identifier: String(repeating: "1", count: 32))
        try conflict.publish(
            try conflict.sealAck(retryableReceipt(payload: conflict.transport.payload)),
            identifier: String(repeating: "2", count: 32)
        )
        XCTAssertEqual(
            try conflict.scanner().scan().events.map(\.classification),
            [.conflict]
        )
    }

    func testClassificationIsRestartIdempotentAndDoesNotMutateLocalState() throws {
        let fixture = try MailboxAckScannerFixture()
        try fixture.publish(fixture.pythonAck())
        let before = try fixture.snapshotLocalState()

        let first = try fixture.scanner().scan()
        let second = try fixture.scanner().scan()

        XCTAssertEqual(first.events.map(\.classification), second.events.map(\.classification))
        XCTAssertEqual(first.events.map(\.receipt), second.events.map(\.receipt))
        XCTAssertEqual(try fixture.snapshotLocalState(), before)
    }

    func testQuarantineMetadataNeverContainsSensitiveValues() throws {
        let fixture = try MailboxAckScannerFixture()
        try fixture.publish(Data("Bearer secret payload_sha256 /private/path".utf8))

        let report = try fixture.scanner().scan()
        let encoded = String(describing: report.quarantine)

        XCTAssertLessThanOrEqual(report.quarantine.records.count, 1_000)
        for forbidden in [
            "Bearer", "payload_sha256", "/private/path",
            fixture.context.receiverID.hexV1, fixture.context.receiverSigningKeyID,
        ] {
            XCTAssertFalse(encoded.contains(forbidden))
        }
    }
}
