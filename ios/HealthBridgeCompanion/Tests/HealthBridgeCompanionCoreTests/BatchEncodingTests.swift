import XCTest
@testable import HealthBridgeCompanionCore

final class BatchEncodingTests: XCTestCase {
    func testBatchEncoderProducesReceiverContractKeysAndUtcTimestamps() throws {
        let batch = HealthBridgeBatchV1(
            generatedAt: "2026-06-08T09:00:00Z",
            exportWindow: HealthBridgeTimeWindow(
                startTime: "2026-06-01T00:00:00Z",
                endTime: "2026-06-08T00:00:00Z"
            ),
            sources: [
                HealthBridgeSource(
                    sourceKey: "apple_health.phone",
                    name: "Apple Health on iPhone",
                    kind: .phone,
                    bundleID: HealthBridgeAppIdentity.bundleIdentifier,
                    deviceModel: "iPhone"
                )
            ],
            healthTypes: [HealthBridgeHealthType.steps],
            samples: [
                HealthBridgeSample(
                    clientRecordID: "hk-sample-steps-20260601",
                    sourceKey: "apple_health.phone",
                    typeCode: "steps",
                    startTime: "2026-06-01T00:00:00Z",
                    endTime: "2026-06-02T00:00:00Z",
                    value: 4321,
                    unit: "count",
                    metadata: ["aggregation": "daily_sum"]
                )
            ],
            workouts: [],
            sleepSessions: [],
            deletedRecords: [],
            sync: HealthBridgeSyncContext(
                syncWindow: HealthBridgeTimeWindow(
                    startTime: "2026-06-01T00:00:00Z",
                    endTime: "2026-06-08T00:00:00Z"
                ),
                cursors: [
                    HealthBridgeSyncCursor(
                        sourceKey: "apple_health.phone",
                        cursorKind: "anchored_object_query",
                        cursorValue: "cursor-1"
                    )
                ]
            )
        )

        let data = try HealthBridgeBatchEncoder().encode(batch)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["schema_id"] as? String, "health_bridge.batch.v1")
        XCTAssertEqual(object["schema_version"] as? String, "1.0.0")
        XCTAssertEqual(object["generated_at"] as? String, "2026-06-08T09:00:00Z")
        XCTAssertNotNil(object["export_window"])
        XCTAssertNotNil(object["health_types"])
        XCTAssertNotNil(object["deleted_records"])
        XCTAssertNil(object["generatedAt"])
    }

    func testUTCFormatterUsesWholeSecondZuluTimestamps() {
        let formatter = HealthBridgeUTCFormatter.makeFormatter()
        let cases: [(Double, String)] = [
            (0, "1970-01-01T00:00:00Z"),
            (1.9, "1970-01-01T00:00:01Z"),
            (-3600.875, "1969-12-31T22:59:59Z"),
            (-0.125, "1969-12-31T23:59:59Z"),
            (0.125, "1970-01-01T00:00:00Z"),
            (1_710_053_999.875, "2024-03-10T06:59:59Z"),
            (1_710_054_000.125, "2024-03-10T07:00:00Z"),
        ]
        for (epoch, expected) in cases {
            let date = Date(timeIntervalSince1970: epoch)
            XCTAssertEqual(HealthBridgeUTCFormatter.string(from: date), expected)
            XCTAssertEqual(HealthBridgeUTCFormatter.string(from: date, using: formatter), expected)
            XCTAssertEqual(formatter.date(from: expected)?.timeIntervalSince1970, floor(epoch))
        }
    }
}
