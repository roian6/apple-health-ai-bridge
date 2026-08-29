import Foundation

public final class AutomaticSyncDiagnosticStore {
    private struct Snapshot: Codable {
        let version: Int
        var records: [AutomaticSyncDiagnosticRecord]
        var pendingSinceBucketByLane: [String: Int]

        static let empty = Snapshot(
            version: 1,
            records: [],
            pendingSinceBucketByLane: [:]
        )
    }

    public static let maximumRecordCount = 32

    public let fileURL: URL
    private let maximumRecordCount: Int
    private let fileManager: FileManager

    public convenience init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.init(
            fileURL: applicationSupport
                .appendingPathComponent("HealthBridgeCompanion", isDirectory: true)
                .appendingPathComponent("automatic-sync-diagnostics.json"),
            fileManager: fileManager
        )
    }

    public init(
        fileURL: URL,
        maximumRecordCount: Int = AutomaticSyncDiagnosticStore.maximumRecordCount,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.maximumRecordCount = max(1, maximumRecordCount)
        self.fileManager = fileManager
    }

    public var history: [AutomaticSyncDiagnosticRecord] {
        recoveringSnapshot().records
    }

    public var latestRecord: AutomaticSyncDiagnosticRecord? {
        history.last
    }

    public func record(_ record: AutomaticSyncDiagnosticRecord) {
        var snapshot = recoveringSnapshot()
        snapshot.records = Array(
            (snapshot.records + [record]).suffix(maximumRecordCount)
        )
        try? persist(snapshot)
    }

    public func noteObserverCompletionLatency(_ latency: TimeInterval) {
        var snapshot = recoveringSnapshot()
        guard let index = snapshot.records.indices.reversed().first(where: {
            snapshot.records[$0].wakeSource == .healthKitObserver
                && snapshot.records[$0].observerCompletionLatencyBucket == .pending
        }) else {
            return
        }
        snapshot.records[index] = snapshot.records[index]
            .replacingObserverCompletionLatency(.bucket(for: latency))
        try? persist(snapshot)
    }

    public func pendingSnapshot(
        pendingTypeCodes: [String],
        now: Date = Date()
    ) -> AutomaticSyncPendingSnapshot {
        let canonicalTypeCodes = Set(
            GenericQuantityCoveragePolicy.canonicalTypeCodes(for: pendingTypeCodes)
        )
        var currentCounts: [String: Int] = [:]
        for typeCode in canonicalTypeCodes {
            let lane = AutomaticSyncDiagnosticLane(typeCode: typeCode)
            if lane == .quantity {
                currentCounts[lane.rawValue, default: 0] += 1
            } else {
                currentCounts[lane.rawValue] = 1
            }
        }

        let currentTimeBucket = Int(now.timeIntervalSince1970 / 900)
        var snapshot = recoveringSnapshot()
        snapshot.pendingSinceBucketByLane = snapshot.pendingSinceBucketByLane.filter {
            currentCounts[$0.key] != nil
        }
        var newlyObservedLanes = Set<String>()
        for lane in currentCounts.keys
            where snapshot.pendingSinceBucketByLane[lane] == nil {
            snapshot.pendingSinceBucketByLane[lane] = currentTimeBucket
            newlyObservedLanes.insert(lane)
        }
        try? persist(snapshot)

        guard let oldest = snapshot.pendingSinceBucketByLane.min(by: {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value < $1.value
        }),
        let oldestLane = AutomaticSyncDiagnosticLane(rawValue: oldest.key) else {
            return .empty
        }
        return AutomaticSyncPendingSnapshot(
            pendingLaneCount: currentCounts.values.reduce(0, +),
            oldestPendingLane: oldestLane,
            oldestPendingLaneAgeBucket: newlyObservedLanes.contains(oldest.key)
                ? .unknown
                : .bucket(
                    for: TimeInterval(max(0, currentTimeBucket - oldest.value)) * 900
                )
        )
    }

    private func recoveringSnapshot() -> Snapshot {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
        do {
            let snapshot = try JSONDecoder().decode(
                Snapshot.self,
                from: Data(contentsOf: fileURL)
            )
            guard snapshot.version == 1,
                  snapshot.records.count <= maximumRecordCount else {
                return .empty
            }
            return snapshot
        } catch {
            return .empty
        }
    }

    private func persist(_ snapshot: Snapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableFileURL = fileURL
        try mutableFileURL.setResourceValues(resourceValues)
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        #endif
    }
}
