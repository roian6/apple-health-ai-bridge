from __future__ import annotations

import hashlib
import re
from pathlib import Path
from typing import Final

ROOT: Final = Path(__file__).parents[2]
DIAGNOSTICS: Final = ROOT / (
    "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/"
    "AutomaticSyncDiagnostics.swift"
)
DIAGNOSTIC_STORE: Final = ROOT / (
    "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/"
    "AutomaticSyncDiagnosticStore.swift"
)
BACKGROUND_SYNC: Final = ROOT / (
    "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/BackgroundSync.swift"
)
VIEW_MODEL: Final = (
    ROOT / "ios/HealthBridgeCompanion/App/HealthBridgeCompanionViewModel.swift"
)
CONTENT_VIEW: Final = ROOT / "ios/HealthBridgeCompanion/App/ContentView.swift"
HEALTHKIT_CATALOG: Final = ROOT / (
    "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/"
    "HealthKitReadTypeCatalog.swift"
)
SWIFT_TESTS: Final = ROOT / (
    "ios/HealthBridgeCompanion/Tests/HealthBridgeCompanionCoreTests/"
    "AutomaticSyncDiagnosticsTests.swift"
)
PROJECT: Final = (
    ROOT / "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj"
)
WORK_PLAN_SHA256: Final = (
    "980f24413eba8203b7a35fe53df7ed665dd044b5b3423b154fe0fda8e2a18b05"
)


def test_private_automatic_sync_diagnostic_store_is_bounded_and_recoverable() -> None:
    # Given: the source-only diagnostic milestone.
    assert DIAGNOSTICS.exists(), "automatic-sync diagnostic source is missing"

    # When: the private store contract is inspected.
    assert DIAGNOSTIC_STORE.exists(), "automatic-sync diagnostic store is missing"
    source = DIAGNOSTIC_STORE.read_text(encoding="utf-8")

    # Then: it is bounded, atomic, private, backup-excluded, and fail-open on damage.
    assert "maximumRecordCount = 32" in source
    assert ".suffix(maximumRecordCount)" in source
    assert "recordAccepted" in source
    assert "recordFinal" in source
    assert "record.runID" in source
    assert ".atomic" in source
    assert ".posixPermissions: 0o700" in source
    assert ".posixPermissions: 0o600" in source
    assert ".isExcludedFromBackup = true" in source
    assert ".protectionKey" in source
    assert "completeUntilFirstUserAuthentication" in source
    assert "automatic-sync-diagnostics.json" in source
    assert "diagnostic-write-" in source
    assert "replaceItemAt" in source
    assert "recoveringSnapshot" in source
    assert "pendingSinceBucketByLane" in source
    assert "pendingLaneKeys" in source
    assert "Self.pendingLaneKeys.contains($0.key)" in source
    assert "privacyPreservingPendingKey" not in source
    assert 'return "quantity:' not in source
    assert "[String: Date]" not in source


def test_diagnostic_record_contains_only_bounded_operational_metadata() -> None:
    # Given: the diagnostic record declaration.
    source = DIAGNOSTICS.read_text(encoding="utf-8")
    assert "case unknown" in source
    assert "observed pending" in source
    record = source.split("public struct AutomaticSyncDiagnosticRecord", 1)[1].split(
        "public init", 1
    )[0]

    # When: persisted field names are extracted.
    fields = set(re.findall(r"public let ([A-Za-z][A-Za-z0-9]*):", record))

    # Then: the schema has only the investigation's privacy-safe metadata.
    assert fields == {
        "admissionResult",
        "observerCompletionLatencyBucket",
        "oldestPendingLane",
        "oldestPendingLaneAgeBucket",
        "pendingLaneCount",
        "remainingPendingLaneCount",
        "runID",
        "runOutcome",
        "selectedLane",
        "triggerLane",
        "triggerReason",
        "wakeSource",
    }
    forbidden = {
        "bearer",
        "credential",
        "cursor",
        "endpoint",
        "identifier",
        "payload",
        "sampledate",
        "samplevalue",
        "token",
        "url",
    }
    assert fields.isdisjoint(forbidden)


