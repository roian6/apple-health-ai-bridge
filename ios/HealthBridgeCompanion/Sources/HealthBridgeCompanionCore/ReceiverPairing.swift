import Foundation
import CryptoKit

public struct MailboxBootstrapDescriptor: Codable, Equatable, Sendable {
    public let version: Int
    public let invitationID: String
    public let receiverSigningPublicKey: String
    public let receiverAgreementPublicKey: String

    enum CodingKeys: String, CodingKey {
        case version
        case invitationID = "invitation_id"
        case receiverSigningPublicKey = "receiver_signing_public_key"
        case receiverAgreementPublicKey = "receiver_agreement_public_key"
    }

    func validate() throws {
        guard version == 1, let id = Data(hexV1: invitationID), id.count == 16,
              id.hexV1 == invitationID,
              Data(strictBase64URL: receiverSigningPublicKey, count: 32) != nil,
              Data(strictBase64URL: receiverAgreementPublicKey, count: 32) != nil else {
            throw ReceiverPairingBundleError.unsupportedTransport
        }
    }
}

enum NativeMailboxPairing {
    static let domain = Data("health-bridge/mailbox-pairing/v1/".utf8)

    static func seal(_ pending: ReceiverPendingPairing, keys: MailboxKeyStore) throws -> Data {
        guard let bootstrap = pending.mailboxBootstrap, let secret = pending.invitationSecret,
              let invitationID = Data(hexV1: bootstrap.invitationID) else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        try bootstrap.validate()
        let identity = try keys.loadOrCreate()
        let plaintext = try DeliveryProtocolV1.encodeMetadata(.object([
            "invitation_secret": .string(secret), "installation_id": .string(pending.installationID),
            "device_credential": .string(pending.deviceCredential), "platform": .string(pending.platform),
            "device_signing_public_key": .string(identity.signingPublicKey.base64URLEncodedString()),
            "device_agreement_public_key": .string(identity.agreementPublicKey.base64URLEncodedString()),
        ]))
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let receiver = try Curve25519.KeyAgreement.PublicKey(rawRepresentation:
            DeliveryProtocolV1.unb64(bootstrap.receiverAgreementPublicKey, length: 32))
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: receiver)
        let key = DeliveryProtocolV1.hkdf(shared, salt: invitationID, info: domain + Data("request/key".utf8), count: 32)
        let nonce = AES.GCM.Nonce()
        let nonceData = nonce.withUnsafeBytes { Data($0) }
        var fields: [String: HBJCS1Value] = [
            "v": .integer(1), "kind": .string("request"), "invitation_id": .string(bootstrap.invitationID),
            "sender_signing_public_key": .string(identity.signingPublicKey.base64URLEncodedString()),
            "ephemeral_public_key": .string(ephemeral.publicKey.rawRepresentation.base64URLEncodedString()),
            "nonce": .string(nonceData.base64URLEncodedString()),
        ]
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce,
            authenticating: domain + Data("request/aad\0".utf8) + DeliveryProtocolV1.encodeMetadata(.object(fields)))
        fields["ciphertext"] = .string((box.ciphertext + box.tag).base64URLEncodedString())
        fields["signature"] = .string(try keys.sign(domain + Data("request/signature\0".utf8)
            + DeliveryProtocolV1.encodeMetadata(.object(fields))).base64URLEncodedString())
        return try DeliveryProtocolV1.encodeMetadata(.object(fields))
    }

    static func openCompletion(_ encoded: Data, pending: ReceiverPendingPairing, keys: MailboxKeyStore) throws -> ReceiverPairingCredential {
        guard let bootstrap = pending.mailboxBootstrap, let request = pending.sealedRequest,
              let invitationID = Data(hexV1: bootstrap.invitationID) else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        var fields = try DeliveryProtocolV1.object(encoded, fields: [
            "v", "kind", "invitation_id", "sender_signing_public_key", "request_sha256", "nonce", "ciphertext", "signature",
        ], limit: 65_536)
        let digest = Data(SHA256.hash(data: request))
        guard try DeliveryProtocolV1.integer(fields, "v") == 1,
              try DeliveryProtocolV1.string(fields, "kind") == "completion",
              try DeliveryProtocolV1.string(fields, "invitation_id") == bootstrap.invitationID,
              try DeliveryProtocolV1.string(fields, "request_sha256") == digest.hexV1,
              try DeliveryProtocolV1.string(fields, "sender_signing_public_key") == bootstrap.receiverSigningPublicKey else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        let signature = try DeliveryProtocolV1.unb64(DeliveryProtocolV1.string(fields, "signature"), length: 64)
        fields.removeValue(forKey: "signature")
        let signer = try Curve25519.Signing.PublicKey(rawRepresentation:
            DeliveryProtocolV1.unb64(bootstrap.receiverSigningPublicKey, length: 32))
        guard try signer.isValidSignature(signature, for: domain + Data("completion/signature\0".utf8)
            + DeliveryProtocolV1.encodeMetadata(.object(fields))) else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        let shared = try keys.sharedSecret(with: DeliveryProtocolV1.unb64(bootstrap.receiverAgreementPublicKey, length: 32))
        let salt = invitationID + digest
        let key = DeliveryProtocolV1.hkdf(shared, salt: salt, info: domain + Data("completion/key".utf8), count: 32)
        let nonce = try DeliveryProtocolV1.unb64(DeliveryProtocolV1.string(fields, "nonce"), length: 12)
        let combined = try DeliveryProtocolV1.unb64(DeliveryProtocolV1.string(fields, "ciphertext"))
        guard combined.count >= 16,
              nonce == DeliveryProtocolV1.hkdf(shared, salt: salt, info: domain + Data("completion/nonce".utf8), count: 32).prefix(12) else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        fields.removeValue(forKey: "ciphertext")
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: combined.dropLast(16), tag: combined.suffix(16))
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key),
            authenticating: domain + Data("completion/aad\0".utf8) + DeliveryProtocolV1.encodeMetadata(.object(fields)))
        let payload = try JSONDecoder().decode(PairingCompletionPayload.self, from: plaintext)
        guard payload.schemaID == ReceiverPairingCredential.supportedSchemaID,
              payload.schemaVersion == ReceiverPairingCredential.supportedSchemaVersion,
              payload.receiverURL == nil,
              payload.mailboxReceiverSigningPublicKey == bootstrap.receiverSigningPublicKey,
              payload.mailboxReceiverAgreementPublicKey == bootstrap.receiverAgreementPublicKey else {
            throw ReceiverPairingRedeemError.invalidResponse
        }
        let identity = try ReceiverClient.mailboxConnectionIdentity(payload: payload, pendingPairing: pending,
            deviceIdentity: keys.loadOrCreate(), required: true)
        return ReceiverPairingCredential(label: payload.label, receiverURLString: nil,
            bearerToken: "", tokenPrefix: "", mailboxIdentity: identity)
    }
}

