import CryptoKit
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

@MainActor
final class NativeMailboxPairingExchangeTests: XCTestCase {
    func testNativeStagePersistsTrustAndReusesIdentityWithoutHTTPCollision() throws {
        let f = try ExchangeFixture()
        defer { f.close() }
        let invitation = try f.peer.invitation()
        let coordinator = f.coordinator()
        XCTAssertFalse(try coordinator.hasPendingPairing())
        XCTAssertEqual(f.resolutions, 0)
        XCTAssertTrue(f.requests.isEmpty)
        XCTAssertTrue(f.installation.token.isEmpty)
        let first = try f.state().stage(invitation: invitation)
        XCTAssertEqual(first.transport, .mailbox)
        XCTAssertEqual(first.invitationSecret, invitation.invitationSecret)
        let raw = f.pending.token
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(object["expiresAt"] as? String, invitation.expiresAt)
        let trust = try XCTUnwrap(object["mailboxBootstrap"] as? [String: Any])
        let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(invitation.mailboxBootstrap))
        XCTAssertEqual(trust as NSDictionary, try XCTUnwrap(expected as? NSDictionary))
        XCTAssertFalse((object["receiverURLString"] as? String)?.isEmpty == false)
        XCTAssertFalse((object["redeemURLString"] as? String)?.isEmpty == false)
        XCTAssertEqual(try f.state().stage(invitation: invitation), first)
        XCTAssertEqual(f.pending.token, raw)
        let different = try ExchangePeer(signingByte: 0x35).invitation()
        XCTAssertThrowsError(try f.state().stage(invitation: different)) { error in
            XCTAssertEqual(error as? ReceiverPairingStateError, .pendingPairingConflict)
        }
        XCTAssertEqual(f.pending.token, raw)
    }

    func testFirstExchangeCommitsVerifiedIdentityWithoutHTTP() async throws {
        let f = try ExchangeFixture()
        defer { f.close() }
        XCTAssertNil(try f.settings.currentConnectionRecordV2())
        _ = try await f.coordinator().pair(invitation: f.peer.invitation())
        XCTAssertEqual(f.requests.count, 1)
        XCTAssertGreaterThan(f.completionReads, 0)
        let pending = try XCTUnwrap(f.publishedPending)
        let record = try XCTUnwrap(f.settings.currentConnectionRecordV2())
        XCTAssertEqual(record.activation, .paired(activeTransport: .mailbox))
        guard case .available(let identity) = record.mailboxIdentity else { return XCTFail("Missing committed identity") }
        XCTAssertEqual(identity.devicePrincipal, "installation:" + ExchangePeer.installationHash(pending.installationID).hexV1)
        XCTAssertEqual(identity.opaqueBinding, f.peer.expectedBinding)
        XCTAssertEqual(record.localScope.bindingID, identity.opaqueBinding)
        XCTAssertTrue(f.settings.receiverURLString.isEmpty)
        XCTAssertTrue(try f.settings.loadBearerToken().isEmpty)
        XCTAssertNil(try f.state().loadPending())
        XCTAssertTrue(f.backup.token.isEmpty)
    }

    func testLostCompletionColdResumeReusesPersistedSealedRequest() async throws {
        let f = try ExchangeFixture()
        defer { f.close() }
        f.allowCompletion = false
        do {
            _ = try await f.coordinator().pair(invitation: f.peer.invitation())
            XCTFail("Missing response must not commit")
        } catch { }
        guard let original = f.requests.first else { return XCTFail("NOT_REACHED: request publication") }
        let pending = try XCTUnwrap(f.state().loadPending())
        XCTAssertNil(try f.settings.currentConnectionRecordV2())
        f.allowCompletion = true
        _ = try await f.coordinator().resumePendingPairing()
        XCTAssertTrue(f.requests.allSatisfy { $0 == original })
        XCTAssertEqual(f.publishedPending?.installationID, pending.installationID)
        XCTAssertEqual(f.publishedPending?.deviceCredential, pending.deviceCredential)
        XCTAssertEqual(f.settings.activeTransport, .mailbox)
    }

    func testTamperedCompletionCannotCommitAfterReachingResponse() async throws {
        for tamper in ["receiverTrust", "requestDigest", "invitation", "installation", "binding"] {
            let f = try ExchangeFixture()
            defer { f.close() }
            f.peer.tamper = tamper
            let keys = try f.keys.loadOrCreate()
            try f.settings.save(receiverURLString: "https://synthetic.example/v1/batches",
                bearerToken: "synthetic-existing-direct")
            let outbox = try FileOutbox(directory: f.root.appendingPathComponent("existing-outbox"))
            let payload = Data("synthetic queued bytes".utf8)
            let item = try outbox.enqueue(payload, receiverIdentity: XCTUnwrap(f.settings.receiverBindingID))
            let primary = f.primary.token
            let backup = f.backup.token
            let queuedIDs = try outbox.pendingItems().map(\.id)
            do {
                _ = try await f.coordinator().pair(invitation: f.peer.invitation())
                XCTFail("Tampered completion accepted: \(tamper)")
            } catch { }
            XCTAssertGreaterThan(f.requests.count, 0, "NOT_REACHED: \(tamper) request")
            XCTAssertGreaterThan(f.completionReads, 0, "NOT_REACHED: \(tamper) authentication boundary")
            XCTAssertEqual(f.primary.token, primary)
            XCTAssertEqual(f.backup.token, backup)
            XCTAssertEqual(try outbox.pendingItems().map(\.id), queuedIDs)
            XCTAssertEqual(try Data(contentsOf: item.fileURL), payload)
            XCTAssertEqual(try f.keys.loadOrCreate(), keys)
            if !f.requests.isEmpty { XCTAssertNotNil(try f.state().loadPending()) }
        }
    }

    func testCancellationBeforePublicationEmitsNothing() async throws {
        let f = try ExchangeFixture()
        defer { f.close() }
        let coordinator = f.coordinator()
        _ = try f.state().stage(invitation: f.peer.invitation())
        try coordinator.beginPendingCancellation()
        _ = try coordinator.cancelPendingPairing()
        _ = try await coordinator.resumePendingPairing()
        XCTAssertTrue(f.requests.isEmpty)
        XCTAssertEqual(f.cancelPublications, 0)
        XCTAssertNil(try f.state().loadPending())
        XCTAssertNil(try f.settings.currentConnectionRecordV2().flatMap { record in
            record.activation == .unpaired ? nil : record
        })
    }

    func testCommittedResponseLossCancellationRequiresSignedReceiptAcrossRestart() async throws {
        let f = try ExchangeFixture()
        defer { f.close() }
        f.allowCompletion = false
        f.allowReceipt = false
        let first = f.coordinator()
        do { _ = try await first.pair(invitation: f.peer.invitation()) } catch { }
        guard let request = f.requests.first else { return XCTFail("NOT_REACHED: simulated remote commit") }
        let pending = try XCTUnwrap(f.state().loadPending())
        try first.beginPendingCancellation()
        _ = try? first.cancelPendingPairing()
        XCTAssertNotNil(try f.state().loadPending(), "Possible remote commit needs retained request authority")
        XCTAssertTrue(try f.state().hasPendingCancellation())
        f.allowCompletion = true // Late authenticated completion is now visible.
        _ = try? await f.coordinator().resumePendingPairing()
        XCTAssertNotEqual(f.settings.activeTransport, .mailbox)
        XCTAssertEqual(try f.state().loadPending()?.deviceCredential, pending.deviceCredential)
        XCTAssertGreaterThan(f.cancelPublications, 0, "NOT_REACHED: authenticated cancel publication")
        XCTAssertTrue(f.requests.allSatisfy { $0 == request })
        f.allowReceipt = true
        for tamper in ["requestDigest", "signature"] {
            f.peer.receiptTamper = tamper
            try f.refreshReceipt()
            let readsBefore = f.receiptReads
            _ = try? await f.coordinator().resumePendingPairing()
            XCTAssertGreaterThan(f.receiptReads, readsBefore, "NOT_REACHED: tampered receipt authentication")
            XCTAssertNotNil(try f.state().loadPending(), "Unauthenticated receipt must retain cancellation authority")
            XCTAssertTrue(try f.state().hasPendingCancellation())
            XCTAssertNotEqual(f.settings.activeTransport, .mailbox)
        }
        f.peer.receiptTamper = nil
        try f.refreshReceipt()
        _ = try await f.coordinator().resumePendingPairing()
        XCTAssertGreaterThan(f.receiptReads, 0, "NOT_REACHED: cancelled receipt verification")
        XCTAssertNil(try f.state().loadPending())
        XCTAssertFalse(try f.state().hasPendingCancellation())
        XCTAssertNotEqual(f.settings.activeTransport, .mailbox)
    }
    func testExplicitPrivateResetClearsPublishedNativeAuthority() async throws {
        let f = try ExchangeFixture()
        defer { f.close() }
        f.allowCompletion = false
        do {
            _ = try await f.coordinator().pair(invitation: f.peer.invitation())
            return XCTFail("Unavailable completion must leave a pending request")
        } catch ExchangeFailure.responseUnavailable {
            XCTAssertEqual(f.requests.count, 1)
        }
        let state = f.state()
        let pending = try XCTUnwrap(state.loadPending())
        XCTAssertTrue(pending.publicationMayHaveOccurred)
        XCTAssertFalse(pending.nativeCancellationConfirmed)
        XCTAssertThrowsError(try state.clearPending()) { error in
            XCTAssertEqual(error as? ReceiverPairingStateError, .nativeCancellationRequiresReceipt)
        }
        try state.beginPendingCancellation(
            expectedGeneration: f.settings.receiverSettingsGenerationToken)

        try state.resetPrivatePairingState()

        XCTAssertNil(try state.loadPending())
        XCTAssertFalse(try state.hasPendingCancellation())
        XCTAssertEqual(try state.loadOrCreateInstallationID(), pending.installationID)
        XCTAssertEqual(f.requests.count, 1)
        XCTAssertEqual(f.cancelPublications, 0)
    }

    func testPeerCompletionUsesJSONNullForURLFreeReceiver() throws {
        let peer = try ExchangePeer()
        let probe = try PeerWireSelfTestProbe(receiverSigning: peer.signing.publicKey.rawRepresentation,
            receiverAgreement: peer.agreement.publicKey.rawRepresentation)
        let request = try probe.request()
        let response = try peer.completion(request: request, pending: probe.pending)
        let payload = try probe.openCompletion(response, request: request)
        XCTAssertEqual(payload["receiver_url"], .null,
            "PEER-WIRE-001: URL-free receiver completion must contain genuine JSON null, not an empty String")
    }

    func testPeerRejectsAuthenticatedAdditionalRequestAndCancellationFields() throws {
        let peer = try ExchangePeer()
        let probe = try PeerWireSelfTestProbe(receiverSigning: peer.signing.publicKey.rawRepresentation,
            receiverAgreement: peer.agreement.publicKey.rawRepresentation)
        let ordinary = try probe.request()
        let response = try peer.completion(request: ordinary, pending: probe.pending)
        XCTAssertEqual(try probe.openCompletion(response, request: ordinary)["schema_id"],
            .string("health_bridge.receiver_pairing_completion.v1"))
        let cancel = try probe.cancel(request: ordinary)
        let receipt = try peer.cancelled(cancel: cancel, request: ordinary)
        XCTAssertEqual(try probe.authenticateResponse(receipt, kind: "cancelled", request: ordinary)["kind"],
            .string("cancelled"), "The ordinary request-bound cancellation must be accepted first")

        // Build and cryptographically check each variant outside the throws assertion.
        // Builder failures must never count as the peer rejecting an unknown field.
        let outerExtra = try probe.request(extraEnvelopeField: true)
        let innerExtra = try probe.request(extraPlaintextField: true)
        let cancelExtra = try probe.cancel(request: ordinary, extraField: true)
        XCTAssertThrowsError(try peer.completion(request: outerExtra, pending: probe.pending),
            "PEER-WIRE-002: peer must reject an additional authenticated request-envelope field")
        XCTAssertThrowsError(try peer.completion(request: innerExtra, pending: probe.pending),
            "PEER-WIRE-002: peer must reject an additional encrypted request-plaintext field")
        XCTAssertThrowsError(try peer.cancelled(cancel: cancelExtra, request: ordinary),
            "PEER-WIRE-002: peer must reject an additional signed cancellation field")
    }

}

