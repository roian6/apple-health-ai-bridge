import Foundation

extension DeliveryProtocolV1 {
    public static func encodeMetadata(_ value: HBJCS1Value) throws -> Data {
        var nodes = 0
        return try encodeMetadata(value, depth: 0, nodes: &nodes)
    }

    private static func encodeMetadata(
        _ value: HBJCS1Value,
        depth: Int,
        nodes: inout Int
    ) throws -> Data {
        guard depth <= maxMetadataDepth, nodes < maxMetadataNodes else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        nodes += 1
        switch value {
        case let .string(string):
            return encodeString(string)
        case let .integer(integer):
            return Data(String(integer).utf8)
        case let .bool(boolean):
            return Data((boolean ? "true" : "false").utf8)
        case .null:
            return Data("null".utf8)
        case let .array(values):
            return try Data("[".utf8) + values.enumerated().reduce(into: Data()) { output, pair in
                if pair.offset > 0 { output.append(UInt8(ascii: ",")) }
                output += try encodeMetadata(pair.element, depth: depth + 1, nodes: &nodes)
            } + Data("]".utf8)
        case let .object(fields):
            for key in fields.keys where !validKey(key) {
                throw DeliveryProtocolV1Error.authenticationFailed
            }
            let keys = fields.keys.sorted { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }
            return try Data("{".utf8) + keys.enumerated().reduce(into: Data()) { output, pair in
                if pair.offset > 0 { output.append(UInt8(ascii: ",")) }
                output += encodeString(pair.element) + Data(":".utf8)
                guard let field = fields[pair.element] else {
                    throw DeliveryProtocolV1Error.authenticationFailed
                }
                output += try encodeMetadata(field, depth: depth + 1, nodes: &nodes)
            } + Data("}".utf8)
        }
    }

    public static func decodeMetadata(_ encoded: Data) throws -> HBJCS1Value {
        guard encoded.count <= maxEnvelopeBytes else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        var parser = HBJCS1Parser(
            bytes: Array(encoded),
            maxDepth: maxMetadataDepth,
            maxNodes: maxMetadataNodes
        )
        let value = try parser.parse()
        guard try encodeMetadata(value) == encoded else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        return value
    }

    private static func validKey(_ value: String) -> Bool {
        guard let first = value.utf8.first, (97 ... 122).contains(first) else { return false }
        return value.utf8.allSatisfy { (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 95 }
    }

    private static func encodeString(_ value: String) -> Data {
        var result = Data([UInt8(ascii: "\"")])
        for byte in value.utf8 {
            switch byte {
            case 0x22:
                result += Data("\\\"".utf8)
            case 0x5c:
                result += Data("\\\\".utf8)
            case 0 ..< 0x20:
                result += Data(String(format: "\\u00%02x", byte).utf8)
            default:
                result.append(byte)
            }
        }
        result.append(UInt8(ascii: "\""))
        return result
    }
}

private struct HBJCS1Parser {
    let bytes: [UInt8]
    let maxDepth: Int
    let maxNodes: Int
    var index = 0
    var nodes = 0

    mutating func parse() throws -> HBJCS1Value {
        let value = try parseValue(depth: 0)
        guard index == bytes.count else { throw DeliveryProtocolV1Error.authenticationFailed }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> HBJCS1Value {
        guard depth <= maxDepth, nodes < maxNodes, index < bytes.count else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        nodes += 1
        switch bytes[index] {
        case UInt8(ascii: "\""):
            return .string(try parseString())
        case UInt8(ascii: "{"):
            return try parseObject(depth: depth)
        case UInt8(ascii: "["):
            return try parseArray(depth: depth)
        case UInt8(ascii: "t"):
            try expect("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try expect("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try expect("null")
            return .null
        default:
            return .integer(try parseInteger())
        }
    }

    private mutating func parseObject(depth: Int) throws -> HBJCS1Value {
        index += 1
        var fields: [String: HBJCS1Value] = [:]
        if consume(UInt8(ascii: "}")) { return .object(fields) }
        while true {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw DeliveryProtocolV1Error.authenticationFailed
            }
            let key = try parseString()
            guard fields[key] == nil else { throw DeliveryProtocolV1Error.authenticationFailed }
            try require(UInt8(ascii: ":"))
            fields[key] = try parseValue(depth: depth + 1)
            if consume(UInt8(ascii: "}")) { return .object(fields) }
            try require(UInt8(ascii: ","))
        }
    }

    private mutating func parseArray(depth: Int) throws -> HBJCS1Value {
        index += 1
        var values: [HBJCS1Value] = []
        if consume(UInt8(ascii: "]")) { return .array(values) }
        while true {
            values.append(try parseValue(depth: depth + 1))
            if consume(UInt8(ascii: "]")) { return .array(values) }
            try require(UInt8(ascii: ","))
        }
    }

    private mutating func parseString() throws -> String {
        try require(UInt8(ascii: "\""))
        var output = Data()
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\"") {
                guard let string = String(data: output, encoding: .utf8) else {
                    throw DeliveryProtocolV1Error.authenticationFailed
                }
                return string
            }
            if byte == UInt8(ascii: "\\") {
                output.append(try parseEscape())
            } else {
                guard byte >= 0x20 else { throw DeliveryProtocolV1Error.authenticationFailed }
                output.append(byte)
            }
        }
        throw DeliveryProtocolV1Error.authenticationFailed
    }

    private mutating func parseEscape() throws -> UInt8 {
        guard index < bytes.count else { throw DeliveryProtocolV1Error.authenticationFailed }
        let byte = bytes[index]
        index += 1
        if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") { return byte }
        guard byte == UInt8(ascii: "u"), index + 4 <= bytes.count,
              bytes[index] == UInt8(ascii: "0"), bytes[index + 1] == UInt8(ascii: "0"),
              let value = UInt8(String(bytes: bytes[index + 2 ..< index + 4], encoding: .ascii) ?? "", radix: 16),
              value < 0x20 else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        index += 4
        return value
    }

    private mutating func parseInteger() throws -> Int64 {
        let start = index
        if consume(UInt8(ascii: "-")) { guard index < bytes.count else { throw DeliveryProtocolV1Error.authenticationFailed } }
        guard index < bytes.count, (48 ... 57).contains(bytes[index]) else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        if bytes[index] == 48 {
            index += 1
        } else {
            while index < bytes.count, (48 ... 57).contains(bytes[index]) { index += 1 }
        }
        guard let value = Int64(String(bytes: bytes[start ..< index], encoding: .ascii) ?? "") else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        return value
    }

    private mutating func expect(_ value: String) throws {
        for byte in value.utf8 { try require(byte) }
    }

    private mutating func require(_ byte: UInt8) throws {
        guard consume(byte) else { throw DeliveryProtocolV1Error.authenticationFailed }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
