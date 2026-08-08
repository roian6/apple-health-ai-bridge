import CryptoKit
import Foundation

public enum DeliveryProtocolV1Error: String, Error, Equatable, Sendable {
    case authenticationFailed = "authentication_failed"
    case payloadInvalid = "payload_invalid"
    case payloadOversize = "payload_oversize"
}

public indirect enum HBJCS1Value: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case bool(Bool)
    case null
    case array([HBJCS1Value])
    case object([String: HBJCS1Value])
}

public enum DeliveryProtocolV1 {
    static let contentType = "application/vnd.health-bridge.batch-v1+json"
    static let maxEnvelopeBytes = 2_097_152
    static let maxPayloadBytes = 1_048_576
    static let maxAckBytes = 65_536
    static let maxMetadataDepth = 128
    static let maxMetadataNodes = maxEnvelopeBytes

    static let deliverySalt = Data("health-bridge/mailbox/v1/delivery/salt".utf8)
    static let deliveryKey = Data("health-bridge/mailbox/v1/delivery/key".utf8)
    static let deliveryAAD = Data("health-bridge/mailbox/v1/delivery/aad".utf8)
    static let deliverySignature = Data("health-bridge/mailbox/v1/delivery/signature".utf8)
    static let ackID = Data("health-bridge/mailbox/v1/ack/id".utf8)
    static let ackSalt = Data("health-bridge/mailbox/v1/ack/salt".utf8)
    static let ackKey = Data("health-bridge/mailbox/v1/ack/key".utf8)
    static let ackNonce = Data("health-bridge/mailbox/v1/ack/nonce".utf8)
    static let ackAAD = Data("health-bridge/mailbox/v1/ack/aad".utf8)
    static let ackSignature = Data("health-bridge/mailbox/v1/ack/signature".utf8)
    static let nul = Data([0])

    public static func keyID(algorithm: String, publicKey: Data) throws -> String {
        guard ["ed25519", "x25519"].contains(algorithm), publicKey.count == 32 else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        return Data(SHA256.hash(data: Data(algorithm.utf8) + nul + publicKey))
            .prefixDataV1(16).hexV1
    }

    static func requireID(_ value: String) throws -> Data {
        guard isLowercaseHex(value, count: 32),
              let decoded = Data(hexV1: value), decoded.count == 16 else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        return decoded
    }

    static func b64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func unb64(_ value: String, length: Int? = nil) throws -> Data {
        guard value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              !value.contains("=") else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        let translated = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = translated + String(repeating: "=", count: (4 - translated.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded), b64(decoded) == value,
              length == nil || decoded.count == length else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        return decoded
    }

    static func salt(_ domain: Data, receiverID: Data, deviceID: Data) -> Data {
        Data(SHA256.hash(data: domain + nul + receiverID + deviceID))
    }

    static func hkdf(_ secret: SharedSecret, salt: Data, info: Data, count: Int) -> Data {
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: count
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func signaturePreimage(_ domain: Data, _ fields: [String: HBJCS1Value]) throws -> Data {
        domain + nul + (try encodeMetadata(.object(fields)))
    }

    static func string(_ fields: [String: HBJCS1Value], _ name: String) throws -> String {
        guard case let .string(value) = fields[name] else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        return value
    }

    static func integer(_ fields: [String: HBJCS1Value], _ name: String) throws -> Int64 {
        guard case let .integer(value) = fields[name] else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        return value
    }

    static func object(_ encoded: Data, fields expected: Set<String>, limit: Int) throws -> [String: HBJCS1Value] {
        guard encoded.count <= limit, case let .object(value) = try decodeMetadata(encoded),
              Set(value.keys) == expected else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        return value
    }

    public static func replacingMetadataString(_ encoded: Data, field: String, value: String) throws -> Data {
        guard case var .object(fields) = try decodeMetadata(encoded), fields[field] != nil else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        fields[field] = .string(value)
        return try encodeMetadata(.object(fields))
    }

    static func unsignedMetadata(_ encoded: Data) throws -> Data {
        guard case var .object(fields) = try decodeMetadata(encoded),
              fields.removeValue(forKey: "signature") != nil else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        return try encodeMetadata(.object(fields))
    }

    static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        let bytes = value.utf8
        return bytes.count == count && bytes.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }
}

extension Data {
    init?(hexV1: String) {
        guard hexV1.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: hexV1.count / 2)
        var index = hexV1.startIndex
        while index < hexV1.endIndex {
            let next = hexV1.index(index, offsetBy: 2)
            guard let byte = UInt8(hexV1[index ..< next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }

    var hexV1: String { map { String(format: "%02x", $0) }.joined() }
    func prefixDataV1(_ count: Int) -> Data { Data(prefix(count)) }
}
