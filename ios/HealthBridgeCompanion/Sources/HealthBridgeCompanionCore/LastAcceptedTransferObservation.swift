import Foundation

/// Evidence observed locally, not sample freshness or the original delivery time.
public struct LastAcceptedTransferObservation: Equatable, Codable, Sendable {
    public enum EvidenceKind: String, Codable, Sendable {
        case directResponse
        case mailboxCommit
    }

    public let bindingID: String
    public let generation: String
    public let observedAt: Date
    public let evidenceKind: EvidenceKind

    public init(
        bindingID: String,
        generation: String,
        observedAt: Date,
        evidenceKind: EvidenceKind
    ) {
        self.bindingID = bindingID
        self.generation = generation
        self.observedAt = observedAt
        self.evidenceKind = evidenceKind
    }
}

/// Best-effort metadata only. Callers serialize access and validate current scope
/// before recording; accepting a transfer does not depend on recording it here.
public final class LastAcceptedTransferObservationStore {
    public static let didChange = Notification.Name("healthBridge.acceptedTransferObservationDidChange")

    private struct StoredRecord: Codable {
        let version: Int
        let observation: LastAcceptedTransferObservation
        let resetEpoch: UUID?
    }

    private static let key = "healthBridge.lastAcceptedTransferObservation"
    private let userDefaults: UserDefaults
    private let resetEpochURL: URL

    public convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.init(
            userDefaults: .standard,
            resetEpochURL: support.appendingPathComponent("HealthBridgeCompanion", isDirectory: true)
                .appendingPathComponent("accepted-transfer-reset-epoch")
        )
    }

    public init(userDefaults: UserDefaults, resetEpochURL: URL) {
        self.userDefaults = userDefaults
        self.resetEpochURL = resetEpochURL
    }

    /// Replaces the sole record. UserDefaults does not acknowledge durable writes.
    public func record(_ observation: LastAcceptedTransferObservation) {
        do {
            let record = StoredRecord(version: 1, observation: observation, resetEpoch: try loadResetEpoch())
            userDefaults.set(try JSONEncoder().encode(record), forKey: Self.key)
        } catch {
            return // Recording display metadata is best effort.
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    public func load(
        bindingID: String,
        generation: String
    ) -> LastAcceptedTransferObservation? {
        guard let data = userDefaults.data(forKey: Self.key) else { return nil }
        do {
            let record = try JSONDecoder().decode(StoredRecord.self, from: data)
            guard record.version == 1,
                  record.resetEpoch == (try loadResetEpoch()),
                  record.observation.bindingID == bindingID,
                  record.observation.generation == generation else { return nil }
            return record.observation
        } catch {
            return nil
        }
    }

    /// A replacement epoch invalidates old evidence even if defaults are replayed.
    public func clear() throws {
        try FileManager.default.createDirectory(
            at: resetEpochURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(UUID()).write(to: resetEpochURL, options: .atomic)
        userDefaults.removeObject(forKey: Self.key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func loadResetEpoch() throws -> UUID? {
        do {
            return try JSONDecoder().decode(UUID.self, from: Data(contentsOf: resetEpochURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }
}
