import CryptoKit
import Foundation

public enum MailboxKeyLifecycleState: String, Codable, Equatable, Sendable {
    case notInitialized = "not_initialized"
    case active
    case lost
    case revoked
}

public enum MailboxKeyDiagnosticState: String, Codable, CaseIterable, Equatable, Sendable {
    case notInitialized = "not_initialized"
    case active
    case revoked
    case lost
    case malformed
    case rollbackDetected = "rollback_detected"
    case locked
    case accessDenied = "access_denied"
    case unavailable
}

public enum MailboxKeyLifecyclePresentation {
    public static func label(_ state: MailboxKeyDiagnosticState) -> String {
        switch state {
        case .notInitialized: "Not initialized"
        case .active: "Active"
        case .revoked: "Revoked"
        case .lost: "Lost"
        case .malformed: "Malformed"
        case .rollbackDetected: "Rollback detected"
        case .locked: "Locked"
        case .accessDenied: "Access denied"
        case .unavailable: "Unavailable"
        }
    }

    public static func detail(_ state: MailboxKeyDiagnosticState) -> String {
        switch state {
        case .notInitialized:
            "No mailbox connection key has been initialized on this iPhone."
        case .active:
            "Mailbox connection key material is active on this iPhone."
        case .revoked:
            "Mailbox connection key material is revoked and will not be replaced automatically."
        case .lost:
            "Mailbox connection key material is unreadable or incomplete and will not be replaced automatically."
        case .malformed:
            "Mailbox connection key state failed strict validation."
        case .rollbackDetected:
            "Mailbox connection key rollback protection blocked the stored state."
        case .locked:
            "Mailbox connection key state is unavailable while this iPhone is locked."
        case .accessDenied:
            "Mailbox connection key access was denied."
        case .unavailable:
            "Mailbox connection key storage is unavailable."
        }
    }
}

public enum MailboxKeyBackupPolicy: String, Equatable, Sendable {
    case thisDeviceOnlyNoBackup = "this_device_only_no_backup"
}

public struct MailboxPublicIdentity: Equatable, Sendable {
    public let signingPublicKey: Data
    public let agreementPublicKey: Data
    public let signingKeyID: String
    public let agreementKeyID: String

    init(signingPrivateKey: Data, agreementPrivateKey: Data) throws {
        let signing = try Curve25519.Signing.PrivateKey(
            rawRepresentation: signingPrivateKey
        ).publicKey.rawRepresentation
        let agreement = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: agreementPrivateKey
        ).publicKey.rawRepresentation
        self.signingPublicKey = signing
        self.agreementPublicKey = agreement
        self.signingKeyID = mailboxKeyIdentifier(
            algorithm: "ed25519",
            publicKey: signing
        )
        self.agreementKeyID = mailboxKeyIdentifier(
            algorithm: "x25519",
            publicKey: agreement
        )
    }

    init(
        signingPublicKey: Data,
        agreementPublicKey: Data,
        signingKeyID: String,
        agreementKeyID: String
    ) {
        self.signingPublicKey = signingPublicKey
        self.agreementPublicKey = agreementPublicKey
        self.signingKeyID = signingKeyID
        self.agreementKeyID = agreementKeyID
    }
}

public struct MailboxKeyContinuityRecord: Codable, Equatable, Sendable {
    public let agreementNewPublicKey: String
    public let agreementOldPublicKey: String
    public let domain: String
    public let newAgreementKeyID: String
    public let newSigningKeyID: String
    public let oldAgreementKeyID: String
    public let oldSigningKeyID: String
    public let rotatedAtMilliseconds: Int64
    public let signature: String
    public let signingNewPublicKey: String
    public let signingOldPublicKey: String
    public let v: Int

    enum CodingKeys: String, CodingKey {
        case agreementNewPublicKey = "agreement_new_public_key"
        case agreementOldPublicKey = "agreement_old_public_key"
        case domain
        case newAgreementKeyID = "new_agreement_key_id"
        case newSigningKeyID = "new_signing_key_id"
        case oldAgreementKeyID = "old_agreement_key_id"
        case oldSigningKeyID = "old_signing_key_id"
        case rotatedAtMilliseconds = "rotated_at_ms"
        case signature
        case signingNewPublicKey = "signing_new_public_key"
        case signingOldPublicKey = "signing_old_public_key"
        case v
    }

    public func canonicalData() throws -> Data {
        try mailboxCanonicalJSON(self)
    }

    public func replacingNewAgreementKeyID(_ value: String) -> Self {
        Self(
            agreementNewPublicKey: agreementNewPublicKey,
            agreementOldPublicKey: agreementOldPublicKey,
            domain: domain,
            newAgreementKeyID: value,
            newSigningKeyID: newSigningKeyID,
            oldAgreementKeyID: oldAgreementKeyID,
            oldSigningKeyID: oldSigningKeyID,
            rotatedAtMilliseconds: rotatedAtMilliseconds,
            signature: signature,
            signingNewPublicKey: signingNewPublicKey,
            signingOldPublicKey: signingOldPublicKey,
            v: v
        )
    }

