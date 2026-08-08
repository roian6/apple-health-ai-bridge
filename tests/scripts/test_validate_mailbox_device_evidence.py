from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING

import pytest

from health_bridge._mailbox_evidence_models import PhysicalReport
from tests.scripts.mailbox_evidence_support import (
    ARCHIVE_SHA,
    CONNECTION_HANDLE,
    DEVICE_SIGNING_KEY_ID,
    RECEIVER_ID,
    build_synthetic_evidence,
    read_document,
    run_validator,
    write_document,
)

if TYPE_CHECKING:
    from health_bridge.contract._hbjcs1 import JsonValue

ROOT = Path(__file__).resolve().parents[2]


def test_report_schema_is_exact_and_aggregate_only() -> None:
    report = PhysicalReport.model_validate_json(
        (
            ROOT / "fixtures/mailbox_evidence/m3/aggregate-report-shape.synthetic.json"
        ).read_bytes()
    )

    assert set(PhysicalReport.model_fields) == {
        "v",
        "kind",
        "run_id",
        "challenge",
        "embedded_commit_sha",
        "bundle_identifier_sha256",
        "app_version",
        "build_number",
        "device_identifier_sha256",
        "device_model",
        "os_version",
        "receiver_fingerprint",
        "device_signing_key_fingerprint",
        "connection_generation",
        "started_at_ms",
        "finished_at_ms",
        "scenario_results",
        "transition_counts",
        "receipt_id",
        "dataset_generation",
        "signature",
    }
    assert "payload" not in " ".join(PhysicalReport.model_fields)
    assert "digest" not in " ".join(PhysicalReport.model_fields)
    names = [item.name for item in report.scenario_results]
    assert names == [
        "persisted_encoder_bytes_encrypted_unchanged",
        "strict_receiver_parse_without_reserialization",
    ]


def test_valid_aggregate_report_uses_local_anchor_and_consumes_challenge(
    tmp_path: Path,
) -> None:
    fixture = build_synthetic_evidence(tmp_path / "evidence")

    result = run_validator(fixture)

    assert result.returncode == 0, result.stderr
    assert result.stdout == "PASS mailbox physical evidence\n"
    assert result.stderr == ""
    state = read_document(fixture.state_path)
    bindings = state["bindings"]
    assert isinstance(bindings, list)
    binding = bindings[0]
    assert isinstance(binding, dict)
    assert binding["consumed"] is True


@pytest.mark.parametrize(
    "forbidden_key",
    [
        "receiver_id",
        "device_id",
        "device_signing_key_id",
        "device_agreement_key_id",
        "receiver_signing_key_id",
        "receiver_agreement_key_id",
        "sender_signing_key_id",
        "sender_agreement_key_id",
        "payload_bytes",
        "payload_sha256",
        "pairing_secret",
        "bearer_token",
        "health_data",
    ],
)
def test_forbidden_report_data_is_rejected_before_bad_signature(
    tmp_path: Path,
    forbidden_key: str,
) -> None:
    fixture = build_synthetic_evidence(tmp_path / "evidence")
    report = read_document(fixture.report_path)
    report[forbidden_key] = "synthetic-forbidden"
    report["signature"] = "A" * 86
    write_document(fixture.report_path, report)

    result = run_validator(fixture)

    assert result.returncode == 1
    assert result.stderr == "FAIL forbidden_data\n"
    assert "synthetic-forbidden" not in result.stderr


def test_report_public_key_is_rejected_before_bad_signature(tmp_path: Path) -> None:
    fixture = build_synthetic_evidence(tmp_path / "evidence")
    report = read_document(fixture.report_path)
    report["alternate_public_key"] = "A" * 43
    report["signature"] = "A" * 86
    write_document(fixture.report_path, report)

    result = run_validator(fixture)

    assert result.returncode == 1
    assert result.stderr == "FAIL forbidden_data\n"


