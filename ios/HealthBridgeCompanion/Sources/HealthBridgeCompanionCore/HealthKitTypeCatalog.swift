import Foundation

public enum HealthKitCatalogObjectKind: String, Codable, Equatable, Sendable {
    case quantity
    case category
    case workout
}

public enum HealthKitMetricAggregation: String, Codable, Equatable, Sendable {
    case sum
    case minMaxAverage = "min_max_average"
    case latest
    case count
    case duration
}

public struct HealthKitTypeCatalogEntry: Codable, Equatable, Sendable {
    public let typeCode: String
    public let displayName: String
    public let healthKitIdentifier: String
    public let objectKind: HealthKitCatalogObjectKind
    public let canonicalUnit: String
    public let sensitivity: HealthBridgeHealthType.Sensitivity
    public let aggregation: HealthKitMetricAggregation
    public let usesDedicatedSyncLane: Bool
    public let backgroundEligible: Bool

    enum CodingKeys: String, CodingKey {
        case typeCode = "type_code"
        case displayName = "display_name"
        case healthKitIdentifier = "healthkit_identifier"
        case objectKind = "object_kind"
        case canonicalUnit = "canonical_unit"
        case sensitivity
        case aggregation
        case usesDedicatedSyncLane = "uses_dedicated_sync_lane"
        case backgroundEligible = "background_eligible"
    }

    public init(
        typeCode: String,
        displayName: String,
        healthKitIdentifier: String,
        objectKind: HealthKitCatalogObjectKind,
        canonicalUnit: String,
        sensitivity: HealthBridgeHealthType.Sensitivity,
        aggregation: HealthKitMetricAggregation,
        usesDedicatedSyncLane: Bool,
        backgroundEligible: Bool
    ) {
        self.typeCode = typeCode
        self.displayName = displayName
        self.healthKitIdentifier = healthKitIdentifier
        self.objectKind = objectKind
        self.canonicalUnit = canonicalUnit
        self.sensitivity = sensitivity
        self.aggregation = aggregation
        self.usesDedicatedSyncLane = usesDedicatedSyncLane
        self.backgroundEligible = backgroundEligible
    }
}

public enum HealthKitTypeCatalog {
    private static func quantityEntry(
        _ typeCode: String,
        _ displayName: String,
        _ healthKitIdentifier: String,
        _ canonicalUnit: String,
        sensitivity: HealthBridgeHealthType.Sensitivity,
        aggregation: HealthKitMetricAggregation,
        backgroundEligible: Bool = true
    ) -> HealthKitTypeCatalogEntry {
        HealthKitTypeCatalogEntry(
            typeCode: typeCode,
            displayName: displayName,
            healthKitIdentifier: healthKitIdentifier,
            objectKind: .quantity,
            canonicalUnit: canonicalUnit,
            sensitivity: sensitivity,
            aggregation: aggregation,
            usesDedicatedSyncLane: false,
            backgroundEligible: backgroundEligible
        )
    }

