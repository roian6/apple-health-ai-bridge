import Foundation
import Security
import XCTest
@testable import HealthBridgeCompanionCore

final class MailboxKeyStoreTrustTests: XCTestCase {
    func testInitializedIdentityWithoutExpectedAnchorFailsClosed() throws {
        // Given
        let keychain = RepairSyntheticMailboxKeychain()
        let store = MailboxKeyStore(service: repairService(), keychain: keychain)
        _ = try store.loadOrCreate()
        keychain.removeExpectedIdentity()

        // When / Then
        XCTAssertThrowsError(try store.loadOrCreate()) { error in
            XCTAssertEqual(error as? MailboxKeyStoreError, .keyMaterialLost)
        }
        XCTAssertNil(keychain.expectedIdentityData())
    }

    func testRotationSnapshotRollbackIsRejectedByIndependentGeneration() throws {
        try assertSnapshotRollbackRejected { store, first in
            _ = try store.rotate(expectedSigningKeyID: first.signingKeyID)
        }
    }

    func testRevocationSnapshotRollbackIsRejectedByIndependentGeneration() throws {
        try assertSnapshotRollbackRejected { store, _ in
            _ = try store.revoke()
        }
    }

    func testExclusiveLockBackendFailureMapsToPublicUnavailableError() {
        // Given
        let store = MailboxKeyStore(
            service: repairService(),
            keychain: LockFailingMailboxKeychain()
        )

        // When / Then
        XCTAssertThrowsError(try store.loadOrCreate()) { error in
            XCTAssertEqual(error as? MailboxKeyStoreError, .keychainUnavailable)
        }
    }

    func testInitializedStateWithoutProvisioningAnchorFailsClosed() throws {
        let keychain = RepairSyntheticMailboxKeychain()
        let store = MailboxKeyStore(service: repairService(), keychain: keychain)
        _ = try store.loadOrCreate()
        keychain.removeProvisioning()

        XCTAssertThrowsError(try store.loadOrCreate()) { error in
            XCTAssertEqual(error as? MailboxKeyStoreError, .keyMaterialLost)
        }
    }

    func testInterruptedRotationRecoversVerifiedForwardGeneration() throws {
        try assertInterruptedTransitionRecovers { store, first in
            _ = try store.rotate(expectedSigningKeyID: first.signingKeyID)
        }
    }

    func testInterruptedRevocationRecoversVerifiedForwardGeneration() throws {
        try assertInterruptedTransitionRecovers { store, _ in
            _ = try store.revoke()
        }
    }

    private func assertSnapshotRollbackRejected(
        transition: (MailboxKeyStore, MailboxPublicIdentity) throws -> Void
    ) throws {
        // Given
        let keychain = RepairSyntheticMailboxKeychain()
        let store = MailboxKeyStore(service: repairService(), keychain: keychain)
        let first = try store.loadOrCreate()
        let snapshot = keychain.mutableStateSnapshot()
        try transition(store, first)
        keychain.restoreMutableState(snapshot)

        // When / Then
        XCTAssertThrowsError(try store.loadOrCreate()) { error in
            XCTAssertEqual(String(describing: error), "rollbackDetected")
        }
    }

    private func assertInterruptedTransitionRecovers(
        transition: (MailboxKeyStore, MailboxPublicIdentity) throws -> Void
    ) throws {
        let keychain = RepairSyntheticMailboxKeychain()
        let store = MailboxKeyStore(service: repairService(), keychain: keychain)
        let first = try store.loadOrCreate()
        let old = keychain.allStateSnapshot()
        try transition(store, first)
        let new = keychain.allStateSnapshot()
        for includeExpectedAnchor in [false, true] {
            keychain.simulateTransitionCrash(
                old: old,
                new: new,
                includeExpectedAnchor: includeExpectedAnchor
            )
            _ = try store.publicSummary()
            XCTAssertEqual(keychain.allStateSnapshot(), new)
        }
    }
}

private final class LockFailingMailboxKeychain: MailboxKeychainClient {
    func withExclusiveAccess<T>(service: String, _ body: () throws -> T) throws -> T {
        throw MailboxKeychainBackendError(status: errSecNotAvailable)
    }

    func data(service: String, account: String) throws -> Data? {
        XCTFail("lock failure must prevent keychain reads")
        return nil
    }

    func store(_ data: Data, service: String, account: String) throws {
        XCTFail("lock failure must prevent keychain writes")
    }

    func remove(service: String, account: String) throws {
        XCTFail("lock failure must prevent keychain removal")
    }

    func trustData(service: String, record: MailboxTrustRecord) throws -> Data? {
        XCTFail("lock failure must prevent trust reads")
        return nil
    }

    func storeTrust(
        _ data: Data,
        service: String,
        record: MailboxTrustRecord
    ) throws {
        XCTFail("lock failure must prevent trust writes")
    }

    func removeTrust(service: String, record: MailboxTrustRecord) throws {
        XCTFail("lock failure must prevent trust removal")
    }
}
