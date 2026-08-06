import Foundation

extension DeliveryProtocolV1 {
    static func validatePayload(_ plaintext: Data) throws {
        guard plaintext.count <= maxPayloadBytes else { throw DeliveryProtocolV1Error.payloadOversize }
        do {
            var parser = DeliveryJSONParser(bytes: Array(plaintext))
            let value = try parser.parse()
            try DeliveryPayloadShape.validate(value)
            let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: plaintext)
            guard batch.schemaID == "health_bridge.batch.v1",
                  validSchemaVersion(batch.schemaVersion) else {
                throw DeliveryProtocolV1Error.payloadInvalid
            }
        } catch let error as DeliveryProtocolV1Error {
            throw error
        } catch {
            throw DeliveryProtocolV1Error.payloadInvalid
        }
    }

    private static func validSchemaVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "1"
            && parts[1].utf8.allSatisfy({ (48 ... 57).contains($0) }) && !parts[1].isEmpty
            && parts[2].utf8.allSatisfy({ (48 ... 57).contains($0) }) && !parts[2].isEmpty
    }
}

private indirect enum DeliveryJSONValue {
    case object([String: DeliveryJSONValue])
    case array([DeliveryJSONValue])
    case string
    case number
    case bool
    case null
}

private struct DeliveryJSONParser {
    let bytes: [UInt8]
    var index = 0
    var nodes = 0

    mutating func parse() throws -> DeliveryJSONValue {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw invalid }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> DeliveryJSONValue {
        guard depth <= DeliveryProtocolV1.maxMetadataDepth,
              nodes < DeliveryProtocolV1.maxMetadataNodes,
              index < bytes.count else { throw invalid }
        nodes += 1
        switch bytes[index] {
        case UInt8(ascii: "{"):
            return try parseObject(depth: depth)
        case UInt8(ascii: "["):
            return try parseArray(depth: depth)
        case UInt8(ascii: "\""):
            _ = try parseString()
            return .string
        case UInt8(ascii: "t"):
            try expect("true")
            return .bool
        case UInt8(ascii: "f"):
            try expect("false")
            return .bool
        case UInt8(ascii: "n"):
            try expect("null")
            return .null
        default:
            try parseNumber()
            return .number
        }
    }