public enum ReceiverPairingBundleError: Error, Equatable, LocalizedError {
    case invalidJSON
    case unsupportedSchema
    case invalidReceiverURL
    case emptyBearerToken
    case emptyInvitationSecret
    case invalidInvitationCode
    case crossOriginRedeemURL
    case unsupportedTransport
    case invalidDeepLink
    case missingPayload

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Pairing data is invalid."
        case .unsupportedSchema:
            return "Pairing data schema is not supported."
        case .invalidReceiverURL:
            return "Pairing server URL must use http or https and include a host."
        case .emptyBearerToken:
            return "Legacy pairing bearer token is empty."
        case .emptyInvitationSecret:
            return "Pairing invitation is empty."
        case .invalidInvitationCode:
            return "Invitation code must contain fifteen valid letters or numbers."
        case .crossOriginRedeemURL:
            return "Pairing redeem URL must use the same server as the receiver URL."
        case .unsupportedTransport:
            return "Pairing transport selection is not supported."
        case .invalidDeepLink:
            return "Pairing link is not a supported Health Bridge link."
        case .missingPayload:
            return "Pairing link is missing its payload."
        }
    }
}

public enum ReceiverPairingTransport: String, Codable, Equatable, Sendable {
    case direct
    case mailbox
}

public struct ReceiverPairingBundle: Equatable, Sendable {
    public static let supportedSchemaID = "health_bridge.receiver_pairing.v1"
    public static let supportedSchemaVersion = "1.0.0"

