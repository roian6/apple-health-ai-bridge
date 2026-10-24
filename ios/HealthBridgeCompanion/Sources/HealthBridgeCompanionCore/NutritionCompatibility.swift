import Foundation

public enum NutritionSupport: Equatable, Sendable {
    case unknown
    case unsupported
    case supported

    public var notice: String {
        switch self {
        case .unknown:
            "Nutrition support is unknown. Nutrition is held; reconnect or update the Receiver."
        case .unsupported:
            "Nutrition is held. Update the Receiver to enable nutrition delivery."
        case .supported:
            ""
        }
    }

    public static func decode(_ data: Data) -> NutritionSupport {
        struct Declaration: Decodable {
            let schema_id: String
            let batch_schema_id: String
            let nutrition_supported: Bool
        }
        guard let declaration = try? JSONDecoder().decode(Declaration.self, from: data),
              declaration.schema_id == "health_bridge.receiver_capabilities.v1",
              declaration.batch_schema_id == "health_bridge.batch.v1" else { return .unknown }
        return declaration.nutrition_supported ? .supported : .unsupported
    }
}

public enum NutritionCompatibility {
    public static let typeCodes: Set<String> = [
        "dietary_energy_consumed", "dietary_protein", "dietary_carbohydrates",
        "dietary_fat_total", "dietary_fiber"
    ]

    public static func isNutrition(_ code: String) -> Bool {
        // Future dietary types must not inherit the fixed five-type declaration.
        code.hasPrefix("dietary_")
    }

    public static func containsNutrition(_ batch: HealthBridgeBatchV1) -> Bool {
        batch.healthTypes.contains { $0.category == .nutrition || isNutrition($0.typeCode) }
            || batch.samples.contains { isNutrition($0.typeCode) }
            || batch.deletedRecords.contains { $0.clientRecordID.hasPrefix("hk-quantity-dietary-") }
            || batch.sync.cursors.contains { $0.cursorKind.contains("dietary_") }
    }

    public static func permits(_ batch: HealthBridgeBatchV1, support: NutritionSupport) -> Bool {
        guard containsNutrition(batch) else { return true }
        guard support == .supported else { return false }
        return batch.healthTypes.filter { $0.category == .nutrition || isNutrition($0.typeCode) }
            .allSatisfy { typeCodes.contains($0.typeCode) }
            && batch.samples.filter { isNutrition($0.typeCode) }
                .allSatisfy { typeCodes.contains($0.typeCode) }
            && batch.sync.cursors.filter { $0.cursorKind.contains("dietary_") }
                .allSatisfy { cursor in typeCodes.contains { cursor.cursorKind.hasSuffix($0) } }
            && batch.deletedRecords.filter { $0.clientRecordID.hasPrefix("hk-quantity-dietary-") }
                .allSatisfy { record in
                    typeCodes.contains {
                        record.clientRecordID.hasPrefix("hk-quantity-" + $0.replacingOccurrences(of: "_", with: "-") + "-")
                    }
                }
    }

    public static func supportedProjection(_ batch: HealthBridgeBatchV1) -> HealthBridgeBatchV1? {
        let types = batch.healthTypes.filter { $0.category != .nutrition && !isNutrition($0.typeCode) }
        let samples = batch.samples.filter { !isNutrition($0.typeCode) }
        let deletions = batch.deletedRecords.filter {
            !$0.clientRecordID.hasPrefix("hk-quantity-dietary-")
        }
        guard !types.isEmpty || !samples.isEmpty || !batch.workouts.isEmpty
                || !batch.sleepSessions.isEmpty || !deletions.isEmpty else { return nil }
        return HealthBridgeBatchV1(
            schemaID: batch.schemaID, schemaVersion: batch.schemaVersion,
            generatedAt: batch.generatedAt, exportWindow: batch.exportWindow,
            sources: batch.sources, healthTypes: types, samples: samples,
            workouts: batch.workouts, sleepSessions: batch.sleepSessions, deletedRecords: deletions,
            // The original retains every checkpoint. A partial delivery never earns it.
            sync: HealthBridgeSyncContext(syncWindow: batch.sync.syncWindow, cursors: [])
        )
    }
}

struct NutritionPayloadRevision: Equatable, Sendable {
    let number: UInt64
    let size: UInt64
    let modified: Date

    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        self.number = number.uint64Value
        self.size = size.uint64Value
        self.modified = modified
    }
}

