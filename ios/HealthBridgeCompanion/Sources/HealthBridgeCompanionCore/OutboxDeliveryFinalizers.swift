import Foundation

public protocol OutboxDeliveryCommitFinalizing {
    @MainActor func isFinalized(_ context: OutboxDeliveryFinalizationContext) async throws -> Bool
    @MainActor func finalize(_ context: OutboxDeliveryFinalizationContext) async throws
}

public struct OutboxDeliveryNoopFinalizer: OutboxDeliveryCommitFinalizing {
    public init() {}

    public func isFinalized(_: OutboxDeliveryFinalizationContext) throws -> Bool {
        true
    }

    public func finalize(_: OutboxDeliveryFinalizationContext) throws {}
}

#if !HEALTH_BRIDGE_MAILBOX_QA
public final class OutboxDeliveryCursorFinalizer: OutboxDeliveryCommitFinalizing {
    private let outbox: FileOutbox
    private let cursorStore: any SyncCursorStoring
    private let proofStore: CoreLaneUploadProofStore?
    private let pendingGenerationStore: BackgroundSyncSettingsStore?

    public init(
        outbox: FileOutbox,
        cursorStore: any SyncCursorStoring,
        proofStore: CoreLaneUploadProofStore? = nil,
        pendingGenerationStore: BackgroundSyncSettingsStore? = nil
    ) {
        self.outbox = outbox
        self.cursorStore = cursorStore
        self.proofStore = proofStore
        self.pendingGenerationStore = pendingGenerationStore
    }

    public func isFinalized(
        _ context: OutboxDeliveryFinalizationContext
    ) throws -> Bool {
        try finalizationRecord(for: context) == nil
    }

    public func finalize(_ context: OutboxDeliveryFinalizationContext) throws {
        guard let record = try finalizationRecord(for: context) else { return }
        try finalize(record)
    }

    @discardableResult
    @MainActor
    public func recordDirectReceiverAcceptanceForSync(
        descriptor: DirectUploadCompletionDescriptor,
        sleepStore: @autoclosure () throws -> any SleepSyncManifestStoring,
        validate: @escaping @MainActor () throws -> Void,
        onNewAcceptance: @MainActor () -> Void = {}
    ) async throws -> Bool {
        try await outbox.prepareNutritionCompatibility(validate: validate)
        let item = try outbox.pendingItem(id: descriptor.itemID)
        if let item, item.receiverIdentity != descriptor.receiverBindingID {
            throw ReceiverOutboxIdentityError.oldestItemBelongsToDifferentReceiver
        }
        let prepared = try item.flatMap { try outbox.preparedNutritionPayload(for: $0) }
        if item == nil,
           let record = try outbox.directFinalizationRecordReady(
               receiverIdentity: descriptor.receiverBindingID,
               where: { Self.isSleepRecord($0) && $1.contains(descriptor.itemID) }
           ) {
            guard try await recoverDirectSleepAcknowledgment(
                record, receiverBindingID: descriptor.receiverBindingID,
                receiverGeneration: descriptor.receiverGeneration, sleepStore: sleepStore(), validate: validate
            ) else {
                throw OutboxDeliveryCoordinatorError.ownershipMismatch
            }
            return true
        }
        // If the payload is gone, only a durable ACK from this path can prove
        // that Sleep was checked before retirement.
        if prepared?.mayContainSleep != false,
           try !outbox.hasDirectAcknowledgmentWithSleepChecked(
               itemID: descriptor.itemID, receiverIdentity: descriptor.receiverBindingID
           ) {
            try await commitDirectSleepIfPending(
                descriptor: descriptor, item: item, sleepStore: sleepStore(),
                validate: {
                    try validate()
                    guard try self.outbox.pendingItem(id: descriptor.itemID) == item else {
                        throw CancellationError()
                    }
                    if let item { _ = try self.outbox.preparedNutritionPayload(for: item) }
                }
            )
        }
        try Task.checkCancellation()
        try validate()
        let record = try outbox.recordDirectUploadAcceptance(
            itemID: descriptor.itemID, receiverIdentity: descriptor.receiverBindingID,
            sleepChecked: item != nil,
            onNewAcceptance: { onNewAcceptance() }
        )
        guard let record else { return false }
        return try finalizeDirect(record)
    }