def test_settings_render_distinct_read_only_automatic_sync_evidence_lines() -> None:
    # Given: the Settings automatic-sync section and its view model.
    content = CONTENT_VIEW.read_text(encoding="utf-8")
    view_model = VIEW_MODEL.read_text(encoding="utf-8")

    # When: the read-only diagnostic labels and values are inspected.
    labels = {
        "Current status": "backgroundSyncStatus",
        "Registration": "automaticSyncRegistrationLine",
        "BG request": "automaticSyncScheduleLine",
        "Last wake": "automaticSyncWakeLine",
        "Last run": "automaticSyncRunLine",
        "Latest lane": "automaticSyncLaneDiagnosticLine",
    }

    # Then: each evidence class has its own line without removing the current status.
    for label, property_name in labels.items():
        assert f'LabeledContent("{label}", value: viewModel.{property_name})' in content
        assert f"var {property_name}: String" in view_model
    automatic_sync_section = content.split('Section("Automatic Sync")', 1)[1].split(
        'Section("Activity Log")', 1
    )[0]
    assert (
        'LabeledContent("Current status", value: viewModel.backgroundSyncStatus)'
        in automatic_sync_section
    )


def test_sync_wiring_preserves_observer_completion_order() -> None:
    # Given: the existing automatic-sync and HealthKit observer flows.
    view_model = VIEW_MODEL.read_text(encoding="utf-8")
    catalog = HEALTHKIT_CATALOG.read_text(encoding="utf-8")

    # When: diagnostic calls and observer ACK are inspected.
    required_view_model_fragments = (
        "AutomaticSyncDiagnosticDraft(",
        "runID: diagnosticRunID",
        "diagnostic.noteAdmission(admission)",
        "diagnostic.noteSelection(workPlan.lane)",
        "diagnostic.noteRunAccepted()",
        "persistAcceptedAutomaticSyncDiagnostic(diagnostic)",
        "diagnostic.noteCompletion(",
        "automaticSyncDiagnosticStore.recordFinal(diagnostic.record)",
        "diagnostic.noteObserverCompletionLatency(latency)",
        "recordUnavailableAutomaticSyncDiagnostic(",
        "durableStateUnavailable: true",
    )

    # Then: every liveness point exists and HealthKit ACK precedes file I/O.
    for fragment in required_view_model_fragments:
        assert fragment in view_model
    assert "observerCompletionHandler:" in catalog
    assert "AutomaticSyncObserverEventLifecycle.process(" in catalog
    assert "AutomaticSyncDiagnosticDraft?" in catalog
    assert "let runID = UUID()" in catalog
    assert "acknowledge: completion.call" in catalog
    assert "persistDiagnostic: observerCompletionHandler" in catalog
    assert "completedDraft, latency in" in view_model
    assert "persistCompletedObserverAutomaticSyncDiagnostic(" in view_model
    assert "if !diagnostic.defersPersistenceUntilObserverAcknowledgement" in view_model
    assert "backgroundSyncStore.lastSelectedLane" in view_model


def test_observer_diagnostic_persistence_seam_has_executable_boundary_coverage() -> (
    None
):
    diagnostics = DIAGNOSTICS.read_text(encoding="utf-8")
    tests = SWIFT_TESTS.read_text(encoding="utf-8")

    assert "enum AutomaticSyncObserverEventLifecycle" in diagnostics
    assert "let diagnostic = await eventHandler()" in diagnostics
    assert "acknowledge()" in diagnostics
    assert "persistDiagnostic(diagnostic, completionLatency)" in diagnostics
    assert "testObserverDiagnosticPersistenceBeginsOnlyAfterAcknowledgement" in tests
    assert "FileManager.default.fileExists(atPath: fileURL.path)" in tests
    assert "store.recordFinal(completedDraft.record)" in tests


