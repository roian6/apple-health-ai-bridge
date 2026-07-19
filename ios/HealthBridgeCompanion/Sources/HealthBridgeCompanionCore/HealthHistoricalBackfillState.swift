import Foundation

public struct HealthHistoricalBackfillState: Equatable, Codable, Sendable {
    public let selectedTypeCodes: [String]
    public let completedTypeCodes: [String]
    public let olderThanCursorsByTypeCode: [String: Date]
    public let historyDepth: HealthHistoryDepth

    public init(
        selectedTypeCodes: [String] = [],
        completedTypeCodes: [String] = [],
        olderThanCursorsByTypeCode: [String: Date] = [:],
        historyDepth: HealthHistoryDepth = .allAvailable
    ) {
        self.selectedTypeCodes = selectedTypeCodes.sorted()
        self.completedTypeCodes = completedTypeCodes.sorted()
        self.olderThanCursorsByTypeCode = olderThanCursorsByTypeCode
        self.historyDepth = historyDepth.sanitized
    }

    public var isComplete: Bool {
        !selectedTypeCodes.isEmpty && Set(completedTypeCodes).isSuperset(of: selectedTypeCodes)
    }

    public var incompleteTypeCodes: [String] {
        let completed = Set(completedTypeCodes)
        return selectedTypeCodes.filter { !completed.contains($0) }
    }
}

public enum HealthHistoricalBackfillPolicy {
    public static func sparseAllAvailableTypeCodes(
        selectedTypeCodes: [String],
        historyDepth: HealthHistoryDepth
    ) -> [String] {
        guard historyDepth.sanitized == .allAvailable else { return [] }
        return GenericQuantityCoveragePolicy.coveragePlan(availableTypeCodes: selectedTypeCodes)
            .availableEntries
            .map(\.typeCode)
            .filter { GenericQuantityCoveragePolicy.sparseFullHistoryTypeCodes.contains($0) }
            .sorted()
    }
}

public enum HealthHistoricalBackfillPresentation {
    public static func summary(state: HealthHistoricalBackfillState) -> String {
        guard !state.selectedTypeCodes.isEmpty else {
            return "Additional history sync has not run yet. No sample values are shown."
        }
        let completed = Set(state.completedTypeCodes)
        let completeCount = state.selectedTypeCodes.filter { completed.contains($0) }.count
        let totalCount = state.selectedTypeCodes.count
        if completeCount == totalCount {
            return "Additional history sync complete for \(totalCount) selected item(s). No sample values are shown."
        }
        let remainingCount = totalCount - completeCount
        return "Additional history sync progress: \(completeCount)/\(totalCount) selected item(s) complete. \(remainingCount) item(s) remaining. No sample values are shown."
    }
}

public final class HealthHistoricalBackfillStateStore {
    private enum Key {
        static let state = "healthBridge.historicalBackfill.state"
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public var state: HealthHistoricalBackfillState {
        guard let data = userDefaults.data(forKey: Key.state),
              let decoded = try? JSONDecoder().decode(HealthHistoricalBackfillState.self, from: data)
        else {
            return HealthHistoricalBackfillState()
        }
        return HealthHistoricalBackfillState(
            selectedTypeCodes: sanitize(decoded.selectedTypeCodes),
            completedTypeCodes: sanitize(decoded.completedTypeCodes),
            olderThanCursorsByTypeCode: decoded.olderThanCursorsByTypeCode,
            historyDepth: decoded.historyDepth
        )
    }

    public var incompleteTypeCodes: [String] {
        state.incompleteTypeCodes
    }

    public func start(typeCodes: [String], historyDepth: HealthHistoryDepth) {
        save(HealthHistoricalBackfillState(
            selectedTypeCodes: sanitize(typeCodes),
            completedTypeCodes: [],
            olderThanCursorsByTypeCode: [:],
            historyDepth: historyDepth
        ))
    }

    public func saveOlderThanCursor(_ cursor: Date, for typeCode: String) {
        guard !typeCode.isEmpty, state.selectedTypeCodes.contains(typeCode) else { return }
        let next = state
        var cursors = next.olderThanCursorsByTypeCode
        cursors[typeCode] = cursor
        save(HealthHistoricalBackfillState(
            selectedTypeCodes: next.selectedTypeCodes,
            completedTypeCodes: next.completedTypeCodes,
            olderThanCursorsByTypeCode: cursors,
            historyDepth: next.historyDepth
        ))
    }

    public func markCompleted(_ typeCode: String) {
        guard !typeCode.isEmpty, state.selectedTypeCodes.contains(typeCode) else { return }
        var completed = Set(state.completedTypeCodes)
        completed.insert(typeCode)
        save(HealthHistoricalBackfillState(
            selectedTypeCodes: state.selectedTypeCodes,
            completedTypeCodes: Array(completed),
            olderThanCursorsByTypeCode: state.olderThanCursorsByTypeCode,
            historyDepth: state.historyDepth
        ))
    }

    public func reset() {
        userDefaults.removeObject(forKey: Key.state)
    }

    private func save(_ state: HealthHistoricalBackfillState) {
        if let data = try? JSONEncoder().encode(state) {
            userDefaults.set(data, forKey: Key.state)
        }
    }

    private func sanitize(_ typeCodes: [String]) -> [String] {
        Array(Set(typeCodes.filter { !$0.isEmpty })).sorted()
    }
}
