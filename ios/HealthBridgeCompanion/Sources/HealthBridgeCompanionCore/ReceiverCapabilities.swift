import Foundation

/// A declaration of Receiver support, independent of delivery receipts or liveness.
public struct ReceiverCapabilities: Equatable, Sendable {
    public let nutritionSupported: Bool

    public init(nutritionSupported: Bool) { self.nutritionSupported = nutritionSupported }

    public static func decodeHTTP(_ data: Data) -> Self? {
        struct Declaration: Decodable {
            let schema_id: String
            let batch_schema_id: String
            let nutrition_supported: Bool
        }
        guard let declaration = try? JSONDecoder().decode(Declaration.self, from: data),
              declaration.schema_id == "health_bridge.receiver_capabilities.v1",
              declaration.batch_schema_id == "health_bridge.batch.v1" else { return nil }
        return Self(nutritionSupported: declaration.nutrition_supported)
    }

    static func decodeAuthenticated(_ value: HBJCS1Value) throws -> Self {
        guard case .object(let fields) = value,
              fields["schema_id"] == .string("health_bridge.receiver_capabilities.v1"),
              fields["batch_schema_id"] == .string("health_bridge.batch.v1"),
              case .bool(let supported)? = fields["nutrition_supported"] else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        return Self(nutritionSupported: supported)
    }
}