    @MainActor
    private func commitDirectSleepIfPending(
        descriptor: DirectUploadCompletionDescriptor,
        item: FileOutboxItem?,
        sleepStore: any SleepSyncManifestStoring,
        validate: @escaping @MainActor () throws -> Void
    ) async throws {
        let revision = try sleepStore.revisionForSync()
        let check = { @MainActor in
            try Task.checkCancellation()
            try validate()
            guard try sleepStore.revisionForSync() == revision else { throw CancellationError() }
        }
        if let pending = try await sleepStore.loadPendingForSync(validate: check) {
            let matches = try await SleepSyncValueWork.run {
                guard let item else { return false }
                return try Data(contentsOf: item.fileURL) == pending.payload
            }
            try check()
            if pending.outboxItemID == descriptor.itemID, !matches {
                throw OutboxDeliveryCoordinatorError.ownershipMismatch
            }
            if matches {
                guard pending.receiverBindingID == descriptor.receiverBindingID,
                      pending.connectionGeneration == descriptor.receiverGeneration,
                      item?.receiverIdentity == descriptor.receiverBindingID else {
                    throw OutboxDeliveryCoordinatorError.ownershipMismatch
                }
                // An ACK can arrive before the caller journals its assigned FIFO ID.
                // Exact accepted bytes plus binding/generation still identify that transition.
                let checkRetirement = { @MainActor in
                    try self.outbox.requireUploadAdmission()
                    try self.outbox.requireDirectRetirementAllowed(itemID: descriptor.itemID)
                }
                let committedRevision = try await sleepStore.saveManifestForSync(
                    pending.manifest, validate: {
                        try check()
                        try checkRetirement()
                    }
                )
                let checkCommitted = { @MainActor in
                    try Task.checkCancellation()
                    try validate()
                    try checkRetirement()
                    guard try sleepStore.revisionForSync() == committedRevision else {
                        throw CancellationError()
                    }
                }
                _ = try await sleepStore.clearPendingForSync(id: pending.id, validate: checkCommitted)
            }
        }
        try Task.checkCancellation()
        try validate()
    }

    @discardableResult
    @MainActor
    public func recordDirectReceiverAcceptanceForSync(
        itemID: String,
        receiverBindingID: String,
        validate: @MainActor () throws -> Void
    ) async throws -> Bool {
        try await outbox.prepareNutritionCompatibility(validate: validate)
        return try recordDirectReceiverAcceptance(
            itemID: itemID, receiverBindingID: receiverBindingID
        )
    }

    @discardableResult
    public func recordDirectReceiverAcceptance(
        itemID: String,
        receiverBindingID: String
    ) throws -> Bool {
        try recordDirectReceiverAcceptance(
            itemID: itemID, receiverBindingID: receiverBindingID, sleepChecked: false
        )
    }

    @discardableResult
    func recordDirectReceiverAcceptance(
        itemID: String,
        receiverBindingID: String,
        sleepChecked: Bool
    ) throws -> Bool {
        guard let record = try outbox.recordDirectUploadAcceptance(
            itemID: itemID,
            receiverIdentity: receiverBindingID,
            sleepChecked: sleepChecked,
            onNewAcceptance: {}
        ) else {
            return false
        }
        return try finalizeDirect(record)
    }

    @discardableResult
    public func finalizeDirectAcknowledgments(
        receiverBindingID: String
    ) throws -> Bool {
        guard let record = try outbox.directFinalizationRecordReady(
            receiverIdentity: receiverBindingID,
            where: { !Self.isSleepRecord($0) || $1.isEmpty }
        ) else {
            return false
        }
        return try finalizeDirect(record)
    }

