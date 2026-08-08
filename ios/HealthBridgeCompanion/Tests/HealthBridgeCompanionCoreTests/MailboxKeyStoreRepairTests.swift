import CryptoKit
import Foundation
import Security
import XCTest
@testable import HealthBridgeCompanionCore

final class MailboxKeyStoreRepairTests: XCTestCase {
    func testInitializationWriteFailureRollsBackOnlyNewAttemptArtifacts() throws {
        let keychain = RepairSyntheticMailboxKeychain()
        keychain.storeFailureNumber = 3
        let store = MailboxKeyStore(service: repairService(), keychain: keychain)

        XCTAssertThrowsError(try store.loadOrCreate()) { error in
            XCTAssertEqual(error as? MailboxKeyStoreError, .keychainUnavailable)
        }
        XCTAssertEqual(store.diagnosticState(), .notInitialized)
        XCTAssertTrue(keychain.allStateSnapshot().isEmpty)
    }

    func testInitializationRollbackFailureRemainsLostUntilExplicitRetryConverges() throws {
        let keychain = RepairSyntheticMailboxKeychain()
        keychain.storeFailureNumber = 3
        keychain.removalFailureNumber = 1
        let store = MailboxKeyStore(service: repairService(), keychain: keychain)

        XCTAssertThrowsError(try store.loadOrCreate()) { error in
            XCTAssertEqual(error as? MailboxKeyStoreError, .keyMaterialLost)
        }
        XCTAssertEqual(store.diagnosticState(), .lost)

        keychain.storeFailureNumber = nil
        keychain.removalFailureNumber = nil
        try store.resetLostKeyMaterial(authorization: .allowedForTesting)

        XCTAssertEqual(store.diagnosticState(), .notInitialized)
        XCTAssertTrue(keychain.allStateSnapshot().isEmpty)
    }

    func testLostKeyRecoveryIsCrashRetryableAndDoesNotReconstructTrust() throws {
        let keychain = RepairSyntheticMailboxKeychain()
        let store = MailboxKeyStore(service: repairService(), keychain: keychain)
        _ = try store.loadOrCreate()
        keychain.removePrivateIdentity()
        keychain.removalFailureNumber = 3

        XCTAssertThrowsError(
            try store.resetLostKeyMaterial(authorization: .allowedForTesting)
        ) { error in
            XCTAssertEqual(error as? MailboxKeyStoreError, .keychainUnavailable)
        }
        XCTAssertEqual(store.diagnosticState(), .lost)

        keychain.removalFailureNumber = nil
        try store.resetLostKeyMaterial(authorization: .allowedForTesting)

        XCTAssertEqual(store.diagnosticState(), .notInitialized)
        XCTAssertTrue(keychain.allStateSnapshot().isEmpty)
    }

