from __future__ import annotations

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
        "failure",
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

    # Then: every liveness point exists. Error recovery durably retains its
    # coarse token before ACK; full diagnostic persistence remains after ACK.
    for fragment in required_view_model_fragments:
        assert fragment in view_model
    observer_failure = view_model.split("private func noteHealthKitObserverFailure", 1)[
        1
    ].split("#endif", 1)[0]
    assert (
        "BackgroundRefreshScheduler.scheduleNextRefreshIfNeeded(viewModel: self)"
        in observer_failure
    )

    assert "observerCompletionHandler:" in catalog
    assert "observerAdmissionHandler:" in catalog
    assert "AutomaticSyncObserverEventLifecycle.process(" in catalog
    assert "AutomaticSyncDiagnosticDraft?" in catalog
    assert "let runID = UUID()" in catalog
    assert "acknowledge: completion.call" in catalog
    assert "completion.beforeRecovery" not in catalog
    assert "defer { acknowledge() }" in (
        ROOT
        / (
            "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/"
            "BackgroundDeliveryFailureRecovery.swift"
        )
    ).read_text(encoding="utf-8")
    assert "persistDiagnostic: observerCompletionHandler" in catalog
    assert "completedDraft, latency in" in view_model
    assert "persistCompletedObserverAutomaticSyncDiagnostic(" in view_model
    assert "if !diagnostic.defersPersistenceUntilObserverAcknowledgement" in view_model
    assert "backgroundSyncStore.lastSelectedLane" in view_model

    observer_start = view_model.split("coordinator.start(", 1)[1].split(
        "recordBackgroundSyncRegistrationIfAllowed(", 1
    )[0]
    admission = observer_start.split("observerAdmissionHandler:", 1)[1].split(
        "observerCompletionHandler:", 1
    )[0]
    continuation = observer_start.split(
        ") { [weak self] typeCode, diagnosticRunID in", 1
    )[1]
    assert "backgroundSyncStore.markPendingObserverTypeCodes([typeCode])" in admission
    assert (
        "BackgroundRefreshScheduler.scheduleNextRefreshIfNeeded(viewModel: self)"
        in admission
    )
    assert "runBackgroundRefreshSyncCollectingDiagnostic(" not in admission
    assert "runBackgroundRefreshSyncCollectingDiagnostic(" in continuation


def test_observer_diagnostic_persistence_seam_has_executable_boundary_coverage() -> (
    None
):
    diagnostics = DIAGNOSTICS.read_text(encoding="utf-8")
    tests = SWIFT_TESTS.read_text(encoding="utf-8")

    assert "enum AutomaticSyncObserverEventLifecycle" in diagnostics
    lifecycle = diagnostics.split("enum AutomaticSyncObserverEventLifecycle", 1)[
        1
    ].split("public struct AutomaticSyncDiagnosticRecord", 1)[0]
    admission = lifecycle.index("let admission = await admissionHandler()")
    acknowledgement = lifecycle.index("acknowledge()")
    continuation = lifecycle.index("diagnostic = await eventHandler()")
    persistence = lifecycle.index("persistDiagnostic(diagnostic, completionLatency)")
    assert admission < acknowledgement < continuation < persistence
    assert "testObserverAcknowledgesAfterAdmissionBeforeBlockedContinuation" in tests
    assert "testObserverAdmissionCanFinishWithoutStartingContinuation" in tests
    assert 'events, ["admission", "acknowledge", "continuation"]' in tests
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


def test_failure_recovery_reconciles_durable_state_and_uses_typed_diagnostics() -> None:
    background_sync = BACKGROUND_SYNC.read_text(encoding="utf-8")
    diagnostics = DIAGNOSTICS.read_text(encoding="utf-8")
    view_model = VIEW_MODEL.read_text(encoding="utf-8")

    recovery = background_sync.split(
        "public enum BackgroundSyncFailureRecoveryPolicy", 1
    )[1].split("public actor BackgroundSyncRunGate", 1)[0]
    compact_recovery = "".join(recovery.split())
    failure_finish = view_model.split(
        "private func finishBackgroundRunPreservingObserverDirtiness", 1
    )[1].split("private func deferAutomaticSyncForPendingOutboxIfNeeded", 1)[0]

    assert (
        "for:admittedPendingTypeCodes+gatePendingTypeCodes+durableTypeCodes"
        in compact_recovery
    )
    assert "&& !pendingTypeCodes.isEmpty" in recovery
    assert "loadPendingObserverTypeCodeGenerations()" in failure_finish
    assert "BackgroundSyncFailureRecoveryPolicy.plan(" in failure_finish
    assert (
        "await backgroundRunGate.retainObserverTypeCodes(recovery.pendingTypeCodes)"
        in failure_finish
    )
    assert "if recovery.shouldScheduleRetry" in failure_finish
    assert "clearPendingObserverTypeCodes" not in failure_finish
    assert "public struct AutomaticSyncDiagnosticFailure" in diagnostics
    assert "public let failure: AutomaticSyncDiagnosticFailure?" in diagnostics
    assert "diagnostic.noteFailure(failure)" in view_model
    assert "backgroundLaneFailureDetail" not in view_model
    assert "failureDetail: String?" not in view_model


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


def test_bounded_planner_is_independent_of_diagnostic_storage() -> None:
    # Scheduler behavior is exercised by BackgroundSyncWorkPlanTests; diagnostics
    # must remain fail-open rather than becoming a prerequisite for lane planning.
    source = BACKGROUND_SYNC.read_text(encoding="utf-8")
    start = source.index("    public static func workPlan(")
    end = source.index("    public static var observedHealthTypes", start)
    planner = source[start:end]
    assert "AutomaticSyncDiagnostic" not in planner
    assert "maximumLaneAttempts" in planner

    view_model = VIEW_MODEL.read_text(encoding="utf-8")
    start = view_model.index("let workPlan = HealthBridgeBackgroundSync.workPlan(")
    end = view_model.index("diagnostic.noteSelection", start)
    admission_plan = view_model[start:end]
    assert (
        "coreLaneLastSuccess: backgroundSyncStore.coreLaneLastSuccess" in admission_plan
    )
    assert "now: startedAt" in admission_plan
    assert "automaticSyncDiagnosticStore" not in admission_plan


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
        "testObserverAcknowledgesAfterAdmissionBeforeBlockedContinuation",
        "testObserverAdmissionCanFinishWithoutStartingContinuation",
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