private enum ExchangeFailure: Error { case responseUnavailable, invalidPeer }
private final class ExchangeTokens: ReceiverTokenStoring {
    var token = ""
    func loadToken() throws -> String { token }
    func saveToken(_ token: String) throws { self.token = token }
}

@MainActor
private final class ExchangeFixture {
    let root: URL
    let suite = "NativeMailboxPairingExchangeTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let primary = ExchangeTokens(), backup = ExchangeTokens(), pending = ExchangeTokens()
    let installation = ExchangeTokens(), cancellation = ExchangeTokens()
    let keys: MailboxKeyStore
    let settings: ReceiverSettingsStore
    let peer: ExchangePeer
    let session: URLSession
    var requests: [Data] = []
    var publishedPending: ReceiverPendingPairing?
    var completionReads = 0, cancelPublications = 0, receiptReads = 0, resolutions = 0
    var allowCompletion = true, allowReceipt = true

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeExchange-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = ReceiverSettingsStore(userDefaults: defaults, tokenStore: primary, preCutoverBackupStore: backup)
        keys = MailboxKeyStore(service: "synthetic.exchange", keychain: ExchangeMemoryKeys())
        peer = try ExchangePeer()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExchangeNoNetwork.self]
        session = URLSession(configuration: config)
    }

    func state() -> ReceiverPairingStateStore {
        ReceiverPairingStateStore(pendingStore: pending, installationIDStore: installation, cancellationStore: cancellation,
            installationIDGenerator: { "00000000-0000-4000-8000-000000000077" },
            deviceCredentialGenerator: { "hb_" + String(repeating: "a", count: 64) })
    }

    func coordinator() -> ReceiverPairingCoordinator {
        ReceiverPairingCoordinator(client: ReceiverClient(session: session), stateStore: state(), settingsStore: settings,
            mailboxKeyStore: keys, nativeMailboxIO: io())
    }

    func io() -> NativeMailboxPairingIO {
        NativeMailboxPairingIO(resolve: { [self] descriptor in
            resolutions += 1
            XCTAssertEqual(descriptor, try peer.invitation().mailboxBootstrap)
            let directory = root.appendingPathComponent("provider/pairing/\(descriptor.invitationID)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return directory
        }, publish: { [self] url, bytes in
            guard url.isFileURL, url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
                XCTFail("Operation escaped private fixture root")
                throw ExchangeFailure.invalidPeer
            }
            if url.lastPathComponent == "request.hbp" {
                let staged = try XCTUnwrap(state().loadPending())
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(pending.token.utf8)) as? [String: Any])
                let sealed = try XCTUnwrap(object["sealedRequest"] as? String)
                XCTAssertEqual(Data(base64Encoded: sealed), bytes, "Durable exact request must precede publication")
                requests.append(bytes)
                publishedPending = staged
                let response = try peer.completion(request: bytes, pending: staged)
                try ExchangePeer.write(response, to: url.deletingLastPathComponent().appendingPathComponent("completion.hbp"))
            } else if url.lastPathComponent == "cancel.hbp" {
                cancelPublications += 1
                let receipt = try peer.cancelled(cancel: bytes, request: XCTUnwrap(requests.first))
                try ExchangePeer.write(receipt, to: url.deletingLastPathComponent().appendingPathComponent("cancelled.hbp"))
            } else { XCTFail("Unexpected publication name"); throw ExchangeFailure.invalidPeer }
            try ExchangePeer.write(bytes, to: url)
        }, read: { [self] url in
            guard url.isFileURL, url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
                XCTFail("Operation escaped private fixture root")
                throw ExchangeFailure.invalidPeer
            }
            if url.lastPathComponent == "completion.hbp" {
                if !allowCompletion { return nil }
                completionReads += 1
            }
            if url.lastPathComponent == "cancelled.hbp" {
                if !allowReceipt { return nil }
                receiptReads += 1
            }
            return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        }, hydrate: { [self] url in
            guard url.isFileURL, url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
                XCTFail("Operation escaped private fixture root")
                throw ExchangeFailure.invalidPeer
            }
        }, wait: { throw ExchangeFailure.responseUnavailable })
    }

    func refreshReceipt() throws {
        let directory = root.appendingPathComponent("provider/pairing/\(ExchangePeer.invitationID)")
        let cancel = try Data(contentsOf: directory.appendingPathComponent("cancel.hbp"))
        let receipt = try peer.cancelled(cancel: cancel, request: XCTUnwrap(requests.first))
        try ExchangePeer.write(receipt, to: directory.appendingPathComponent("cancelled.hbp"))
    }

    func close() {
        print("native exchange reached: resolve=\(resolutions) request=\(requests.count) completion=\(completionReads) cancel=\(cancelPublications) receipt=\(receiptReads)")
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ExchangeNoNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Native pairing must not use HTTP")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() { }
}