def test_diagnostic_lifecycle_distinguishes_accepted_failed_and_completed() -> None:
    diagnostics = DIAGNOSTICS.read_text(encoding="utf-8")
    draft = (
        ROOT
        / (
            "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/"
            "AutomaticSyncDiagnosticDraft.swift"
        )
    ).read_text(encoding="utf-8")
    view_model = VIEW_MODEL.read_text(encoding="utf-8")

    assert "case accepted" in diagnostics
    assert "case deferred" in diagnostics
    assert "case failed" in diagnostics
    assert "func noteRunAccepted()" in draft
    assert "succeeded ? .completed : .failed" in view_model
    assert "mailboxReconciliationPoint == .beforePayloadGeneration" in view_model
    assert "case .failed:" in view_model
    assert "diagnostic.noteCompletion(.failed)" in view_model
    assert "automaticSyncDiagnosticStore.recordFinal(diagnostic.record)" in view_model


def test_diagnostic_types_are_not_connected_to_upload_or_public_status_surfaces() -> (
    None
):
    # Given: every batch, transport, receiver, and public status source file.
    private_symbols = ("AutomaticSyncDiagnosticRecord", "AutomaticSyncDiagnosticStore")
    excluded_paths = [
        *ROOT.glob(
            "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/*Batch*.swift"
        ),
        *ROOT.glob(
            "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/*Upload*.swift"
        ),
        ROOT
        / (
            "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/"
            "ReceiverClient.swift"
        ),
        ROOT / "src/health_bridge/status.py",
    ]

    # When: those outbound/public surfaces are scanned.
    offenders = {
        str(path.relative_to(ROOT))
        for path in excluded_paths
        if any(symbol in path.read_text(encoding="utf-8") for symbol in private_symbols)
    }

    # Then: diagnostic history has no outbound or public-status dependency.
    assert offenders == set()


def test_work_plan_policy_remains_byte_identical() -> None:
    # Given: the planner implementation boundary from public origin/main.
    source = BACKGROUND_SYNC.read_text(encoding="utf-8")
    work_plan_start = r"    public static func workPlan\(.*?\n"
    observed_types_start = r"    public static var observedHealthTypes"
    pattern = f"{work_plan_start}{observed_types_start}"
    match = re.search(
        pattern,
        source,
        flags=re.DOTALL,
    )
    assert match is not None

    # When: its exact source bytes are hashed.
    digest = hashlib.sha256(match.group(0).encode()).hexdigest()

    # Then: diagnostic instrumentation has not changed planner policy.
    assert digest == WORK_PLAN_SHA256


def test_swift_model_store_rendering_tests_and_xcode_membership_are_present() -> None:
    # Given: the later-Mac Swift gate and the checked-in Xcode project.
    assert SWIFT_TESTS.exists(), "focused Swift diagnostic tests are missing"
    tests = SWIFT_TESTS.read_text(encoding="utf-8")
    project = PROJECT.read_text(encoding="utf-8")

    # When: the intended pure behavior cases are inspected.
    cases = (
        "testHistoryEvictsOldestRecordsAtBound",
        "testMissingAndCorruptFilesRecoverWithoutThrowing",
        "testPendingLaneAgeUsesCoarseObservedDurationBuckets",
        "testQuantityPendingAgeTracksOnlyTheCoarseLane",
        "testRecoveryScrubsLegacyNonLanePendingKeysFromDisk",
        "testObserverDiagnosticPersistenceBeginsOnlyAfterAcknowledgement",
        "testLatestLaneRenderingOmitsPrivateValuesAndIdentifiers",
        "testObserverCompletionLatencyUpdatesOnlyTheMatchingRun",
        "testAcceptedDeferredAndFailedOutcomesRemainDistinct",
        "testFinalRecordReplacesOnlyItsDurableAcceptedCheckpoint",
        "testSkippedAttemptCannotReplaceAnotherRunsAcceptedCheckpoint",
        "testBoundedHistoryPreservesTheActiveAcceptedCheckpoint",
    )

    # Then: all cases and the new production source are available to later Mac builds.
    for case in cases:
        assert f"func {case}()" in tests
    for source_name in (
        "AutomaticSyncDiagnostics.swift",
        "AutomaticSyncDiagnosticStore.swift",
        "AutomaticSyncDiagnosticDraft.swift",
    ):
        assert project.count(f"{source_name} in Sources") == 2
        assert project.count(f"path = {source_name};") == 1