    @discardableResult
    @MainActor
    public func finalizeDirectAcknowledgments(
        receiverBindingID: String,
        receiverGeneration: String,
        sleepStore: @autoclosure () throws -> any SleepSyncManifestStoring,
        validate: @escaping @MainActor () throws -> Void
    ) async throws -> Bool {
        try validate()
        if try finalizeDirectAcknowledgments(receiverBindingID: receiverBindingID) { return true }
        guard let record = try outbox.directFinalizationRecordReady(receiverIdentity: receiverBindingID) else {
            return false
        }
        return try await recoverDirectSleepAcknowledgment(
            record, receiverBindingID: receiverBindingID, receiverGeneration: receiverGeneration,
            sleepStore: sleepStore(), validate: validate
        )
    }

    @MainActor
    func recoverDirectSleepAcknowledgment(
        itemID: String,
        receiverBindingID: String,
        receiverGeneration: String,
        sleepStore: any SleepSyncManifestStoring,
        validate: @escaping @MainActor () throws -> Void
    ) async throws -> Bool {
        guard let record = try outbox.directFinalizationRecordReady(
            receiverIdentity: receiverBindingID,
            where: { Self.isSleepRecord($0) && $1.contains(itemID) }
        ) else { return false }
        return try await recoverDirectSleepAcknowledgment(
            record, receiverBindingID: receiverBindingID, receiverGeneration: receiverGeneration,
            sleepStore: sleepStore, validate: validate
        )
    }

    private static func isSleepRecord(_ record: FileOutboxFinalizationRecord) -> Bool {
        let sleepCursorKinds = [
            SleepSyncBatchFactory.foregroundCursorKind,
            SleepSyncBatchFactory.anchoredCursorKind,
            SleepSyncBatchFactory.baselineResetCursorKind,
        ]
        return record.pendingGenerationRetirements[HealthBridgeHealthType.sleepAnalysis.typeCode] != nil
            || record.cursorCheckpoint.map({ sleepCursorKinds.contains($0.cursorKind) }) == true
    }

    private func finalizeDirect(_ record: FileOutboxFinalizationRecord) throws -> Bool {
        if Self.isSleepRecord(record), try !outbox.uncheckedDirectAcknowledgmentIDs(for: record).isEmpty {
            return false
        }
        try finalize(record)
        return true
    }

    @MainActor
    private func recoverDirectSleepAcknowledgment(
        _ record: FileOutboxFinalizationRecord,
        receiverBindingID: String,
        receiverGeneration: String,
        sleepStore: any SleepSyncManifestStoring,
        validate: @escaping @MainActor () throws -> Void
    ) async throws -> Bool {
        let storedIntent = try outbox.directSleepCleanupIntent(for: record)
        if let storedIntent,
           storedIntent.receiverBindingID != receiverBindingID || storedIntent.receiverGeneration != receiverGeneration {
            return false
        }
        let revision = try sleepStore.revisionForSync()
        let check = { @MainActor in
            try Task.checkCancellation()
            try validate()
            try self.outbox.requireUploadAdmission()
            guard try sleepStore.revisionForSync() == revision else { throw CancellationError() }
        }
        let pending = try await sleepStore.loadPendingForSync(validate: check)
        let intent: DirectSleepCleanupIntent
        if let storedIntent {
            intent = storedIntent
        } else {
            guard let pending, let itemID = pending.outboxItemID,
                  try outbox.uncheckedDirectAcknowledgmentIDs(for: record) == Set([itemID]),
                  pending.receiverBindingID == receiverBindingID,
                  pending.connectionGeneration == receiverGeneration,
                  pending.manifest.receiverSettingsGeneration == receiverGeneration,
                  pending.rejectedMinimumResetEpoch == nil,
                  let manifest = try await sleepStore.loadManifestForSync(validate: check) else {
                return false
            }
            // The legacy ACK cannot prove the bytes, only the already committed transition.
            let alreadyCommitted = try await SleepSyncValueWork.run { manifest == pending.manifest }
            try check()
            guard alreadyCommitted else { return false }
            intent = DirectSleepCleanupIntent(
                itemID: itemID, journalID: pending.id, receiverBindingID: receiverBindingID,
                receiverGeneration: receiverGeneration
            )
            try outbox.beginDirectSleepCleanup(intent, for: record)
        }
        try check()
        let cleanedRevision: SleepSyncStorageRevision
        if let pending, pending.id == intent.journalID {
            guard pending.outboxItemID == intent.itemID,
                  pending.receiverBindingID == intent.receiverBindingID,
                  pending.connectionGeneration == intent.receiverGeneration,
                  pending.manifest.receiverSettingsGeneration == intent.receiverGeneration,
                  pending.rejectedMinimumResetEpoch == nil else {
                return false
            }
            cleanedRevision = try await sleepStore.clearPendingForSync(id: intent.journalID, validate: {
                try check()
                guard try self.outbox.directSleepCleanupIntent(for: record) == intent else {
                    throw CancellationError()
                }
            })
        } else {
            // No exact journal remains. In particular, do not clear a replacement.
            cleanedRevision = revision
        }
        try Task.checkCancellation()
        try validate()
        guard try sleepStore.revisionForSync() == cleanedRevision else { throw CancellationError() }
        try outbox.finishDirectSleepCleanup(intent, for: record)
        guard try outbox.directFinalizationRecordReady(
            receiverIdentity: receiverBindingID,
            where: { candidate, _ in candidate == record }
        ) == record else {
            return false
        }
        return try finalizeDirect(record)
    }

