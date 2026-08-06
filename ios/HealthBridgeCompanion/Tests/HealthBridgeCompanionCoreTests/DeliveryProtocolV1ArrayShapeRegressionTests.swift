import CryptoKit
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class DeliveryProtocolV1ArrayShapeRegressionTests: XCTestCase {
    func testAuthenticatedUnknownFieldsFailForEveryFlatArrayElementShape() throws {
        for elementCase in elementCases {
            var element = elementCase.element
            element["unexpected"] = "synthetic"
            try assertPayloadInvalid(
                payload(replacing: elementCase, with: element),
                row: "unknown-\(elementCase.name)"
            )
        }
    }

    func testAuthenticatedMissingRequiredFieldsFailForEveryFlatArrayElementShape() throws {
        for elementCase in elementCases {
            var element = elementCase.element
            element.removeValue(forKey: elementCase.requiredKey)
            try assertPayloadInvalid(
                payload(replacing: elementCase, with: element),
                row: "missing-\(elementCase.name)-\(elementCase.requiredKey)"
            )
        }
    }

    func testAuthenticatedUnknownFieldsFailForSleepSessionAndStageIntervalShapes() throws {
        for target in ["sleep-session", "sleep-stage-interval"] {
            var interval = validStageInterval
            var session = validSleepSession
            if target == "sleep-session" {
                session["unexpected"] = "synthetic"
            } else {
                interval["unexpected"] = "synthetic"
            }
            session["stage_intervals"] = [interval]
            try assertPayloadInvalid(
                payload(replacingRootArray: "sleep_sessions", with: session),
                row: "unknown-\(target)"
            )
        }
    }

    func testAuthenticatedMissingRequiredFieldFailsForStageIntervalShape() throws {
        var interval = validStageInterval
        interval.removeValue(forKey: "stage")
        var session = validSleepSession
        session["stage_intervals"] = [interval]
        try assertPayloadInvalid(
            payload(replacingRootArray: "sleep_sessions", with: session),
            row: "missing-sleep-stage-interval-stage"
        )
    }

    private var elementCases: [ArrayElementCase] {
        [
            .init(
                name: "sources",
                arrayKey: "sources",
                requiredKey: "name",
                element: [
                    "source_key": "synthetic.phone.shape",
                    "name": "Synthetic Shape Phone",
                    "kind": "phone",
                ]
            ),
            .init(
                name: "health_types",
                arrayKey: "health_types",
                requiredKey: "display_name",
                element: [
                    "type_code": "synthetic_steps",
                    "display_name": "Synthetic Steps",
                    "category": "activity",
                    "default_unit": "count",
                    "sensitivity": "low",
                    "aliases": ["SyntheticStepCount"],
                ]
            ),
            .init(
                name: "workouts",
                arrayKey: "workouts",
                requiredKey: "duration_seconds",
                element: [
                    "client_record_id": "synthetic-workout-shape",
                    "source_key": "synthetic.phone.alpha",
                    "workout_type": "synthetic_walk",
                    "start_time": "2026-06-08T08:00:00Z",
                    "end_time": "2026-06-08T08:05:00Z",
                    "duration_seconds": 300,
                ]
            ),
            .init(
                name: "deleted_records",
                arrayKey: "deleted_records",
                requiredKey: "deleted_at",
                element: [
                    "record_family": "sample",
                    "source_key": "synthetic.phone.alpha",
                    "client_record_id": "synthetic-deleted-shape",
                    "deleted_at": "2026-06-08T10:00:00Z",
                ]
            ),
            .init(
                name: "sync.cursors",
                arrayKey: "cursors",
                requiredKey: "cursor_value",
                nestedInSync: true,
                element: [
                    "source_key": "synthetic.phone.alpha",
                    "cursor_kind": "synthetic_anchor",
                    "cursor_value": "synthetic-cursor-shape",
                ]
            ),
        ]
    }

    private func payload(replacing elementCase: ArrayElementCase, with element: [String: Any]) throws -> Data {
        let fixture = try DeliveryProtocolV1TestSupport.fixture("swift")
        let plaintext = try DeliveryProtocolV1TestSupport.data(fixture.plaintext)
        guard var root = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw DeliveryProtocolV1Error.payloadInvalid
        }
        if elementCase.nestedInSync {
            guard var sync = root["sync"] as? [String: Any] else {
                throw DeliveryProtocolV1Error.payloadInvalid
            }
            sync[elementCase.arrayKey] = [element]
            root["sync"] = sync
        } else {
            root[elementCase.arrayKey] = [element]
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func payload(replacingRootArray key: String, with element: [String: Any]) throws -> Data {
        let fixture = try DeliveryProtocolV1TestSupport.fixture("swift")
        let plaintext = try DeliveryProtocolV1TestSupport.data(fixture.plaintext)
        guard var root = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw DeliveryProtocolV1Error.payloadInvalid
        }
        root[key] = [element]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private var validSleepSession: [String: Any] {
        [
            "client_record_id": "synthetic-sleep-shape",
            "source_key": "synthetic.phone.alpha",
            "start_time": "2026-06-08T01:00:00Z",
            "end_time": "2026-06-08T02:00:00Z",
        ]
    }

    private var validStageInterval: [String: Any] {
        [
            "stage": "synthetic_stage",
            "start_time": "2026-06-08T01:00:00Z",
            "end_time": "2026-06-08T02:00:00Z",
        ]
    }

    private func assertPayloadInvalid(_ plaintext: Data, row: String) throws {
        let ephemeral = try DeliveryProtocolV1TestSupport.agreementKey(
            "health-bridge/swift/array-shape/\(row)/ephemeral"
        )
        let nonce = DeliveryProtocolV1TestSupport.digest(
            "health-bridge/swift/array-shape/\(row)/nonce"
        ).prefixData(12)
        let envelope = try DeliveryProtocolV1.sealDeliveryForVector(
            plaintext,
            context: DeliveryProtocolV1TestSupport.envelopeSeal("swift"),
            ephemeralPrivateKey: ephemeral,
            nonce: nonce
        )
        XCTAssertThrowsError(
            try DeliveryProtocolV1.openDelivery(
                envelope,
                context: DeliveryProtocolV1TestSupport.envelopeOpen("swift")
            ),
            row
        ) { error in
            XCTAssertEqual(error as? DeliveryProtocolV1Error, .payloadInvalid, row)
        }
    }
}

private struct ArrayElementCase {
    let name: String
    let arrayKey: String
    let requiredKey: String
    let nestedInSync: Bool
    let element: [String: Any]

    init(
        name: String,
        arrayKey: String,
        requiredKey: String,
        nestedInSync: Bool = false,
        element: [String: Any]
    ) {
        self.name = name
        self.arrayKey = arrayKey
        self.requiredKey = requiredKey
        self.nestedInSync = nestedInSync
        self.element = element
    }
}
