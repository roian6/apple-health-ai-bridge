import XCTest
#if canImport(HealthKit)
import HealthKit
#endif
@testable import HealthBridgeCompanionCore

final class WorkoutSyncBatchFactoryTests: XCTestCase {
#if canImport(HealthKit)
    func testHealthKitActivitiesKeepTheirIdentityThroughExport() throws {
        let activities: [(HKWorkoutActivityType, String)] = [
            (.americanFootball, "american_football"),
            (.archery, "archery"),
            (.australianFootball, "australian_football"),
            (.badminton, "badminton"),
            (.baseball, "baseball"),
            (.basketball, "basketball"),
            (.bowling, "bowling"),
            (.boxing, "boxing"),
            (.climbing, "climbing"),
            (.cricket, "cricket"),
            (.crossTraining, "cross_training"),
            (.curling, "curling"),
            (.cycling, "cycling"),
            (.dance, "dance"),
            (.danceInspiredTraining, "dance_inspired_training"),
            (.elliptical, "elliptical"),
            (.equestrianSports, "equestrian_sports"),
            (.fencing, "fencing"),
            (.fishing, "fishing"),
            (.functionalStrengthTraining, "functional_strength_training"),
            (.golf, "golf"),
            (.gymnastics, "gymnastics"),
            (.handball, "handball"),
            (.hiking, "hiking"),
            (.hockey, "hockey"),
            (.hunting, "hunting"),
            (.lacrosse, "lacrosse"),
            (.martialArts, "martial_arts"),
            (.mindAndBody, "mind_and_body"),
            (.mixedMetabolicCardioTraining, "mixed_metabolic_cardio_training"),
            (.paddleSports, "paddle_sports"),
            (.play, "play"),
            (.preparationAndRecovery, "preparation_and_recovery"),
            (.racquetball, "racquetball"),
            (.rowing, "rowing"),
            (.rugby, "rugby"),
            (.running, "running"),
            (.sailing, "sailing"),
            (.skatingSports, "skating_sports"),
            (.snowSports, "snow_sports"),
            (.soccer, "soccer"),
            (.softball, "softball"),
            (.squash, "squash"),
            (.stairClimbing, "stair_climbing"),
            (.surfingSports, "surfing_sports"),
            (.swimming, "swimming"),
            (.tableTennis, "table_tennis"),
            (.tennis, "tennis"),
            (.trackAndField, "track_and_field"),
            (.traditionalStrengthTraining, "traditional_strength_training"),
            (.volleyball, "volleyball"),
            (.walking, "walking"),
            (.waterFitness, "water_fitness"),
            (.waterPolo, "water_polo"),
            (.waterSports, "water_sports"),
            (.wrestling, "wrestling"),
            (.yoga, "yoga"),
            (.barre, "barre"),
            (.coreTraining, "core_training"),
            (.crossCountrySkiing, "cross_country_skiing"),
            (.downhillSkiing, "downhill_skiing"),
            (.flexibility, "flexibility"),
            (.highIntensityIntervalTraining, "hiit"),
            (.jumpRope, "jump_rope"),
            (.kickboxing, "kickboxing"),
            (.pilates, "pilates"),
            (.snowboarding, "snowboarding"),
            (.stairs, "stairs"),
            (.stepTraining, "step_training"),
            (.wheelchairWalkPace, "wheelchair_walk_pace"),
            (.wheelchairRunPace, "wheelchair_run_pace"),
            (.taiChi, "tai_chi"),
            (.mixedCardio, "mixed_cardio"),
            (.handCycling, "hand_cycling"),
            (.discSports, "disc_sports"),
            (.fitnessGaming, "fitness_gaming"),
            (.cardioDance, "cardio_dance"),
            (.socialDance, "social_dance"),
            (.pickleball, "pickleball"),
            (.cooldown, "cooldown"),
            (.swimBikeRun, "swim_bike_run"),
            (.transition, "transition"),
            (.other, "other"),
        ]
        for (activity, expected) in activities {
            try assertExportedActivity(activity, equals: expected)
        }
        if #available(iOS 17.0, macOS 14.0, *) {
            try assertExportedActivity(.underwaterDiving, equals: "underwater_diving")
        }
    }

    func testUnmappedHealthKitActivitiesPreserveUnsignedRawValuesThroughExport() throws {
        let activities: [(UInt, String)] = [
            (0, "healthkit_activity_0"),
            (81, "healthkit_activity_81"),
            (2998, "healthkit_activity_2998"),
            (2999, "healthkit_activity_2999"),
            (9999, "healthkit_activity_9999"),
            (UInt.max, "healthkit_activity_18446744073709551615"),
        ]
        for (rawValue, expected) in activities {
            let activity = try XCTUnwrap(HKWorkoutActivityType(rawValue: rawValue))
            try assertExportedActivity(activity, equals: expected, unmapped: true)
        }
    }

    private func assertExportedActivity(
        _ activity: HKWorkoutActivityType,
        equals expected: String,
        unmapped: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let start = try date("2026-06-09T10:00:00Z")
        let end = try date("2026-06-09T10:45:00Z")
        // HealthKit validates constructor inputs against this SDK's known types.
        // Override only the activity getter to model a future/unknown SDK value.
        let workoutClass: HKWorkout.Type = unmapped ? UnmappedActivityWorkout.self : HKWorkout.self
        let workout = workoutClass.init(
            activityType: unmapped ? .other : activity,
            start: start,
            end: end,
            duration: 2700,
            totalEnergyBurned: nil,
            totalDistance: nil,
            metadata: nil
        )
        (workout as? UnmappedActivityWorkout)?.unmappedActivity = activity
        let summary = workoutSummary(for: workout)
        XCTAssertEqual(summary.workoutType, expected, file: file, line: line)
        XCTAssertEqual(summary.uuid, workout.uuid, file: file, line: line)
        let batch = WorkoutSyncBatchFactory.makeAnchoredWorkoutBatch(
            workouts: [summary],
            deletedWorkouts: [],
            anchorCursorValue: "synthetic-anchor",
            windowStart: start,
            windowEnd: end,
            generatedAt: end
        )
        let encoded = try HealthBridgeBatchEncoder().encode(batch)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let records = try XCTUnwrap(object["workouts"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1, file: file, line: line)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record["workout_type"] as? String, expected, file: file, line: line)
        XCTAssertEqual(
            record["client_record_id"] as? String,
            "hk-workout-\(workout.uuid.uuidString.lowercased())",
            file: file,
            line: line
        )
    }
