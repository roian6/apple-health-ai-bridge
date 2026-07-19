import Foundation

public enum ConnectionTestBatchFactory {
    public static func make(now: Date = Date()) -> HealthBridgeBatchV1 {
        let timestamp = HealthBridgeUTCFormatter.string(from: now)
        let source = HealthBridgeSource(
            sourceKey: "apple_health.phone",
            name: "Apple Health on iPhone",
            kind: .phone,
            bundleID: HealthBridgeAppIdentity.bundleIdentifier,
            deviceModel: "iPhone"
        )
        let window = HealthBridgeTimeWindow(startTime: timestamp, endTime: timestamp)
        return HealthBridgeBatchV1(
            generatedAt: timestamp,
            exportWindow: window,
            sources: [source],
            healthTypes: HealthBridgeHealthType.canonicalTypes,
            samples: [],
            workouts: [],
            sleepSessions: [],
            deletedRecords: [],
            sync: HealthBridgeSyncContext(
                syncWindow: window,
                cursors: [
                    HealthBridgeSyncCursor(
                        sourceKey: source.sourceKey,
                        cursorKind: "connection_test",
                        cursorValue: timestamp
                    )
                ]
            )
        )
    }
}