def test_scalar_alias_equal_to_local_identifier_fails_before_signature(
    tmp_path: Path,
) -> None:
    fixture = build_synthetic_evidence(tmp_path / "evidence")
    report = read_document(fixture.report_path)
    report["correlation_label"] = RECEIVER_ID
    report["signature"] = "A" * 86
    write_document(fixture.report_path, report)

    result = run_validator(fixture)

    assert result.returncode == 1
    assert result.stderr == "FAIL forbidden_identifier\n"
    assert RECEIVER_ID not in result.stderr


def test_missing_or_ambiguous_anchor_fails_closed(tmp_path: Path) -> None:
    missing = build_synthetic_evidence(tmp_path / "missing")
    state = read_document(missing.state_path)
    state["bindings"] = []
    write_document(missing.state_path, state)
    ambiguous = build_synthetic_evidence(tmp_path / "ambiguous")
    state = read_document(ambiguous.state_path)
    bindings = state["bindings"]
    assert isinstance(bindings, list)
    bindings.append(bindings[0])
    write_document(ambiguous.state_path, state)

    missing_result = run_validator(missing)
    ambiguous_result = run_validator(ambiguous)

    assert missing_result.returncode == 1
    assert missing_result.stderr == "FAIL anchored_lookup_missing\n"
    assert ambiguous_result.returncode == 1
    assert ambiguous_result.stderr == "FAIL anchored_lookup_ambiguous\n"


@pytest.mark.parametrize(
    "fingerprint_field",
    ["receiver_fingerprint", "device_signing_key_fingerprint"],
)
def test_fingerprint_mismatch_fails_closed(
    tmp_path: Path,
    fingerprint_field: str,
) -> None:
    mismatch = build_synthetic_evidence(tmp_path / "mismatch")
    report = read_document(mismatch.report_path)
    report[fingerprint_field] = "0" * 16
    write_document(mismatch.report_path, report)

    mismatch_result = run_validator(mismatch)

    assert mismatch_result.returncode == 1
    assert mismatch_result.stderr == "FAIL fingerprint_mismatch\n"


def test_fingerprint_collision_fails_closed(tmp_path: Path) -> None:
    collision = build_synthetic_evidence(tmp_path / "collision")
    state = read_document(collision.state_path)
    connections = state["connections"]
    assert isinstance(connections, list)
    connection = connections[0]
    assert isinstance(connection, dict)
    colliding: dict[str, JsonValue] = dict(connection)
    colliding["connection_handle"] = "second-synthetic-connection"
    connections.append(colliding)
    write_document(collision.state_path, state)

    collision_result = run_validator(collision)

    assert collision_result.returncode == 1
    assert collision_result.stderr == "FAIL fingerprint_collision\n"


def test_required_scenarios_and_aggregate_only_shape_are_strict(tmp_path: Path) -> None:
    fixture = build_synthetic_evidence(tmp_path / "evidence")
    report = read_document(fixture.report_path)
    results = report["scenario_results"]
    assert isinstance(results, list)
    del results[1]
    write_document(fixture.report_path, report)

    result = run_validator(fixture)

    assert result.returncode == 1
    assert result.stderr == "FAIL scenario_missing\n"


@pytest.mark.parametrize(
    ("artifact_name", "field", "replacement"),
    [
        ("codesign", "archive_sha256", "2" * 64),
        ("codesign", "code_directory_hash", "2" * 40),
        ("codesign", "signing_identity_sha256", "2" * 64),
        ("codesign", "container_identifier_sha256", "2" * 64),
        ("codesign", "bundle_identifier_sha256", "2" * 64),
        ("codesign", "verified", False),
        ("install", "archive_sha256", "2" * 64),
        ("install", "install_receipt_sha256", "2" * 64),
        ("install", "device_identifier_sha256", "2" * 64),
        ("install", "device_model", "SyntheticPhone2,1"),
        ("install", "os_version", "18.1-synthetic"),
        ("install", "build_number", "16"),
    ],
)
def test_codesign_and_install_bindings_are_exact(
    tmp_path: Path,
    artifact_name: str,
    field: str,
    replacement: JsonValue,
) -> None:
    fixture = build_synthetic_evidence(tmp_path / "evidence")
    path = (
        fixture.codesign_path if artifact_name == "codesign" else fixture.install_path
    )
    artifact = read_document(path)
    artifact[field] = replacement
    write_document(path, artifact)

    result = run_validator(fixture)

    assert result.returncode == 1
    assert result.stderr == "FAIL artifact_binding_mismatch\n"
    assert ARCHIVE_SHA not in result.stderr


