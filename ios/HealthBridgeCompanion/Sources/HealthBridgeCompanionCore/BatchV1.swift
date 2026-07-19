import Foundation

public struct HealthBridgeBatchV1: Codable, Equatable, Sendable {
    public let schemaID: String
    public let schemaVersion: String
    public let generatedAt: String
    public let exportWindow: HealthBridgeTimeWindow
    public let sources: [HealthBridgeSource]
    public let healthTypes: [HealthBridgeHealthType]
    public let samples: [HealthBridgeSample]
    public let workouts: [HealthBridgeWorkout]
    public let sleepSessions: [HealthBridgeSleepSession]
    public let deletedRecords: [HealthBridgeDeletedRecord]
    public let sync: HealthBridgeSyncContext

    public init(
        schemaID: String = "health_bridge.batch.v1",
        schemaVersion: String = "1.0.0",
        generatedAt: String,
        exportWindow: HealthBridgeTimeWindow,
        sources: [HealthBridgeSource],
        healthTypes: [HealthBridgeHealthType],
        samples: [HealthBridgeSample],
        workouts: [HealthBridgeWorkout],
        sleepSessions: [HealthBridgeSleepSession],
        deletedRecords: [HealthBridgeDeletedRecord],
        sync: HealthBridgeSyncContext
    ) {
        self.schemaID = schemaID
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.exportWindow = exportWindow
        self.sources = sources
        self.healthTypes = healthTypes
        self.samples = samples
        self.workouts = workouts
        self.sleepSessions = sleepSessions
        self.deletedRecords = deletedRecords
        self.sync = sync
    }

    enum CodingKeys: String, CodingKey {
        case schemaID = "schema_id"
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case exportWindow = "export_window"
        case sources
        case healthTypes = "health_types"
        case samples
        case workouts
        case sleepSessions = "sleep_sessions"
        case deletedRecords = "deleted_records"
        case sync
    }
}

public struct HealthBridgeTimeWindow: Codable, Equatable, Sendable {
    public let startTime: String
    public let endTime: String

    public init(startTime: String, endTime: String) {
        self.startTime = startTime
        self.endTime = endTime
    }

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
    }
}

public struct HealthBridgeSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case phone
        case watch
        case app
        case manual
    }

    public let sourceKey: String
    public let name: String
    public let kind: Kind
    public let bundleID: String?
    public let deviceModel: String?

    public init(sourceKey: String, name: String, kind: Kind, bundleID: String? = nil, deviceModel: String? = nil) {
        self.sourceKey = sourceKey
        self.name = name
        self.kind = kind
        self.bundleID = bundleID
        self.deviceModel = deviceModel
    }

    enum CodingKeys: String, CodingKey {
        case sourceKey = "source_key"
        case name
        case kind
        case bundleID = "bundle_id"
        case deviceModel = "device_model"
    }
}

public struct HealthBridgeSample: Codable, Equatable, Sendable {
    public let clientRecordID: String
    public let sourceKey: String
    public let typeCode: String
    public let startTime: String
    public let endTime: String
    public let value: Double
    public let unit: String
    public let metadata: [String: String]

    public init(
        clientRecordID: String,
        sourceKey: String,
        typeCode: String,
        startTime: String,
        endTime: String,
        value: Double,
        unit: String,
        metadata: [String: String] = [:]
    ) {
        self.clientRecordID = clientRecordID
        self.sourceKey = sourceKey
        self.typeCode = typeCode
        self.startTime = startTime
        self.endTime = endTime
        self.value = value
        self.unit = unit
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case clientRecordID = "client_record_id"
        case sourceKey = "source_key"
        case typeCode = "type_code"
        case startTime = "start_time"
        case endTime = "end_time"
        case value
        case unit
        case metadata
    }
}

public struct HealthBridgeWorkout: Codable, Equatable, Sendable {
    public let clientRecordID: String
    public let sourceKey: String
    public let workoutType: String
    public let startTime: String
    public let endTime: String
    public let durationSeconds: Int
    public let energyKcal: Double?
    public let distanceMeters: Double?

