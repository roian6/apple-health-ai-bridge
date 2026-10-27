import CryptoKit
import Foundation
import XCTest
@testable import HealthBridgeCompanion

final class NutritionTokenStore: ReceiverTokenStoring {
    private var token = ""
    var loadsBeforeFailure: Int?
    private(set) var failedLoads = 0
    func loadToken() throws -> String {
        if let remaining = loadsBeforeFailure {
            if remaining == 0 {
                loadsBeforeFailure = nil
                failedLoads += 1
                throw KeychainReceiverTokenStoreError.unavailable
            }
            loadsBeforeFailure = remaining - 1
        }
        return token
    }
    func saveToken(_ token: String) throws { self.token = token }
}

final class NutritionKeychain: MailboxKeychainClient {
    private var items: [String: Data] = [:]
    private var trust: [String: Data] = [:]
    func withExclusiveAccess<T>(service: String, _ body: () throws -> T) throws -> T { try body() }
    func data(service: String, account: String) throws -> Data? { items[service + ":" + account] }
    func store(_ data: Data, service: String, account: String) throws { items[service + ":" + account] = data }
    func remove(service: String, account: String) throws { items.removeValue(forKey: service + ":" + account) }
    func trustData(service: String, record: MailboxTrustRecord) throws -> Data? { trust[service + ":" + record.rawValue] }
    func storeTrust(_ data: Data, service: String, record: MailboxTrustRecord) throws {
        trust[service + ":" + record.rawValue] = data
    }
    func removeTrust(service: String, record: MailboxTrustRecord) throws {
        trust.removeValue(forKey: service + ":" + record.rawValue)
    }
}

@MainActor
final class NutritionMailboxFixture {
    let base: NutritionFixture
    let keys: MailboxKeyStore
    let identity: MailboxConnectionIdentityV1
    let context: MailboxAckContext
    let locator: MailboxResolvedLocatorV1
    let signing = Curve25519.Signing.PrivateKey()
    let agreement = Curve25519.KeyAgreement.PrivateKey()
    var envelopeNumber: UInt8 = 0
    var capabilityReadIO = MailboxReceiverCapabilities.IO(requestDownload: { _ in })

    init(nativePairing: Bool = false) throws {
        base = try NutritionFixture(directPairing: !nativePairing)
        keys = MailboxKeyStore(service: base.suite, keychain: NutritionKeychain())
        let device = try keys.loadOrCreate()
        let receiverID = Data(repeating: 0x71, count: 16)
        let deviceID = Data(repeating: 0x72, count: 16)
        identity = MailboxConnectionIdentityV1(
            receiverID: receiverID.hexV1, deviceID: deviceID.hexV1, devicePrincipal: "synthetic-nutrition",
            deviceSigningKeyID: device.signingKeyID, deviceAgreementKeyID: device.agreementKeyID,
            receiverSigningKeyID: try DeliveryProtocolV1.keyID(
                algorithm: "ed25519", publicKey: signing.publicKey.rawRepresentation
            ),
            receiverAgreementKeyID: try DeliveryProtocolV1.keyID(
                algorithm: "x25519", publicKey: agreement.publicKey.rawRepresentation
            ),
            receiverSigningPublicKey: signing.publicKey.rawRepresentation.base64URLEncodedString(),
            receiverAgreementPublicKey: agreement.publicKey.rawRepresentation.base64URLEncodedString(),
            opaqueBinding: Data(repeating: 0x73, count: 32).base64URLEncodedString(), connectionGeneration: 1
        )
        if nativePairing {
            try base.settings.saveNativeMailboxPairing(
                identity, expectedGeneration: base.settings.receiverSettingsGenerationToken
            )
        } else {
            try base.settings.saveMailboxPairing(
                receiverURLString: "http://127.0.0.1:8765/v1/batches", bearerToken: "synthetic-nutrition",
                mailboxIdentity: identity, expectedGeneration: base.settings.receiverSettingsGenerationToken
            )
        }
        context = MailboxAckContext(
            receiverID: receiverID, deviceID: deviceID, receiverBindingID: identity.opaqueBinding,
            connectionGeneration: 1, deviceAgreementPrivateKey: try keys.agreementPrivateKey(),
            deviceAgreementKeyID: device.agreementKeyID,
            receiverSigningPublicKey: signing.publicKey, receiverSigningKeyID: identity.receiverSigningKeyID,
            receiverAgreementPublicKey: agreement.publicKey, receiverAgreementKeyID: identity.receiverAgreementKeyID,
            deviceSigningPublicKey: try Curve25519.Signing.PublicKey(rawRepresentation: device.signingPublicKey),
            deviceSigningKeyID: device.signingKeyID
        )
        let provider = base.root.appendingPathComponent("provider")
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        locator = try MailboxLocatorV1.resolveIsolated(
            providerRoot: provider, containerIdentifier: "synthetic.nutrition",
            receiverComponent: identity.receiverID, deviceComponent: identity.deviceID,
            localRecordURL: base.root.appendingPathComponent("local/locator.json")
        )
        if !nativePairing { try writeCapabilities() }
    }

