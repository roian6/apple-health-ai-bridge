import CryptoKit
import Foundation

public enum MailboxQAAction: String, Codable, Sendable {
    case pair
    case advance
    case scanFinalize = "scan_finalize"
    case signedReport = "signed_report"
    case cleanup
}

public enum MailboxQAFault: String, Codable, Sendable {
    case publisherENOSPC = "publisher_enospc"
}

public enum MailboxQAHarnessError: Error, Equatable, Sendable {
    case malformedPairing
    case existingPairingMismatch
    case invalidAction
    case invalidState
    case unavailable
}

public struct MailboxQAPairingCompletionV1: Codable, Equatable, Sendable {
    public let v: Int
    public let kind: String
    public let namespace: String
    public let receiverID: String
    public let deviceID: String
    public let receiverBindingID: String
    public let connectionGeneration: Int64
    public let receiverSigningPublicKey: String
    public let receiverAgreementPublicKey: String
    public let receiverSigningKeyID: String
    public let receiverAgreementKeyID: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case v, kind, namespace
        case receiverID = "receiver_id"
        case deviceID = "device_id"
        case receiverBindingID = "receiver_binding_id"
        case connectionGeneration = "connection_generation"
        case receiverSigningPublicKey = "receiver_signing_public_key"
        case receiverAgreementPublicKey = "receiver_agreement_public_key"
        case receiverSigningKeyID = "receiver_signing_key_id"
        case receiverAgreementKeyID = "receiver_agreement_key_id"
    }

    public static func strictDecode(
        _ data: Data,
        namespace: String,
        runID: String
    ) throws -> Self {
        guard let fields = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
              Set(fields.keys) == Set(CodingKeys.allCases.map(\.rawValue))
        else {
            throw MailboxQAHarnessError.malformedPairing
        }
        let completion = try JSONDecoder().decode(Self.self, from: data)
        let receiverSigning = try strictBase64URL(
            completion.receiverSigningPublicKey,
            count: 32
        )
        let receiverAgreement = try strictBase64URL(
            completion.receiverAgreementPublicKey,
            count: 32
        )
        let receiverID = try strictBase64URL(completion.receiverID, count: 16)
        let deviceID = try strictBase64URL(completion.deviceID, count: 16)
        guard let runBytes = Data(hexV1: runID), runBytes.count == 16 else {
            throw MailboxQAHarnessError.malformedPairing
        }
        var bindingMaterial = Data("health-bridge/mailbox-qa/binding".utf8)
        bindingMaterial.append(0)
        bindingMaterial.append(receiverID)
        bindingMaterial.append(deviceID)
        bindingMaterial.append(runBytes)
        let expectedBinding = Data(SHA256.hash(data: bindingMaterial))
        guard completion.v == 1,
              completion.kind
              == "health_bridge.mailbox_qa_pairing_completion.v1",
              completion.namespace == namespace,
              completion.connectionGeneration > 0,
              try strictBase64URL(completion.receiverBindingID, count: 32)
              == expectedBinding,
              try DeliveryProtocolV1.keyID(
                  algorithm: "ed25519",
                  publicKey: receiverSigning
              ) == completion.receiverSigningKeyID,
              try DeliveryProtocolV1.keyID(
                  algorithm: "x25519",
                  publicKey: receiverAgreement
              ) == completion.receiverAgreementKeyID
        else {
            throw MailboxQAHarnessError.malformedPairing
        }
        return completion
    }
}

public struct MailboxQAPairingRecordV1: Codable, Equatable, Sendable {
    public let v: Int
    public let kind: String
    public let runID: String
    public let challenge: String
    public let sourceCommit: String
    public let namespace: String
    public let invitationFingerprint: String
    public let redeemEndpointFingerprint: String
    public let receiverID: Data
    public let deviceID: Data
    public let receiverBindingID: String
    public let connectionGeneration: Int64
    public let receiverSigningPublicKey: Data
    public let receiverAgreementPublicKey: Data
    public let receiverSigningKeyID: String
    public let receiverAgreementKeyID: String
    public let deviceSigningPrivateKey: Data
    public let deviceAgreementPrivateKey: Data
    public let deviceCredential: String
    public let installationID: String

    public var signingPrivateKey: Curve25519.Signing.PrivateKey {
        get throws {
            try Curve25519.Signing.PrivateKey(
                rawRepresentation: deviceSigningPrivateKey
            )
        }
    }

