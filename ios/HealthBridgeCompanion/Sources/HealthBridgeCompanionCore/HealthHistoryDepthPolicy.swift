import Foundation

public enum HealthHistoryDepth: Equatable, Codable, Sendable {
    case allAvailable
    case lastDays(Int)
    case sinceDate(Date)

    public func lowerBoundDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .allAvailable:
            return nil
        case let .lastDays(days):
            guard days > 0 else { return nil }
            let startOfToday = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: -days, to: startOfToday)
                ?? startOfToday.addingTimeInterval(TimeInterval(-days * 24 * 60 * 60))
        case let .sinceDate(date):
            return date
        }
    }

    public var sanitized: HealthHistoryDepth {
        switch self {
        case .allAvailable:
            return .allAvailable
        case let .lastDays(days):
            return days > 0 ? .lastDays(days) : .allAvailable
        case let .sinceDate(date):
            return date.timeIntervalSince1970.isFinite ? .sinceDate(date) : .allAvailable
        }
    }
}

public struct HealthHistoryDepthOptionRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let historyDepth: HealthHistoryDepth
    public let isSelected: Bool

    public init(
        id: String,
        title: String,
        detail: String,
        historyDepth: HealthHistoryDepth,
        isSelected: Bool
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.historyDepth = historyDepth.sanitized
        self.isSelected = isSelected
    }
}

public enum HealthHistoryDepthPresentation {
    private static let options: [(id: String, title: String, detail: String, historyDepth: HealthHistoryDepth)] = [
        (
            id: "all_available",
            title: "All",
            detail: "Widest available range; high-volume data stays bounded.",
            historyDepth: .allAvailable
        ),
        (
            id: "last_365_days",
            title: "1 year",
            detail: "Last 365 days.",
            historyDepth: .lastDays(365)
        ),
        (
            id: "last_180_days",
            title: "180 days",
            detail: "Last 180 days.",
            historyDepth: .lastDays(180)
        ),
        (
            id: "last_90_days",
            title: "90 days",
            detail: "Last 90 days.",
            historyDepth: .lastDays(90)
        ),
        (
            id: "last_30_days",
            title: "30 days",
            detail: "Fastest first setup.",
            historyDepth: .lastDays(30)
        ),
    ]

    public static func optionRows(selected: HealthHistoryDepth) -> [HealthHistoryDepthOptionRow] {
        let selected = selected.sanitized
        return options.map { option in
            HealthHistoryDepthOptionRow(
                id: option.id,
                title: option.title,
                detail: option.detail,
                historyDepth: option.historyDepth,
                isSelected: option.historyDepth == selected
            )
        }
    }

    public static func historyDepth(forOptionID optionID: String) -> HealthHistoryDepth {
        options.first { $0.id == optionID }?.historyDepth ?? .allAvailable
    }

    public static func optionID(for historyDepth: HealthHistoryDepth) -> String {
        let sanitized = historyDepth.sanitized
        return options.first { $0.historyDepth == sanitized }?.id ?? "all_available"
    }

    public static func summary(selected: HealthHistoryDepth) -> String {
        switch selected.sanitized {
        case .allAvailable:
            return "All"
        case let .lastDays(days):
            return "Last \(days) days"
        case .sinceDate:
            return "Custom range"
        }
    }
}

public final class HealthHistoryDepthSelectionStore {
    private enum Key {
        static let historyDepth = "healthBridge.historyDepth.selection"
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public var historyDepth: HealthHistoryDepth {
        guard let data = userDefaults.data(forKey: Key.historyDepth),
              let decoded = try? JSONDecoder().decode(HealthHistoryDepth.self, from: data)
        else {
            return .allAvailable
        }
        return decoded.sanitized
    }

    public func saveHistoryDepth(_ historyDepth: HealthHistoryDepth) {
        let sanitized = historyDepth.sanitized
        if let data = try? JSONEncoder().encode(sanitized) {
            userDefaults.set(data, forKey: Key.historyDepth)
        }
    }

    public func clear() {
        userDefaults.removeObject(forKey: Key.historyDepth)
    }
}