def test_embedded_commit_must_match_harness_and_requested_commit(
    tmp_path: Path,
) -> None:
    fixture = build_synthetic_evidence(tmp_path / "evidence")
    report = read_document(fixture.report_path)
    report["embedded_commit_sha"] = "2" * 40
    write_document(fixture.report_path, report)

    result = run_validator(fixture)

    assert result.returncode == 1
    assert result.stderr == "FAIL artifact_binding_mismatch\n"


def test_stale_challenge_and_failed_scenario_fail_closed(tmp_path: Path) -> None:
    stale = build_synthetic_evidence(tmp_path / "stale")
    state = read_document(stale.state_path)
    bindings = state["bindings"]
    assert isinstance(bindings, list)
    binding = bindings[0]
    assert isinstance(binding, dict)
    binding["expires_at_ms"] = 1
    write_document(stale.state_path, state)
    failed = build_synthetic_evidence(tmp_path / "failed")
    report = read_document(failed.report_path)
    scenarios = report["scenario_results"]
    assert isinstance(scenarios, list)
    scenario = scenarios[0]
    assert isinstance(scenario, dict)
    scenario["result"] = "fail"
    write_document(failed.report_path, report)

    stale_result = run_validator(stale)
    failed_result = run_validator(failed)

    assert stale_result.returncode == 1
    assert stale_result.stderr == "FAIL challenge_stale\n"
    assert failed_result.returncode == 1
    assert failed_result.stderr == "FAIL scenario_failed\n"


def test_reused_challenge_and_invalid_signature_fail(tmp_path: Path) -> None:
    reused = build_synthetic_evidence(tmp_path / "reused")
    state = read_document(reused.state_path)
    bindings = state["bindings"]
    assert isinstance(bindings, list)
    binding = bindings[0]
    assert isinstance(binding, dict)
    binding["consumed"] = True
    write_document(reused.state_path, state)
    invalid = build_synthetic_evidence(tmp_path / "invalid")
    report = read_document(invalid.report_path)
    report["signature"] = "A" * 86
    write_document(invalid.report_path, report)

    reused_result = run_validator(reused)
    invalid_result = run_validator(invalid)

    assert reused_result.returncode == 1
    assert reused_result.stderr == "FAIL challenge_reused\n"
    assert invalid_result.returncode == 1
    assert invalid_result.stderr == "FAIL signature_invalid\n"


@pytest.mark.parametrize(
    "prerequisite",
    ["signing", "container", "device", "account", "authorization"],
)
def test_missing_external_prerequisite_is_hold_never_pass(
    tmp_path: Path,
    prerequisite: str,
) -> None:
    fixture = build_synthetic_evidence(tmp_path / "evidence")
    prerequisites_path = fixture.directory / "prerequisites.hbjcs1"
    prerequisites = read_document(prerequisites_path)
    prerequisites[prerequisite] = "unavailable"
    write_document(prerequisites_path, prerequisites)

    result = run_validator(fixture)

    assert result.returncode == 3
    assert result.stdout == "HOLD external prerequisite unavailable\n"
    assert result.stderr == ""


def test_unknown_report_field_is_rejected(tmp_path: Path) -> None:
    fixture = build_synthetic_evidence(tmp_path / "evidence")
    report = read_document(fixture.report_path)
    report["unexpected_counter"] = 1
    write_document(fixture.report_path, report)

    result = run_validator(fixture)

    assert result.returncode == 1
    assert result.stderr == "FAIL schema_invalid\n"
    assert CONNECTION_HANDLE not in result.stderr
    assert DEVICE_SIGNING_KEY_ID not in result.stderr
