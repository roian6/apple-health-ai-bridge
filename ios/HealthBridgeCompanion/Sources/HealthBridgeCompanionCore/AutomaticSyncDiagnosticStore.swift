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

    private enum StoreError: Error {
        case privacyMetadataVerificationFailed
    }

    public static let maximumRecordCount = 32
    private static let pendingLaneKeys: Set<String> = [
        AutomaticSyncDiagnosticLane.steps.rawValue,
        AutomaticSyncDiagnosticLane.dailyActivity.rawValue,
        AutomaticSyncDiagnosticLane.workouts.rawValue,
        AutomaticSyncDiagnosticLane.sleep.rawValue,
        AutomaticSyncDiagnosticLane.quantity.rawValue,
    ]

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

    @discardableResult
    public func record(_ record: AutomaticSyncDiagnosticRecord) -> Bool {
        var snapshot = recoveringSnapshot()
        snapshot.records = boundedRecords(snapshot.records + [record])
        return persistFailOpen(snapshot)
    }

    @discardableResult
    public func recordAccepted(_ record: AutomaticSyncDiagnosticRecord) -> Bool {
        var snapshot = recoveringSnapshot()
        snapshot.records = snapshot.records.map {
            $0.runOutcome == .accepted
                ? $0.replacingRunOutcome(.interrupted)
                : $0
        }
        snapshot.records = boundedRecords(snapshot.records + [record])
        return persistFailOpen(snapshot)
    }

    @discardableResult
    public func recordFinal(_ record: AutomaticSyncDiagnosticRecord) -> Bool {
        var snapshot = recoveringSnapshot()
        if let index = snapshot.records.indices.reversed().first(where: {
            snapshot.records[$0].runID == record.runID
        }) {
            snapshot.records[index] = record
        } else {
            snapshot.records = boundedRecords(snapshot.records + [record])
        }
        return persistFailOpen(snapshot)
    }

    @discardableResult
    public func noteObserverCompletionLatency(
        _ latency: TimeInterval,
        runID: UUID
    ) -> Bool {
        var snapshot = recoveringSnapshot()
        guard let index = snapshot.records.indices.reversed().first(where: {
            snapshot.records[$0].runID == runID
                && snapshot.records[$0].wakeSource == .healthKitObserver
                && snapshot.records[$0].observerCompletionLatencyBucket == .pending
        }) else {
            return false
        }
        snapshot.records[index] = snapshot.records[index]
            .replacingObserverCompletionLatency(.bucket(for: latency))
        return persistFailOpen(snapshot)
    }

    public func pendingSnapshot(
        pendingTypeCodes: [String],
        now: Date = Date()
    ) -> AutomaticSyncPendingSnapshot {
        let canonicalTypeCodes = Set(
            GenericQuantityCoveragePolicy.canonicalTypeCodes(for: pendingTypeCodes)
        )
        var currentKeys: [String: AutomaticSyncDiagnosticLane] = [:]
        for typeCode in canonicalTypeCodes {
            let lane = AutomaticSyncDiagnosticLane(typeCode: typeCode)
            currentKeys[lane.rawValue] = lane
        }

        let currentTimeBucket = Int(now.timeIntervalSince1970 / 900)
        var snapshot = recoveringSnapshot()
        snapshot.pendingSinceBucketByLane = snapshot.pendingSinceBucketByLane.filter {
            currentKeys[$0.key] != nil
        }
        var newlyObservedKeys = Set<String>()
        for key in currentKeys.keys
            where snapshot.pendingSinceBucketByLane[key] == nil {
            snapshot.pendingSinceBucketByLane[key] = currentTimeBucket
            newlyObservedKeys.insert(key)
        }
        _ = persistFailOpen(snapshot)

        guard let oldest = snapshot.pendingSinceBucketByLane.min(by: {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value < $1.value
        }),
        let oldestLane = currentKeys[oldest.key] else {
            return .empty
        }
        return AutomaticSyncPendingSnapshot(
            pendingLaneCount: currentKeys.count,
            oldestPendingLane: oldestLane,
            oldestPendingLaneAgeBucket: newlyObservedKeys.contains(oldest.key)
                ? .unknown
                : .bucket(
                    for: TimeInterval(max(0, currentTimeBucket - oldest.value)) * 900
                )
        )
    }

    private func boundedRecords(
        _ records: [AutomaticSyncDiagnosticRecord]
    ) -> [AutomaticSyncDiagnosticRecord] {
        guard records.count > maximumRecordCount else { return records }
        var bounded = Array(records.suffix(maximumRecordCount))
        guard let accepted = records.last(where: { $0.runOutcome == .accepted }),
              !bounded.contains(where: { $0.runID == accepted.runID }) else {
            return bounded
        }
        bounded.removeFirst()
        bounded.insert(accepted, at: 0)
        return bounded
    }


    private func recoveringSnapshot() -> Snapshot {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
        do {
            let snapshot = try JSONDecoder().decode(
                Snapshot.self,
                from: Data(contentsOf: fileURL)
            )
            let allowedPending = snapshot.pendingSinceBucketByLane.filter {
                Self.pendingLaneKeys.contains($0.key)
            }
            if allowedPending.count != snapshot.pendingSinceBucketByLane.count {
                let scrubbed = Snapshot(
                    version: 1,
                    records: snapshot.version == 1
                        ? boundedRecords(snapshot.records)
                        : [],
                    pendingSinceBucketByLane: allowedPending
                )
                _ = persistFailOpen(scrubbed)
                return scrubbed
            }
            guard snapshot.version == 1,
                  snapshot.records.count <= maximumRecordCount,
                  snapshot.pendingSinceBucketByLane.count <= 256 else {
                return .empty
            }
            return snapshot
        } catch {
            return .empty
        }
    }

    private func persistFailOpen(_ snapshot: Snapshot) -> Bool {
        do {
            try persist(snapshot)
            return true
        } catch {
            try? fileManager.removeItem(at: fileURL)
            return false
        }
    }

    private func persist(_ snapshot: Snapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try applyDirectoryPrivacyMetadata(at: directory)

        let temporaryURL = directory.appendingPathComponent(
            "diagnostic-write-\(UUID().uuidString.lowercased()).tmp"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: temporaryURL, options: .atomic)
        try applyFilePrivacyMetadata(at: temporaryURL)
        try verifyFilePrivacyMetadata(at: temporaryURL)

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
        try applyFilePrivacyMetadata(at: fileURL)
        try verifyFilePrivacyMetadata(at: fileURL)
    }

    private func applyDirectoryPrivacyMetadata(at directory: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try excludeFromBackup(directory)
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        #endif
    }

    private func applyFilePrivacyMetadata(at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        try excludeFromBackup(url)
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func excludeFromBackup(_ url: URL) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
    }

    private func verifyFilePrivacyMetadata(at url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == 0o600 else {
            throw StoreError.privacyMetadataVerificationFailed
        }
        let resourceValues = try url.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        guard resourceValues.isExcludedFromBackup == true else {
            throw StoreError.privacyMetadataVerificationFailed
        }
        #if os(iOS)
        guard let protection = attributes[.protectionKey] as? FileProtectionType,
              protection == .completeUntilFirstUserAuthentication else {
            throw StoreError.privacyMetadataVerificationFailed
        }
        #endif
    }
}