    public let schemaID: String
    public let schemaVersion: String
    public let label: String
    public let receiverURLString: String
    public let bearerToken: String
    public let tokenPrefix: String
    public let createdAt: String
    public let warning: String

    public var receiverURL: URL? {
        URL(string: receiverURLString)
    }

    public init(jsonData: Data) throws {
        let payload: LegacyPairingPayload
        do {
            payload = try JSONDecoder().decode(LegacyPairingPayload.self, from: jsonData)
        } catch {
            throw ReceiverPairingBundleError.invalidJSON
        }
        try Self.validate(payload)
        self.schemaID = payload.schemaID
        self.schemaVersion = payload.schemaVersion
        self.label = payload.label
        self.receiverURLString = payload.receiverURL
        self.bearerToken = payload.bearerToken
        self.tokenPrefix = payload.tokenPrefix
        self.createdAt = payload.createdAt
        self.warning = payload.warning
    }

    public init(deepLink: URL) throws {
        try self.init(jsonData: PairingLinkDecoder.payloadData(from: deepLink))
    }

    public static func decode(_ string: String) throws -> ReceiverPairingBundle {
        if let url = PairingLinkDecoder.pairingURL(from: string) {
            return try ReceiverPairingBundle(deepLink: url)
        }
        return try ReceiverPairingBundle(jsonData: Data(string.utf8))
    }

    private static func validate(_ payload: LegacyPairingPayload) throws {
        guard payload.schemaID == supportedSchemaID,
              payload.schemaVersion == supportedSchemaVersion
        else {
            throw ReceiverPairingBundleError.unsupportedSchema
        }
        _ = try validatedHTTPURL(payload.receiverURL)
        guard !payload.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReceiverPairingBundleError.emptyBearerToken
        }
    }
}

public struct ReceiverPairingInvitation: Equatable, Sendable {
    public static let supportedSchemaID = "health_bridge.receiver_pairing_invitation.v2"
    public static let supportedSchemaVersion = "2.0.0"

    public let schemaID: String
    public let schemaVersion: String
    public let label: String
    public let receiverURLString: String?
    public let redeemURLString: String?
    public let invitationSecret: String
    public let expiresAt: String
    public let transport: ReceiverPairingTransport
    public let mailboxBootstrap: MailboxBootstrapDescriptor?
    public let mailboxProtocolVersion: Int?
    public let receiverURL: URL?
    public let redeemURL: URL?