private final class ExchangeMemoryKeys: MailboxKeychainClient {
    private var items: [String: Data] = [:]
    func withExclusiveAccess<T>(service: String, _ body: () throws -> T) throws -> T { try body() }
    func data(service: String, account: String) throws -> Data? { items[service + account] }
    func store(_ data: Data, service: String, account: String) throws { items[service + account] = data }
    func remove(service: String, account: String) throws { items.removeValue(forKey: service + account) }
    func trustData(service: String, record: MailboxTrustRecord) throws -> Data? { items[service + record.rawValue] }
    func storeTrust(_ data: Data, service: String, record: MailboxTrustRecord) throws { items[service + record.rawValue] = data }
    func removeTrust(service: String, record: MailboxTrustRecord) throws { items.removeValue(forKey: service + record.rawValue) }
}

// Independent wire fixtures for the peer's own contract tests. No coordinator,
// production pairing codec, stores, filesystem, or provider operations are used.
private struct PeerWireSelfTestProbe {
    private static let domain = "health-bridge/mailbox-pairing/v1/"
    private static let invitationID = "00112233445566778899aabbccddeeff"
    private static let invitationBytes = Data((0..<16).map { UInt8($0 * 17) })
    private let signing: Curve25519.Signing.PrivateKey
    private let agreement: Curve25519.KeyAgreement.PrivateKey
    private let receiverSigning: Data
    private let receiverAgreement: Data
    let pending = ReceiverPendingPairing(label: "synthetic-native-iphone", receiverURLString: "",
        redeemURLString: "", invitationSecret: "hbi_synthetic_native_invitation", invitationCode: nil,
        installationID: "00000000-0000-4000-8000-000000000077",
        deviceCredential: "hb_" + String(repeating: "a", count: 64), platform: "ios", transport: .mailbox)

