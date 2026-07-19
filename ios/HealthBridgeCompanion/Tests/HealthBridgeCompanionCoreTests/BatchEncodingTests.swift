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
        XCTAssertEqual(HealthBridgeUTCFormatter.string(from: Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00Z")
        XCTAssertEqual(HealthBridgeUTCFormatter.string(from: Date(timeIntervalSince1970: 1.9)), "1970-01-01T00:00:01Z")
    }
}
