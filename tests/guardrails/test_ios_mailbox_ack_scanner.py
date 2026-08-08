from pathlib import Path

ROOT = Path("ios/HealthBridgeCompanion")
CORE = ROOT / "Sources" / "HealthBridgeCompanionCore"
TESTS = ROOT / "Tests" / "HealthBridgeCompanionCoreTests"
PROJECT = ROOT / "HealthBridgeCompanion.xcodeproj" / "project.pbxproj"

PRODUCT_FILES = (
    "DeliveryProtocolV1AckAuthentication.swift",
    "MailboxAckModels.swift",
    "MailboxAckFileReader.swift",
    "MailboxAckOutboxLookup.swift",
    "MailboxAckScanner.swift",
    "MailboxAckClassifier.swift",
    "MailboxAckDeletion.swift",
)
TEST_FILES = (
    "MailboxAckScannerTests.swift",
    "MailboxAckScannerFilesystemTests.swift",
    "MailboxAckScannerDeletionTests.swift",
    "MailboxAckScannerTestSupport.swift",
)


def test_ack_scanner_is_product_code_with_focused_swift_tests() -> None:
    project = PROJECT.read_text(encoding="utf-8")
    for name in PRODUCT_FILES:
        assert (CORE / name).is_file()
        assert project.count(name) >= 3
    for name in TEST_FILES:
        assert (TESTS / name).is_file()

    focused = "\n".join((TESTS / name).read_text() for name in TEST_FILES)
    for required in (
        "testPythonProducedCommittedAckEmitsExactlyOneEvent",
        "testLookupBeginsOnlyAfterSignatureVerification",
        "testDuplicateIdenticalAndConflictingValidAcksAreDeterministic",
        "testSymlinkHardlinkAndNonregularFinalsFailClosed",
        "testPathReplacementAfterOpenFailsClosed",
        "testDeletionRequiresDurableCommittedFinalizationProof",
        "testDeletionAfterValidConflictIsRejectedAndPreservesBothEntries",
    ):
        assert required in focused


def test_ack_authentication_precedes_outbox_lookup_and_scanner_is_nonterminal() -> None:
    scanner = (CORE / "MailboxAckScanner.swift").read_text(encoding="utf-8")
    authentication = scanner.index("DeliveryProtocolV1.authenticateAck")
    lookup = scanner.index("lookup.lookup")
    assert authentication < lookup

    product = "\n".join((CORE / name).read_text() for name in PRODUCT_FILES)
    for required in (
        "maximumScanFiles = 10_000",
        "maximumScanBytes: Int64 = 2 * 1024 * 1024 * 1024",
        "MailboxLayoutV1.maximumMetadataBytes",
        "O_NOFOLLOW",
        "openat(",
        "fstatat(",
        "fstat(",
        "st_nlink == 1",
        "unlinkat(",
        "MailboxLocatorV1.revalidate",
        "receiverSigningKeyID",
        "receiverBindingID",
        "payloadSHA256",
        "mailboxBoundItemsForAckScanning",
        "duplicateIdentical",
        "durableFinalizationRequired",
    ):
        assert required in product
    for forbidden in (
        "markUploaded(",
        "pendingItems(",
        "acknowledgeCursorCheckpoint(",
        "clearPending(",
        "UserDefaults",
        "os_log",
        "Logger(",
    ):
        assert forbidden not in product