    private static let directQuantityExpansionEntries: [HealthKitTypeCatalogEntry] = [
        quantityEntry("heart_rate_recovery_one_minute", "Heart Rate Recovery One Minute", "HKQuantityTypeIdentifierHeartRateRecoveryOneMinute", "count/min", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("walking_heart_rate_average", "Walking Heart Rate Average", "HKQuantityTypeIdentifierWalkingHeartRateAverage", "count/min", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("blood_alcohol_content", "Blood Alcohol Content", "HKQuantityTypeIdentifierBloodAlcoholContent", "%", sensitivity: .high, aggregation: .minMaxAverage),
        quantityEntry("blood_glucose", "Blood Glucose", "HKQuantityTypeIdentifierBloodGlucose", "mg/dL", sensitivity: .high, aggregation: .minMaxAverage),
        quantityEntry("blood_pressure_systolic", "Blood Pressure Systolic", "HKQuantityTypeIdentifierBloodPressureSystolic", "mmHg", sensitivity: .high, aggregation: .minMaxAverage),
        quantityEntry("blood_pressure_diastolic", "Blood Pressure Diastolic", "HKQuantityTypeIdentifierBloodPressureDiastolic", "mmHg", sensitivity: .high, aggregation: .minMaxAverage),
        quantityEntry("sleeping_breathing_disturbances", "Sleeping Breathing Disturbances", "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances", "count", sensitivity: .high, aggregation: .sum),
        quantityEntry("peripheral_perfusion_index", "Peripheral Perfusion Index", "HKQuantityTypeIdentifierPeripheralPerfusionIndex", "%", sensitivity: .high, aggregation: .minMaxAverage),
        quantityEntry("forced_vital_capacity", "Forced Vital Capacity", "HKQuantityTypeIdentifierForcedVitalCapacity", "liters", sensitivity: .high, aggregation: .latest),
        quantityEntry("forced_expiratory_volume_1", "Forced Expiratory Volume 1", "HKQuantityTypeIdentifierForcedExpiratoryVolume1", "liters", sensitivity: .high, aggregation: .latest),
        quantityEntry("peak_expiratory_flow_rate", "Peak Expiratory Flow Rate", "HKQuantityTypeIdentifierPeakExpiratoryFlowRate", "L/min", sensitivity: .high, aggregation: .latest),
        quantityEntry("body_temperature", "Body Temperature", "HKQuantityTypeIdentifierBodyTemperature", "°C", sensitivity: .high, aggregation: .minMaxAverage),
        quantityEntry("skin_temperature", "Wrist Temperature", "HKQuantityTypeIdentifierAppleSleepingWristTemperature", "°C", sensitivity: .high, aggregation: .minMaxAverage),
        quantityEntry("six_minute_walk_test_distance", "Six Minute Walk Test Distance", "HKQuantityTypeIdentifierSixMinuteWalkTestDistance", "m", sensitivity: .high, aggregation: .latest),
        quantityEntry("stand_time", "Stand Time", "HKQuantityTypeIdentifierAppleStandTime", "minutes", sensitivity: .moderate, aggregation: .sum),
        quantityEntry("exercise_time", "Exercise Time", "HKQuantityTypeIdentifierAppleExerciseTime", "minutes", sensitivity: .moderate, aggregation: .sum),
        quantityEntry("energy", "Active Energy", "HKQuantityTypeIdentifierActiveEnergyBurned", "kcal", sensitivity: .moderate, aggregation: .sum, backgroundEligible: true),
        quantityEntry("physical_effort", "Physical Effort", "HKQuantityTypeIdentifierPhysicalEffort", "kcal/kg/hr", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("distance_cycling", "Cycling Distance", "HKQuantityTypeIdentifierDistanceCycling", "m", sensitivity: .moderate, aggregation: .sum),
        quantityEntry("distance_swimming", "Swimming Distance", "HKQuantityTypeIdentifierDistanceSwimming", "m", sensitivity: .moderate, aggregation: .sum),
        quantityEntry("distance_downhill_snow_sports", "Downhill Snow Sports Distance", "HKQuantityTypeIdentifierDistanceDownhillSnowSports", "m", sensitivity: .moderate, aggregation: .sum),
        quantityEntry("walking_step_length", "Walking Step Length", "HKQuantityTypeIdentifierWalkingStepLength", "cm", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("walking_speed", "Walking Speed", "HKQuantityTypeIdentifierWalkingSpeed", "m/s", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("walking_double_support_percentage", "Walking Double Support Percentage", "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage", "%", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("walking_asymmetry_percentage", "Walking Asymmetry Percentage", "HKQuantityTypeIdentifierWalkingAsymmetryPercentage", "%", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("walking_steadiness", "Walking Steadiness", "HKQuantityTypeIdentifierAppleWalkingSteadiness", "%", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("stair_descent_speed", "Stair Descent Speed", "HKQuantityTypeIdentifierStairDescentSpeed", "m/s", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("stair_ascent_speed", "Stair Ascent Speed", "HKQuantityTypeIdentifierStairAscentSpeed", "m/s", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("running_power", "Running Power", "HKQuantityTypeIdentifierRunningPower", "watts", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("running_speed", "Running Speed", "HKQuantityTypeIdentifierRunningSpeed", "m/s", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("running_vertical_oscillation", "Running Vertical Oscillation", "HKQuantityTypeIdentifierRunningVerticalOscillation", "cm", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("running_ground_contact_time", "Running Ground Contact Time", "HKQuantityTypeIdentifierRunningGroundContactTime", "ms", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("running_stride_length", "Running Stride Length", "HKQuantityTypeIdentifierRunningStrideLength", "cm", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("swimming_stroke_count", "Swimming Stroke Count", "HKQuantityTypeIdentifierSwimmingStrokeCount", "count", sensitivity: .moderate, aggregation: .sum),
        quantityEntry("underwater_depth", "Underwater Depth", "HKQuantityTypeIdentifierUnderwaterDepth", "m", sensitivity: .high, aggregation: .minMaxAverage),
        quantityEntry("workout_effort_score", "Workout Effort Score", "HKQuantityTypeIdentifierWorkoutEffortScore", "apple_effort_score", sensitivity: .moderate, aggregation: .latest),
        quantityEntry("estimated_workout_effort_score", "Estimated Workout Effort Score", "HKQuantityTypeIdentifierEstimatedWorkoutEffortScore", "apple_effort_score", sensitivity: .moderate, aggregation: .latest),
        quantityEntry("environmental_audio_exposure", "Environmental Audio Exposure", "HKQuantityTypeIdentifierEnvironmentalAudioExposure", "dBASPL", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("headphone_audio_exposure", "Headphone Audio Exposure", "HKQuantityTypeIdentifierHeadphoneAudioExposure", "dBASPL", sensitivity: .moderate, aggregation: .minMaxAverage),
        quantityEntry("uv_exposure", "UV Exposure", "HKQuantityTypeIdentifierUVExposure", "count", sensitivity: .moderate, aggregation: .sum),
        quantityEntry("inhaler_usage", "Inhaler Usage", "HKQuantityTypeIdentifierInhalerUsage", "count", sensitivity: .high, aggregation: .sum),
        quantityEntry("electrodermal_activity", "Electrodermal Activity", "HKQuantityTypeIdentifierElectrodermalActivity", "S", sensitivity: .high, aggregation: .minMaxAverage),
        quantityEntry("push_count", "Push Count", "HKQuantityTypeIdentifierPushCount", "count", sensitivity: .low, aggregation: .sum),
        quantityEntry("atrial_fibrillation_burden", "Atrial Fibrillation Burden", "HKQuantityTypeIdentifierAtrialFibrillationBurden", "%", sensitivity: .high, aggregation: .minMaxAverage),
        quantityEntry("insulin_delivery", "Insulin Delivery", "HKQuantityTypeIdentifierInsulinDelivery", "IU", sensitivity: .high, aggregation: .sum),
        quantityEntry("number_of_times_fallen", "Number of Times Fallen", "HKQuantityTypeIdentifierNumberOfTimesFallen", "count", sensitivity: .high, aggregation: .sum),
        quantityEntry("number_of_alcoholic_beverages", "Number of Alcoholic Beverages", "HKQuantityTypeIdentifierNumberOfAlcoholicBeverages", "count", sensitivity: .high, aggregation: .sum),
        quantityEntry("nike_fuel", "Nike Fuel", "HKQuantityTypeIdentifierNikeFuel", "count", sensitivity: .low, aggregation: .sum),
        quantityEntry("hydration", "Hydration", "HKQuantityTypeIdentifierDietaryWater", "mL", sensitivity: .moderate, aggregation: .sum),
    ]

    public static let entries: [HealthKitTypeCatalogEntry] = [
        HealthKitTypeCatalogEntry(
            typeCode: "steps",
            displayName: "Steps",
            healthKitIdentifier: "HKQuantityTypeIdentifierStepCount",
            objectKind: .quantity,
            canonicalUnit: "count",
            sensitivity: .low,
            aggregation: .sum,
            usesDedicatedSyncLane: true,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "workout",
            displayName: "Workout",
            healthKitIdentifier: "HKWorkoutType",
            objectKind: .workout,
            canonicalUnit: "session",
            sensitivity: .moderate,
            aggregation: .count,
            usesDedicatedSyncLane: true,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "sleep_analysis",
            displayName: "Sleep Analysis",
            healthKitIdentifier: "HKCategoryTypeIdentifierSleepAnalysis",
            objectKind: .category,
            canonicalUnit: "stage",
            sensitivity: .moderate,
            aggregation: .duration,
            usesDedicatedSyncLane: true,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "heart_rate",
            displayName: "Heart Rate",
            healthKitIdentifier: "HKQuantityTypeIdentifierHeartRate",
            objectKind: .quantity,
            canonicalUnit: "bpm",
            sensitivity: .moderate,
            aggregation: .minMaxAverage,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "resting_heart_rate",
            displayName: "Resting Heart Rate",
            healthKitIdentifier: "HKQuantityTypeIdentifierRestingHeartRate",
            objectKind: .quantity,
            canonicalUnit: "bpm",
            sensitivity: .moderate,
            aggregation: .minMaxAverage,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "heart_rate_variability_sdnn",
            displayName: "Heart Rate Variability SDNN",
            healthKitIdentifier: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
            objectKind: .quantity,
            canonicalUnit: "ms",
            sensitivity: .high,
            aggregation: .minMaxAverage,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "oxygen_saturation",
            displayName: "Oxygen Saturation",
            healthKitIdentifier: "HKQuantityTypeIdentifierOxygenSaturation",
            objectKind: .quantity,
            canonicalUnit: "%",
            sensitivity: .high,
            aggregation: .minMaxAverage,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "respiratory_rate",
            displayName: "Respiratory Rate",
            healthKitIdentifier: "HKQuantityTypeIdentifierRespiratoryRate",
            objectKind: .quantity,
            canonicalUnit: "brpm",
            sensitivity: .moderate,
            aggregation: .minMaxAverage,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "height",
            displayName: "Height",
            healthKitIdentifier: "HKQuantityTypeIdentifierHeight",
            objectKind: .quantity,
            canonicalUnit: "cm",
            sensitivity: .high,
            aggregation: .latest,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "weight",
            displayName: "Weight",
            healthKitIdentifier: "HKQuantityTypeIdentifierBodyMass",
            objectKind: .quantity,
            canonicalUnit: "kg",
            sensitivity: .high,
            aggregation: .latest,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "body_mass",
            displayName: "Body Mass",
            healthKitIdentifier: "HKQuantityTypeIdentifierBodyMass",
            objectKind: .quantity,
            canonicalUnit: "kg",
            sensitivity: .high,
            aggregation: .latest,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "body_mass_index",
            displayName: "Body Mass Index",
            healthKitIdentifier: "HKQuantityTypeIdentifierBodyMassIndex",
            objectKind: .quantity,
            canonicalUnit: "kg/m²",
            sensitivity: .high,
            aggregation: .latest,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "lean_body_mass",
            displayName: "Lean Body Mass",
            healthKitIdentifier: "HKQuantityTypeIdentifierLeanBodyMass",
            objectKind: .quantity,
            canonicalUnit: "kg",
            sensitivity: .high,
            aggregation: .latest,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "body_fat_percentage",
            displayName: "Body Fat Percentage",
            healthKitIdentifier: "HKQuantityTypeIdentifierBodyFatPercentage",
            objectKind: .quantity,
            canonicalUnit: "%",
            sensitivity: .high,
            aggregation: .latest,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "waist_circumference",
            displayName: "Waist Circumference",
            healthKitIdentifier: "HKQuantityTypeIdentifierWaistCircumference",
            objectKind: .quantity,
            canonicalUnit: "cm",
            sensitivity: .high,
            aggregation: .latest,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "active_energy",
            displayName: "Active Energy",
            healthKitIdentifier: "HKQuantityTypeIdentifierActiveEnergyBurned",
            objectKind: .quantity,
            canonicalUnit: "kcal",
            sensitivity: .moderate,
            aggregation: .sum,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "basal_energy",
            displayName: "Basal Energy",
            healthKitIdentifier: "HKQuantityTypeIdentifierBasalEnergyBurned",
            objectKind: .quantity,
            canonicalUnit: "kcal",
            sensitivity: .moderate,
            aggregation: .sum,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "distance_walking_running",
            displayName: "Walking + Running Distance",
            healthKitIdentifier: "HKQuantityTypeIdentifierDistanceWalkingRunning",
            objectKind: .quantity,
            canonicalUnit: "m",
            sensitivity: .moderate,
            aggregation: .sum,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "flights_climbed",
            displayName: "Flights Climbed",
            healthKitIdentifier: "HKQuantityTypeIdentifierFlightsClimbed",
            objectKind: .quantity,
            canonicalUnit: "count",
            sensitivity: .low,
            aggregation: .sum,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
        HealthKitTypeCatalogEntry(
            typeCode: "vo2_max",
            displayName: "VO2 Max",
            healthKitIdentifier: "HKQuantityTypeIdentifierVO2Max",
            objectKind: .quantity,
            canonicalUnit: "mL/kg/min",
            sensitivity: .high,
            aggregation: .latest,
            usesDedicatedSyncLane: false,
            backgroundEligible: true
        ),
    ] + directQuantityExpansionEntries

    public static var dedicatedSyncTypeCodes: [String] {
        entries.filter(\.usesDedicatedSyncLane).map(\.typeCode)
    }

    public static func entry(for typeCode: String) -> HealthKitTypeCatalogEntry? {
        entries.first { $0.typeCode == typeCode }
    }

    public static func healthType(forTypeCode typeCode: String) -> HealthBridgeHealthType? {
        entry(for: typeCode).map(healthType(from:))
    }

    public static func healthType(from entry: HealthKitTypeCatalogEntry) -> HealthBridgeHealthType {
        HealthBridgeHealthType(
            typeCode: entry.typeCode,
            displayName: entry.displayName,
            category: category(for: entry),
            defaultUnit: entry.canonicalUnit,
            sensitivity: entry.sensitivity,
            aliases: [entry.healthKitIdentifier]
        )
    }

    private static func category(for entry: HealthKitTypeCatalogEntry) -> HealthBridgeHealthType.Category {
        switch entry.objectKind {
        case .workout:
            return .workout
        case .category:
            if entry.typeCode == "sleep_analysis" {
                return .sleep
            }
            return .activity
        case .quantity:
            switch entry.typeCode {
            case "height",
                 "weight",
                 "body_mass",
                 "body_mass_index",
                 "lean_body_mass",
                 "body_fat_percentage",
                 "waist_circumference",
                 "body_temperature",
                 "skin_temperature":
                return .body
            case "heart_rate",
                 "resting_heart_rate",
                 "heart_rate_variability_sdnn",
                 "heart_rate_recovery_one_minute",
                 "walking_heart_rate_average",
                 "oxygen_saturation",
                 "respiratory_rate",
                 "vo2_max",
                 "blood_alcohol_content",
                 "blood_glucose",
                 "blood_pressure_systolic",
                 "blood_pressure_diastolic",
                 "sleeping_breathing_disturbances",
                 "peripheral_perfusion_index",
                 "forced_vital_capacity",
                 "forced_expiratory_volume_1",
                 "peak_expiratory_flow_rate",
                 "atrial_fibrillation_burden",
                 "insulin_delivery":
                return .heart
            default:
                return .activity
            }
        }
    }
}