    func testLostKeyRecoveryRefusesUnsafeCallerPolicyAndCompleteStates() throws {
        let deniedAuthorizations: [(MailboxKeyRecoveryAuthorization, MailboxKeyRecoveryError)] = [
            (.init(receiverActivationIsUnpaired: false, pendingPairingExists: false, terminalTransitionIsPending: false, pendingOutboxCount: 0, operationIsActive: false), .receiverActivationNotUnpaired),
            (.init(receiverActivationIsUnpaired: true, pendingPairingExists: true, terminalTransitionIsPending: false, pendingOutboxCount: 0, operationIsActive: false), .pairingOrTerminalTransitionPending),
            (.init(receiverActivationIsUnpaired: true, pendingPairingExists: false, terminalTransitionIsPending: true, pendingOutboxCount: 0, operationIsActive: false), .pairingOrTerminalTransitionPending),
            (.init(receiverActivationIsUnpaired: true, pendingPairingExists: false, terminalTransitionIsPending: false, pendingOutboxCount: nil, operationIsActive: false), .outboxStatusUnavailable),
            (.init(receiverActivationIsUnpaired: true, pendingPairingExists: false, terminalTransitionIsPending: false, pendingOutboxCount: 1, operationIsActive: false), .outboxNotEmpty),
            (.init(receiverActivationIsUnpaired: true, pendingPairingExists: false, terminalTransitionIsPending: false, pendingOutboxCount: 0, operationIsActive: true), .operationActive),
        ]
        for (authorization, expected) in deniedAuthorizations {
            let keychain = RepairSyntheticMailboxKeychain()
            let store = MailboxKeyStore(service: repairService(), keychain: keychain)
            _ = try store.loadOrCreate()
            keychain.removePrivateIdentity()

            XCTAssertThrowsError(
                try store.resetLostKeyMaterial(authorization: authorization)
            ) { error in
                XCTAssertEqual(error as? MailboxKeyRecoveryError, expected)
            }
            XCTAssertFalse(keychain.allStateSnapshot().isEmpty)
        }

        let activeStore = MailboxKeyStore(
            service: repairService(),
            keychain: RepairSyntheticMailboxKeychain()
        )
        _ = try activeStore.loadOrCreate()
        XCTAssertThrowsError(
            try activeStore.resetLostKeyMaterial(authorization: .allowedForTesting)
        ) { error in
            XCTAssertEqual(error as? MailboxKeyRecoveryError, .lifecycleNotLost)
        }

        let revokedStore = MailboxKeyStore(
            service: repairService(),
            keychain: RepairSyntheticMailboxKeychain()
        )
        _ = try revokedStore.loadOrCreate()
        _ = try revokedStore.revoke()
        XCTAssertThrowsError(
            try revokedStore.resetLostKeyMaterial(authorization: .allowedForTesting)
        ) { error in
            XCTAssertEqual(error as? MailboxKeyRecoveryError, .lifecycleNotLost)
        }

        let malformedKeychain = RepairSyntheticMailboxKeychain()
        let malformedStore = MailboxKeyStore(
            service: repairService(),
            keychain: malformedKeychain
        )
        _ = try malformedStore.loadOrCreate()
        malformedKeychain.mutateIdentityJSON { json in
            json["state"] = "not_initialized"
        }
        let malformedSnapshot = malformedKeychain.allStateSnapshot()
        XCTAssertThrowsError(
            try malformedStore.resetLostKeyMaterial(authorization: .allowedForTesting)
        ) { error in
            XCTAssertEqual(error as? MailboxKeyStoreError, .malformedState)
        }
        XCTAssertEqual(malformedKeychain.allStateSnapshot(), malformedSnapshot)
    }

    func testCompletePrivateRecordLossIsDetectedFromExternalExpectedIdentity() throws {
        // Given
        let keychain = RepairSyntheticMailboxKeychain()
        let store = MailboxKeyStore(service: repairService(), keychain: keychain)
        let first = try store.loadOrCreate()
        keychain.removePrivateIdentityAndMarker()

        // When / Then
        XCTAssertThrowsError(try store.loadOrCreate()) { error in
            XCTAssertEqual(error as? MailboxKeyStoreError, .keyMaterialLost)
        }
        XCTAssertEqual(keychain.expectedSigningKeyID(), first.signingKeyID)
    }

    func testConcurrentInitializationReturnsOnePersistedIdentity() throws {
        // Given
        let barrier = RepairBarrier(participants: 2)
        let keychain = RepairSyntheticMailboxKeychain(transactionBarrier: barrier.wait)
        let service = repairService()
        let returned = RepairResults<MailboxPublicIdentity>()

        // When
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            returned.capture {
                try MailboxKeyStore(service: service, keychain: keychain).loadOrCreate()
            }
        }

