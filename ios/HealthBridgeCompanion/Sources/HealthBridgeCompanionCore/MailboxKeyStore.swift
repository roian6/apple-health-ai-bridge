import CryptoKit
import Foundation

public enum MailboxKeyStoreError: Error, Equatable, Sendable {
    case keyMaterialLost
    case keysRevoked
    case staleIdentity
    case malformedState
    case rollbackDetected
    case keychainLocked
    case keychainAccessDenied
    case keychainUnavailable
}

public enum MailboxKeyPairingPreflightFailure: String, Error, Equatable, Sendable {
    case keyMaterialLost = "key_material_lost"
    case keysRevoked = "keys_revoked"
    case staleIdentity = "stale_identity"
    case malformedState = "malformed_state"
    case rollbackDetected = "rollback_detected"
    case keychainLocked = "keychain_locked"
    case keychainAccessDenied = "keychain_access_denied"
    case keychainUnavailable = "keychain_unavailable"

    init(_ error: MailboxKeyStoreError) {
        switch error {
        case .keyMaterialLost: self = .keyMaterialLost
        case .keysRevoked: self = .keysRevoked
        case .staleIdentity: self = .staleIdentity
        case .malformedState: self = .malformedState
        case .rollbackDetected: self = .rollbackDetected
        case .keychainLocked: self = .keychainLocked
        case .keychainAccessDenied: self = .keychainAccessDenied
        case .keychainUnavailable: self = .keychainUnavailable
        }
    }
}

public enum ReceiverPairingPreflightError: Error, Equatable, Sendable {
    case mailboxKey(MailboxKeyPairingPreflightFailure)
}

public struct MailboxKeyRecoveryAuthorization: Equatable, Sendable {
    public let receiverActivationIsUnpaired: Bool
    public let pendingPairingExists: Bool
    public let terminalTransitionIsPending: Bool
    public let pendingOutboxCount: Int?
    public let operationIsActive: Bool

    public init(
        receiverActivationIsUnpaired: Bool,
        pendingPairingExists: Bool,
        terminalTransitionIsPending: Bool,
        pendingOutboxCount: Int?,
        operationIsActive: Bool
    ) {
        self.receiverActivationIsUnpaired = receiverActivationIsUnpaired
        self.pendingPairingExists = pendingPairingExists
        self.terminalTransitionIsPending = terminalTransitionIsPending
        self.pendingOutboxCount = pendingOutboxCount
        self.operationIsActive = operationIsActive
    }
}

public enum MailboxKeyRecoveryError: Error, Equatable, Sendable {
    case receiverActivationNotUnpaired
    case pairingOrTerminalTransitionPending
    case outboxStatusUnavailable
    case outboxNotEmpty
    case operationActive
    case lifecycleNotLost
}

public final class MailboxKeyStore: MailboxSigningIdentityProviding {
    public static let backupPolicy = MailboxKeyBackupPolicy.thisDeviceOnlyNoBackup

    private let persistence: MailboxKeyPersistence

    public convenience init(service: String) {
        self.init(service: service, keychain: SystemMailboxKeychain())
    }

    init(service: String, keychain: MailboxKeychainClient) {
        persistence = MailboxKeyPersistence(service: service, keychain: keychain)
    }

    public func loadOrCreate() throws -> MailboxPublicIdentity {
        try persistence.exclusively {
            let loaded = try persistence.readState()
            guard let stored = loaded.stored else {
                guard loaded.anchor == nil, loaded.provisioning == nil else {
                    throw MailboxKeyStoreError.keyMaterialLost
                }
                let created = newStoredKeys()
                do {
                    try persistence.writeInitializedMarker()
                    try persistence.write(created)
                    let anchor = try anchorFor(created)
                    try persistence.write(anchor)
                    try persistence.write(try provisioningFor(anchor))
                    return try publicIdentity(created)
                } catch {
                    let initializationError = error
                    do {
                        try persistence.removeAllKeyMaterial()
                    } catch {
                        throw MailboxKeyStoreError.keyMaterialLost
                    }
                    throw initializationError
                }
            }
            guard let anchor = loaded.anchor, let provisioning = loaded.provisioning else {
                throw MailboxKeyStoreError.keyMaterialLost
            }
            try reconcile(stored: stored, anchor: anchor, provisioning: provisioning)
            try requireActive(stored)
            return try publicIdentity(stored)
        }
    }

    public func publicSummary() throws -> MailboxKeyLifecycleSummary {
        try persistence.exclusively {
            let loaded: LoadedMailboxState
            do {
                loaded = try persistence.readState()
            } catch MailboxKeyStoreError.keyMaterialLost {
                return MailboxKeyLifecycleSummary(state: .lost)
            }
            guard let stored = loaded.stored else {
                return MailboxKeyLifecycleSummary(state: .notInitialized)
            }
            guard let anchor = loaded.anchor, let provisioning = loaded.provisioning else {
                return MailboxKeyLifecycleSummary(state: .lost)
            }
            try reconcile(stored: stored, anchor: anchor, provisioning: provisioning)
            return try lifecycleSummary(stored)
        }
    }