    func removeCapabilities() throws {
        let url = locator.deviceRoot.appendingPathComponent(MailboxReceiverCapabilities.filename)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func writeCapabilities(supported: Bool = true, tamperUnknownField: Bool = false) throws {
        var fields: [String: HBJCS1Value] = [
            "v": .integer(1), "kind": .string("receiver_capabilities"),
            "receiver_id": .string(identity.receiverID), "device_id": .string(identity.deviceID),
            "connection_generation": .integer(1),
            "receiver_signing_key_id": .string(identity.receiverSigningKeyID),
            "capabilities": .object([
                "schema_id": .string("health_bridge.receiver_capabilities.v1"),
                "batch_schema_id": .string("health_bridge.batch.v1"),
                "nutrition_supported": .bool(supported),
                "future_synthetic": .object(["enabled": .bool(true)])
            ])
        ]
        let unsigned = try DeliveryProtocolV1.encodeMetadata(.object(fields))
        let domain = Data("health-bridge/mailbox/v1/receiver-capabilities/signature\0".utf8)
        fields["signature"] = .string(try signing.signature(for: domain + unsigned).base64URLEncodedString())
        if tamperUnknownField, case .object(var capabilities)? = fields["capabilities"] {
            capabilities["future_synthetic"] = .object(["enabled": .bool(false)])
            fields["capabilities"] = .object(capabilities)
        }
        try DeliveryProtocolV1.encodeMetadata(.object(fields)).write(
            to: locator.deviceRoot.appendingPathComponent("receiver-capabilities.json"), options: .atomic
        )
    }

    func components() -> ProductionMailboxComponents {
        let location = locator
        let lookup = FileOutboxMailboxAckLookup(outbox: base.outbox, deviceSigningPublicKey: context.deviceSigningPublicKey)
        let transport = MailboxTransport(
            outbox: base.outbox,
            context: MailboxTransportContext(
                receiverID: context.receiverID, deviceID: context.deviceID,
                receiverBindingID: identity.opaqueBinding, connectionGeneration: 1,
                receiverAgreementPublicKey: agreement.publicKey, receiverAgreementKeyID: identity.receiverAgreementKeyID,
                deviceSigningPublicKey: context.deviceSigningPublicKey, deviceSigningKeyID: identity.deviceSigningKeyID
            ),
            sealer: DeliveryProtocolMailboxEnvelopeSealer(keyStore: keys), locate: { location },
            publisher: POSIXMailboxEnvelopePublisher(),
            envelopeID: { [self] in envelopeNumber += 1; return Data(repeating: envelopeNumber, count: 16) },
            nowMilliseconds: { 1_790_000_000_000 },
            isCancelled: { withUnsafeCurrentTask { $0?.isCancelled ?? false } },
            observe: { url, digest in
                SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() == digest
            }
        )
        return ProductionMailboxComponents(
            identity: identity, deviceSigningPublicKey: context.deviceSigningPublicKey, ackContext: context,
            transport: transport, ackLookup: lookup,
            scanner: MailboxAckScanner(context: context, lookup: lookup, locate: { location }), locate: { location }
        )
    }

    func delivery() -> ProductionMailboxDelivery {
        let components = components()
        return ProductionMailboxDelivery(
            settingsStore: base.settings, outbox: base.outbox, cursorStore: base.cursors,
            pendingGenerationStore: BackgroundSyncSettingsStore(userDefaults: base.defaults),
            keyStore: keys, componentsFactory: { components }, receiverClient: base.client, capabilityReadIO: capabilityReadIO
        )
    }

    func receiveAndAcknowledge(_ item: FileOutboxItem) throws -> HealthBridgeBatchV1 {
        let envelopeID = try components().transport.finalizedEnvelopeID(itemID: item.id)
        let lane = try XCTUnwrap(locator.lanes[.deliveries])
        let name = try MailboxLayoutV1.finalFileName(identifier: envelopeID.hexV1, kind: .delivery)
        let opened = try DeliveryProtocolV1.openDelivery(
            Data(contentsOf: lane.appendingPathComponent(name)),
            context: DeliveryEnvelopeOpenContext(
                receiverID: context.receiverID, deviceID: context.deviceID, connectionGeneration: 1,
                receiverAgreementPrivateKey: agreement, senderSigningPublicKey: context.deviceSigningPublicKey
            )
        )
        let payload = try Data(contentsOf: item.fileURL)
        XCTAssertEqual(opened.plaintext, payload)
        let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: payload)
        // Synthetic receiver invocation is local; native settings retain no HTTP credential.
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8765/v1/batches")))
        request.httpMethod = "POST"
        XCTAssertEqual(try base.receiver.respond(request, body: payload).0, 202)
        let ack = try DeliveryProtocolV1.sealAck(
            DeliveryReceiptV1(
                result: .committed,
                payloadSHA256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                receiptID: 1, datasetGeneration: 1, committedAtMS: 1_790_000_000_000, errorCode: nil
            ),
            context: DeliveryAckSealContext(
                envelopeID: envelopeID, receiverID: context.receiverID, deviceID: context.deviceID,
                connectionGeneration: 1, deviceAgreementPublicKey: context.deviceAgreementPrivateKey.publicKey,
                receiverSigningPrivateKey: signing, receiverAgreementPrivateKey: agreement
            )
        )
        let ackName = try MailboxLayoutV1.finalFileName(identifier: envelopeID.hexV1, kind: .acknowledgment)
        try ack.write(to: XCTUnwrap(locator.lanes[.acks]).appendingPathComponent(ackName), options: [.atomic])
        return batch
    }
}
