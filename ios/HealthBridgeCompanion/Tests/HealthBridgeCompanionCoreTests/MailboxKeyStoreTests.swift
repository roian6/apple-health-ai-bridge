import CryptoKit
import Security
import XCTest
@testable import HealthBridgeCompanionCore

final class MailboxKeyStoreTests: XCTestCase {
    func testDiagnosticStateDistinguishesUninitializedActiveRevokedAndLost() throws {
        let keychain = SyntheticMailboxKeychain()
        let store = MailboxKeyStore(service: syntheticService(), keychain: keychain)

        XCTAssertEqual(store.diagnosticState(), .notInitialized)
        _ = try store.loadOrCreate()
        XCTAssertEqual(store.diagnosticState(), .active)
        _ = try store.revoke()
        XCTAssertEqual(store.diagnosticState(), .revoked)
        keychain.removeFirstStoredItem()
        XCTAssertEqual(store.diagnosticState(), .lost)
    }

    func testDiagnosticStateNeverContainsIdentityOrStorageMetadata() throws {
        let keychain = SyntheticMailboxKeychain()
        let store = MailboxKeyStore(service: syntheticService(), keychain: keychain)
        _ = try store.loadOrCreate()

        let encoded = try JSONEncoder().encode(store.diagnosticState())
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertEqual(json, #""active""#)
        XCTAssertFalse(json.contains("key_id"))
        XCTAssertFalse(json.contains("service"))
        XCTAssertFalse(json.contains("path"))
    }

    func testKeychainIdentityKeepsStableAlgorithmBoundPublicKeysOnly() throws {
        // Given
        let service = "com.example.HealthBridgeCompanion.mailbox-tests.\(UUID().uuidString)"
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mailbox-key-store-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        defer { deleteSyntheticKeychainItems(service: service) }
        defer { try? FileManager.default.removeItem(at: support) }
        let keychain = SystemMailboxKeychain(applicationSupportDirectory: support)
        let firstStore = MailboxKeyStore(service: service, keychain: keychain)

        // When
        let first = try firstStore.loadOrCreate()
        let reloaded = try MailboxKeyStore(
            service: service,
            keychain: keychain
        ).loadOrCreate()

        // Then
        XCTAssertEqual(first, reloaded)
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: first.signingPublicKey)
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: first.agreementPublicKey)
        XCTAssertEqual(
            first.signingKeyID,
            mailboxKeyID(algorithm: "ed25519", publicKey: first.signingPublicKey)
        )
        XCTAssertEqual(
            first.agreementKeyID,
            mailboxKeyID(algorithm: "x25519", publicKey: first.agreementPublicKey)
        )
        XCTAssertNotEqual(first.signingKeyID, first.agreementKeyID)
        let storedLabels = Mirror(reflecting: first).children.compactMap(\.label)
        XCTAssertFalse(storedLabels.contains { $0.localizedCaseInsensitiveContains("private") })
    }

    func testPublicSummarySerializesOnlyLifecycleAndPublicKeyIDs() throws {
        // Given
        let keychain = SyntheticMailboxKeychain()
        let store = MailboxKeyStore(service: syntheticService(), keychain: keychain)
        let identity = try store.loadOrCreate()

        // When
        let summary = try store.publicSummary()
        let encoded = try JSONEncoder().encode(summary)

        // Then
        XCTAssertEqual(summary.state, .active)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: String]
        )
        XCTAssertEqual(
            json,
            [
                "state": "active",
                "signing_key_id": identity.signingKeyID,
                "agreement_key_id": identity.agreementKeyID,
            ]
        )
    }

    func testPrivateSigningOperationDoesNotExportPrivateKeyMaterial() throws {
        // Given
        let store = MailboxKeyStore(
            service: syntheticService(),
            keychain: SyntheticMailboxKeychain()
        )
        let identity = try store.loadOrCreate()
        let message = Data("synthetic mailbox binding".utf8)

        // When
        let signature = try store.sign(message)

        // Then
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: identity.signingPublicKey
        )
        XCTAssertTrue(publicKey.isValidSignature(signature, for: message))
    }

    func testLifecycleReportsLossWhenOnePersistedPrivateKeyDisappears() throws {
        // Given
        let keychain = SyntheticMailboxKeychain()
        let store = MailboxKeyStore(service: syntheticService(), keychain: keychain)
        _ = try store.loadOrCreate()
        keychain.removeFirstStoredItem()

        // When
        let summary = try store.publicSummary()

        // Then
        XCTAssertEqual(summary.state, .lost)
    }

    func testLoadOrCreateRefusesToReplaceLostIdentity() throws {
        // Given
        let keychain = SyntheticMailboxKeychain()
        let store = MailboxKeyStore(service: syntheticService(), keychain: keychain)
        _ = try store.loadOrCreate()
        keychain.removeFirstStoredItem()

        // When / Then
        XCTAssertThrowsError(try store.loadOrCreate()) { error in
            XCTAssertEqual(error as? MailboxKeyStoreError, .keyMaterialLost)
        }
    }

    func testRevocationPersistsAndPreventsSilentRecreation() throws {
        // Given
        let keychain = SyntheticMailboxKeychain()
        let service = syntheticService()
        let store = MailboxKeyStore(service: service, keychain: keychain)
        _ = try store.loadOrCreate()

        // When
        let revoked = try store.revoke()

        // Then
        XCTAssertEqual(revoked.state, .revoked)
        XCTAssertEqual(
            try MailboxKeyStore(service: service, keychain: keychain).publicSummary().state,
            .revoked
        )
        XCTAssertThrowsError(try store.loadOrCreate()) { error in
            XCTAssertEqual(error as? MailboxKeyStoreError, .keysRevoked)
        }
    }

    func testExplicitRotationReplacesBothKeysAndPersistsNewIdentity() throws {
        // Given
        let keychain = SyntheticMailboxKeychain()
        let service = syntheticService()
        let store = MailboxKeyStore(service: service, keychain: keychain)
        let first = try store.loadOrCreate()

        // When
        let rotated = try store.rotate(expectedSigningKeyID: first.signingKeyID)

        // Then
        XCTAssertNotEqual(rotated.identity.signingKeyID, first.signingKeyID)
        XCTAssertNotEqual(rotated.identity.agreementKeyID, first.agreementKeyID)
        XCTAssertEqual(
            try MailboxKeyStore(service: service, keychain: keychain).loadOrCreate(),
            rotated.identity
        )
    }

    func testStaleRotationIsRejectedWithoutChangingIdentity() throws {
        // Given
        let keychain = SyntheticMailboxKeychain()
        let service = syntheticService()
        let store = MailboxKeyStore(service: service, keychain: keychain)
        let first = try store.loadOrCreate()

        // When / Then
        XCTAssertThrowsError(
            try store.rotate(expectedSigningKeyID: String(repeating: "0", count: 32))
        ) { error in
            XCTAssertEqual(error as? MailboxKeyStoreError, .staleIdentity)
        }
        XCTAssertEqual(try store.loadOrCreate(), first)
    }

    func testInteractionNotAllowedMapsToKeychainLocked() {
        assertMappedError(status: errSecInteractionNotAllowed, expected: .keychainLocked)
    }

    func testAuthenticationFailureMapsToKeychainAccessDenied() {
        assertMappedError(status: errSecAuthFailed, expected: .keychainAccessDenied)
    }

    func testMissingEntitlementMapsToKeychainUnavailable() {
        assertMappedError(status: errSecMissingEntitlement, expected: .keychainUnavailable)
    }
}

