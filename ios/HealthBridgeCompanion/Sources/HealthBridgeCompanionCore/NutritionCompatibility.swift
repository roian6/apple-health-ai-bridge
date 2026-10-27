import Foundation

public enum NutritionSupport: Equatable, Sendable {
    case unknown
    case unsupported
    case supported

    public var notice: String {
        switch self {
        case .unknown:
            "Nutrition support is unknown. Nutrition is held until the Receiver declares support."
        case .unsupported:
            "Nutrition is held. Update the Receiver to enable nutrition delivery."
        case .supported:
            ""
        }
    }

    public init(capabilities: ReceiverCapabilities?) {
        guard let capabilities else { self = .unknown; return }
        self = capabilities.nutritionSupported ? .supported : .unsupported
    }

    public static func decode(_ data: Data) -> NutritionSupport {
        NutritionSupport(capabilities: ReceiverCapabilities.decodeHTTP(data))
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

    static func nutritionRemainder(_ batch: HealthBridgeBatchV1) -> HealthBridgeBatchV1 {
        let types = batch.healthTypes.filter { $0.category == .nutrition || isNutrition($0.typeCode) }
        return HealthBridgeBatchV1(
            schemaID: batch.schemaID, schemaVersion: batch.schemaVersion,
            generatedAt: batch.generatedAt, exportWindow: batch.exportWindow,
            sources: batch.sources,
            healthTypes: types.isEmpty ? batch.healthTypes : types,
            samples: batch.samples.filter { isNutrition($0.typeCode) },
            workouts: [], sleepSessions: [],
            deletedRecords: batch.deletedRecords.filter { $0.clientRecordID.hasPrefix("hk-quantity-dietary-") },
            sync: batch.sync
        )
    }
}

public enum FileOutboxNutritionError: LocalizedError {
    case legacyProjectionRequiresRecovery
    case invalidSplit

    public var errorDescription: String? {
        switch self {
        case .legacyProjectionRequiresRecovery:
            "An older mixed nutrition batch is held because its delivery history is incomplete. Pending data is kept. Contact support before resetting private sync state."
        case .invalidSplit:
            "The pending nutrition delivery could not be verified. Pending data is kept."
        }
    }
}

enum NutritionSplitBoundary: CaseIterable {
    case intentPersisted
    case supportedPayloadInstalled
    case remainderPayloadInstalled
    case manifestCommitted
    case acceptancePersisted
    case retirementPersisted
    case parentRemoved
}

struct NutritionCursorKey: Codable, Hashable, Sendable {
    let sourceKey: String
    let cursorKind: String
}

enum NutritionPendingGroup {
    case original(FileOutboxItem, permitsSplit: Bool)
    case split(supported: FileOutboxItem?, remainder: FileOutboxItem?, cursors: Set<NutritionCursorKey>)
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
    let remainder: Data?
    let cursors: Set<NutritionCursorKey>

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
                    projection: projection,
                    remainder: projection == nil ? nil : try JSONEncoder().encode(
                        NutritionCompatibility.nutritionRemainder(batch)
                    ),
                    cursors: Set(batch.sync.cursors.map {
                        NutritionCursorKey(sourceKey: $0.sourceKey, cursorKind: $0.cursorKind)
                    })
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
        var blockedCursors: Set<NutritionCursorKey> = []
        var legacyHold = false
        var selected: [FileOutboxItem] = []
        for group in try nutritionPendingGroups(for: receiverIdentity) {
            switch group {
            case .original(let item, let permitsSplit):
                guard let value = try preparedNutritionPayload(for: item) else { throw CancellationError() }
                // Preserve the exact existing ACK path, independently of discovery.
                switch item.deliveryState?.phase {
                case .published, .providerObserved, .ackVerified:
                    selected.append(item)
                    continue
                default: break
                }
                if value.projection != nil && !permitsSplit {
                    legacyHold = true
                    blockedCursors.formUnion(value.cursors)
                } else if value.permits(support), blockedCursors.isDisjoint(with: value.cursors) {
                    selected.append(item)
                } else {
                    blockedCursors.formUnion(value.cursors)
                }
            case .split(let supported, let remainder, let cursors):
                guard blockedCursors.isDisjoint(with: cursors) else {
                    blockedCursors.formUnion(cursors)
                    continue
                }
                if let supported { return selected.isEmpty ? [supported] : selected }
                if let remainder {
                    guard let value = try preparedNutritionPayload(for: remainder) else { throw CancellationError() }
                    if value.permits(support) { return selected.isEmpty ? [remainder] : selected }
                    blockedCursors.formUnion(cursors)
                }
            }
        }
        if selected.isEmpty && legacyHold { throw FileOutboxNutritionError.legacyProjectionRequiresRecovery }
        return selected
    }

    /// Keep the collection owner immutable, and deliver linked children in its
    /// original position. A committed split never replays the mixed original.
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
        for item in owned {
            guard let value = try preparedNutritionPayload(for: item) else { throw CancellationError() }
            if !value.permits(support), let projection = value.projection,
               let remainder = value.remainder, item.mailboxBinding == nil {
                try prepareNutritionProjection(
                    for: item, payloads: (projection, remainder), cursors: value.cursors
                )
            }
        }
        return try preparedNutritionItems(for: receiverIdentity, support: support)
    }
}
