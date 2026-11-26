"""Source contracts for Mailbox checkpoint completion and acceptance attribution."""

import re

from tests.guardrails.mailbox_publication_effect_contract import (
    BOUNDED_OPERATION_CREDIT_PREFIX,
    MailboxLane,
    swift_tokens,
)
from tests.guardrails.mailbox_publication_guard import SwiftLexer, mailbox_branch_body


def assert_bounded_mailbox_checkpoint_completion(success: str) -> None:
    """Credit the checkpoint only on the branch where its write returns."""
    body = mailbox_branch_body(SwiftLexer(success).views(), MailboxLane.BOUNDED)
    # The checked outer prefix initializes the empty set. Consume the reviewed
    # phase-selection grammar through the real credit; no overwrite, shadowing,
    # or other write can intervene between the fence and insertion.
    prefix = swift_tokens(BOUNDED_OPERATION_CREDIT_PREFIX)
    checkpoint_and_summary = """
        if requestedPhase == .advanceOrReconcileFIFOHead,
           let write = mailboxCheckpointWrite(
               startingCheckpoint: startingCheckpoint,
               nextCheckpoint: summary.nextAcknowledgmentCheckpoint,
               generation: expectedGeneration
           ) {
            do {
                try backgroundSyncStore.persistMailboxAckScanCheckpoint(
                    write.checkpoint, receiverGeneration: expectedGeneration
                )
                completedOperations.insert(.persistScanCheckpoint)
            } catch {
                publishMailboxDeliverySummary(
                    summary.diagnosticLine, finalizedItemIDs: summary.finalizedItemIDs,
                    completedOperations: completedOperations
                )
                throw write
            }
        }
        refreshPendingOutboxCount()
        backgroundSyncStatus = Self.mailboxBackgroundDeliveryMessage(
            summary, pendingCount: pendingOutboxCount
        )
        publishMailboxDeliverySummary(
            summary.diagnosticLine, finalizedItemIDs: summary.finalizedItemIDs,
            completedOperations: completedOperations
        )
    """
    boundary = "Credit persistence only after the bounded checkpoint write succeeds"
    executable = swift_tokens(body.executable)
    selection = f"{boundary}; credit the selected operation"
    assert executable.startswith(f"{prefix} "), selection
    publication = swift_tokens(checkpoint_and_summary)
    after_credit = executable[len(prefix) + 1 :]
    assert after_credit.startswith(f"{publication} "), boundary
    tail = after_credit[len(publication) :].split()
    assert "completedOperations" not in tail, boundary


def assert_manual_mailbox_checkpoint_completion(success: str) -> None:
    """Allow checkpoint completion only on the exact successful write path."""
    body = mailbox_branch_body(SwiftLexer(success).views(), MailboxLane.MANUAL)
    local = swift_tokens("var completedOperations: Set<MailboxDeliveryOperation> =")
    before, declaration, tail = swift_tokens(body.structure).partition(local)
    assert declaration, "Expected manual Mailbox completion state"
    hoist = re.search(
        r"""
        \blet[ ](?P<local>[A-Za-z_]\w*)[ ]:[ ]Set[ ]<[ ]MailboxDeliveryOperation[ ]>
        [ ]=[ ]await[ ]MainActor[ ]\.[ ]run[ ]\{[ ]\[[ ]\.[ ]manualDelivery[ ]\][ ]\}
        """,
        before,
        re.VERBOSE,
    )
    initial = hoist["local"] if hoist else "[.manualDelivery]"
    write = re.search(r"\bif let ([A-Za-z_]\w*) = pendingMailboxCheckpointWrite", tail)
    assert write, "Expected the exact pending checkpoint write"
    expected = """
        if let write = pendingMailboxCheckpointWrite,
           write.canRetry(from: backgroundSyncStore.mailboxAckScanCheckpoint(
               receiverGeneration: expectedGeneration
           )) {
            do {
                try backgroundSyncStore.persistMailboxAckScanCheckpoint(
                    write.checkpoint, receiverGeneration: expectedGeneration
                )
                completedOperations.insert(.persistScanCheckpoint)
            } catch {
                publishMailboxDeliverySummary(
                    flushSummary.mailboxDeliveryDiagnosticLine,
                    finalizedItemIDs: summary.finalizedItemIDs,
                    completedOperations: completedOperations
                )
                throw write
            }
        }
        publishMailboxDeliverySummary(
            flushSummary.mailboxDeliveryDiagnosticLine,
            finalizedItemIDs: summary.finalizedItemIDs,
            completedOperations: completedOperations
        )
        return (summary: flushSummary, lastDirectUploadResult: nil,
                acceptedDirectItemIDs: [])
    """
    checked = swift_tokens(re.sub(r"\bwrite\b", write[1], expected))
    assert tail.strip() == f"{swift_tokens(initial)} {checked}", (
        "Manual Mailbox may complete the checkpoint operation only after the exact "
        "generation-matched write succeeds"
    )


def _declaration(source: str, start: str, end: str) -> str:
    start_at = source.index(start)
    return source[start_at : source.index(end, start_at + len(start))]