    private mutating func parseObject(depth: Int) throws -> DeliveryJSONValue {
        index += 1
        skipWhitespace()
        var fields: [String: DeliveryJSONValue] = [:]
        if consume(UInt8(ascii: "}")) { return .object(fields) }
        while true {
            let key = try parseString()
            guard fields[key] == nil else { throw invalid }
            skipWhitespace()
            try require(UInt8(ascii: ":"))
            skipWhitespace()
            fields[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            if consume(UInt8(ascii: "}")) { return .object(fields) }
            try require(UInt8(ascii: ","))
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws -> DeliveryJSONValue {
        index += 1
        skipWhitespace()
        var values: [DeliveryJSONValue] = []
        if consume(UInt8(ascii: "]")) { return .array(values) }
        while true {
            values.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            if consume(UInt8(ascii: "]")) { return .array(values) }
            try require(UInt8(ascii: ","))
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        try require(UInt8(ascii: "\""))
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\"") {
                let encoded = Data(bytes[start ..< index])
                let wrapped = Data("[".utf8) + encoded + Data("]".utf8)
                guard let decoded = try JSONSerialization.jsonObject(with: wrapped) as? [String],
                      decoded.count == 1 else { throw invalid }
                return decoded[0]
            }
            guard byte >= 0x20 else { throw invalid }
            if byte == UInt8(ascii: "\\") {
                guard index < bytes.count else { throw invalid }
                let escaped = bytes[index]
                index += 1
                if escaped == UInt8(ascii: "u") {
                    guard index + 4 <= bytes.count,
                          bytes[index ..< index + 4].allSatisfy(isASCIIHex) else { throw invalid }
                    index += 4
                } else if ![34, 47, 92, 98, 102, 110, 114, 116].contains(escaped) {
                    throw invalid
                }
            }
        }
        throw invalid
    }

    private mutating func parseNumber() throws {
        if consume(UInt8(ascii: "-")) { guard index < bytes.count else { throw invalid } }
        guard index < bytes.count else { throw invalid }
        if consume(UInt8(ascii: "0")) {
            guard index == bytes.count || !(48 ... 57).contains(bytes[index]) else { throw invalid }
        } else {
            guard consumeDigits(firstMustBeNonzero: true) else { throw invalid }
        }
        if consume(UInt8(ascii: ".")) { guard consumeDigits(firstMustBeNonzero: false) else { throw invalid } }
        if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
            index += 1
            if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
            guard consumeDigits(firstMustBeNonzero: false) else { throw invalid }
        }
    }

    private mutating func consumeDigits(firstMustBeNonzero: Bool) -> Bool {
        guard index < bytes.count,
              firstMustBeNonzero ? (49 ... 57).contains(bytes[index]) : (48 ... 57).contains(bytes[index]) else {
            return false
        }
        while index < bytes.count, (48 ... 57).contains(bytes[index]) { index += 1 }
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func expect(_ value: String) throws {
        for byte in value.utf8 { try require(byte) }
    }

    private mutating func require(_ byte: UInt8) throws {
        guard consume(byte) else { throw invalid }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private func isASCIIHex(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (65 ... 70).contains(byte) || (97 ... 102).contains(byte)
    }

    private var invalid: DeliveryProtocolV1Error { .payloadInvalid }
}

private enum DeliveryPayloadShape {
    static func validate(_ value: DeliveryJSONValue) throws {
        let root = try object(value, required: [
            "schema_id", "schema_version", "generated_at", "export_window", "sources", "health_types",
            "samples", "workouts", "sleep_sessions", "deleted_records", "sync",
        ])
        _ = try object(root["export_window"], required: ["start_time", "end_time"])
        try objects(root["sources"], required: ["source_key", "name", "kind"], optional: ["bundle_id", "device_model"])
        try objects(root["health_types"], required: ["type_code", "display_name", "category", "default_unit", "sensitivity", "aliases"])
        try objects(root["samples"], required: ["client_record_id", "source_key", "type_code", "start_time", "end_time", "value", "unit", "metadata"], nested: validateSample)
        try objects(root["workouts"], required: ["client_record_id", "source_key", "workout_type", "start_time", "end_time", "duration_seconds"], optional: ["energy_kcal", "distance_meters"])
        try objects(root["sleep_sessions"], required: ["client_record_id", "source_key", "start_time", "end_time", "stage_intervals"], nested: validateSleep)
        try objects(root["deleted_records"], required: ["record_family", "source_key", "client_record_id", "deleted_at"])
        let sync = try object(root["sync"], required: ["sync_window", "cursors"])
        _ = try object(sync["sync_window"], required: ["start_time", "end_time"])
        try objects(sync["cursors"], required: ["source_key", "cursor_kind", "cursor_value"])
    }

    private static func validateSample(_ fields: [String: DeliveryJSONValue]) throws {
        guard case let .object(metadata) = fields["metadata"],
              metadata.values.allSatisfy({ if case .string = $0 { true } else { false } }) else { throw invalid }
    }

    private static func validateSleep(_ fields: [String: DeliveryJSONValue]) throws {
        try objects(fields["stage_intervals"], required: ["stage", "start_time", "end_time"])
    }

    private static func objects(
        _ value: DeliveryJSONValue?,
        required: Set<String>,
        optional: Set<String> = [],
        nested: (([String: DeliveryJSONValue]) throws -> Void)? = nil
    ) throws {
        guard case let .array(values) = value else { throw invalid }
        for value in values {
            let fields = try object(value, required: required, optional: optional)
            try nested?(fields)
        }
    }

    private static func object(
        _ value: DeliveryJSONValue?,
        required: Set<String>,
        optional: Set<String> = []
    ) throws -> [String: DeliveryJSONValue] {
        guard case let .object(fields) = value,
              required.isSubset(of: fields.keys),
              Set(fields.keys).isSubset(of: required.union(optional)) else { throw invalid }
        return fields
    }

    private static var invalid: DeliveryProtocolV1Error { .payloadInvalid }
}
