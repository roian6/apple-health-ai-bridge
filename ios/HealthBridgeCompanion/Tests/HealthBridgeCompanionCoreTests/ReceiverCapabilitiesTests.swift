import Foundation
import XCTest
#if canImport(HealthBridgeCompanion)
@testable import HealthBridgeCompanion
#else
@testable import HealthBridgeCompanionCore
#endif

final class ReceiverCapabilitiesTests: XCTestCase {
    func testHTTPKnownFieldsAndCompatibleAdditions() throws {
        for supported in [true, false] {
            let data = Data("""
            {"schema_id":"health_bridge.receiver_capabilities.v1","batch_schema_id":"health_bridge.batch.v1",
            "nutrition_supported":\(supported),"future_synthetic":{"enabled":true}}
            """.utf8)
            let value = try XCTUnwrap(ReceiverCapabilities.decodeHTTP(data))
            XCTAssertEqual(value.nutritionSupported, supported)
            XCTAssertEqual(NutritionSupport.decode(data), supported ? .supported : .unsupported)
        }
    }

    func testHTTPInvalidRequiredFieldsRemainUnknown() {
        for value in ["null", "1", "\"true\""] {
            let data = Data("""
            {"schema_id":"health_bridge.receiver_capabilities.v1","batch_schema_id":"health_bridge.batch.v1","nutrition_supported":\(value)}
            """.utf8)
            XCTAssertNil(ReceiverCapabilities.decodeHTTP(data))
            XCTAssertEqual(NutritionSupport.decode(data), .unknown)
        }
        for data in [Data("{}".utf8), Data("[]".utf8), Data("{\"nutrition_supported\":true}".utf8)] {
            XCTAssertNil(ReceiverCapabilities.decodeHTTP(data))
        }
    }
}