def assert_single_mailbox_finalization_observation(success: str, lane: str) -> None:
    structure = SwiftLexer(lane).views().structure
    assert len(re.findall(r"\brecordNewMailboxFinalization\s*\(", structure)) == 1, (
        "Mailbox acceptance must be attributed once through the guarded helper"
    )
    assert not re.search(r"\brecordAcceptedTransfer\s*\(", structure), (
        "Mailbox summary or error paths must not separately credit acceptance"
    )
    success_structure = SwiftLexer(success).views().structure
    assert len(re.findall(r"\bfinalizedOwner\s*=(?!=)", success_structure)) == 1, (
        "Only the delivery callback can set Mailbox acceptance evidence"
    )


def assert_live_mailbox_finalization_attribution(view_model: str) -> None:
    helper = _declaration(
        view_model,
        "private func recordNewMailboxFinalization(",
        "private func makeProductionMailboxDelivery()",
    )
    tokens = swift_tokens(SwiftLexer(helper).views().structure)
    authority = """
        guard let ownership, let target, target.route == .mailbox,
              let deliveryOutbox, outbox === deliveryOutbox,
              ownership.receiverBindingID == target.bindingID,
              ownership.receiverGeneration == target.generation,
              (try? requireCurrentPayloadDeliveryTarget(target)) != nil,
              (try? deliveryOutbox.requireUploadAdmission()) != nil else { return }
        recordAcceptedTransfer(
            bindingID: target.bindingID, generation: target.generation,
            evidenceKind: .mailboxCommit
        )
    """
    assert tokens.partition("{")[2].strip() == swift_tokens(f"{authority} }}"), (
        "Mailbox acceptance requires live target, matching owner and admitted outbox"
    )


def assert_new_mailbox_finalization_contract(delivery: str) -> None:
    bounded = _declaration(
        delivery,
        "public func reconcilePendingFIFOHeadAcknowledgment(",
        "public func deliverPending()",
    )
    manual = _declaration(
        delivery,
        "public func deliverPending()",
        "static func orderedAcknowledgmentIndices(",
    )
    bounded_tokens = swift_tokens(SwiftLexer(bounded).views().structure)
    manual_tokens = swift_tokens(SwiftLexer(manual).views().structure)
    forwarded = swift_tokens(
        "onNewFinalization: @MainActor (OutboxDeliveryOwnershipV1) -> Void"
    )
    for tokens in (bounded_tokens, manual_tokens):
        assert forwarded in tokens
        assert swift_tokens("onNewFinalization: { _ in }") in tokens
    threading = swift_tokens(
        "components: components, onNewFinalization: onNewFinalization"
    )
    assert manual_tokens.count(threading) == 2
    commit = swift_tokens("""
        try await coordinator.finalizeCommitted(itemID: item.id) {
            onNewFinalization(coordinator.ownership)
        }
    """)
    callback = swift_tokens("onNewFinalization(")
    for tokens, invocations in ((bounded_tokens, 2), (manual_tokens, 1)):
        assert tokens.count(commit) == invocations, (
            "Core must forward evidence from the commit callback with the actual owner"
        )
        assert tokens.count(callback) == invocations, (
            "Core must not synthesize or duplicate durable finalization evidence"
        )


def assert_mailbox_journal_finalization_contract(coordinator: str, outbox: str) -> None:
    coordinator_body = _declaration(
        coordinator, "func finalizeCommitted(\n", "public func "
    )
    coordinator_tokens = swift_tokens(SwiftLexer(coordinator_body).views().structure)
    assert swift_tokens("onNewFinalization: onNewFinalization") in coordinator_tokens
    callback = swift_tokens("onNewFinalization()")
    assert callback not in coordinator_tokens
    writer = _declaration(
        outbox, "func finalizeCommittedMailboxDelivery(", "public func "
    )
    writer_views = SwiftLexer(writer).views()
    body = swift_tokens(writer_views.structure)
    new_commit = """
        if manifest.entries[index].deliveryState == committed {
            try retireCommittedArtifacts(for: manifest.entries[index], fault: fault)
            return committed
        }
        guard manifest.entries[index].deliveryState == expected,
              manifest.entries[index].mailboxBinding != nil else {
            throw FileOutboxMailboxError.deliveryTransitionConflict
        }
        manifest.entries[index].deliveryState = committed
        try persistManifest(manifest) { onNewFinalization() }
        try fault(.statePersisted)
        try retireCommittedArtifacts(for: manifest.entries[index], fault: fault)
        if let identity = manifest.entries[index].receiverIdentity {
            try recordNutritionChildAcceptance(
                itemID: itemID, receiverIdentity: identity
            )
        }
        return committed
        }
    """
    new_finalization = "Only a new durable finalization may signal acceptance"
    assert body.endswith(swift_tokens(new_commit)), new_finalization
    writer_tokens = swift_tokens(writer_views.executable).split()
    assert writer_tokens.count("onNewFinalization") == 2, new_finalization

    persist = _declaration(
        outbox, "private func persistManifest(", "private static func validate("
    )
    atomic_write = """
        private func persistManifest(
            _ manifest: SequenceManifest, onAtomicWrite: () -> Void = {}
        ) throws {
            try Self.validate(manifest)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(manifest)
            try bytes.write(to: sequenceURL, options: [.atomic])
            onAtomicWrite()
            try Self.applySensitiveFileAttributes(
                to: sequenceURL, fileManager: fileManager
            )
            decodedManifest = (bytes, manifest)
        }
    """
    assert swift_tokens(SwiftLexer(persist).views().structure) == swift_tokens(
        atomic_write
    ), "Signal after the atomic manifest write and before throwing hardening"
