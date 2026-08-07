import CryptoKit
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class MailboxQAHarnessTests: XCTestCase {
    func testPairingCompletionRejectsUnknownFieldsAndWrongCanonicalKeyID() throws {
        let receiverSigning = Curve25519.Signing.PrivateKey()
        let receiverAgreement = Curve25519.KeyAgreement.PrivateKey()
        var completion = try pairingCompletion(
            receiverSigning: receiverSigning,
            receiverAgreement: receiverAgreement
        )
        let valid = try JSONSerialization.data(
            withJSONObject: completion,
            options: [.sortedKeys]
        )
        XCTAssertNoThrow(
            try MailboxQAPairingCompletionV1.strictDecode(
                valid,
                namespace: "qa-synthetic",
                runID: String(repeating: "1", count: 32)
            )
        )

        completion["unexpected"] = true
        let unknown = try JSONSerialization.data(withJSONObject: completion)
        XCTAssertThrowsError(
            try MailboxQAPairingCompletionV1.strictDecode(
                unknown,
                namespace: "qa-synthetic",
                runID: String(repeating: "1", count: 32)
            )
        )
        completion.removeValue(forKey: "unexpected")
        completion["receiver_signing_key_id"] = String(repeating: "0", count: 32)
        let wrongKeyID = try JSONSerialization.data(withJSONObject: completion)
        XCTAssertThrowsError(
            try MailboxQAPairingCompletionV1.strictDecode(
                wrongKeyID,
                namespace: "qa-synthetic",
                runID: String(repeating: "1", count: 32)
            )
        )
    }

    func testSyntheticPayloadIsOneExactAppleHealthShapedEncoding() {
        let expected = Data(
            """
            {"deleted_records":[],"export_window":{"end_time":"2026-01-01T00:15:00Z","start_time":"2026-01-01T00:00:00Z"},"generated_at":"2026-01-01T00:15:00Z","health_types":[{"aliases":["HKQuantityTypeIdentifierStepCount"],"category":"activity","default_unit":"count","display_name":"Steps","sensitivity":"low","type_code":"steps"}],"samples":[{"client_record_id":"synthetic-qa-steps-0001","end_time":"2026-01-01T00:15:00Z","metadata":{"fixture":"mailbox_qa"},"source_key":"apple_health.phone","start_time":"2026-01-01T00:00:00Z","type_code":"steps","unit":"count","value":1234}],"schema_id":"health_bridge.batch.v1","schema_version":"1.0.0","sleep_sessions":[],"sources":[{"bundle_id":"dev.example.healthbridge.mailboxqa","device_model":"SyntheticPhone1,1","kind":"phone","name":"Synthetic QA Phone","source_key":"apple_health.phone"}],"sync":{"cursors":[],"sync_window":{"end_time":"2026-01-01T00:15:00Z","start_time":"2026-01-01T00:00:00Z"}},"workouts":[]}
            """.utf8
        )
        XCTAssertEqual(MailboxQASyntheticPayload.exactBytes, expected)
        XCTAssertNoThrow(
            try DeliveryProtocolV1.validatePayload(
                MailboxQASyntheticPayload.exactBytes
            )
        )
    }

    func testFreshHarnessPrimesEncryptedStateBeforePublisherFault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let support = root.appendingPathComponent("support", isDirectory: true)
        let provider = root.appendingPathComponent("provider", isDirectory: true)
        try FileManager.default.createDirectory(
            at: provider,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try QAPairingFixture()
        let harness = try MailboxQAHarness(
            applicationSupportRoot: support,
            providerRoot: provider,
            containerIdentifier: "iCloud.dev.example.healthbridge.mailboxqa",
            pairing: fixture.record,
            envelopeID: { fixture.envelopeID },
            observeEnvelope: { _, _ in true }
        )

        let faulted = try harness.advance(fault: .publisherENOSPC)

        XCTAssertEqual(faulted.lastPhase, .retryableFailure)
        XCTAssertEqual(faulted.faultInjectionCount, 1)
        XCTAssertNotNil(faulted.envelopeSHA256)
    }

    func testDurableHarnessReusesEnvelopeAndFinalizesAuthenticatedAckOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let support = root.appendingPathComponent("support", isDirectory: true)
        let provider = root.appendingPathComponent("provider", isDirectory: true)
        try FileManager.default.createDirectory(
            at: provider,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try QAPairingFixture()
        var harness = try MailboxQAHarness(
            applicationSupportRoot: support,
            providerRoot: provider,
            containerIdentifier: "iCloud.dev.example.healthbridge.mailboxqa",
            pairing: fixture.record,
            envelopeID: { fixture.envelopeID },
            observeEnvelope: { _, _ in true }
        )

        XCTAssertEqual(try harness.advance().lastPhase, .collected)
        XCTAssertEqual(try harness.advance().lastPhase, .encrypted)
        XCTAssertEqual(
            try harness.advance(fault: .publisherENOSPC).lastPhase,
            .retryableFailure
        )
        XCTAssertEqual(try harness.advance().lastPhase, .published)
        let observed = try harness.advance()
        XCTAssertEqual(observed.lastPhase, .providerObserved)
        let finalizedHash = try XCTUnwrap(observed.envelopeSHA256)

        harness = try MailboxQAHarness(
            applicationSupportRoot: support,
            providerRoot: provider,
            containerIdentifier: "iCloud.dev.example.healthbridge.mailboxqa",
            pairing: fixture.record,
            envelopeID: { fixture.envelopeID },
            observeEnvelope: { _, _ in true }
        )
        let restarted = try harness.advance()
        XCTAssertEqual(restarted.lastPhase, .providerObserved)
        XCTAssertEqual(restarted.envelopeSHA256, finalizedHash)
        XCTAssertEqual(restarted.envelopeReuseCount, 1)
        XCTAssertEqual(restarted.restartEpoch, 1)

        try publishCommittedAck(
            fixture: fixture,
            support: support,
            provider: provider
        )
        let committed = try harness.scanAndFinalize()
        XCTAssertEqual(committed.lastPhase, .committedFinalized)
        XCTAssertEqual(committed.finalizationCount, 1)
        XCTAssertEqual(try harness.scanAndFinalize().finalizationCount, 1)
        XCTAssertThrowsError(try harness.advance())
    }

    func testCleanupAllowsOnlyPristineOrFinalizedState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let pristineSupport = root.appendingPathComponent("pristine-support", isDirectory: true)
        let pristineProvider = root.appendingPathComponent("pristine-provider", isDirectory: true)
        let activeSupport = root.appendingPathComponent("active-support", isDirectory: true)
        let activeProvider = root.appendingPathComponent("active-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: pristineProvider, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: activeProvider, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try QAPairingFixture()

        let pristine = try MailboxQAHarness(
            applicationSupportRoot: pristineSupport,
            providerRoot: pristineProvider,
            containerIdentifier: "iCloud.dev.example.healthbridge.mailboxqa",
            pairing: fixture.record,
            envelopeID: { fixture.envelopeID },
            observeEnvelope: { _, _ in true }
        )
        XCTAssertNoThrow(try pristine.removeQAProviderArtifacts())

        let active = try MailboxQAHarness(
            applicationSupportRoot: activeSupport,
            providerRoot: activeProvider,
            containerIdentifier: "iCloud.dev.example.healthbridge.mailboxqa",
            pairing: fixture.record,
            envelopeID: { fixture.envelopeID },
            observeEnvelope: { _, _ in true }
        )
        XCTAssertEqual(try active.advance().lastPhase, .collected)
        XCTAssertThrowsError(try active.removeQAProviderArtifacts()) { error in
            XCTAssertEqual(error as? MailboxQAHarnessError, .invalidState)
        }
    }

    func testTerminalAckBecomesDurableFailureAndAllowsQAOnlyCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let support = root.appendingPathComponent("support", isDirectory: true)
        let provider = root.appendingPathComponent("provider", isDirectory: true)
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try QAPairingFixture()
        let harness = try MailboxQAHarness(
            applicationSupportRoot: support,
            providerRoot: provider,
            containerIdentifier: "iCloud.dev.example.healthbridge.mailboxqa",
            pairing: fixture.record,
            envelopeID: { fixture.envelopeID },
            observeEnvelope: { _, _ in true }
        )

        XCTAssertEqual(try harness.advance().lastPhase, .collected)
        XCTAssertEqual(try harness.advance().lastPhase, .encrypted)
        XCTAssertEqual(try harness.advance().lastPhase, .published)
        XCTAssertEqual(try harness.advance().lastPhase, .providerObserved)
        try publishTerminalAck(
            fixture: fixture,
            support: support,
            provider: provider
        )

        let terminal = try harness.scanAndFinalize()
        XCTAssertEqual(terminal.lastPhase, .terminalFailure)
        let locator = try MailboxLocatorV1.resolveIsolated(
            providerRoot: provider,
            containerIdentifier: "iCloud.dev.example.healthbridge.mailboxqa",
            receiverComponent: fixture.receiverID.hexV1,
            deviceComponent: fixture.deviceID.hexV1,
            localRecordURL: support.appendingPathComponent("test-locator.json")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: locator.deviceRoot.path))
        XCTAssertNoThrow(try harness.removeQAProviderArtifacts())
        XCTAssertFalse(FileManager.default.fileExists(atPath: locator.deviceRoot.path))
    }
}