    public func diagnosticState() -> MailboxKeyDiagnosticState {
        do {
            switch try publicSummary().state {
            case .notInitialized: return .notInitialized
            case .active: return .active
            case .revoked: return .revoked
            case .lost: return .lost
            }
        } catch let error as MailboxKeyStoreError {
            switch error {
            case .keyMaterialLost: return .lost
            case .keysRevoked: return .revoked
            case .malformedState, .staleIdentity: return .malformed
            case .rollbackDetected: return .rollbackDetected
            case .keychainLocked: return .locked
            case .keychainAccessDenied: return .accessDenied
            case .keychainUnavailable: return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    public func resetLostKeyMaterial(
        authorization: MailboxKeyRecoveryAuthorization
    ) throws {
        try Self.requireRecoveryAuthorization(authorization)
        try persistence.exclusively {
            let lostIsProven: Bool
            do {
                _ = try persistence.readState()
                lostIsProven = false
            } catch MailboxKeyStoreError.keyMaterialLost {
                lostIsProven = true
            }
            guard lostIsProven else {
                throw MailboxKeyRecoveryError.lifecycleNotLost
            }
            try persistence.removeAllKeyMaterial()
            let remaining = try persistence.readState()
            guard remaining.stored == nil,
                  remaining.anchor == nil,
                  remaining.provisioning == nil else {
                throw MailboxKeyStoreError.keyMaterialLost
            }
        }
    }

    public func sign(_ message: Data) throws -> Data {
        try persistence.exclusively {
            let stored = try activeStoredKeys()
            guard let raw = Data(strictBase64URL: stored.signingPrivateKey, count: 32)
            else {
                throw MailboxKeyStoreError.malformedState
            }
            return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
                .signature(for: message)
        }
    }

    public func sharedSecret(with peerAgreementPublicKey: Data) throws -> SharedSecret {
        try persistence.exclusively {
            let stored = try activeStoredKeys()
            guard let raw = Data(strictBase64URL: stored.agreementPrivateKey, count: 32)
            else {
                throw MailboxKeyStoreError.malformedState
            }
            do {
                let privateKey = try Curve25519.KeyAgreement.PrivateKey(
                    rawRepresentation: raw
                )
                let publicKey = try Curve25519.KeyAgreement.PublicKey(
                    rawRepresentation: peerAgreementPublicKey
                )
                return try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            } catch {
                throw MailboxKeyStoreError.malformedState
            }
        }
    }

    func agreementPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try persistence.exclusively {
            let stored = try activeStoredKeys()
            guard let raw = Data(
                strictBase64URL: stored.agreementPrivateKey,
                count: 32
            ) else {
                throw MailboxKeyStoreError.malformedState
            }
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        }
    }

    public func revoke() throws -> MailboxKeyLifecycleSummary {
        try persistence.exclusively {
            let stored = try activeStoredKeys()
            let revoked = StoredMailboxKeys(
                agreementPrivateKey: stored.agreementPrivateKey,
                continuity: stored.continuity,
                generation: stored.generation + 1,
                signingPrivateKey: stored.signingPrivateKey,
                state: .revoked,
                v: stored.v
            )
            try persistence.writeTransition(revoked)
            return try lifecycleSummary(revoked)
        }
    }

    public func rotate(expectedSigningKeyID: String) throws -> MailboxKeyRotation {
        try persistence.exclusively {
            let stored = try activeStoredKeys()
            let oldIdentity = try publicIdentity(stored)
            guard oldIdentity.signingKeyID == expectedSigningKeyID else {
                throw MailboxKeyStoreError.staleIdentity
            }
            let generated = newStoredKeys(generation: stored.generation + 1)
            let newIdentity = try publicIdentity(generated)
            let continuity = try signedContinuity(
                stored: stored,
                oldIdentity: oldIdentity,
                newIdentity: newIdentity
            )
            let replacement = StoredMailboxKeys(
                agreementPrivateKey: generated.agreementPrivateKey,
                continuity: continuity,
                generation: generated.generation,
                signingPrivateKey: generated.signingPrivateKey,
                state: .active,
                v: 1
            )
            try persistence.writeTransition(replacement)
            return MailboxKeyRotation(identity: newIdentity, continuity: continuity)
        }
    }

    private func activeStoredKeys() throws -> StoredMailboxKeys {
        let loaded = try persistence.readState()
        guard let stored = loaded.stored,
              let anchor = loaded.anchor,
              let provisioning = loaded.provisioning
        else {
            throw MailboxKeyStoreError.keyMaterialLost
        }
        try reconcile(stored: stored, anchor: anchor, provisioning: provisioning)
        try requireActive(stored)
        return stored
    }

    private func reconcile(
        stored: StoredMailboxKeys,
        anchor: ExpectedIdentityAnchor,
        provisioning: MailboxProvisioningAnchor
    ) throws {
        let writes = try requiredMailboxReconciliation(
            stored: stored,
            anchor: anchor,
            provisioning: provisioning
        )
        if let anchor = writes.anchor {
            try persistence.write(anchor)
        }
        if let provisioning = writes.provisioning {
            try persistence.write(provisioning)
        }
    }

    private static func requireRecoveryAuthorization(
        _ authorization: MailboxKeyRecoveryAuthorization
    ) throws {
        guard authorization.receiverActivationIsUnpaired else {
            throw MailboxKeyRecoveryError.receiverActivationNotUnpaired
        }
        guard !authorization.pendingPairingExists,
              !authorization.terminalTransitionIsPending else {
            throw MailboxKeyRecoveryError.pairingOrTerminalTransitionPending
        }
        guard let pendingOutboxCount = authorization.pendingOutboxCount else {
            throw MailboxKeyRecoveryError.outboxStatusUnavailable
        }
        guard pendingOutboxCount == 0 else {
            throw MailboxKeyRecoveryError.outboxNotEmpty
        }
        guard !authorization.operationIsActive else {
            throw MailboxKeyRecoveryError.operationActive
        }
    }
}
