"""Source contracts for Mailbox checkpoint completion and acceptance attribution."""

import re

from tests.guardrails.mailbox_publication_effect_contract import (
    MailboxLane,
    swift_tokens,
)
from tests.guardrails.mailbox_publication_guard import SwiftLexer, mailbox_branch_body


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
    body = swift_tokens(SwiftLexer(writer).views().structure)
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
        try persistManifest(manifest)
        try fault(.statePersisted)
        try retireCommittedArtifacts(for: manifest.entries[index], fault: fault)
        if let identity = manifest.entries[index].receiverIdentity {
            try recordNutritionChildAcceptance(
                itemID: itemID, receiverIdentity: identity
            )
        }
        onNewFinalization()
        return committed
    """
    assert swift_tokens(new_commit) in body, (
        "Only a new durable finalization may signal acceptance"
    )
    assert body.count(callback) == 1