private struct QAPairingFixture {
    let receiverSigning = Curve25519.Signing.PrivateKey()
    let receiverAgreement = Curve25519.KeyAgreement.PrivateKey()
    let deviceSigning = Curve25519.Signing.PrivateKey()
    let deviceAgreement = Curve25519.KeyAgreement.PrivateKey()
    let receiverID = Data(repeating: 0x17, count: 16)
    let deviceID = Data(repeating: 0x18, count: 16)
    let envelopeID = Data(repeating: 0x19, count: 16)
    let record: MailboxQAPairingRecordV1

    init() throws {
        record = MailboxQAPairingRecordV1(
            v: 1,
            kind: "health_bridge.mailbox_qa_pairing_record.v1",
            runID: String(repeating: "1", count: 32),
            challenge: Data(repeating: 0x11, count: 32)
                .base64URLEncodedString(),
            sourceCommit: String(repeating: "a", count: 40),
            namespace: "qa-synthetic",
            invitationFingerprint: String(repeating: "b", count: 64),
            redeemEndpointFingerprint: String(repeating: "c", count: 64),
            receiverID: receiverID,
            deviceID: deviceID,
            receiverBindingID: qaBinding(
                receiverID: receiverID,
                deviceID: deviceID
            ).base64URLEncodedString(),
            connectionGeneration: 1,
            receiverSigningPublicKey: receiverSigning.publicKey.rawRepresentation,
            receiverAgreementPublicKey: receiverAgreement.publicKey.rawRepresentation,
            receiverSigningKeyID: try DeliveryProtocolV1.keyID(
                algorithm: "ed25519",
                publicKey: receiverSigning.publicKey.rawRepresentation
            ),
            receiverAgreementKeyID: try DeliveryProtocolV1.keyID(
                algorithm: "x25519",
                publicKey: receiverAgreement.publicKey.rawRepresentation
            ),
            deviceSigningPrivateKey: deviceSigning.rawRepresentation,
            deviceAgreementPrivateKey: deviceAgreement.rawRepresentation,
            deviceCredential: "hb_synthetic",
            installationID: "00000000-0000-4000-8000-000000000017"
        )
    }
}

