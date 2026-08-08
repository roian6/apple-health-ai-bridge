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

    public init(
        outbox: FileOutbox,
        cursorStore: any SyncCursorStoring,
        proofStore: CoreLaneUploadProofStore? = nil
    ) {
        self.outbox = outbox
        self.cursorStore = cursorStore
        self.proofStore = proofStore
    }

    public func isFinalized(
        _ context: OutboxDeliveryFinalizationContext
    ) throws -> Bool {
        try checkpoint(for: context) == nil
    }

    public func finalize(_ context: OutboxDeliveryFinalizationContext) throws {
        guard let checkpoint = try checkpoint(for: context) else { return }
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
        try outbox.acknowledgeCursorCheckpoint(checkpoint)
    }

    private func checkpoint(
        for context: OutboxDeliveryFinalizationContext
    ) throws -> FileOutboxCursorCheckpoint? {
        try outbox.cursorCheckpointReadyForDeliveryFinalization(
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

    public init(
        store: any SleepSyncManifestStoring,
        pendingTransition: SleepSyncPendingTransition
    ) {
        self.store = store
        self.pendingTransition = pendingTransition
    }

    public func isFinalized(
        _ context: OutboxDeliveryFinalizationContext
    ) throws -> Bool {
        try validate(context)
        guard let current = try store.loadPendingTransition() else {
            return try store.loadManifest() == pendingTransition.manifest
        }
        guard current == pendingTransition else {
            throw OutboxDeliveryCoordinatorError.ownershipMismatch
        }
        return false
    }

    public func finalize(_ context: OutboxDeliveryFinalizationContext) throws {
        try validate(context)
        guard let current = try store.loadPendingTransition() else {
            guard try store.loadManifest() == pendingTransition.manifest else {
                throw OutboxDeliveryCoordinatorError.finalizationIncomplete
            }
            return
        }
        guard current == pendingTransition else {
            throw OutboxDeliveryCoordinatorError.ownershipMismatch
        }
        if try store.loadManifest() != pendingTransition.manifest {
            try store.saveManifest(pendingTransition.manifest)
        }
        try store.clearPendingTransition(id: pendingTransition.id)
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
