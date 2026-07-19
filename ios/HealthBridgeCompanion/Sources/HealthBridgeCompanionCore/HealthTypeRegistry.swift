import Foundation

public struct HealthBridgeHealthType: Codable, Equatable, Hashable, Sendable {
    public enum Category: String, Codable, Equatable, Hashable, Sendable {
        case activity
        case body
        case heart
        case sleep
        case workout
    }

    public enum Sensitivity: String, Codable, Equatable, Hashable, Sendable {
        case low
        case moderate
        case high
    }

    public let typeCode: String
    public let displayName: String
    public let category: Category
    public let defaultUnit: String
    public let sensitivity: Sensitivity
    public let aliases: [String]

    public init(
        typeCode: String,
        displayName: String,
        category: Category,
        defaultUnit: String,
        sensitivity: Sensitivity,
        aliases: [String]
    ) {
        self.typeCode = typeCode
        self.displayName = displayName
        self.category = category
        self.defaultUnit = defaultUnit
        self.sensitivity = sensitivity
        self.aliases = aliases
    }

    enum CodingKeys: String, CodingKey {
        case typeCode = "type_code"
        case displayName = "display_name"
        case category
        case defaultUnit = "default_unit"
        case sensitivity
        case aliases
    }

    public static let steps = HealthBridgeHealthType(
        typeCode: "steps",
        displayName: "Steps",
        category: .activity,
        defaultUnit: "count",
        sensitivity: .low,
        aliases: ["HKQuantityTypeIdentifierStepCount"]
    )

    public static let heartRate = HealthBridgeHealthType(
        typeCode: "heart_rate",
        displayName: "Heart Rate",
        category: .heart,
        defaultUnit: "bpm",
        sensitivity: .moderate,
        aliases: ["HKQuantityTypeIdentifierHeartRate"]
    )

    public static let weight = HealthBridgeHealthType(
        typeCode: "weight",
        displayName: "Weight",
        category: .body,
        defaultUnit: "kg",
        sensitivity: .high,
        aliases: ["HKQuantityTypeIdentifierBodyMass", "body_mass"]
    )

    public static let sleepAnalysis = HealthBridgeHealthType(
        typeCode: "sleep_analysis",
        displayName: "Sleep Analysis",
        category: .sleep,
        defaultUnit: "stage",
        sensitivity: .moderate,
        aliases: ["HKCategoryTypeIdentifierSleepAnalysis"]
    )

    public static let workouts = HealthBridgeHealthType(
        typeCode: "workout",
        displayName: "Workout",
        category: .workout,
        defaultUnit: "session",
        sensitivity: .moderate,
        aliases: ["HKWorkoutType"]
    )

    public static let canonicalTypes: [HealthBridgeHealthType] = [
        .steps,
        .heartRate,
        .weight,
        .sleepAnalysis,
        .workouts,
    ]

    public static let dedicatedSyncTypes: [HealthBridgeHealthType] = [
        .steps,
        .workouts,
        .sleepAnalysis,
    ]

    public static func resolve(alias: String) -> HealthBridgeHealthType? {
        canonicalTypes.first { $0.aliases.contains(alias) }
    }
}
