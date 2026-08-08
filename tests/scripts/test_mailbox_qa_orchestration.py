from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import cast

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from health_bridge.mailbox_qa.device_operations import (
    issue_device_observed_receipts,
)
from health_bridge.mailbox_qa.m3_contract import SCENARIO_PRODUCERS
from health_bridge.mailbox_qa.m3_models import M3AnchorV1, ScenarioReceiptV1
from health_bridge.mailbox_qa.orchestration import SCENARIOS, new_orchestration
from health_bridge.mailbox_qa.scenario_issuance import ScenarioReceiptContextV1
from tests.scripts.mailbox_m3_v1_support import build_m3_fixture, read
from tests.scripts.production_seal_support import write_synthetic_production_seal


def test_orchestration_is_ordered_and_never_skips_a_scenario() -> None:
    # Given: a fresh bounded QA orchestration run.
    state = new_orchestration("synthetic-run")

    # When: every scenario is advanced in contract order.
    for scenario in SCENARIOS:
        assert state.next_scenario == scenario
        state = state.advance(scenario)

    # Then: completion occurs only after cleanup, rollback, and preservation.
    assert state.status == "complete"
    assert state.next_scenario is None
    assert SCENARIOS[-3:] == ("cleanup", "rollback", "production_preservation")
    assert set(SCENARIO_PRODUCERS).issubset(SCENARIOS)


def test_uninstrumented_quota_fault_is_hold_not_pass() -> None:
    # Given: a run advanced to the lock/unlock scenario.
    state = new_orchestration("synthetic-run")
    while state.next_scenario != "lock_unlock":
        scenario = state.next_scenario
        assert scenario is not None
        state = state.advance(scenario)

    # When: faithful physical lock instrumentation is unavailable.
    state = state.hold_for_missing_instrumentation()

    # Then: the contract stops with an explicit HOLD.
    assert state.status == "hold"
    assert state.hold_reason == "faithful_instrumentation_unavailable"
    assert state.next_scenario is None


def test_orchestrator_executes_challenge_then_holds_for_observation(
    tmp_path: Path,
) -> None:
    # Given: a private empty run root and no physical-device observations.
    run_root = tmp_path / "qa-run"
    run_root.mkdir(mode=0o700)
    state = run_root / "orchestration.json"

    # When: init and two bounded execute operations run without scenario input.
    initialized = _run_orchestrator("init", state, run_root)
    challenge = _run_orchestrator("execute", state, run_root)
    physical = _run_orchestrator("execute", state, run_root)

    # Then: the challenge is private and the next physical action remains HOLD.
    assert initialized.returncode == 0
    assert challenge.returncode == 0
    assert (run_root / "challenge.hbjcs1").stat().st_mode & 0o777 == 0o600
    assert physical.returncode == 3
    output = cast("dict[str, object]", json.loads(physical.stdout))
    assert output["status"] == "hold"
    assert output["next_scenario"] == "build_qa_provenance"
    assert "PASS" not in physical.stdout


def test_orchestrator_has_no_caller_verdict_or_scenario_controls() -> None:
    # Given: the executable parent orchestration surface.
    source = Path("scripts/mailbox-qa-orchestrate.py").read_text(encoding="utf-8")

    # When / Then: callers cannot set scenario, checks, counts, or PASS.
    for forbidden in (
        "--scenario",
        "--checks",
        "--counts",
        "--verdict",
        "--timestamp",
        "--fingerprint",
        "faithful-fault-instrumentation",
    ):
        assert forbidden not in source


def test_device_owned_facts_issue_only_derived_parent_receipts(
    tmp_path: Path,
) -> None:
    # Given: a canonical device-signed report bound to a private challenge.
    fixture = build_m3_fixture(tmp_path / "attempt")
    fixture.report.chmod(0o600)
    anchor = M3AnchorV1.model_validate(read(fixture.anchor))
    context = ScenarioReceiptContextV1(
        v=1,
        kind="health_bridge.mailbox_qa_receipt_context.v1",
        run_id=anchor.run_id,
        challenge=anchor.challenge,
        head=anchor.head,
        qa_bundle_fingerprint=anchor.qa_bundle_fingerprint,
        qa_container_fingerprint=anchor.qa_container_fingerprint,
        created_at_ms=anchor.created_at_ms,
        expires_at_ms=anchor.expires_at_ms,
    )

    # When: the parent owner verifies the report and derives operation receipts.
    receipts = issue_device_observed_receipts(
        fixture.report,
        fixture.anchor,
        context,
        Ed25519PrivateKey.from_private_bytes(hashlib.sha256(b"m3-parent").digest()),
        provider_envelope=None,
    )
    parsed = tuple(ScenarioReceiptV1.model_validate(value) for value in receipts)

    # Then: only device-observable scenarios are issued, with no caller checks.
    assert {value.scenario for value in parsed} == {
        "authenticated_committed_ack",
        "restart_retry",
        "persisted_encoder_bytes_encrypted_unchanged",
        "lock_unlock",
        "foreground_background_termination",
        "quota_disk_fault",
    }
    assert all(value.producer == "parent_orchestrator" for value in parsed)


def _run_orchestrator(
    action: str,
    state: Path,
    run_root: Path,
) -> subprocess.CompletedProcess[str]:
    seal = run_root.parent / "production-seal.hbjcs1"
    seal_anchor, _ = write_synthetic_production_seal(seal)
    return subprocess.run(
        [
            sys.executable,
            "scripts/mailbox-qa-orchestrate.py",
            action,
            "--state",
            str(state),
            "--run-reference",
            "synthetic-run",
            "--run-root",
            str(run_root),
            "--production-seal",
            str(seal),
            "--production-seal-anchor-sha256",
            seal_anchor,
        ],
        check=False,
        capture_output=True,
        text=True,
    )
