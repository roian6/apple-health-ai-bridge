import Foundation

public struct GenericQuantityCoveragePlan: Equatable, Sendable {
    public let availableEntries: [HealthKitTypeCatalogEntry]
    public let unsupportedTypeCodes: [String]
    public let requiresReadPermission: Bool
    public let containsHighSensitivityMetrics: Bool
    public let containsHighVolumeMetrics: Bool
    public let maximumForegroundWindowDays: Int
    public let permissionSummary: String

    public init(
        availableEntries: [HealthKitTypeCatalogEntry],
        unsupportedTypeCodes: [String],
        requiresReadPermission: Bool,
        containsHighSensitivityMetrics: Bool,
        containsHighVolumeMetrics: Bool,
        maximumForegroundWindowDays: Int,
        permissionSummary: String
    ) {
        self.availableEntries = availableEntries
        self.unsupportedTypeCodes = unsupportedTypeCodes
        self.requiresReadPermission = requiresReadPermission
        self.containsHighSensitivityMetrics = containsHighSensitivityMetrics
        self.containsHighVolumeMetrics = containsHighVolumeMetrics
        self.maximumForegroundWindowDays = maximumForegroundWindowDays
        self.permissionSummary = permissionSummary
    }
}

public enum GenericQuantityCoveragePolicy {
    public static let defaultMaximumForegroundWindowDays = 7
    public static let highVolumeMaximumForegroundWindowDays = 1
    public static let legacyCanonicalTypeCodeAliases: [String: String] = [
        "active_energy": "energy",
        "body_mass": "weight",
    ]
    public static let activityBasicsTypeCodes: [String] = [
        "basal_energy",
        "distance_walking_running",
        "energy",
        "flights_climbed",
    ]

    public static let highVolumeTypeCodes: Set<String> = [
        "heart_rate",
        "oxygen_saturation",
        "respiratory_rate",
    ]

    public static let sparseFullHistoryTypeCodes: Set<String> = [
        "body_fat_percentage",
        "body_mass",
        "body_mass_index",
        "height",
        "lean_body_mass",
        "waist_circumference",
        "weight",
    ]

    public static func supportedQuantityEntries() -> [HealthKitTypeCatalogEntry] {
        HealthKitTypeCatalog.entries
            .filter { entry in
                entry.objectKind == .quantity && !entry.usesDedicatedSyncLane
                    && canonicalTypeCode(for: entry.typeCode) == entry.typeCode
            }
            .sorted { $0.typeCode < $1.typeCode }
    }

    public static func canonicalTypeCode(for typeCode: String) -> String {
        legacyCanonicalTypeCodeAliases[typeCode] ?? typeCode
    }

    public static func canonicalTypeCodes(for typeCodes: [String]) -> [String] {
        Array(Set(typeCodes.map(canonicalTypeCode(for:))))
            .sorted()
    }

    public static func canonicalSupportedTypeCodes(_ typeCodes: [String]) -> [String] {
        coveragePlan(availableTypeCodes: typeCodes)
            .availableEntries
            .map(\.typeCode)
    }

    public static func activityBasicsEntries() -> [HealthKitTypeCatalogEntry] {
        let typeCodeSet = Set(activityBasicsTypeCodes)
        return supportedQuantityEntries()
            .filter { typeCodeSet.contains($0.typeCode) }
            .sorted { $0.typeCode < $1.typeCode }
    }

    public static func coveragePlan(
        availableTypeCodes: [String]
    ) -> GenericQuantityCoveragePlan {
        let supportedEntries = supportedQuantityEntries()
        let entriesByTypeCode = Dictionary(
            uniqueKeysWithValues: supportedEntries.map { ($0.typeCode, $0) }
        )
        let canonicalAvailableTypeCodes = canonicalTypeCodes(for: availableTypeCodes)
        let availableEntries = canonicalAvailableTypeCodes
            .compactMap { entriesByTypeCode[$0] }
            .sorted { $0.typeCode < $1.typeCode }
        let availableTypeCodeSet = Set(availableEntries.map(\.typeCode))
        let unsupportedTypeCodes = Array(Set(availableTypeCodes))
            .filter { !availableTypeCodeSet.contains(canonicalTypeCode(for: $0)) }
            .sorted()
        let containsHighSensitivity = availableEntries.contains {
            $0.sensitivity == .high
        }
        let containsHighVolume = availableEntries.contains {
            highVolumeTypeCodes.contains($0.typeCode)
        }
        return GenericQuantityCoveragePlan(
            availableEntries: availableEntries,
            unsupportedTypeCodes: unsupportedTypeCodes,
            requiresReadPermission: !availableEntries.isEmpty,
            containsHighSensitivityMetrics: containsHighSensitivity,
            containsHighVolumeMetrics: containsHighVolume,
            maximumForegroundWindowDays: containsHighVolume
                ? highVolumeMaximumForegroundWindowDays
                : defaultMaximumForegroundWindowDays,
            permissionSummary: permissionSummary(
                availableEntries: availableEntries,
                containsHighSensitivity: containsHighSensitivity,
                containsHighVolume: containsHighVolume
            )
        )
    }

    private static func permissionSummary(
        availableEntries: [HealthKitTypeCatalogEntry],
        containsHighSensitivity: Bool,
        containsHighVolume: Bool
    ) -> String {
        guard !availableEntries.isEmpty else {
            return "No runtime-available supported quantity data is available on this iPhone."
        }
        let metricNames = availableEntries.map(\.displayName).joined(separator: ", ")
        var parts = [
            "Supported quantity data in scope: \(metricNames).",
            "The app asks iOS for read-only access and sends allowed data only to your connected local bridge.",
            "Apple Health permissions control which values iOS allows the app to read. Turn off Automatic Sync to stop automatic transfers.",
        ]
        if containsHighSensitivity {
            parts.append(
                "Some supported items are sensitive health data. Apple Health permissions determine whether iOS makes them available to your local tools."
            )
        }
        if containsHighVolume {
            parts.append(
                "High-frequency items use a shorter Sync Now window to limit processing and upload size."
            )
        }
        return parts.joined(separator: " ")
    }
}