    func signaturePreimage() throws -> Data {
        let unsigned = MailboxUnsignedContinuity(
            agreementNewPublicKey: agreementNewPublicKey,
            agreementOldPublicKey: agreementOldPublicKey,
            domain: domain,
            newAgreementKeyID: newAgreementKeyID,
            newSigningKeyID: newSigningKeyID,
            oldAgreementKeyID: oldAgreementKeyID,
            oldSigningKeyID: oldSigningKeyID,
            rotatedAtMilliseconds: rotatedAtMilliseconds,
            signingNewPublicKey: signingNewPublicKey,
            signingOldPublicKey: signingOldPublicKey,
            v: v
        )
        var result = Data(MailboxKeyConstants.continuityDomain.utf8)
        result.append(0)
        result.append(try mailboxCanonicalJSON(unsigned))
        return result
    }
}

public struct MailboxKeyRotation: Equatable, Sendable {
    public let identity: MailboxPublicIdentity
    public let continuity: MailboxKeyContinuityRecord
}

struct MailboxUnsignedContinuity: Codable {
    let agreementNewPublicKey: String
    let agreementOldPublicKey: String
    let domain: String
    let newAgreementKeyID: String
    let newSigningKeyID: String
    let oldAgreementKeyID: String
    let oldSigningKeyID: String
    let rotatedAtMilliseconds: Int64
    let signingNewPublicKey: String
    let signingOldPublicKey: String
    let v: Int

    enum CodingKeys: String, CodingKey {
        case agreementNewPublicKey = "agreement_new_public_key"
        case agreementOldPublicKey = "agreement_old_public_key"
        case domain
        case newAgreementKeyID = "new_agreement_key_id"
        case newSigningKeyID = "new_signing_key_id"
        case oldAgreementKeyID = "old_agreement_key_id"
        case oldSigningKeyID = "old_signing_key_id"
        case rotatedAtMilliseconds = "rotated_at_ms"
        case signingNewPublicKey = "signing_new_public_key"
        case signingOldPublicKey = "signing_old_public_key"
        case v
    }
}

enum MailboxKeyConstants {
    static let continuityDomain = "health-bridge/mailbox/key-continuity/v1"
    static let anchorDomain = "health-bridge/mailbox/expected-identity/v1"
    static let provisioningDomain = "health-bridge/mailbox/provisioning-anchor/v1"
    static let maximumStateBytes = 4_096
}

func verifyMailboxKeyContinuity(_ record: MailboxKeyContinuityRecord) throws {
    guard record.v == 1,
          record.domain == MailboxKeyConstants.continuityDomain,
          record.rotatedAtMilliseconds >= 0,
          let oldSigning = Data(strictBase64URL: record.signingOldPublicKey, count: 32),
          let oldAgreement = Data(strictBase64URL: record.agreementOldPublicKey, count: 32),
          let newSigning = Data(strictBase64URL: record.signingNewPublicKey, count: 32),
          let newAgreement = Data(strictBase64URL: record.agreementNewPublicKey, count: 32),
          let signature = Data(strictBase64URL: record.signature, count: 64),
          record.oldSigningKeyID == mailboxKeyIdentifier(
              algorithm: "ed25519", publicKey: oldSigning
          ),
          record.oldAgreementKeyID == mailboxKeyIdentifier(
              algorithm: "x25519", publicKey: oldAgreement
          ),
          record.newSigningKeyID == mailboxKeyIdentifier(
              algorithm: "ed25519", publicKey: newSigning
          ),
          record.newAgreementKeyID == mailboxKeyIdentifier(
              algorithm: "x25519", publicKey: newAgreement
          )
    else {
        throw MailboxKeyStoreError.malformedState
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: oldSigning)
    guard publicKey.isValidSignature(signature, for: try record.signaturePreimage()) else {
        throw MailboxKeyStoreError.malformedState
    }
}

func mailboxCanonicalJSON<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

extension Data {
    init?(strictBase64URL value: String, count: Int) {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({
                  (65 ... 90).contains($0.value)
                      || (97 ... 122).contains($0.value)
                      || (48 ... 57).contains($0.value)
                      || $0 == "-"
                      || $0 == "_"
              })
        else {
            return nil
        }
        let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let decoded = Data(base64Encoded: standard),
              decoded.count == count,
              decoded.base64URLEncodedString() == value
        else {
            return nil
        }
        self = decoded
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct MailboxKeyLifecycleSummary: Codable, Equatable, Sendable {
    public let state: MailboxKeyLifecycleState
    public let signingKeyID: String?
    public let agreementKeyID: String?

    init(
        state: MailboxKeyLifecycleState,
        signingKeyID: String? = nil,
        agreementKeyID: String? = nil
    ) {
        self.state = state
        self.signingKeyID = signingKeyID
        self.agreementKeyID = agreementKeyID
    }

    enum CodingKeys: String, CodingKey {
        case state
        case signingKeyID = "signing_key_id"
        case agreementKeyID = "agreement_key_id"
    }
}

func mailboxKeyIdentifier(algorithm: String, publicKey: Data) -> String {
    var preimage = Data(algorithm.utf8)
    preimage.append(0)
    preimage.append(publicKey)
    return SHA256.hash(data: preimage).prefix(16).map {
        String(format: "%02x", $0)
    }.joined()
}
