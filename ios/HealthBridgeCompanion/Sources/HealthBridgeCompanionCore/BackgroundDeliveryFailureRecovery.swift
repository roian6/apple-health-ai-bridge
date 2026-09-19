import Foundation

public enum BackgroundRecoveryLane: String, Codable, CaseIterable, Sendable {
    case steps, dailyActivity = "daily_activity", workouts, sleep, quantity

    public init(typeCode: String) {
        switch AutomaticSyncDiagnosticLane(typeCode: typeCode) {
        case .steps: self = .steps
        case .dailyActivity: self = .dailyActivity
        case .workouts: self = .workouts
        case .sleep: self = .sleep
        default: self = .quantity
        }
    }
}

public final class BackgroundObserverAcknowledgement: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?

    public init(_ completion: @escaping () -> Void) {
        self.completion = completion
    }

    public func call() {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?()
    }
}

public enum BackgroundRecoveryDurableState: String, Codable, Sendable {
    case available, unavailable
}

public struct BackgroundObserverPendingDiagnostic: Codable, Equatable, Sendable {
    public let lanes: Set<BackgroundRecoveryLane>
    public let durableState: BackgroundRecoveryDurableState
}
