from pathlib import Path

ROOT = Path("ios/HealthBridgeCompanion")
CORE = ROOT / "Sources" / "HealthBridgeCompanionCore"
TESTS = ROOT / "Tests" / "HealthBridgeCompanionCoreTests"
PROJECT = ROOT / "HealthBridgeCompanion.xcodeproj" / "project.pbxproj"

PRODUCT_FILES = (
    "OutboxDeliveryModels.swift",
    "OutboxDeliveryFinalizers.swift",
    "OutboxDeliveryCoordinator.swift",
    "OutboxDeliveryCoordinatorAck.swift",
)
TEST_FILES = (
    "OutboxDeliveryCoordinatorTestSupport.swift",
    "OutboxDeliveryCoordinatorTests.swift",
    "OutboxDeliveryCoordinatorFaultTests.swift",
    "OutboxDeliveryCoordinatorFinalizationTests.swift",
)


def test_todo16_coordinator_is_product_code_with_focused_swift_tests() -> None:
    for name in (*PRODUCT_FILES, *TEST_FILES):
        directory = CORE if name in PRODUCT_FILES else TESTS
        assert (directory / name).is_file(), name

    project = PROJECT.read_text(encoding="utf-8")
    for name in PRODUCT_FILES:
        assert project.count(name) >= 3


def test_todo16_state_and_test_contract_cover_required_boundaries() -> None:
    models = (CORE / "OutboxDeliveryModels.swift").read_text(encoding="utf-8")
    product = "\n".join(
        (CORE / name).read_text(encoding="utf-8") for name in PRODUCT_FILES
    )
    tests = "\n".join((TESTS / name).read_text(encoding="utf-8") for name in TEST_FILES)

    for state in (
        "collected",
        "encrypted",
        "published",
        "providerObserved",
        "ackVerified",
        "committedFinalized",
        "retryableFailure",
        "terminalFailure",
    ):
        assert f"case {state}" in models
    for contract in (
        "MailboxAckEvent",
        "handleDirectHTTPSuccess",
        "deleteAcknowledgment",
        "OutboxDeliveryCommitFinalizing",
        "isFinalized",
    ):
        assert contract in product
    for scenario in (
        "testOrderedHappyPathRestartsAtEveryStateAndFinalizesOnce",
        "testFaultsAroundEnvelopeAndStateWritesRecoverWithoutCryptoReentry",
        "testAckNackConflictGenerationAndStaleHTTPBoundariesDoNotRetire",
        "testCursorAndSleepFinalizationAreExactlyOnce",
        "testCommittedFinalizationRetiresOnlyExactArtifacts",
        "testAckDeletionFailureKeepsCommittedFinalization",
        "testTodo14V4MigrationInfersEncryptedWithoutResealing",
    ):
        assert scenario in tests


def test_todo16_source_has_no_encoder_or_parallel_database() -> None:
    source = "\n".join(
        (CORE / name).read_text(encoding="utf-8") for name in PRODUCT_FILES
    )
    assert "HealthBridgeBatchEncoder" not in source
    assert "SQLite" not in source
    assert "URLSession" not in source
    assert "print(" not in source
