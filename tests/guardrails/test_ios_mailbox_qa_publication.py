from pathlib import Path

CORE = Path("ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore")
QA_INVOCATION = Path("ios/HealthBridgeCompanion/MailboxQA/MailboxQAInvocation.swift")


def test_signed_qa_selects_the_platform_publisher_and_preserves_faults() -> None:
    # Given: the dependency closure used by every signed QA advance.
    dependencies = (CORE / "MailboxQAHarnessDependencies.swift").read_text(
        encoding="utf-8"
    )

    # When: the publisher factory and coordinator wiring are inspected.
    factory = dependencies[dependencies.index("enum MailboxQAPublisherFactory") :]

    # Then: iOS follows production while fault and non-iOS tests remain deterministic.
    assert "MailboxQAPublisherFactory.publisher(fault: fault)" in dependencies
    assert "fault != nil" in factory
    assert "MailboxQAFaultPublisher()" in factory
    assert "#if os(iOS)" in factory
    assert "FileProviderMailboxEnvelopePublisher()" in factory
    assert "#else" in factory
    assert "POSIXMailboxEnvelopePublisher()" in factory


def test_file_provider_ubiquity_move_uses_the_blocking_executor() -> None:
    # Given: the File Provider publisher used by production and signed iOS QA.
    publisher = (CORE / "MailboxAtomicPublisher.swift").read_text(encoding="utf-8")

    # When: the single initial ubiquity move is traced to its execution boundary.
    executor_call = "try executor.run {\n            try publishWithUbiquityManager("

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
    assert "queue.sync(execute: operation)" in executor
    assert executor_call in publisher


def test_signed_qa_advance_remains_serialized_on_the_main_actor() -> None:
    # Given: the signed QA invocation and its durable harness.
    invocation = QA_INVOCATION.read_text(encoding="utf-8")
    harness = (CORE / "MailboxQAHarness.swift").read_text(encoding="utf-8")
    advance_action = invocation[
        invocation.index("case .advance") : invocation.index("case .scanFinalize")
    ]

    # When / Then: only the blocking publisher crosses queues, never harness ownership.
    assert "@MainActor\nfinal class MailboxQAInvocation" in invocation
    assert "public func advance(" in harness
    assert advance_action.count("harness.advance") == 2
    assert "Task.detached" not in advance_action
    assert "Task {" not in advance_action