    public init(jsonData: Data) throws {
        let payload: InvitationPairingPayload
        do {
            payload = try JSONDecoder().decode(InvitationPairingPayload.self, from: jsonData)
        } catch {
            throw ReceiverPairingBundleError.invalidJSON
        }
        guard payload.schemaID == Self.supportedSchemaID,
              payload.schemaVersion == Self.supportedSchemaVersion else {
            throw ReceiverPairingBundleError.unsupportedSchema
        }
        let transport: ReceiverPairingTransport
        switch (payload.transport, payload.mailboxProtocolVersion) {
        case (.some(.direct), nil), (nil, nil):
            transport = .direct
        case (.some(.mailbox), 1):
            transport = .mailbox
        default:
            throw ReceiverPairingBundleError.unsupportedTransport
        }
        let receiverURL: URL?
        let redeemURL: URL?
        if let bootstrap = payload.mailboxBootstrap {
            guard transport == .mailbox, payload.receiverURL == nil, payload.redeemURL == nil else {
                throw ReceiverPairingBundleError.unsupportedTransport
            }
            try bootstrap.validate()
            receiverURL = nil
            redeemURL = nil
        } else {
            let receiver = try validatedHTTPURL(payload.receiverURL ?? "")
            let redeem = try validatedHTTPURL(payload.redeemURL ?? "")
            guard urlOrigin(receiver) == urlOrigin(redeem) else {
                throw ReceiverPairingBundleError.crossOriginRedeemURL
            }
            receiverURL = receiver
            redeemURL = redeem
        }
        guard !payload.invitationSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReceiverPairingBundleError.emptyInvitationSecret
        }
        self.schemaID = payload.schemaID
        self.schemaVersion = payload.schemaVersion
        self.label = payload.label
        self.receiverURLString = payload.receiverURL
        self.redeemURLString = payload.redeemURL
        self.invitationSecret = payload.invitationSecret
        self.expiresAt = payload.expiresAt
        self.transport = transport
        self.mailboxBootstrap = payload.mailboxBootstrap
        self.mailboxProtocolVersion = payload.mailboxProtocolVersion
        self.receiverURL = receiverURL
        self.redeemURL = redeemURL
    }

    public init(deepLink: URL) throws {
        try self.init(jsonData: PairingLinkDecoder.payloadData(from: deepLink))
    }
}

public enum ReceiverPairingMaterial: Equatable, Sendable {
    case legacy(ReceiverPairingBundle)
    case invitation(ReceiverPairingInvitation)

    public init(jsonData: Data) throws {
        let envelope: PairingSchemaEnvelope
        do {
            envelope = try JSONDecoder().decode(PairingSchemaEnvelope.self, from: jsonData)
        } catch {
            throw ReceiverPairingBundleError.invalidJSON
        }
        switch envelope.schemaID {
        case ReceiverPairingBundle.supportedSchemaID:
            self = .legacy(try ReceiverPairingBundle(jsonData: jsonData))
        case ReceiverPairingInvitation.supportedSchemaID:
            self = .invitation(try ReceiverPairingInvitation(jsonData: jsonData))
        default:
            throw ReceiverPairingBundleError.unsupportedSchema
        }
    }

    public init(deepLink: URL) throws {
        try self.init(jsonData: PairingLinkDecoder.payloadData(from: deepLink))
    }

    public static func decode(_ string: String) throws -> ReceiverPairingMaterial {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = PairingLinkDecoder.pairingURL(from: trimmed) {
            return try ReceiverPairingMaterial(deepLink: url)
        }
        return try ReceiverPairingMaterial(jsonData: Data(trimmed.utf8))
    }
}

public struct ReceiverManualPairing: Equatable, Sendable {
    private static let invitationAlphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    public let receiverURL: URL
    public let redeemURL: URL
    public let invitationCode: String

    public init(serverURLString: String, invitationCode: String) throws {
        let serverURL = try validatedHTTPURL(
            serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard var receiverComponents = URLComponents(
            url: serverURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw ReceiverPairingBundleError.invalidReceiverURL
        }
        if receiverComponents.path.isEmpty || receiverComponents.path == "/" {
            receiverComponents.path = "/v1/batches"
        }
        guard let receiverURL = receiverComponents.url else {
            throw ReceiverPairingBundleError.invalidReceiverURL
        }
        var redeemComponents = receiverComponents
        redeemComponents.path = "/v1/pairing/redeem"
        redeemComponents.query = nil
        redeemComponents.fragment = nil
        guard let redeemURL = redeemComponents.url else {
            throw ReceiverPairingBundleError.invalidReceiverURL
        }
        self.receiverURL = receiverURL
        self.redeemURL = redeemURL
        self.invitationCode = try Self.normalizedCode(invitationCode)
    }

    private static func normalizedCode(_ value: String) throws -> String {
        let compact = value
            .uppercased()
            .filter { !$0.isWhitespace && $0 != "-" }
        guard compact.count == 15,
              compact.allSatisfy({ invitationAlphabet.contains($0) })
        else {
            throw ReceiverPairingBundleError.invalidInvitationCode
        }
        let firstSplit = compact.index(compact.startIndex, offsetBy: 5)
        let secondSplit = compact.index(firstSplit, offsetBy: 5)
        return "\(compact[..<firstSplit])-\(compact[firstSplit..<secondSplit])-\(compact[secondSplit...])"
    }
}

private enum PairingLinkDecoder {
    static func pairingURL(from string: String) -> URL? {
        guard let url = URL(string: string), isSupportedPairingURL(url) else {
            return nil
        }
        return url
    }