private func pairingCompletion(
    receiverSigning: Curve25519.Signing.PrivateKey,
    receiverAgreement: Curve25519.KeyAgreement.PrivateKey
) throws -> [String: Any] {
    [
        "v": 1,
        "kind": "health_bridge.mailbox_qa_pairing_completion.v1",
        "namespace": "qa-synthetic",
        "receiver_id": Data(repeating: 0x17, count: 16).base64URLEncodedString(),
        "device_id": Data(repeating: 0x18, count: 16).base64URLEncodedString(),
        "receiver_binding_id": qaBinding(
            receiverID: Data(repeating: 0x17, count: 16),
            deviceID: Data(repeating: 0x18, count: 16)
        ).base64URLEncodedString(),
        "connection_generation": 1,
        "receiver_signing_public_key": receiverSigning.publicKey.rawRepresentation
            .base64URLEncodedString(),
        "receiver_agreement_public_key": receiverAgreement.publicKey.rawRepresentation
            .base64URLEncodedString(),
        "receiver_signing_key_id": try DeliveryProtocolV1.keyID(
            algorithm: "ed25519",
            publicKey: receiverSigning.publicKey.rawRepresentation
        ),
        "receiver_agreement_key_id": try DeliveryProtocolV1.keyID(
            algorithm: "x25519",
            publicKey: receiverAgreement.publicKey.rawRepresentation
        ),
    ]
}