#endif

    func testFactoryBuildsStableWorkoutRecordsForReceiverContract() throws {
        let generatedAt = try date("2026-06-10T08:00:00Z")
        let windowStart = try date("2026-06-01T00:00:00Z")
        let windowEnd = try date("2026-06-10T08:00:00Z")
        let workoutID = try XCTUnwrap(UUID(uuidString: "A3E4C5B6-1111-2222-3333-444455556666"))
        let workouts = [
            HealthKitWorkoutSummary(
                uuid: workoutID,
                workoutType: "traditional_strength_training",
                start: try date("2026-06-09T10:00:00Z"),
                end: try date("2026-06-09T10:45:30Z"),
                durationSeconds: 2730,
                activeEnergyKcal: 240.5,
                distanceMeters: nil
            )
        ]

        let batch = WorkoutSyncBatchFactory.makeWorkoutBatch(
            workouts: workouts,
            windowStart: windowStart,
            windowEnd: windowEnd,
            generatedAt: generatedAt
        )

        XCTAssertEqual(batch.generatedAt, "2026-06-10T08:00:00Z")
        XCTAssertEqual(batch.exportWindow.startTime, "2026-06-01T00:00:00Z")
        XCTAssertEqual(batch.exportWindow.endTime, "2026-06-10T08:00:00Z")
        XCTAssertEqual(batch.sources, [
            HealthBridgeSource(
                sourceKey: "apple_health.phone",
                name: "Apple Health on iPhone",
                kind: .phone,
                bundleID: HealthBridgeAppIdentity.bundleIdentifier,
                deviceModel: "iPhone"
            )
        ])
        XCTAssertEqual(batch.healthTypes, [.workouts])
        XCTAssertTrue(batch.samples.isEmpty)
        XCTAssertEqual(batch.workouts.count, 1)
        let workout = try XCTUnwrap(batch.workouts.first)
        XCTAssertEqual(workout.clientRecordID, "hk-workout-a3e4c5b6-1111-2222-3333-444455556666")
        XCTAssertEqual(workout.sourceKey, "apple_health.phone")
        XCTAssertEqual(workout.workoutType, "traditional_strength_training")
        XCTAssertEqual(workout.startTime, "2026-06-09T10:00:00Z")
        XCTAssertEqual(workout.endTime, "2026-06-09T10:45:30Z")
        XCTAssertEqual(workout.durationSeconds, 2730)
        XCTAssertEqual(workout.energyKcal, 240.5)
        XCTAssertNil(workout.distanceMeters)
        XCTAssertEqual(batch.sync.cursors, [
            HealthBridgeSyncCursor(
                sourceKey: "apple_health.phone",
                cursorKind: "foreground_workout_sync",
                cursorValue: "2026-06-10T08:00:00Z"
            )
        ])
    }

    func testFactoryClampsDurationToSerializedWholeSecondInterval() throws {
        let start = Date(timeIntervalSince1970: 1_000.9)
        let end = Date(timeIntervalSince1970: 1_100.1)
        let workoutID = try XCTUnwrap(
            UUID(uuidString: "A3E4C5B6-1111-2222-3333-444455556666")
        )

        let batch = WorkoutSyncBatchFactory.makeWorkoutBatch(
            workouts: [
                HealthKitWorkoutSummary(
                    uuid: workoutID,
                    workoutType: "walking",
                    start: start,
                    end: end,
                    durationSeconds: 101,
                    activeEnergyKcal: nil,
                    distanceMeters: nil
                )
            ],
            windowStart: start,
            windowEnd: end,
            generatedAt: end
        )

        let workout = try XCTUnwrap(batch.workouts.first)
        XCTAssertEqual(workout.startTime, "1970-01-01T00:16:40Z")
        XCTAssertEqual(workout.endTime, "1970-01-01T00:18:20Z")
        XCTAssertEqual(workout.durationSeconds, 100)
    }

    func testForegroundUploadPolicyAllowsCursorOnlyWorkoutBatch() throws {
        let batch = WorkoutSyncBatchFactory.makeWorkoutBatch(
            workouts: [],
            windowStart: try date("2026-06-01T00:00:00Z"),
            windowEnd: try date("2026-06-02T00:00:00Z"),
            generatedAt: try date("2026-06-02T00:00:01Z")
        )

        XCTAssertTrue(batch.workouts.isEmpty)
        XCTAssertEqual(batch.sync.cursors, [
            HealthBridgeSyncCursor(
                sourceKey: "apple_health.phone",
                cursorKind: "foreground_workout_sync",
                cursorValue: "2026-06-02T00:00:00Z"
            )
        ])
        XCTAssertTrue(ForegroundSyncUploadPolicy.shouldUpload(batch))
    }

    func testAnchoredWorkoutBatchEncodesAddsDeletesAndAnchorCursor() throws {
        let addedID = try XCTUnwrap(UUID(uuidString: "A3E4C5B6-1111-2222-3333-444455556666"))
        let deletedID = try XCTUnwrap(UUID(uuidString: "B3E4C5B6-1111-2222-3333-444455556666"))

        let batch = WorkoutSyncBatchFactory.makeAnchoredWorkoutBatch(
            workouts: [
                HealthKitWorkoutSummary(
                    uuid: addedID,
                    workoutType: "running",
                    start: try date("2026-06-14T09:00:00Z"),
                    end: try date("2026-06-14T09:45:00Z"),
                    durationSeconds: 2700,
                    activeEnergyKcal: 420,
                    distanceMeters: 7500
                )
            ],
            deletedWorkouts: [
                HealthKitDeletedWorkout(
                    uuid: deletedID,
                    deletedAt: try date("2026-06-15T03:30:00Z")
                )
            ],
            anchorCursorValue: "base64-healthkit-anchor",
            windowStart: try date("2026-06-14T00:00:00Z"),
            windowEnd: try date("2026-06-15T03:30:00Z"),
            generatedAt: try date("2026-06-15T03:30:01Z")
        )

        XCTAssertEqual(batch.healthTypes, [.workouts])
        XCTAssertEqual(batch.workouts.map(\.clientRecordID), [
            "hk-workout-a3e4c5b6-1111-2222-3333-444455556666"
        ])
        XCTAssertEqual(batch.deletedRecords, [
            HealthBridgeDeletedRecord(
                recordFamily: "workout",
                sourceKey: "apple_health.phone",
                clientRecordID: "hk-workout-b3e4c5b6-1111-2222-3333-444455556666",
                deletedAt: "2026-06-15T03:30:00Z"
            )
        ])
        XCTAssertEqual(batch.sync.cursors, [
            HealthBridgeSyncCursor(
                sourceKey: "apple_health.phone",
                cursorKind: "anchored_workout_sync",
                cursorValue: "base64-healthkit-anchor"
            )
        ])
        XCTAssertTrue(ForegroundSyncUploadPolicy.shouldUpload(batch))
    }

    func testAnchoredWorkoutBatchUploadsDeletionOnlyChanges() throws {
        let deletedID = try XCTUnwrap(UUID(uuidString: "B3E4C5B6-1111-2222-3333-444455556666"))

        let batch = WorkoutSyncBatchFactory.makeAnchoredWorkoutBatch(
            workouts: [],
            deletedWorkouts: [
                HealthKitDeletedWorkout(
                    uuid: deletedID,
                    deletedAt: try date("2026-06-15T03:30:00Z")
                )
            ],
            anchorCursorValue: "base64-healthkit-anchor",
            windowStart: try date("2026-06-14T00:00:00Z"),
            windowEnd: try date("2026-06-15T03:30:00Z"),
            generatedAt: try date("2026-06-15T03:30:01Z")
        )

        XCTAssertTrue(batch.workouts.isEmpty)
        XCTAssertEqual(batch.deletedRecords.map(\.clientRecordID), [
            "hk-workout-b3e4c5b6-1111-2222-3333-444455556666"
        ])
        XCTAssertTrue(ForegroundSyncUploadPolicy.shouldUpload(batch))
    }

    func testAnchoredWorkoutBatchCanBeBuiltFromReaderChangeSet() throws {
        let addedID = try XCTUnwrap(UUID(uuidString: "A3E4C5B6-1111-2222-3333-444455556666"))
        let changes = HealthKitAnchoredWorkoutChanges(
            workouts: [
                HealthKitWorkoutSummary(
                    uuid: addedID,
                    workoutType: "running",
                    start: try date("2026-06-14T09:00:00Z"),
                    end: try date("2026-06-14T09:45:00Z"),
                    durationSeconds: 2700,
                    activeEnergyKcal: 420,
                    distanceMeters: 7500
                )
            ],
            deletedWorkouts: [],
            anchorCursorValue: "reader-anchor",
            windowStart: try date("2026-06-14T09:00:00Z"),
            windowEnd: try date("2026-06-15T03:30:00Z")
        )

        let batch = WorkoutSyncBatchFactory.makeAnchoredWorkoutBatch(
            changes: changes,
            generatedAt: try date("2026-06-15T03:30:01Z")
        )

        XCTAssertEqual(batch.workouts.map(\.clientRecordID), [
            "hk-workout-a3e4c5b6-1111-2222-3333-444455556666"
        ])
        XCTAssertTrue(batch.deletedRecords.isEmpty)
        XCTAssertEqual(batch.sync.cursors, [
            HealthBridgeSyncCursor(
                sourceKey: "apple_health.phone",
                cursorKind: "anchored_workout_sync",
                cursorValue: "reader-anchor"
            )
        ])
    }

    func testAnchoredWorkoutBatchUploadsCursorOnlyReaderChangeSet() throws {
        let changes = HealthKitAnchoredWorkoutChanges(
            workouts: [],
            deletedWorkouts: [],
            anchorCursorValue: "reader-anchor",
            windowStart: try date("2026-06-15T03:30:00Z"),
            windowEnd: try date("2026-06-15T03:30:00Z")
        )

        let batch = WorkoutSyncBatchFactory.makeAnchoredWorkoutBatch(
            changes: changes,
            generatedAt: try date("2026-06-15T03:30:01Z")
        )

        XCTAssertTrue(batch.workouts.isEmpty)
        XCTAssertTrue(batch.deletedRecords.isEmpty)
        XCTAssertEqual(batch.sync.cursors, [
            HealthBridgeSyncCursor(
                sourceKey: "apple_health.phone",
                cursorKind: "anchored_workout_sync",
                cursorValue: "reader-anchor"
            )
        ])
        XCTAssertTrue(ForegroundSyncUploadPolicy.shouldUpload(batch))
    }

    func testFactorySortsWorkoutsAndFiltersInvalidDurations() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let workouts = [
            HealthKitWorkoutSummary(
                uuid: secondID,
                workoutType: "running",
                start: try date("2026-06-03T12:00:00Z"),
                end: try date("2026-06-03T12:30:00Z"),
                durationSeconds: 1800,
                activeEnergyKcal: 310,
                distanceMeters: 5000
            ),
            HealthKitWorkoutSummary(
                uuid: firstID,
                workoutType: "walking",
                start: try date("2026-06-02T12:00:00Z"),
                end: try date("2026-06-02T12:20:00Z"),
                durationSeconds: 1200,
                activeEnergyKcal: nil,
                distanceMeters: 1300
            ),
            HealthKitWorkoutSummary(
                uuid: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003")),
                workoutType: "other",
                start: try date("2026-06-04T12:00:00Z"),
                end: try date("2026-06-04T12:00:00Z"),
                durationSeconds: 0,
                activeEnergyKcal: nil,
                distanceMeters: nil
            ),
        ]

        let batch = WorkoutSyncBatchFactory.makeWorkoutBatch(
            workouts: workouts,
            windowStart: try date("2026-06-01T00:00:00Z"),
            windowEnd: try date("2026-06-05T00:00:00Z"),
            generatedAt: try date("2026-06-10T08:00:00Z")
        )

        XCTAssertEqual(batch.workouts.map(\.clientRecordID), [
            "hk-workout-00000000-0000-0000-0000-000000000001",
            "hk-workout-00000000-0000-0000-0000-000000000002",
        ])
        XCTAssertEqual(batch.workouts.map(\.workoutType), ["walking", "running"])
    }
}

#if canImport(HealthKit)
private final class UnmappedActivityWorkout: HKWorkout, @unchecked Sendable {
    var unmappedActivity: HKWorkoutActivityType = .other

    override var workoutActivityType: HKWorkoutActivityType {
        unmappedActivity
    }
}
#endif

private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return try XCTUnwrap(formatter.date(from: string))
}