private final class SyntheticMailboxKeychain: MailboxKeychainClient {
    private var items: [String: Data] = [:]
    private var trustItems: [String: Data] = [:]
    var failureStatus: OSStatus?

    func withExclusiveAccess<T>(service: String, _ body: () throws -> T) throws -> T {
        try failWhenConfigured()
        return try body()
    }

    func data(service: String, account: String) throws -> Data? {
        try failWhenConfigured()
        return items["\(service)\0\(account)"]
    }

    func store(_ data: Data, service: String, account: String) throws {
        try failWhenConfigured()
        items["\(service)\0\(account)"] = data
    }

    func trustData(service: String, record: MailboxTrustRecord) throws -> Data? {
        try failWhenConfigured()
        return trustItems["\(service)\0\(record.rawValue)"]
    }

    func storeTrust(
        _ data: Data,
        service: String,
        record: MailboxTrustRecord
    ) throws {
        try failWhenConfigured()
        trustItems["\(service)\0\(record.rawValue)"] = data
    }

    func remove(service: String, account: String) throws {
        try failWhenConfigured()
        items.removeValue(forKey: "\(service)\0\(account)")
    }

    func removeTrust(service: String, record: MailboxTrustRecord) throws {
        try failWhenConfigured()
        trustItems.removeValue(forKey: "\(service)\0\(record.rawValue)")
    }

    func removeFirstStoredItem() {
        guard let key = items.keys.first(where: { $0.hasSuffix("\0identity-v1") }) else {
            return
        }
        items.removeValue(forKey: key)
    }

    private func failWhenConfigured() throws {
        if let failureStatus {
            throw MailboxKeychainBackendError(status: failureStatus)
        }
    }
}

private func assertMappedError(status: OSStatus, expected: MailboxKeyStoreError) {
    let keychain = SyntheticMailboxKeychain()
    keychain.failureStatus = status
    let store = MailboxKeyStore(service: syntheticService(), keychain: keychain)

    XCTAssertThrowsError(try store.loadOrCreate()) { error in
        XCTAssertEqual(error as? MailboxKeyStoreError, expected)
    }
}

private func syntheticService() -> String {
    "com.example.HealthBridgeCompanion.mailbox-tests.\(UUID().uuidString)"
}

private func mailboxKeyID(algorithm: String, publicKey: Data) -> String {
    var preimage = Data(algorithm.utf8)
    preimage.append(0)
    preimage.append(publicKey)
    return SHA256.hash(data: preimage).prefix(16).map {
        String(format: "%02x", $0)
    }.joined()
}

private func deleteSyntheticKeychainItems(service: String) {
    for itemClass in [kSecClassGenericPassword, kSecClassKey] {
        SecItemDelete(
            [
                kSecClass as String: itemClass,
                kSecAttrService as String: service,
            ] as CFDictionary
        )
    }
}