    private func finalize(_ record: FileOutboxFinalizationRecord) throws {
        if let checkpoint = record.cursorCheckpoint {
            try finalizeCursor(checkpoint)
            if let start = checkpoint.workoutHistoryStart {
                let kind = AnchoredWorkoutSyncPolicy.historicalBackfillCursorKind
                let previous = try cursorStore.cursorValue(
                    receiverBindingID: checkpoint.receiverIdentity,
                    sourceKey: checkpoint.sourceKey,
                    cursorKind: kind
                ).flatMap(HealthBridgeUTCFormatter.date(from:))
                if previous.map({ start < $0 }) ?? true {
                    try cursorStore.saveCursorValue(
                        HealthBridgeUTCFormatter.string(from: start),
                        receiverBindingID: checkpoint.receiverIdentity,
                        sourceKey: checkpoint.sourceKey,
                        cursorKind: kind
                    )
                }
            }
        }
        let retirements = record.eligiblePendingGenerationRetirements
        if !retirements.isEmpty {
            guard let pendingGenerationStore else {
                throw FileOutboxCursorCheckpointError.pendingCommit
            }
            try pendingGenerationStore.clearPendingObserverTypeCodes(
                matching: retirements,
                typeCodes: retirements.keys.sorted()
            )
        }
        try outbox.acknowledgeFinalizationRecord(record)
    }

    private func finalizeCursor(_ checkpoint: FileOutboxCursorCheckpoint) throws {
        if try cursorStore.cursorValue(
            receiverBindingID: checkpoint.receiverIdentity,
            sourceKey: checkpoint.sourceKey,
            cursorKind: checkpoint.cursorKind
        ) != checkpoint.cursorValue {
            try cursorStore.saveCursorValue(
                checkpoint.cursorValue,
                receiverBindingID: checkpoint.receiverIdentity,
                sourceKey: checkpoint.sourceKey,
                cursorKind: checkpoint.cursorKind
            )
        }
        finalizeUploadProof(checkpoint)
    }

    private func finalizationRecord(
        for context: OutboxDeliveryFinalizationContext
    ) throws -> FileOutboxFinalizationRecord? {
        try outbox.finalizationRecordReadyForDelivery(
            itemID: context.itemID,
            ownership: context.ownership
        )
    }

