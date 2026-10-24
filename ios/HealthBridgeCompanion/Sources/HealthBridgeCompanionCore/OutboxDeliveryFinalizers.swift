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
        guard let record = try outbox.recordDirectUploadAccepted(
            itemID: itemID,
            receiverIdentity: receiverBindingID
        ) else {
            return false
        }
        try finalize(record)
        return true
    }

    @discardableResult
    public func finalizeDirectAcknowledgments(
        receiverBindingID: String
    ) throws -> Bool {
        guard let record = try outbox.directFinalizationRecordReady(
            receiverIdentity: receiverBindingID
        ) else {
            return false
        }
        try finalize(record)
        return true
    }

    private func finalize(_ record: FileOutboxFinalizationRecord) throws {
        if let checkpoint = record.cursorCheckpoint {
            try finalizeCursor(checkpoint)
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