private func qaBinding(receiverID: Data, deviceID: Data) -> Data {
    var material = Data("health-bridge/mailbox-qa/binding".utf8)
    material.append(0)
    material.append(receiverID)
    material.append(deviceID)
    material.append(Data(repeating: 0x11, count: 16))
    return Data(SHA256.hash(data: material))
}

private func publishCommittedAck(
    fixture: QAPairingFixture,
    support: URL,
    provider: URL
) throws {
    try publishAck(
        fixture: fixture,
        support: support,
        provider: provider,
        result: .committed,
        errorCode: nil
    )
}

private func publishTerminalAck(
    fixture: QAPairingFixture,
    support: URL,
    provider: URL
) throws {
    try publishAck(
        fixture: fixture,
        support: support,
        provider: provider,
        result: .terminal,
        errorCode: .principalMismatch
    )
}

private func publishAck(
    fixture: QAPairingFixture,
    support: URL,
    provider: URL,
    result: DeliveryReceiptV1.Result,
    errorCode: DeliveryReceiptV1.ErrorCode?
) throws {
    let outbox = try FileOutbox(
        directory: support.appendingPathComponent("outbox-v4")
    )
    let item = try XCTUnwrap(outbox.mailboxBoundItemsForAckScanning().first)
    let binding = try XCTUnwrap(item.mailboxBinding)
    let envelopeID = fixture.envelopeID
    let ack = try DeliveryProtocolV1.sealAck(
        DeliveryReceiptV1(
            result: result,
            payloadSHA256: binding.payloadSHA256,
            receiptID: result == .committed ? 17 : nil,
            datasetGeneration: result == .committed ? 1 : nil,
            committedAtMS: result == .committed ? 1_782_000_000_000 : nil,
            errorCode: errorCode
        ),
        context: DeliveryAckSealContext(
            envelopeID: envelopeID,
            receiverID: fixture.receiverID,
            deviceID: fixture.deviceID,
            connectionGeneration: 1,
            deviceAgreementPublicKey: fixture.deviceAgreement.publicKey,
            receiverSigningPrivateKey: fixture.receiverSigning,
            receiverAgreementPrivateKey: fixture.receiverAgreement
        )
    )
    let authenticated = try DeliveryProtocolV1.authenticateAck(
        ack,
        context: DeliveryAckAuthenticationContext(
            receiverID: fixture.receiverID,
            deviceID: fixture.deviceID,
            connectionGeneration: 1,
            deviceAgreementPrivateKey: fixture.deviceAgreement,
            receiverSigningPublicKey: fixture.receiverSigning.publicKey,
            receiverAgreementPublicKey: fixture.receiverAgreement.publicKey
        )
    )
    let locator = try MailboxLocatorV1.resolveIsolated(
        providerRoot: provider,
        containerIdentifier: "iCloud.dev.example.healthbridge.mailboxqa",
        receiverComponent: fixture.receiverID.hexV1,
        deviceComponent: fixture.deviceID.hexV1,
        localRecordURL: support.appendingPathComponent("test-locator.json")
    )
    let lane = try XCTUnwrap(locator.lanes[.acks])
    let name = try MailboxLayoutV1.finalFileName(
        identifier: authenticated.ackID.hexV1,
        kind: .acknowledgment
    )
    try ack.write(
        to: lane.appendingPathComponent(name),
        options: [.withoutOverwriting]
    )
}
