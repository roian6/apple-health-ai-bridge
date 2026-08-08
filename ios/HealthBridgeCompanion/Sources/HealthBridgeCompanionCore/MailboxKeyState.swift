import CryptoKit
import Foundation

struct StoredMailboxKeys: Codable, Equatable {
    let agreementPrivateKey: String
    let continuity: MailboxKeyContinuityRecord?
    let generation: Int
    let signingPrivateKey: String
    let state: MailboxKeyLifecycleState
    let v: Int

    enum CodingKeys: String, CodingKey {
        case agreementPrivateKey = "agreement_private_key"
        case continuity
        case generation
        case signingPrivateKey = "signing_private_key"
        case state
        case v
    }
}

struct ExpectedIdentityAnchor: Codable, Equatable {
    let agreementKeyID: String
    let agreementPublicKey: String
    let continuity: MailboxKeyContinuityRecord?
    let domain: String
    let generation: Int
    let signingKeyID: String
    let signingPublicKey: String
    let state: MailboxKeyLifecycleState
    let v: Int

    enum CodingKeys: String, CodingKey {
        case agreementKeyID = "agreement_key_id"
        case agreementPublicKey = "agreement_public_key"
        case continuity
        case domain
        case generation
        case signingKeyID = "signing_key_id"
        case signingPublicKey = "signing_public_key"
        case state
        case v
    }
}

struct LoadedMailboxState {
    let stored: StoredMailboxKeys?
    let anchor: ExpectedIdentityAnchor?
    let provisioning: MailboxProvisioningAnchor?
}

func newStoredKeys(generation: Int = 1) -> StoredMailboxKeys {
    StoredMailboxKeys(
        agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey()
            .rawRepresentation.base64URLEncodedString(),
        continuity: nil,
        generation: generation,
        signingPrivateKey: Curve25519.Signing.PrivateKey()
            .rawRepresentation.base64URLEncodedString(),
        state: .active,
        v: 1
    )
}

func publicIdentity(_ stored: StoredMailboxKeys) throws -> MailboxPublicIdentity {
    guard let signing = Data(strictBase64URL: stored.signingPrivateKey, count: 32),
          let agreement = Data(strictBase64URL: stored.agreementPrivateKey, count: 32)
    else {
        throw MailboxKeyStoreError.malformedState
    }
    do {
        return try MailboxPublicIdentity(
            signingPrivateKey: signing,
            agreementPrivateKey: agreement
        )
    } catch {
        throw MailboxKeyStoreError.malformedState
    }
}

func publicIdentity(_ anchor: ExpectedIdentityAnchor) throws -> MailboxPublicIdentity {
    guard let signing = Data(strictBase64URL: anchor.signingPublicKey, count: 32),
          let agreement = Data(strictBase64URL: anchor.agreementPublicKey, count: 32),
          anchor.signingKeyID == mailboxKeyIdentifier(
              algorithm: "ed25519", publicKey: signing
          ),
          anchor.agreementKeyID == mailboxKeyIdentifier(
              algorithm: "x25519", publicKey: agreement
          )
    else {
        throw MailboxKeyStoreError.malformedState
    }
    return MailboxPublicIdentity(
        signingPublicKey: signing,
        agreementPublicKey: agreement,
        signingKeyID: anchor.signingKeyID,
        agreementKeyID: anchor.agreementKeyID
    )
}

func requireActive(_ stored: StoredMailboxKeys) throws {
    switch stored.state {
    case .active:
        return
    case .revoked:
        throw MailboxKeyStoreError.keysRevoked
    case .lost, .notInitialized:
        throw MailboxKeyStoreError.malformedState
    }
}

func lifecycleSummary(
    _ stored: StoredMailboxKeys
) throws -> MailboxKeyLifecycleSummary {
    let identity = try publicIdentity(stored)
    return MailboxKeyLifecycleSummary(
        state: stored.state,
        signingKeyID: identity.signingKeyID,
        agreementKeyID: identity.agreementKeyID
    )
}

func strictDecode<Value: Codable>(_ data: Data) throws -> Value {
    guard data.count <= MailboxKeyConstants.maximumStateBytes else {
        throw MailboxKeyStoreError.malformedState
    }
    do {
        let decoded = try JSONDecoder().decode(Value.self, from: data)
        guard try mailboxCanonicalJSON(decoded) == data else {
            throw MailboxKeyStoreError.malformedState
        }
        return decoded
    } catch let error as MailboxKeyStoreError {
        throw error
    } catch {
        throw MailboxKeyStoreError.malformedState
    }
}