    public init(
        clientRecordID: String,
        sourceKey: String,
        workoutType: String,
        startTime: String,
        endTime: String,
        durationSeconds: Int,
        energyKcal: Double? = nil,
        distanceMeters: Double? = nil
    ) {
        self.clientRecordID = clientRecordID
        self.sourceKey = sourceKey
        self.workoutType = workoutType
        self.startTime = startTime
        self.endTime = endTime
        self.durationSeconds = durationSeconds
        self.energyKcal = energyKcal
        self.distanceMeters = distanceMeters
    }

    enum CodingKeys: String, CodingKey {
        case clientRecordID = "client_record_id"
        case sourceKey = "source_key"
        case workoutType = "workout_type"
        case startTime = "start_time"
        case endTime = "end_time"
        case durationSeconds = "duration_seconds"
        case energyKcal = "energy_kcal"
        case distanceMeters = "distance_meters"
    }
}

public struct HealthBridgeSleepStageInterval: Codable, Equatable, Sendable {
    public let stage: String
    public let startTime: String
    public let endTime: String

    public init(stage: String, startTime: String, endTime: String) {
        self.stage = stage
        self.startTime = startTime
        self.endTime = endTime
    }

    enum CodingKeys: String, CodingKey {
        case stage
        case startTime = "start_time"
        case endTime = "end_time"
    }
}

public struct HealthBridgeSleepSession: Codable, Equatable, Sendable {
    public let clientRecordID: String
    public let sourceKey: String
    public let startTime: String
    public let endTime: String
    public let stageIntervals: [HealthBridgeSleepStageInterval]

    public init(
        clientRecordID: String,
        sourceKey: String,
        startTime: String,
        endTime: String,
        stageIntervals: [HealthBridgeSleepStageInterval]
    ) {
        self.clientRecordID = clientRecordID
        self.sourceKey = sourceKey
        self.startTime = startTime
        self.endTime = endTime
        self.stageIntervals = stageIntervals
    }

    enum CodingKeys: String, CodingKey {
        case clientRecordID = "client_record_id"
        case sourceKey = "source_key"
        case startTime = "start_time"
        case endTime = "end_time"
        case stageIntervals = "stage_intervals"
    }
}

public struct HealthBridgeDeletedRecord: Codable, Equatable, Sendable {
    public let recordFamily: String
    public let sourceKey: String
    public let clientRecordID: String
    public let deletedAt: String

    public init(recordFamily: String, sourceKey: String, clientRecordID: String, deletedAt: String) {
        self.recordFamily = recordFamily
        self.sourceKey = sourceKey
        self.clientRecordID = clientRecordID
        self.deletedAt = deletedAt
    }

    enum CodingKeys: String, CodingKey {
        case recordFamily = "record_family"
        case sourceKey = "source_key"
        case clientRecordID = "client_record_id"
        case deletedAt = "deleted_at"
    }
}

public struct HealthBridgeSyncContext: Codable, Equatable, Sendable {
    public let syncWindow: HealthBridgeTimeWindow
    public let cursors: [HealthBridgeSyncCursor]

    public init(syncWindow: HealthBridgeTimeWindow, cursors: [HealthBridgeSyncCursor]) {
        self.syncWindow = syncWindow
        self.cursors = cursors
    }

    enum CodingKeys: String, CodingKey {
        case syncWindow = "sync_window"
        case cursors
    }
}

public struct HealthBridgeSyncCursor: Codable, Equatable, Sendable {
    public let sourceKey: String
    public let cursorKind: String
    public let cursorValue: String

    public init(sourceKey: String, cursorKind: String, cursorValue: String) {
        self.sourceKey = sourceKey
        self.cursorKind = cursorKind
        self.cursorValue = cursorValue
    }

    enum CodingKeys: String, CodingKey {
        case sourceKey = "source_key"
        case cursorKind = "cursor_kind"
        case cursorValue = "cursor_value"
    }
}
