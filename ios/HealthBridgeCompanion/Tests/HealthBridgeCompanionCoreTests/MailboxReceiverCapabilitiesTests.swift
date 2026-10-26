import CryptoKit
import Foundation
import XCTest
#if canImport(HealthBridgeCompanion)
@testable import HealthBridgeCompanion
#else
@testable import HealthBridgeCompanionCore
#endif

struct CapabilityTestFixture: Sendable {
    let key: Curve25519.Signing.PrivateKey
    let identity: MailboxConnectionIdentityV1
    let document: Data

    init() throws {
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        identity = MailboxConnectionIdentityV1(
            receiverID: String(repeating: "02", count: 16), deviceID: String(repeating: "03", count: 16),
            devicePrincipal: "synthetic", deviceSigningKeyID: String(repeating: "11", count: 16),
            deviceAgreementKeyID: String(repeating: "22", count: 16),
            receiverSigningKeyID: try DeliveryProtocolV1.keyID(algorithm: "ed25519", publicKey: key.publicKey.rawRepresentation),
            receiverAgreementKeyID: String(repeating: "33", count: 16),
            receiverSigningPublicKey: key.publicKey.rawRepresentation.base64URLEncodedString(),
            receiverAgreementPublicKey: Data(repeating: 0x44, count: 32).base64URLEncodedString(),
            opaqueBinding: Data(repeating: 0x55, count: 32).base64URLEncodedString(), connectionGeneration: 1
        )
        struct Golden: Decodable { let document_utf8: String }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        document = Data(try JSONDecoder().decode(Golden.self, from: Data(contentsOf:
            root.appendingPathComponent("tests/fixtures/mailbox_receiver_capabilities_v1.synthetic.json"))).document_utf8.utf8)
    }

    func changed(_ mutation: (inout [String: HBJCS1Value]) -> Void, resign: Bool = true) throws -> Data {
        guard case .object(var fields) = try DeliveryProtocolV1.decodeMetadata(document) else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        mutation(&fields)
        if resign {
            fields.removeValue(forKey: "signature")
            let domain = Data("health-bridge/mailbox/v1/receiver-capabilities/signature\0".utf8)
            fields["signature"] = .string(try key.signature(for: domain + DeliveryProtocolV1.encodeMetadata(.object(fields))).base64URLEncodedString())
        }
        return try DeliveryProtocolV1.encodeMetadata(.object(fields))
    }
}

final class MailboxReceiverCapabilitiesTests: XCTestCase {
    func testPythonGoldenAndUnknownFieldSignatureBinding() throws {
        let f = try CapabilityTestFixture()
        XCTAssertTrue(try MailboxReceiverCapabilities.decode(f.document, identity: f.identity).nutritionSupported)
        let tampered = try f.changed({ fields in
            guard case .object(var capabilities)? = fields["capabilities"] else { return }
            capabilities["future_synthetic"] = .object(["enabled": .bool(false)])
            fields["capabilities"] = .object(capabilities)
        }, resign: false)
        XCTAssertThrowsError(try MailboxReceiverCapabilities.decode(tampered, identity: f.identity))
        let compatible = try f.changed { fields in
            guard case .object(var capabilities)? = fields["capabilities"] else { return }
            capabilities["future_synthetic"] = .object(["enabled": .bool(false)])
            fields["capabilities"] = .object(capabilities)
        }
        XCTAssertTrue(try MailboxReceiverCapabilities.decode(compatible, identity: f.identity).nutritionSupported)
    }

    func testRejectsSignedWrongWrapperAndRequiredFields() throws {
        let f = try CapabilityTestFixture()
        let wrong: [(String, HBJCS1Value)] = [
            ("v", .bool(true)), ("v", .integer(2)), ("kind", .string("ack")),
            ("receiver_id", .string(String(repeating: "04", count: 16))),
            ("device_id", .string(String(repeating: "04", count: 16))),
            ("connection_generation", .integer(2)), ("connection_generation", .integer(-1)),
            ("connection_generation", .bool(true)), ("receiver_signing_key_id", .string(String(repeating: "00", count: 16))),
            ("extra", .null), ("capabilities", .object([:])), ("capabilities", .null)
        ]
        for (name, value) in wrong {
            let data = try f.changed { $0[name] = value }
            XCTAssertThrowsError(try MailboxReceiverCapabilities.decode(data, identity: f.identity), name)
        }
        for (field, value) in [("nutrition_supported", HBJCS1Value.integer(1)), ("schema_id", .string("unknown")), ("batch_schema_id", .string("unknown"))] {
            let data = try f.changed { fields in
                guard case .object(var capabilities)? = fields["capabilities"] else { return }
                capabilities[field] = value
                fields["capabilities"] = .object(capabilities)
            }
            XCTAssertThrowsError(try MailboxReceiverCapabilities.decode(data, identity: f.identity))
        }
    }

    func testFalseDeclarationAndMalformedBounds() throws {
        let f = try CapabilityTestFixture()
        let unsupported = try f.changed { fields in
            guard case .object(var capabilities)? = fields["capabilities"] else { return }
            capabilities["nutrition_supported"] = .bool(false)
            fields["capabilities"] = .object(capabilities)
        }
        XCTAssertFalse(try MailboxReceiverCapabilities.decode(unsupported, identity: f.identity).nutritionSupported)
        for data in [Data(repeating: 0x20, count: 8193), Data("{}".utf8), Data([0xff]),
            Data(String(decoding: f.document, as: UTF8.self).replacingOccurrences(of: "\"v\":1", with: "\"v\":1,\"v\":1").utf8)] {
            XCTAssertThrowsError(try MailboxReceiverCapabilities.decode(data, identity: f.identity))
        }
    }
}