func validate(_ stored: StoredMailboxKeys) throws {
    guard stored.v == 1,
          stored.generation >= 1,
          stored.state == .active || stored.state == .revoked else {
        throw MailboxKeyStoreError.malformedState
    }
    _ = try publicIdentity(stored)
    if let continuity = stored.continuity {
        try verifyMailboxKeyContinuity(continuity)
    }
}

func validate(_ anchor: ExpectedIdentityAnchor) throws {
    guard anchor.v == 1,
          anchor.domain == MailboxKeyConstants.anchorDomain,
          anchor.generation >= 1,
          anchor.state == .active || anchor.state == .revoked
    else {
        throw MailboxKeyStoreError.malformedState
    }
    _ = try publicIdentity(anchor)
    if let continuity = anchor.continuity {
        try verifyMailboxKeyContinuity(continuity)
    }
}

func anchorFor(_ stored: StoredMailboxKeys) throws -> ExpectedIdentityAnchor {
    let identity = try publicIdentity(stored)
    return ExpectedIdentityAnchor(
        agreementKeyID: identity.agreementKeyID,
        agreementPublicKey: identity.agreementPublicKey.base64URLEncodedString(),
        continuity: stored.continuity,
        domain: MailboxKeyConstants.anchorDomain,
        generation: stored.generation,
        signingKeyID: identity.signingKeyID,
        signingPublicKey: identity.signingPublicKey.base64URLEncodedString(),
        state: stored.state,
        v: 1
    )
}

func signedContinuity(
    stored: StoredMailboxKeys,
    oldIdentity: MailboxPublicIdentity,
    newIdentity: MailboxPublicIdentity
) throws -> MailboxKeyContinuityRecord {
    let unsigned = MailboxKeyContinuityRecord(
        agreementNewPublicKey: newIdentity.agreementPublicKey.base64URLEncodedString(),
        agreementOldPublicKey: oldIdentity.agreementPublicKey.base64URLEncodedString(),
        domain: MailboxKeyConstants.continuityDomain,
        newAgreementKeyID: newIdentity.agreementKeyID,
        newSigningKeyID: newIdentity.signingKeyID,
        oldAgreementKeyID: oldIdentity.agreementKeyID,
        oldSigningKeyID: oldIdentity.signingKeyID,
        rotatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
        signature: Data(repeating: 0, count: 64).base64URLEncodedString(),
        signingNewPublicKey: newIdentity.signingPublicKey.base64URLEncodedString(),
        signingOldPublicKey: oldIdentity.signingPublicKey.base64URLEncodedString(),
        v: 1
    )
    guard let raw = Data(strictBase64URL: stored.signingPrivateKey, count: 32) else {
        throw MailboxKeyStoreError.malformedState
    }
    let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    let signature = try signingKey.signature(for: unsigned.signaturePreimage())
    let record = MailboxKeyContinuityRecord(
        agreementNewPublicKey: unsigned.agreementNewPublicKey,
        agreementOldPublicKey: unsigned.agreementOldPublicKey,
        domain: unsigned.domain,
        newAgreementKeyID: unsigned.newAgreementKeyID,
        newSigningKeyID: unsigned.newSigningKeyID,
        oldAgreementKeyID: unsigned.oldAgreementKeyID,
        oldSigningKeyID: unsigned.oldSigningKeyID,
        rotatedAtMilliseconds: unsigned.rotatedAtMilliseconds,
        signature: signature.base64URLEncodedString(),
        signingNewPublicKey: unsigned.signingNewPublicKey,
        signingOldPublicKey: unsigned.signingOldPublicKey,
        v: unsigned.v
    )
    try verifyMailboxKeyContinuity(record)
    return record
}

func continuityMatches(
    _ record: MailboxKeyContinuityRecord,
    old: MailboxPublicIdentity,
    new: MailboxPublicIdentity
) -> Bool {
    record.oldSigningKeyID == old.signingKeyID
        && record.oldAgreementKeyID == old.agreementKeyID
        && record.newSigningKeyID == new.signingKeyID
        && record.newAgreementKeyID == new.agreementKeyID
        && record.signingOldPublicKey == old.signingPublicKey.base64URLEncodedString()
        && record.agreementOldPublicKey == old.agreementPublicKey.base64URLEncodedString()
        && record.signingNewPublicKey == new.signingPublicKey.base64URLEncodedString()
        && record.agreementNewPublicKey == new.agreementPublicKey.base64URLEncodedString()
}