    public var agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey {
        get throws {
            try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: deviceAgreementPrivateKey
            )
        }
    }

    public func validate() throws {
        let signing = try signingPrivateKey
        let agreement = try agreementPrivateKey
        guard let runBytes = Data(hexV1: runID), runBytes.count == 16 else {
            throw MailboxQAHarnessError.malformedPairing
        }
        var bindingMaterial = Data("health-bridge/mailbox-qa/binding".utf8)
        bindingMaterial.append(0)
        bindingMaterial.append(receiverID)
        bindingMaterial.append(deviceID)
        bindingMaterial.append(runBytes)
        guard v == 1,
              kind == "health_bridge.mailbox_qa_pairing_record.v1",
              challenge.utf8.count == 43,
              try strictBase64URL(challenge, count: 32).count == 32,
              sourceCommit.utf8.count == 40,
              sourceCommit.utf8.allSatisfy(isLowerHex),
              namespace.hasPrefix("qa-"),
              invitationFingerprint.count == 64,
              redeemEndpointFingerprint.count == 64,
              invitationFingerprint.utf8.allSatisfy(isLowerHex),
              redeemEndpointFingerprint.utf8.allSatisfy(isLowerHex),
              receiverID.count == 16,
              deviceID.count == 16,
              connectionGeneration > 0,
              receiverSigningPublicKey.count == 32,
              receiverAgreementPublicKey.count == 32,
              try DeliveryProtocolV1.keyID(
                  algorithm: "ed25519",
                  publicKey: receiverSigningPublicKey
              ) == receiverSigningKeyID,
              try DeliveryProtocolV1.keyID(
                  algorithm: "x25519",
                  publicKey: receiverAgreementPublicKey
              ) == receiverAgreementKeyID,
              try strictBase64URL(receiverBindingID, count: 32).count == 32,
              try strictBase64URL(receiverBindingID, count: 32)
              == Data(SHA256.hash(data: bindingMaterial)),
              signing.rawRepresentation == deviceSigningPrivateKey,
              agreement.rawRepresentation == deviceAgreementPrivateKey,
              deviceCredential.hasPrefix("hb_"),
              UUID(uuidString: installationID) != nil
        else {
            throw MailboxQAHarnessError.malformedPairing
        }
    }
}

private func isLowerHex(_ byte: UInt8) -> Bool {
    (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
}

public struct MailboxQATransitionCountsV1: Codable, Equatable, Sendable {
    public var collected = 0
    public var encrypted = 0
    public var published = 0
    public var providerObserved = 0
    public var ackVerified = 0
    public var committedFinalized = 0
    public var retryableFailure = 0
    public var terminalFailure = 0

    enum CodingKeys: String, CodingKey {
        case collected, encrypted, published
        case providerObserved = "provider_observed"
        case ackVerified = "ack_verified"
        case committedFinalized = "committed_finalized"
        case retryableFailure = "retryable_failure"
        case terminalFailure = "terminal_failure"
    }

    public mutating func observe(_ phase: OutboxDeliveryPhase) {
        switch phase {
        case .collected: collected += 1
        case .encrypted: encrypted += 1
        case .published: published += 1
        case .providerObserved: providerObserved += 1
        case .ackVerified: ackVerified += 1
        case .committedFinalized: committedFinalized += 1
        case .retryableFailure: retryableFailure += 1
        case .terminalFailure: terminalFailure += 1
        }
    }
}

public struct MailboxQADurableStateV1: Codable, Equatable, Sendable {
    public let v: Int
    public let kind: String
    public let runID: String
    public let challenge: String
    public let sourceCommit: String
    public var itemID: String?
    public var lastPhase: OutboxDeliveryPhase?
    public var envelopeSHA256: String?
    public var envelopeReuseCount: Int
    public var lifecycleEpoch: Int
    public var restartEpoch: Int
    public var finalizationCount: Int
    public var faultInjectionCount: Int
    public var foregroundObservationCount: Int
    public var backgroundObservationCount: Int
    public var protectedDataAvailableCount: Int
    public var protectedDataUnavailableCount: Int
    public var transitions: MailboxQATransitionCountsV1
}

public func strictBase64URL(_ value: String, count: Int) throws -> Data {
    guard !value.isEmpty,
          value.utf8.allSatisfy({
              (48 ... 57).contains($0)
                  || (65 ... 90).contains($0)
                  || (97 ... 122).contains($0)
                  || $0 == 45
                  || $0 == 95
          })
    else {
        throw MailboxQAHarnessError.malformedPairing
    }
    let standard = value.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padding = String(repeating: "=", count: (4 - standard.count % 4) % 4)
    guard let decoded = Data(base64Encoded: standard + padding),
          decoded.count == count,
          decoded.base64URLEncodedString() == value
    else {
        throw MailboxQAHarnessError.malformedPairing
    }
    return decoded
}