private struct CapabilityLocalFixture: Sendable {
    let root: URL
    let locator: MailboxResolvedLocatorV1
    let golden: CapabilityTestFixture
    var file: URL { locator.deviceRoot.appendingPathComponent(MailboxReceiverCapabilities.filename) }
    init() throws {
        golden = try CapabilityTestFixture()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CapabilityRead-\(UUID().uuidString)")
        let provider = root.appendingPathComponent("provider")
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        locator = try MailboxLocatorV1.resolveIsolated(providerRoot: provider, containerIdentifier: "synthetic.capabilities",
            receiverComponent: golden.identity.receiverID, deviceComponent: golden.identity.deviceID,
            localRecordURL: root.appendingPathComponent("local/locator.json"))
        try golden.document.write(to: file)
    }
    func close() { try? FileManager.default.removeItem(at: root) }
}

private final class CapabilityReadProbe: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Capability IO entered")
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var onMain = false
    private var expired = false
    private var requests = 0
    func block() {
        lock.withLock { onMain = Thread.isMainThread }
        entered.fulfill()
        if semaphore.wait(timeout: .now() + 5) != .success { lock.withLock { expired = true } }
    }
    func release() { semaphore.signal() }
    func requested() { lock.withLock { requests += 1 } }
    var downloadRequests: Int { lock.withLock { requests } }
    var occupiedMain: Bool { lock.withLock { onMain } }
    var watchdogExpired: Bool { lock.withLock { expired } }
}

extension MailboxReceiverCapabilitiesTests {
    @MainActor
    func testLocalReadAndMissingOrPlaceholderRequestsHydrationOnlyOnce() async throws {
        let f = try CapabilityLocalFixture(); defer { f.close() }
        let locator = f.locator
        let valid = try await MailboxReceiverCapabilities.read(identity: f.golden.identity, locate: { locator })
        XCTAssertEqual(valid?.nutritionSupported, true)
        for missing in [false, true] {
            if missing { try FileManager.default.removeItem(at: f.file) }
            let probe = CapabilityReadProbe()
            let io = MailboxReceiverCapabilities.IO(isLocal: { _ in false }, requestDownload: { url in
                XCTAssertEqual(url, f.file); probe.requested()
            }, readBytes: { _ in XCTFail("Remote metadata must not be polled or read"); return Data() })
            let result = try await MailboxReceiverCapabilities.read(identity: f.golden.identity, locate: { locator }, io: io)
            XCTAssertNil(result)
            XCTAssertEqual(probe.downloadRequests, 1)
        }
    }

    @MainActor
    func testCoordinatedReadLeavesMainActorResponsiveAndCancellationFencesResult() async throws {
        for cancel in [false, true] {
            let f = try CapabilityLocalFixture(); defer { f.close() }
            let locator = f.locator
            let probe = CapabilityReadProbe(); defer { probe.release() }
            let io = MailboxReceiverCapabilities.IO(readBytes: { url in
                probe.block()
                return try MailboxRegularFileReader.read(url, maximumBytes: 8192)
            })
            let task = Task { try await MailboxReceiverCapabilities.read(identity: f.golden.identity, locate: { locator }, io: io) }
            await fulfillment(of: [probe.entered], timeout: 5)
            var heartbeat = false
            await Task { @MainActor in heartbeat = true }.value
            XCTAssertTrue(heartbeat)
            XCTAssertFalse(probe.occupiedMain)
            XCTAssertFalse(probe.watchdogExpired)
            if cancel { task.cancel() }
            probe.release()
            if cancel {
                do { _ = try await task.value; XCTFail("Cancelled IO must not return support") }
                catch is CancellationError { }
            } else {
                let result = try await task.value
                XCTAssertEqual(result?.nutritionSupported, true)
            }
            XCTAssertFalse(probe.watchdogExpired)
        }
    }

    @MainActor
    func testSymlinkAndReplacedDirectoryAreUnknown() async throws {
        for replaceDirectory in [false, true] {
            let f = try CapabilityLocalFixture(); defer { f.close() }
            let locator = f.locator
            let io: MailboxReceiverCapabilities.IO
            if replaceDirectory {
                io = .init(readBytes: { url in
                    let bytes = try MailboxRegularFileReader.read(url, maximumBytes: 8192)
                    try FileManager.default.moveItem(at: locator.deviceRoot, to: f.root.appendingPathComponent("detached"))
                    return bytes
                })
            } else {
                try FileManager.default.removeItem(at: f.file)
                let other = f.root.appendingPathComponent("other")
                try f.golden.document.write(to: other)
                try FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: other)
                io = .init()
            }
            let result = try await MailboxReceiverCapabilities.read(identity: f.golden.identity, locate: { locator }, io: io)
            XCTAssertNil(result)
        }
    }

    func testTrustedKeyCannotBeReplacedByWrapper() throws {
        let f = try CapabilityTestFixture()
        let attacker = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x61, count: 32))
        guard case .object(var raw) = try DeliveryProtocolV1.decodeMetadata(f.document) else { return XCTFail("Golden malformed") }
        raw["receiver_signing_key_id"] = .string(try DeliveryProtocolV1.keyID(algorithm: "ed25519", publicKey: attacker.publicKey.rawRepresentation))
        raw.removeValue(forKey: "signature")
        let preimage = Data("health-bridge/mailbox/v1/receiver-capabilities/signature\0".utf8) + (try DeliveryProtocolV1.encodeMetadata(.object(raw)))
        raw["signature"] = .string(try attacker.signature(for: preimage).base64URLEncodedString())
        XCTAssertThrowsError(try MailboxReceiverCapabilities.decode(DeliveryProtocolV1.encodeMetadata(.object(raw)), identity: f.identity))
    }
}
