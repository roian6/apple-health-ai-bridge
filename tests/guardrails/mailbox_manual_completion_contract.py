"""Source contracts for Mailbox checkpoint completion and acceptance attribution."""

import re

from tests.guardrails.mailbox_publication_effect_contract import (
    BOUNDED_OPERATION_CREDIT_PREFIX,
    MailboxLane,
    swift_tokens,
)
from tests.guardrails.mailbox_publication_guard import (
    SwiftLexer,
    mailbox_branch_body,
    swift_block_end,
)


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


def _function_executables(source: str, name: str) -> tuple[str, ...]:
    views = SwiftLexer(source).views()
    matches = tuple(re.finditer(rf"\bfunc\s+{re.escape(name)}\s*\(", views.structure))
    bodies: list[str] = []
    for match in matches:
        opening_brace = views.structure.index("{", match.end())
        depth = 0
        for offset in range(opening_brace, len(views.structure)):
            if views.structure[offset] == "{":
                depth += 1
            elif views.structure[offset] == "}":
                depth -= 1
                if depth == 0:
                    bodies.append(views.executable[match.start() : offset + 1])
                    break
        else:
            message = f"Unterminated Swift function: {name}"
            raise AssertionError(message)
    return tuple(bodies)


def _function_executable(source: str, name: str) -> str:
    bodies = _function_executables(source, name)
    assert len(bodies) == 1
    return bodies[0]


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
              (try? currentPayloadDeliveryTarget()) == target,
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
    delivery_views = SwiftLexer(delivery).views()
    assert (
        re.search(r"(?m)^\s*#(?:if|elseif|else|endif)\b", delivery_views.structure)
        is None
    ), "Core must not synthesize or duplicate durable finalization evidence"
    delivery_tokens = swift_tokens(delivery_views.executable)
    forwarded = swift_tokens(
        "onNewFinalization: @MainActor (OutboxDeliveryOwnershipV1) -> Void"
    )
    no_op = swift_tokens("onNewFinalization: { _ in }")
    commit = swift_tokens("""
        try await coordinator.finalizeCommitted(itemID: item.id) {
            onNewFinalization(coordinator.ownership)
        }
    """)
    initial_foreground = swift_tokens("""
        var finalizedItemIDs = try await finalizeVerifiedForegroundHeads(
            components: components, onNewFinalization: onNewFinalization
        )
    """)
    additional_foreground = swift_tokens("""
        finalizedItemIDs.formUnion(try await finalizeVerifiedForegroundHeads(
            components: components, onNewFinalization: onNewFinalization
        ))
    """)
    foreground_declaration = swift_tokens(
        "private func finalizeVerifiedForegroundHeads("
    )
    assert delivery_tokens.count(foreground_declaration) == 1, (
        "Core must not synthesize or duplicate durable finalization evidence"
    )
    foreground = _function_executable(delivery, "finalizeVerifiedForegroundHeads")
    foreground_tokens = swift_tokens(foreground)
    durable_sequence = swift_tokens(
        """let coordinator = try await coordinator(
            components: components, itemID: item.id
        )
        _ = try await coordinator.finalizeCommitted(itemID: item.id) {
            onNewFinalization(coordinator.ownership)
        }
        finalizedItemIDs.insert(item.id)"""
    )
    assert foreground_tokens.count(durable_sequence) == 1, (
        "Core must not synthesize or duplicate durable finalization evidence"
    )
    assert len(re.findall(r"\bcoordinator\b", foreground)) == 4, (
        "Core must not synthesize or duplicate durable finalization evidence"
    )
    bounded_candidates = tuple(
        body
        for body in _function_executables(
            delivery, "reconcilePendingFIFOHeadAcknowledgment"
        )
        if re.search(r"\bcoordinator\b", body) is not None
    )
    assert len(bounded_candidates) == 1, (
        "Core must not synthesize or duplicate durable finalization evidence"
    )
    bounded = bounded_candidates[0]
    bounded_tokens = swift_tokens(bounded)
    bounded_load = swift_tokens(
        """coordinator = try await self.coordinator(
            components: components, itemID: item.id
        )
        phase = try coordinator.state(itemID: item.id)?.phase"""
    )
    assert bounded_tokens.count(bounded_load) == 1, (
        "Core must not synthesize or duplicate durable finalization evidence"
    )
    assert len(re.findall(r"\bcoordinator\b", bounded)) == 24, (
        "Core must not synthesize or duplicate durable finalization evidence"
    )
    coordinator_factories = _function_executables(delivery, "coordinator")
    assert len(coordinator_factories) == 1, (
        "Core must not synthesize or duplicate durable finalization evidence"
    )
    coordinator_factory = swift_tokens(
        """func coordinator(
            components: ProductionMailboxComponents,
            itemID: String
        ) async throws -> OutboxDeliveryCoordinator {"""
    )
    assert swift_tokens(coordinator_factories[0]).startswith(coordinator_factory), (
        "Core must not synthesize or duplicate durable finalization evidence"
    )
    assert delivery_tokens.count("finalizeVerifiedForegroundHeads") == 3, (
        "Core must not synthesize or duplicate durable finalization evidence"
    )
    allowed = delivery_tokens
    callback_contracts = (
        (commit, 3),
        (forwarded, 3),
        (no_op, 2),
        (initial_foreground, 1),
        (additional_foreground, 1),
    )
    for pattern, count in callback_contracts:
        assert allowed.count(pattern) == count, (
            "Core must not synthesize or duplicate durable finalization evidence"
        )
        allowed = allowed.replace(pattern, " ", count)
    assert "onNewFinalization" not in allowed, (
        "Core must not synthesize or duplicate durable finalization evidence"
    )


def assert_mailbox_journal_finalization_contract(coordinator: str, outbox: str) -> None:
    coordinator_body = _declaration(
        coordinator, "func finalizeCommitted(\n", "public func "
    )
    views = SwiftLexer(coordinator_body).views()
    writer_call = re.search(
        r"""
        \breturn\s+try\s+outbox\.finalizeCommittedMailboxDelivery\(\s*
        itemID:\s*itemID,\s*expected:\s*current,\s*committed:\s*committed,\s*
        fault:\s*(\{)
        """,
        views.structure,
        re.VERBOSE,
    )
    assert writer_call, "Expected the durable Mailbox writer"
    after_fault = swift_block_end(views.structure, writer_call.start(1)) + 1
    assert swift_tokens(views.executable[after_fault:]) == swift_tokens(
        ", onNewFinalization: onNewFinalization) }"
    )
    assert len(re.findall(r"\bonNewFinalization\b", views.executable)) == 3, (
        "Coordinator may only forward the finalization callback"
    )
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