    private func finalizeUploadProof(_ checkpoint: FileOutboxCursorCheckpoint) {
        guard let proofStore else { return }
        switch checkpoint.coreLaneUploadProof {
        case .steps:
            if !proofStore.hasUploadedRecords(
                lane: .steps,
                receiverBindingID: checkpoint.receiverIdentity
            ) {
                proofStore.markUploadedRecords(
                    lane: .steps,
                    receiverBindingID: checkpoint.receiverIdentity
                )
            }
        case .workouts:
            if !proofStore.hasUploadedRecords(
                lane: .workouts,
                receiverBindingID: checkpoint.receiverIdentity
            ) {
                proofStore.markUploadedRecords(
                    lane: .workouts,
                    receiverBindingID: checkpoint.receiverIdentity
                )
            }
        case nil:
            break
        }
    }
}

public final class OutboxDeliverySleepFinalizer: OutboxDeliveryCommitFinalizing {
    private let store: any SleepSyncManifestStoring
    private let pendingTransition: SleepSyncPendingTransition
    private let transactionFinalizer: OutboxDeliveryCursorFinalizer?
    private let validateOwner: @MainActor () throws -> Void

    public init(
        store: any SleepSyncManifestStoring,
        pendingTransition: SleepSyncPendingTransition,
        transactionFinalizer: OutboxDeliveryCursorFinalizer? = nil,
        validateOwner: @escaping @MainActor () throws -> Void = {}
    ) {
        self.store = store
        self.pendingTransition = pendingTransition
        self.transactionFinalizer = transactionFinalizer
        self.validateOwner = validateOwner
    }

    @MainActor
    public func isFinalized(
        _ context: OutboxDeliveryFinalizationContext
    ) async throws -> Bool {
        try validate(context)
        let revision = try store.revisionForSync()
        let check = { @MainActor in
            try Task.checkCancellation()
            try self.validateOwner()
            guard try self.store.revisionForSync() == revision else { throw CancellationError() }
        }
        let sleepFinalized: Bool
        let expected = pendingTransition
        if let current = try await store.loadPendingForSync(validate: check) {
            let matches = try await SleepSyncValueWork.run { current == expected }
            try check()
            guard matches else {
                throw OutboxDeliveryCoordinatorError.ownershipMismatch
            }
            sleepFinalized = false
        } else {
            let manifest = try await store.loadManifestForSync(validate: check)
            sleepFinalized = try await SleepSyncValueWork.run { manifest == expected.manifest }
            try check()
        }
        guard sleepFinalized else { return false }
        return try transactionFinalizer?.isFinalized(context) ?? true
    }

    @MainActor
    public func finalize(_ context: OutboxDeliveryFinalizationContext) async throws {
        try validate(context)
        var revision = try store.revisionForSync()
        let check = { @MainActor in
            try Task.checkCancellation()
            try self.validateOwner()
            guard try self.store.revisionForSync() == revision else { throw CancellationError() }
        }
        let expected = pendingTransition
        if let current = try await store.loadPendingForSync(validate: check) {
            let matches = try await SleepSyncValueWork.run { current == expected }
            try check()
            guard matches else {
                throw OutboxDeliveryCoordinatorError.ownershipMismatch
            }
            let manifest = try await store.loadManifestForSync(validate: check)
            let committed = try await SleepSyncValueWork.run { manifest == expected.manifest }
            try check()
            if !committed {
                revision = try await store.saveManifestForSync(expected.manifest, validate: check)
            }
            revision = try await store.clearPendingForSync(id: expected.id, validate: check)
        } else {
            let manifest = try await store.loadManifestForSync(validate: check)
            let committed = try await SleepSyncValueWork.run { manifest == expected.manifest }
            try check()
            guard committed else {
                throw OutboxDeliveryCoordinatorError.finalizationIncomplete
            }
        }
        try check()
        try transactionFinalizer?.finalize(context)
    }

    private func validate(_ context: OutboxDeliveryFinalizationContext) throws {
        guard pendingTransition.outboxItemID == context.itemID,
              pendingTransition.receiverBindingID == context.ownership.receiverBindingID,
              pendingTransition.connectionGeneration == context.ownership.receiverGeneration,
              pendingTransition.manifest.baselineResetEpoch == context.ownership.resetEpoch else {
            throw OutboxDeliveryCoordinatorError.ownershipMismatch
        }
    }
}
#endif