    init(receiverSigning: Data, receiverAgreement: Data) throws {
        signing = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x61, count: 32))
        agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x62, count: 32))
        self.receiverSigning = receiverSigning
        self.receiverAgreement = receiverAgreement
    }

    func request(extraEnvelopeField: Bool = false, extraPlaintextField: Bool = false) throws -> Data {
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x63, count: 32))
        let shared = try ephemeral.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: receiverAgreement))
        // Distinct synthetic nonces for the ordinary and two authenticated variants.
        let nonceByte: UInt8 = 0x70 + (extraEnvelopeField ? 1 : 0) + (extraPlaintextField ? 2 : 0)
        let nonce = Data(repeating: nonceByte, count: 12)
        var envelope: [String: HBJCS1Value] = [
            "v": .integer(1), "kind": .string("request"), "invitation_id": .string(Self.invitationID),
            "sender_signing_public_key": .string(Self.b64(signing.publicKey.rawRepresentation)),
            "ephemeral_public_key": .string(Self.b64(ephemeral.publicKey.rawRepresentation)),
            "nonce": .string(Self.b64(nonce)),
        ]
        if extraEnvelopeField { envelope["unexpected_outer"] = .string("synthetic-extra") }
        var inner: [String: HBJCS1Value] = [
            "invitation_secret": .string("hbi_synthetic_native_invitation"),
            "installation_id": .string(pending.installationID), "device_credential": .string(pending.deviceCredential),
            "platform": .string("ios"), "device_signing_public_key": .string(Self.b64(signing.publicKey.rawRepresentation)),
            "device_agreement_public_key": .string(Self.b64(agreement.publicKey.rawRepresentation)),
        ]
        if extraPlaintextField { inner["unexpected_inner"] = .string("synthetic-extra") }
        let plaintext = try Self.canonical(inner)
        let aad = try Self.prefixed("request/aad\0", envelope)
        let key = Self.key(shared, salt: Self.invitationBytes, purpose: "request/key")
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        guard try AES.GCM.open(box, using: key, authenticating: aad) == plaintext else { throw ExchangeFailure.invalidPeer }
        envelope["ciphertext"] = .string(Self.b64(box.ciphertext + box.tag))
        let message = try Self.prefixed("request/signature\0", envelope)
        let signature = try signing.signature(for: message)
        guard signing.publicKey.isValidSignature(signature, for: message) else { throw ExchangeFailure.invalidPeer }
        envelope["signature"] = .string(Self.b64(signature))
        return try Self.canonical(envelope)
    }

    func cancel(request: Data, extraField: Bool = false) throws -> Data {
        var fields: [String: HBJCS1Value] = [
            "v": .integer(1), "kind": .string("cancel"), "invitation_id": .string(Self.invitationID),
            "request_sha256": .string(Self.hex(Self.hash(request))),
            "sender_signing_public_key": .string(Self.b64(signing.publicKey.rawRepresentation)),
        ]
        if extraField { fields["unexpected_cancel"] = .string("synthetic-extra") }
        let message = try Self.prefixed("cancel/signature\0", fields)
        let signature = try signing.signature(for: message)
        guard signing.publicKey.isValidSignature(signature, for: message) else { throw ExchangeFailure.invalidPeer }
        fields["signature"] = .string(Self.b64(signature))
        return try Self.canonical(fields)
    }

    func authenticateResponse(_ encoded: Data, kind: String, request: Data) throws -> [String: HBJCS1Value] {
        var fields = try Self.object(encoded)
        let common: Set<String> = ["v", "kind", "invitation_id", "request_sha256", "sender_signing_public_key", "signature"]
        let expected = kind == "completion" ? common.union(["nonce", "ciphertext"]) : common
        guard Set(fields.keys) == expected, fields["v"] == .integer(1), fields["kind"] == .string(kind),
              fields["invitation_id"] == .string(Self.invitationID),
              fields["request_sha256"] == .string(Self.hex(Self.hash(request))),
              fields["sender_signing_public_key"] == .string(Self.b64(receiverSigning)) else { throw ExchangeFailure.invalidPeer }
        let signature = try Self.bytes(fields, "signature")
        fields.removeValue(forKey: "signature")
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: receiverSigning)
        guard try key.isValidSignature(signature, for: Self.prefixed(kind + "/signature\0", fields)) else {
            throw ExchangeFailure.invalidPeer
        }
        return fields
    }

    func openCompletion(_ encoded: Data, request: Data) throws -> [String: HBJCS1Value] {
        var fields = try authenticateResponse(encoded, kind: "completion", request: request)
        let nonce = try Self.bytes(fields, "nonce")
        let ciphertext = try Self.bytes(fields, "ciphertext")
        fields.removeValue(forKey: "ciphertext")
        let shared = try agreement.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: receiverAgreement))
        let salt = Self.invitationBytes + Self.hash(request)
        let nonceKey = Self.key(shared, salt: salt, purpose: "completion/nonce")
        guard nonce == nonceKey.withUnsafeBytes({ Data($0.prefix(12)) }), ciphertext.count >= 16 else {
            throw ExchangeFailure.invalidPeer
        }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
        let plaintext = try AES.GCM.open(box, using: Self.key(shared, salt: salt, purpose: "completion/key"),
            authenticating: Self.prefixed("completion/aad\0", fields))
        return try Self.object(plaintext)
    }

    private static func canonical(_ fields: [String: HBJCS1Value]) throws -> Data {
        try DeliveryProtocolV1.encodeMetadata(.object(fields))
    }
    private static func object(_ bytes: Data) throws -> [String: HBJCS1Value] {
        guard case .object(let fields) = try DeliveryProtocolV1.decodeMetadata(bytes) else { throw ExchangeFailure.invalidPeer }
        return fields
    }
    private static func prefixed(_ suffix: String, _ fields: [String: HBJCS1Value]) throws -> Data {
        try Data((domain + suffix).utf8) + canonical(fields)
    }
    private static func key(_ shared: SharedSecret, salt: Data, purpose: String) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: Data((domain + purpose).utf8), outputByteCount: 32)
    }
    private static func hash(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
    private static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    private static func b64(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func bytes(_ fields: [String: HBJCS1Value], _ name: String) throws -> Data {
        guard case .string(let text) = fields[name] else { throw ExchangeFailure.invalidPeer }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded), b64(decoded) == text else { throw ExchangeFailure.invalidPeer }
        return decoded
    }
}

