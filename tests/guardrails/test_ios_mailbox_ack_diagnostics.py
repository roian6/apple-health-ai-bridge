from pathlib import Path

VIEW_MODEL = Path("ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift")


def test_manual_mailbox_ack_diagnostic_publishes_only_after_generation_check() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    helper_start = source.index("private func uploadPendingOutbox(")
    helper_end = source.index(
        "private func makeProductionMailboxDelivery()", helper_start
    )
    helper = source[helper_start:helper_end]
    mailbox_start = helper.index("if settingsStore.activeTransport == .mailbox")
    mailbox_end = helper.index("guard let receiverIdentity", mailbox_start)
    mailbox = helper[mailbox_start:mailbox_end]

    delivery = mailbox.index("deliverPending()")
    post_await_generation_check = mailbox.index(
        "try requireCurrentConnectionGeneration(expectedGeneration)", delivery
    )
    summary_mapping = mailbox.index(
        "mailboxDeliveryDiagnosticLine: summary.ackDiagnosticLine"
    )
    publication = mailbox.index(
        "mailboxDeliveryDiagnosticLine = flushSummary.mailboxDeliveryDiagnosticLine"
    )

    assert delivery < post_await_generation_check < summary_mapping < publication
    assert mailbox.index("catch let cancellation as CancellationError") < mailbox.index(
        "catch {"
    )


def test_mailbox_failure_diagnostic_never_uses_arbitrary_error_text() -> None:
    source = VIEW_MODEL.read_text(encoding="utf-8")
    assignments = [
        line.strip()
        for line in source.splitlines()
        if "mailboxDeliveryDiagnosticLine =" in line
    ]

    assert any(
        "MailboxDeliveryDiagnosticLine.failure(for: error)" in line
        for line in assignments
    )
    assert all("describe(" not in line for line in assignments)
    assert all("localizedDescription" not in line for line in assignments)


def test_delivery_phase_wrappers_preserve_ack_processing_order() -> None:
    source = (
        Path("ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore")
        / "ProductionMailboxDelivery.swift"
    ).read_text(encoding="utf-8")
    delivery_start = source.index("public func deliverPending()")
    delivery_end = source.index("private func coordinator(", delivery_start)
    delivery = source[delivery_start:delivery_end]

    phases = [
        ".initialAdvance",
        ".locateAckLane",
        ".hydrateAck",
        ".scanAck",
        ".mapAckItem",
        ".consumeAck",
        ".remainingCount",
    ]
    offsets = [delivery.index(phase) for phase in phases]

    assert offsets == sorted(offsets)
