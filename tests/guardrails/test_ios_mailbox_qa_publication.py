from pathlib import Path

CORE = Path("ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore")


def test_signed_qa_selects_the_platform_publisher_and_preserves_faults() -> None:
    # Given: the dependency closure used by every signed QA advance.
    dependencies = (CORE / "MailboxQAHarnessDependencies.swift").read_text(
        encoding="utf-8"
    )

    # When: the publisher factory and coordinator wiring are inspected.
    factory = dependencies[dependencies.index("enum MailboxQAPublisherFactory") :]

    # Then: iOS follows production while fault and non-iOS tests remain deterministic.
    assert "publisher: publisher(fault)" in dependencies
    harness = (CORE / "MailboxQAHarness.swift").read_text(encoding="utf-8")
    assert "= MailboxQAPublisherFactory.publisher" in harness
    assert "fault != nil" in factory
    assert "MailboxQAFaultPublisher()" in factory
    assert "#if os(iOS)" in factory
    assert "FileProviderMailboxEnvelopePublisher()" in factory
    assert "#else" in factory
    assert "POSIXMailboxEnvelopePublisher()" in factory


def test_file_provider_ubiquity_move_awaits_native_completion_off_main() -> None:
    # Given: the File Provider publisher used by production and signed iOS QA.
    publisher = (CORE / "MailboxAtomicPublisher.swift").read_text(encoding="utf-8")

    # When: the single initial ubiquity move is traced to its execution boundary.
    executor_call = "try await executor.run {"

    # Then: setUbiquitous can only be reached through the dedicated non-main queue.
    assert publisher.count("FileManager.default.setUbiquitous(") == 1
    assert "struct MailboxFileProviderPublicationExecutor" in publisher
    executor = publisher[
        publisher.index(
            "struct MailboxFileProviderPublicationExecutor"
        ) : publisher.index("struct FileProviderMailboxEnvelopePublisher")
    ]
    assert "private let queue = DispatchQueue(" in executor
    assert "label:" in executor
    assert "queue.sync" not in executor
    assert "queue.async" in executor
    assert "withCheckedThrowingContinuation" in executor
    assert "continuation.resume(returning: try operation())" in executor
    assert executor_call in publisher
    assert (
        "try self.publishBlocking(envelope, finalName: finalName, locator: locator)"
        in publisher
    )
    assert (
        "try self.publishPairingRequestBlocking(bytes, locator: locator)" in publisher
    )
    assert (
        "throw MailboxPublicationExecutionError.asynchronousPublicationRequired"
        in publisher
    )


def test_production_awaits_publication_and_rechecks_owner() -> None:
    delivery = (CORE / "ProductionMailboxDelivery.swift").read_text(encoding="utf-8")
    coordinator = (CORE / "OutboxDeliveryCoordinator.swift").read_text(encoding="utf-8")
    transport = (CORE / "MailboxTransport.swift").read_text(encoding="utf-8")
    components = (CORE / "ProductionMailboxComponents.swift").read_text(
        encoding="utf-8"
    )
    assert delivery.count("await deliveryCoordinator.advanceAwaitingPublication(") == 1
    assert delivery.count("await coordinator.advanceAwaitingPublication(") == 2
    assert "await transport.publishEnvelopeAwaitingCompletion(" in coordinator
    assert "await publisher.publishAwaitingCompletion(" in transport
    assert (
        "settingsStore.receiverSettingsGenerationToken != receiverGeneration"
        in components
    )
    start = transport.index("func publishEnvelopeAwaitingCompletion(")
    end = transport.index("func observeEnvelope(", start)
    publication = transport[start:end]
    failure = publication.index("} catch {")
    validation = publication.index("try checkPublicationAdmission()", failure)
    classification = publication.index("if let publicationError", failure)
    assert failure < validation < classification
    assert publication.count("try checkPublicationAdmission()") == 4
    assert "@unchecked Sendable" not in transport + coordinator + components


def test_automatic_mailbox_publication_reuses_the_existing_transfer_gate() -> None:
    view_model = CORE.parent.parent / "App" / "HealthBridgeCompanionViewModel.swift"
    source = view_model.read_text(encoding="utf-8")
    start = source.index("private func reconcileMailboxDeliveryWithExclusiveTransfer(")
    end = source.index("private func reconcileMailboxDeliveryIfNeeded(", start)
    wrapper = source[start:end]
    assert "try await runWithExclusiveDirectOutboxTransfer" in wrapper
    assert "requireCurrentConnectionGeneration(expectedGeneration)" in wrapper
    assert "await self.reconcileMailboxDeliveryIfNeeded(at: point)" in wrapper
    assert source.count("await reconcileMailboxDeliveryWithExclusiveTransfer(at:") == 2