// Independent synthetic receiver: current Python wire, CryptoKit and HBJCS1 only.
// Deliberately does not use any future native request/completion codec.
private final class ExchangePeer {
    static let invitationID = "00112233445566778899aabbccddeeff"
    static let invitationBytes = Data((0..<16).map { UInt8($0 * 17) })
    static let domain = "health-bridge/mailbox-pairing/v1/"
    let signing: Curve25519.Signing.PrivateKey
    let agreement: Curve25519.KeyAgreement.PrivateKey
    var tamper: String?
    var receiptTamper: String?
    var expectedBinding = ""

    init(signingByte: UInt8 = 0x31) throws {
        signing = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: signingByte, count: 32))
        agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x32, count: 32))
    }

    func invitation() throws -> ReceiverPairingInvitation {
        let object: [String: Any] = [
            "schema_id": "health_bridge.receiver_pairing_invitation.v2", "schema_version": "2.0.0",
            "label": "synthetic-native-iphone", "expires_at": "2030-01-01T00:00:00Z",
            "invitation_secret": "hbi_synthetic_native_invitation", "transport": "mailbox",
            "mailbox_protocol_version": 1,
            "mailbox_bootstrap": ["version": 1, "invitation_id": Self.invitationID,
                "receiver_signing_public_key": Self.b64(signing.publicKey.rawRepresentation),
                "receiver_agreement_public_key": Self.b64(agreement.publicKey.rawRepresentation)],
        ]
        return try ReceiverPairingInvitation(jsonData: JSONSerialization.data(withJSONObject: object))
    }

    static func installationHash(_ value: String) -> Data {
        hash(Data("health-bridge-pairing:installation:\(value)".utf8))
    }
    static func hash(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
    static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    static func b64(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decoded(_ text: String) throws -> Data {
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - text.count % 4) % 4)
        let bytes = try XCTUnwrap(Data(base64Encoded: padded))
        XCTAssertEqual(b64(bytes), text)
        return bytes
    }
    static func text(_ object: [String: Any], _ field: String) throws -> String {
        try XCTUnwrap(object[field] as? String, field)
    }
    static func canonical(_ object: [String: Any]) throws -> Data {
        var fields: [String: HBJCS1Value] = [:]
        for (key, value) in object {
            if let string = value as? String { fields[key] = .string(string) }
            else if let number = value as? Int { fields[key] = .integer(Int64(number)) }
            else if value is NSNull { fields[key] = .null }
            else { throw ExchangeFailure.invalidPeer }
        }
        return try DeliveryProtocolV1.encodeMetadata(.object(fields))
    }
    static func object(_ bytes: Data) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(try canonical(object), bytes, "Wire must be canonical HBJCS1")
        return object
    }
    static func domainBytes(_ suffix: String) -> Data { Data((domain + suffix).utf8) }
    static func key(_ shared: SharedSecret, salt: Data, purpose: String) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: domainBytes(purpose), outputByteCount: 32)
    }
    static func keyID(_ algorithm: String, _ bytes: Data) -> String {
        hex(Data(hash(Data((algorithm + "\0").utf8) + bytes).prefix(16)))
    }
    static func write(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func completion(request bytes: Data, pending: ReceiverPendingPairing) throws -> Data {
        XCTAssertLessThanOrEqual(bytes.count, 65_536)
        var envelope = try Self.object(bytes)
        guard Set(envelope.keys) == Set([
            "v", "kind", "invitation_id", "sender_signing_public_key",
            "ephemeral_public_key", "nonce", "ciphertext", "signature",
        ]) else { throw ExchangeFailure.invalidPeer }
        XCTAssertEqual(envelope["v"] as? Int, 1)
        XCTAssertEqual(try Self.text(envelope, "kind"), "request")
        XCTAssertEqual(try Self.text(envelope, "invitation_id"), Self.invitationID)
        let deviceSigning = try Self.decoded(Self.text(envelope, "sender_signing_public_key"))
        let signature = try Self.decoded(Self.text(envelope, "signature"))
        envelope.removeValue(forKey: "signature")
        let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: deviceSigning)
        guard try signingKey.isValidSignature(signature,
            for: Self.domainBytes("request/signature\0") + Self.canonical(envelope)) else {
            throw ExchangeFailure.invalidPeer
        }
        let ciphertext = try Self.decoded(Self.text(envelope, "ciphertext"))
        envelope.removeValue(forKey: "ciphertext")
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: Self.decoded(Self.text(envelope, "ephemeral_public_key")))
        let requestShared = try agreement.sharedSecretFromKeyAgreement(with: ephemeral)
        let nonce = try AES.GCM.Nonce(data: Self.decoded(Self.text(envelope, "nonce")))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
        let plaintext = try AES.GCM.open(box,
            using: Self.key(requestShared, salt: Self.invitationBytes, purpose: "request/key"),
            authenticating: Self.domainBytes("request/aad\0") + Self.canonical(envelope))
        let request = try Self.object(plaintext)
        guard Set(request.keys) == Set([
            "invitation_secret", "installation_id", "device_credential", "platform",
            "device_signing_public_key", "device_agreement_public_key",
        ]) else { throw ExchangeFailure.invalidPeer }
        XCTAssertEqual(try Self.text(request, "invitation_secret"), "hbi_synthetic_native_invitation")
        XCTAssertEqual(try Self.text(request, "installation_id"), pending.installationID)
        XCTAssertEqual(try Self.text(request, "device_credential"), pending.deviceCredential)
        XCTAssertEqual(try Self.text(request, "platform"), "ios")
        XCTAssertEqual(try Self.decoded(Self.text(request, "device_signing_public_key")), deviceSigning)
        let deviceAgreement = try Self.decoded(Self.text(request, "device_agreement_public_key"))
        let receiverSigning = signing.publicKey.rawRepresentation
        let receiverAgreement = agreement.publicKey.rawRepresentation
        let receiverID = Data(Self.hash(Data("health-bridge/mailbox/v1/receiver-id\0".utf8) + receiverSigning).prefix(16))
        let deviceID = Data(Self.hash(Data("health-bridge/mailbox/v1/device-id\0".utf8)
            + Self.installationHash(pending.installationID)).prefix(16))
        expectedBinding = Self.b64(Self.hash(Data("health-bridge/mailbox/v1/connection-binding\0".utf8)
            + receiverID + deviceID + deviceSigning + deviceAgreement + receiverSigning + receiverAgreement))
        var payload: [String: Any] = [
            "schema_id": "health_bridge.receiver_pairing_completion.v1", "schema_version": "1.0.0",
            "label": "synthetic-native-iphone", "receiver_url": NSNull(), "mailbox_protocol_version": 1,
            "mailbox_receiver_id": Self.hex(receiverID), "mailbox_device_id": Self.hex(deviceID),
            "mailbox_receiver_binding_id": expectedBinding, "mailbox_connection_generation": 1,
            "mailbox_receiver_signing_public_key": Self.b64(receiverSigning),
            "mailbox_receiver_agreement_public_key": Self.b64(receiverAgreement),
            "mailbox_receiver_signing_key_id": Self.keyID("ed25519", receiverSigning),
            "mailbox_receiver_agreement_key_id": Self.keyID("x25519", receiverAgreement),
        ]
        if tamper == "installation" { payload["mailbox_device_id"] = String(repeating: "9", count: 32) }
        if tamper == "binding" { payload["mailbox_receiver_binding_id"] = Self.b64(Data(repeating: 0x99, count: 32)) }
        let digest = Self.hash(bytes)
        let salt = Self.invitationBytes + digest
        let shared = try agreement.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: deviceAgreement))
        let nonceKey = Self.key(shared, salt: salt, purpose: "completion/nonce")
        let responseNonce = nonceKey.withUnsafeBytes { Data($0.prefix(12)) }
        let signer = tamper == "receiverTrust"
            ? try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x45, count: 32)) : signing
        var response: [String: Any] = ["v": 1, "kind": "completion",
            "invitation_id": tamper == "invitation" ? String(repeating: "9", count: 32) : Self.invitationID,
            "sender_signing_public_key": Self.b64(signer.publicKey.rawRepresentation),
            "request_sha256": tamper == "requestDigest" ? String(repeating: "9", count: 64) : Self.hex(digest),
            "nonce": Self.b64(responseNonce)]
        let sealed = try AES.GCM.seal(Self.canonical(payload),
            using: Self.key(shared, salt: salt, purpose: "completion/key"), nonce: AES.GCM.Nonce(data: responseNonce),
            authenticating: Self.domainBytes("completion/aad\0") + Self.canonical(response))
        response["ciphertext"] = Self.b64(sealed.ciphertext + sealed.tag)
        response["signature"] = try Self.b64(signer.signature(for:
            Self.domainBytes("completion/signature\0") + Self.canonical(response)))
        return try Self.canonical(response)
    }

    func cancelled(cancel: Data, request: Data) throws -> Data {
        var intent = try Self.object(cancel)
        guard Set(intent.keys) == Set([
            "v", "kind", "invitation_id", "request_sha256", "sender_signing_public_key", "signature",
        ]) else { throw ExchangeFailure.invalidPeer }
        let original = try Self.object(request)
        XCTAssertEqual(intent["v"] as? Int, 1)
        XCTAssertEqual(try Self.text(intent, "kind"), "cancel")
        XCTAssertEqual(try Self.text(intent, "invitation_id"), Self.invitationID)
        XCTAssertEqual(try Self.text(intent, "request_sha256"), Self.hex(Self.hash(request)))
        XCTAssertEqual(try Self.text(intent, "sender_signing_public_key"), try Self.text(original, "sender_signing_public_key"))
        let signature = try Self.decoded(Self.text(intent, "signature"))
        intent.removeValue(forKey: "signature")
        let device = try Curve25519.Signing.PublicKey(rawRepresentation:
            Self.decoded(Self.text(original, "sender_signing_public_key")))
        guard try device.isValidSignature(signature,
            for: Self.domainBytes("cancel/signature\0") + Self.canonical(intent)) else {
            throw ExchangeFailure.invalidPeer
        }
        var receipt: [String: Any] = ["v": 1, "kind": "cancelled", "invitation_id": Self.invitationID,
            "request_sha256": Self.hex(Self.hash(request)), "sender_signing_public_key": Self.b64(signing.publicKey.rawRepresentation)]
        if receiptTamper == "requestDigest" { receipt["request_sha256"] = String(repeating: "9", count: 64) }
        receipt["signature"] = try Self.b64(signing.signature(for:
            Self.domainBytes("cancelled/signature\0") + Self.canonical(receipt)))
        if receiptTamper == "signature" { receipt["signature"] = Self.b64(Data(repeating: 0, count: 64)) }
        return try Self.canonical(receipt)
    }
}
