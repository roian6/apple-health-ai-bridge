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
/// before recording; no transport outcome may depend on this store.
public final class LastAcceptedTransferObservationStore {
    public static let didChange = Notification.Name("healthBridge.acceptedTransferObservationDidChange")

    private struct StoredRecord: Codable {
        let version: Int
        let observation: LastAcceptedTransferObservation
    }

    private static let key = "healthBridge.lastAcceptedTransferObservation"
    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Replaces the sole record. UserDefaults does not acknowledge durable writes.
    public func record(_ observation: LastAcceptedTransferObservation) {
        let record = StoredRecord(version: 1, observation: observation)
        guard let data = try? JSONEncoder().encode(record) else {
            clear()
            return
        }
        userDefaults.set(data, forKey: Self.key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    public func load(
        bindingID: String,
        generation: String
    ) -> LastAcceptedTransferObservation? {
        guard let data = userDefaults.data(forKey: Self.key),
              let record = try? JSONDecoder().decode(StoredRecord.self, from: data),
              record.version == 1,
              record.observation.bindingID == bindingID,
              record.observation.generation == generation else {
            return nil
        }
        return record.observation
    }

    public func clear() {
        userDefaults.removeObject(forKey: Self.key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