    static func payloadData(from url: URL) throws -> Data {
        guard isSupportedPairingURL(url) else {
            throw ReceiverPairingBundleError.invalidDeepLink
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let payload = components.queryItems?.first(where: { $0.name == "payload" })?.value,
              !payload.isEmpty
        else {
            throw ReceiverPairingBundleError.missingPayload
        }
        guard let data = base64URLDecode(payload) else {
            throw ReceiverPairingBundleError.invalidJSON
        }
        return data
    }

    private static func isSupportedPairingURL(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "healthbridge", url.host?.lowercased() == "pair" {
            return true
        }
        return url.scheme?.lowercased() == "https" && url.host != nil && url.path == "/pair"
    }
}

private struct LegacyPairingPayload: Decodable {
    let schemaID: String
    let schemaVersion: String
    let label: String
    let receiverURL: String
    let bearerToken: String
    let tokenPrefix: String
    let createdAt: String
    let warning: String

    enum CodingKeys: String, CodingKey {
        case schemaID = "schema_id"
        case schemaVersion = "schema_version"
        case label
        case receiverURL = "receiver_url"
        case bearerToken = "bearer_token"
        case tokenPrefix = "token_prefix"
        case createdAt = "created_at"
        case warning
    }
}

private struct InvitationPairingPayload: Decodable {
    let schemaID: String
    let schemaVersion: String
    let label: String
    let receiverURL: String?
    let redeemURL: String?
    let invitationSecret: String
    let expiresAt: String
    let transport: ReceiverPairingTransport?
    let mailboxProtocolVersion: Int?
    let mailboxBootstrap: MailboxBootstrapDescriptor?

    enum CodingKeys: String, CodingKey {
        case schemaID = "schema_id"
        case schemaVersion = "schema_version"
        case label
        case receiverURL = "receiver_url"
        case redeemURL = "redeem_url"
        case invitationSecret = "invitation_secret"
        case expiresAt = "expires_at"
        case transport
        case mailboxProtocolVersion = "mailbox_protocol_version"
        case mailboxBootstrap = "mailbox_bootstrap"
    }
}

private struct PairingSchemaEnvelope: Decodable {
    let schemaID: String

    enum CodingKeys: String, CodingKey {
        case schemaID = "schema_id"
    }
}

private struct URLOrigin: Equatable {
    let scheme: String
    let host: String
    let port: Int?
}

private func validatedHTTPURL(_ string: String) throws -> URL {
    guard let url = URL(string: string),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          url.host != nil,
          url.user == nil,
          url.password == nil
    else {
        throw ReceiverPairingBundleError.invalidReceiverURL
    }
    return url
}

private func urlOrigin(_ url: URL) -> URLOrigin {
    let scheme = url.scheme?.lowercased() ?? ""
    let defaultPort = scheme == "https" ? 443 : 80
    return URLOrigin(
        scheme: scheme,
        host: url.host?.lowercased() ?? "",
        port: url.port ?? defaultPort
    )
}

private func base64URLDecode(_ value: String) -> Data? {
    var base64 = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - base64.count % 4) % 4
    if padding > 0 {
        base64 += String(repeating: "=", count: padding)
    }
    return Data(base64Encoded: base64)
}