        // Then
        let values = try returned.successes()
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0], values[1])
        XCTAssertEqual(
            try MailboxKeyStore(service: service, keychain: keychain).loadOrCreate(),
            values[0]
        )
    }

    func testConcurrentExpectedIdentityRotationHasOneWinner() throws {
        // Given
        let keychain = RepairSyntheticMailboxKeychain()
        let service = repairService()
        let first = try MailboxKeyStore(service: service, keychain: keychain).loadOrCreate()
        let barrier = RepairBarrier(participants: 2)
        keychain.transactionBarrier = barrier.wait
        let returned = RepairResults<MailboxKeyRotation>()

        // When
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            returned.capture {
                try MailboxKeyStore(service: service, keychain: keychain).rotate(
                    expectedSigningKeyID: first.signingKeyID
                )
            }
        }

        // Then
        XCTAssertEqual(try returned.successes().count, 1)
        XCTAssertEqual(returned.errors(), [.staleIdentity])
        let persisted = try MailboxKeyStore(
            service: service,
            keychain: keychain
        ).loadOrCreate()
        XCTAssertEqual(try returned.successes()[0].identity, persisted)
    }

    func testRotationPersistsVerifiedCanonicalOldKeySignedContinuity() throws {
        // Given
        let keychain = RepairSyntheticMailboxKeychain()
        let store = MailboxKeyStore(service: repairService(), keychain: keychain)
        let old = try store.loadOrCreate()

        // When
        let rotation = try store.rotate(expectedSigningKeyID: old.signingKeyID)

        // Then
        XCTAssertEqual(rotation.continuity.oldSigningKeyID, old.signingKeyID)
        XCTAssertEqual(rotation.continuity.oldAgreementKeyID, old.agreementKeyID)
        XCTAssertEqual(
            rotation.continuity.newSigningKeyID,
            rotation.identity.signingKeyID
        )
        XCTAssertNoThrow(try verifyMailboxKeyContinuity(rotation.continuity))
        XCTAssertEqual(
            keychain.persistedContinuityData(),
            try rotation.continuity.canonicalData()
        )
    }

    func testContinuityTamperIsRejected() throws {
        // Given
        let store = MailboxKeyStore(
            service: repairService(),
            keychain: RepairSyntheticMailboxKeychain()
        )
        let first = try store.loadOrCreate()
        let rotation = try store.rotate(expectedSigningKeyID: first.signingKeyID)
        let tampered = rotation.continuity.replacingNewAgreementKeyID(
            String(repeating: "0", count: 32)
        )

        // When / Then
        XCTAssertThrowsError(try verifyMailboxKeyContinuity(tampered)) { error in
            XCTAssertEqual(error as? MailboxKeyStoreError, .malformedState)
        }
    }

    func testRotationInterruptionReconcilesStaleExpectedIdentity() throws {
        // Given
        let keychain = RepairSyntheticMailboxKeychain()
        let service = repairService()
        let store = MailboxKeyStore(service: service, keychain: keychain)
        let old = try store.loadOrCreate()
        let staleAnchor = try XCTUnwrap(keychain.expectedIdentityData())
        let rotation = try store.rotate(expectedSigningKeyID: old.signingKeyID)
        keychain.replaceExpectedIdentity(staleAnchor)

        // When
        let recovered = try MailboxKeyStore(
            service: service,
            keychain: keychain
        ).loadOrCreate()

        // Then
        XCTAssertEqual(recovered, rotation.identity)
        XCTAssertEqual(
            keychain.persistedContinuityData(),
            try rotation.continuity.canonicalData()
        )
    }

    func testBooleanVersionIsRejected() throws {
        // Given
        let keychain = RepairSyntheticMailboxKeychain()
        let service = repairService()
        _ = try MailboxKeyStore(service: service, keychain: keychain).loadOrCreate()

        // When
        keychain.mutateIdentityJSON { json in
            json["v"] = true
        }

        // Then
        XCTAssertThrowsError(
            try MailboxKeyStore(service: service, keychain: keychain).loadOrCreate()
        ) { error in
            XCTAssertEqual(error as? MailboxKeyStoreError, .malformedState)
        }
    }

    func testNoncanonicalBase64URLIsRejected() throws {
        // Given
        let keychain = RepairSyntheticMailboxKeychain()
        let service = repairService()
        _ = try MailboxKeyStore(service: service, keychain: keychain).loadOrCreate()

        // When
        keychain.mutateIdentityJSON { json in
            json["signing_private_key"] = "AA=="
        }

        // Then
        XCTAssertThrowsError(
            try MailboxKeyStore(service: service, keychain: keychain).loadOrCreate()
        ) { error in
            XCTAssertEqual(error as? MailboxKeyStoreError, .malformedState)
        }
    }

    func testWrongRawKeySizeIsRejected() throws {
        // Given
        let keychain = RepairSyntheticMailboxKeychain()
        let service = repairService()
        _ = try MailboxKeyStore(service: service, keychain: keychain).loadOrCreate()
        keychain.mutateIdentityJSON { json in
            json["agreement_private_key"] = Data(repeating: 7, count: 31)
                .base64URLEncodedString()
        }

        // When / Then
        XCTAssertThrowsError(
            try MailboxKeyStore(service: service, keychain: keychain).loadOrCreate()
        ) { error in
            XCTAssertEqual(error as? MailboxKeyStoreError, .malformedState)
        }
    }

    func testOversizedMarkerIsRejected() throws {
        // Given
        let keychain = RepairSyntheticMailboxKeychain()
        let service = repairService()
        _ = try MailboxKeyStore(service: service, keychain: keychain).loadOrCreate()

        // When
        keychain.replaceMarker(Data(repeating: 1, count: 4_097))

        // Then
        XCTAssertThrowsError(
            try MailboxKeyStore(service: service, keychain: keychain).loadOrCreate()
        ) { error in
            XCTAssertEqual(error as? MailboxKeyStoreError, .malformedState)
        }
    }
}