struct PreparedNutritionPayload: Sendable {
    let revision: NutritionPayloadRevision
    let containsNutrition: Bool
    let permitsSupported: Bool
    let projection: Data?

    func permits(_ support: NutritionSupport) -> Bool {
        !containsNutrition || (support == .supported && permitsSupported)
    }
}

extension FileOutbox {
    private func nutritionStorageRevision() throws -> [String: NutritionPayloadRevision] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil
        ).map { ($0.lastPathComponent, try NutritionPayloadRevision($0)) })
    }

    /// Capture storage on its owner, transform immutable values off-actor, and
    /// reject a stale result before reconciliation or any projection writes.
    @MainActor
    public func prepareNutritionCompatibility(
        validate: @MainActor () throws -> Void = {}
    ) async throws {
        try Task.checkCancellation()
        try validate()
        try requireUploadAdmission()
        let pending = try pendingItems()
        let revision = try nutritionStorageRevision()
        let payloads = try pending.map { item in
            (item.id, try NutritionPayloadRevision(item.fileURL), try Data(contentsOf: item.fileURL))
        }
        let previous = preparedNutritionPayloads
        let observe = observeNutritionCodec
        let prepared = try await SleepSyncValueWork.run {
            try Dictionary(uniqueKeysWithValues: payloads.map { id, revision, bytes in
                if let retained = previous[id], retained.revision == revision {
                    return (id, retained)
                }
                observe()
                let batch = try JSONDecoder().decode(HealthBridgeBatchV1.self, from: bytes)
                let contains = NutritionCompatibility.containsNutrition(batch)
                let projection = contains
                    ? try NutritionCompatibility.supportedProjection(batch).map { try JSONEncoder().encode($0) }
                    : nil
                return (id, PreparedNutritionPayload(
                    revision: revision, containsNutrition: contains,
                    permitsSupported: NutritionCompatibility.permits(batch, support: .supported),
                    projection: projection
                ))
            })
        }
        try Task.checkCancellation()
        try validate()
        try requireUploadAdmission()
        guard try nutritionStorageRevision() == revision else { throw CancellationError() }
        preparedNutritionPayloads = prepared
    }

    func preparedNutritionPayload(for item: FileOutboxItem) throws -> PreparedNutritionPayload? {
        guard let prepared = preparedNutritionPayloads[item.id] else { return nil }
        guard try NutritionPayloadRevision(item.fileURL) == prepared.revision else {
            throw CancellationError()
        }
        return prepared
    }

    public func containsPreparedNutrition(in items: [FileOutboxItem]) throws -> Bool {
        try items.contains {
            guard let prepared = try preparedNutritionPayload(for: $0) else { throw CancellationError() }
            return prepared.containsNutrition
        }
    }

    /// Selection is read-only: finalizer ownership validation must never create
    /// projections or run payload codecs.
    public func preparedNutritionItems(
        for receiverIdentity: String, support: NutritionSupport
    ) throws -> [FileOutboxItem] {
        try requireUploadAdmission()
        return try pendingItemsForNutritionValidation().prefix { $0.receiverIdentity == receiverIdentity }.filter { item in
            guard let prepared = try preparedNutritionPayload(for: item) else { throw CancellationError() }
            switch item.deliveryState?.phase {
            case .published, .providerObserved, .ackVerified:
                return true
            default:
                return prepared.permits(support)
            }
        }
    }

    /// Retain original payloads and checkpoints; deliver a durable, cursor-free
    /// supported projection once. Replaying originals after upgrade is idempotent.
    public func nutritionCompatibleItems(
        for receiverIdentity: String, support: NutritionSupport
    ) throws -> [FileOutboxItem] {
        try requireUploadAdmission()
        let pending = try pendingItems()
        guard let first = pending.first else { return [] }
        guard first.receiverIdentity == receiverIdentity else {
            throw ReceiverOutboxIdentityError.oldestItemBelongsToDifferentReceiver
        }
        let owned = pending.prefix { $0.receiverIdentity == receiverIdentity }
        let prepared = try owned.map { item in
            guard let value = try preparedNutritionPayload(for: item) else { throw CancellationError() }
            return (item, value)
        }
        for (item, value) in prepared {
            if !value.permits(support), let projection = value.projection {
                try prepareNutritionProjection(for: item, payload: projection)
            }
        }
        return try preparedNutritionItems(for: receiverIdentity, support: support)
    }
}
