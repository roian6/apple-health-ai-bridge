import Foundation

public protocol OutboxDeliveryCommitFinalizing {
    func isFinalized(_ context: OutboxDeliveryFinalizationContext) throws -> Bool
    func finalize(_ context: OutboxDeliveryFinalizationContext) throws
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
        if !record.pendingGenerationRetirements.isEmpty {
            guard let pendingGenerationStore else {
                throw FileOutboxCursorCheckpointError.pendingCommit
            }
            try pendingGenerationStore.clearPendingObserverTypeCodes(
                matching: record.pendingGenerationRetirements,
                typeCodes: record.pendingGenerationRetirements.keys.sorted()
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

    public init(
        store: any SleepSyncManifestStoring,
        pendingTransition: SleepSyncPendingTransition,
        transactionFinalizer: OutboxDeliveryCursorFinalizer? = nil
    ) {
        self.store = store
        self.pendingTransition = pendingTransition
        self.transactionFinalizer = transactionFinalizer
    }

    public func isFinalized(
        _ context: OutboxDeliveryFinalizationContext
    ) throws -> Bool {
        try validate(context)
        let sleepFinalized: Bool
        if let current = try store.loadPendingTransition() {
            guard current == pendingTransition else {
                throw OutboxDeliveryCoordinatorError.ownershipMismatch
            }
            sleepFinalized = false
        } else {
            sleepFinalized = try store.loadManifest() == pendingTransition.manifest
        }
        guard sleepFinalized else { return false }
        return try transactionFinalizer?.isFinalized(context) ?? true
    }

    public func finalize(_ context: OutboxDeliveryFinalizationContext) throws {
        try validate(context)
        if let current = try store.loadPendingTransition() {
            guard current == pendingTransition else {
                throw OutboxDeliveryCoordinatorError.ownershipMismatch
            }
            if try store.loadManifest() != pendingTransition.manifest {
                try store.saveManifest(pendingTransition.manifest)
            }
            try store.clearPendingTransition(id: pendingTransition.id)
        } else {
            guard try store.loadManifest() == pendingTransition.manifest else {
                throw OutboxDeliveryCoordinatorError.finalizationIncomplete
            }
        }
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
