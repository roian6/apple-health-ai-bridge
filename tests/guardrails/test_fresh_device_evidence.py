import json
import math
import subprocess
import sys
from pathlib import Path
from typing import cast

import pytest

VALIDATOR = Path("scripts/validate-fresh-device-evidence.py")
EXPECTED_SOURCE_TREE = "a" * 40
EXPECTED_APP_SHA256 = "b" * 64
EXPECTED_RECEIVER_SHA256 = "c" * 64
OTHER_SOURCE_TREE = "d" * 40
OTHER_SHA256 = "d" * 64


def _duplicate_json_fields(field: str, first: str, second: str) -> str:
    return f'"{field}": "{first}", "{field}": "{second}"'


def _valid_evidence() -> dict[str, object]:
    return {
        "schema_version": 1,
        "synthetic": False,
        "candidate": {
            "marketing_version": "1.0.0",
            "build_number": 15,
            "source_tree": EXPECTED_SOURCE_TREE,
            "executable_sha256": EXPECTED_APP_SHA256,
        },
        "fresh_install": {
            "bundle_absent_before_install": True,
            "launched_without_payload": True,
            "first_screen_not_connected": True,
            "saved_receiver_present": False,
            "pending_pairing_present": False,
            "recovery_banner_present": False,
            "queued_upload_count": 0,
            "identity_freshness": "container-clean-keychain-unproven",
        },
        "permissions": {
            "local_network_prompt_exercised_by_human": True,
            "apple_health_prompt_exercised_by_human": True,
        },
        "receiver": {
            "owner": "linux",
            "pid": 1234,
            "executable_sha256": EXPECTED_RECEIVER_SHA256,
            "health_url_verified_from_iphone": True,
            "mac_receiver_substituted": False,
            "database_owner": "linux",
            "request_owner": "linux",
            "redemption_owner": "linux",
            "ingest_owner": "linux",
        },
        "pairing": {
            "method": "camera-qr",
            "payload_url_shortcut_used": False,
            "app_relaunched_before_commit": False,
            "redemption_baseline": 0,
            "redemption_final": 1,
            "redemption_delta": 1,
            "active_credential_baseline": 0,
            "active_credential_final": 1,
            "active_credential_delta": 1,
        },
        "first_sync": {
            "history_scope": "all",
            "completed": True,
            "duration_seconds": 642.5,
            "sync_run_delta": 1,
            "accepted_batch_delta": 8,
        },
        "idempotence": {
            "completed": True,
            "record_delta": 0,
            "duplicate_device_count": 0,
            "duplicate_credential_count": 0,
            "duplicate_record_count": 0,
        },
        "offline_preflight": {
            "elapsed_seconds": 5.4,
            "health_collection_delta": 0,
            "outbox_enqueue_delta": 0,
            "lane_upload_attempts": 0,
            "visible_loading_ended": True,
        },
        "mid_transfer_outage": {
            "queued_uploads_created": 1,
            "persisted_in_background": True,
            "persisted_after_foreground": True,
        },
        "cancel": {
            "exercised": True,
            "queued_uploads_before_cancel": 2,
            "queued_uploads_after_cancel": 2,
            "visible_loading_ended": True,
        },
        "connection_check": {
            "durable_write_delta": 0,
            "outbox_enqueue_delta": 0,
        },
        "recovery": {
            "same_receiver": True,
            "final_queue_count": 0,
            "duplicate_device_count": 0,
            "duplicate_credential_count": 0,
            "duplicate_record_count": 0,
        },
    }


def _nested_object(document: dict[str, object], path: str) -> dict[str, object]:
    current = document
    for part in path.split("."):
        current = cast("dict[str, object]", current[part])
    return current


def _set_path(document: dict[str, object], path: str, value: object) -> None:
    parent_path, key = path.rsplit(".", maxsplit=1)
    _nested_object(document, parent_path)[key] = value


def _delete_path(document: dict[str, object], path: str) -> None:
    parent_path, key = path.rsplit(".", maxsplit=1)
    del _nested_object(document, parent_path)[key]


def _run_validator(
    tmp_path: Path,
    evidence: dict[str, object],
    *,
    expected_source_tree: str = EXPECTED_SOURCE_TREE,
    expected_app_sha256: str = EXPECTED_APP_SHA256,
    expected_receiver_sha256: str = EXPECTED_RECEIVER_SHA256,
) -> subprocess.CompletedProcess[str]:
    path = tmp_path / "private-evidence.json"
    _ = path.write_text(json.dumps(evidence), encoding="utf-8")
    return subprocess.run(
        [
            sys.executable,
            str(VALIDATOR),
            str(path),
            "--expected-source-tree",
            expected_source_tree,
            "--expected-app-sha256",
            expected_app_sha256,
            "--expected-receiver-sha256",
            expected_receiver_sha256,
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def _run_raw_validator(
    tmp_path: Path,
    raw_evidence: str,
) -> subprocess.CompletedProcess[str]:
    path = tmp_path / "private-evidence.json"
    _ = path.write_text(raw_evidence, encoding="utf-8")
    return subprocess.run(
        [
            sys.executable,
            str(VALIDATOR),
            str(path),
            "--expected-source-tree",
            EXPECTED_SOURCE_TREE,
            "--expected-app-sha256",
            EXPECTED_APP_SHA256,
            "--expected-receiver-sha256",
            EXPECTED_RECEIVER_SHA256,
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def test_fresh_device_evidence_validator_accepts_complete_aggregate_evidence(
    tmp_path: Path,
) -> None:
    completed = _run_validator(tmp_path, _valid_evidence())

    assert completed.returncode == 0, completed.stderr
    assert completed.stdout.strip() == "fresh-device evidence: PASS"


@pytest.mark.parametrize(
    "invalid_elapsed",
    [-1, math.nan, math.inf, -math.inf, True],
)
def test_fresh_device_evidence_validator_rejects_invalid_offline_timing(
    tmp_path: Path,
    invalid_elapsed: object,
) -> None:
    evidence = _valid_evidence()
    _set_path(evidence, "offline_preflight.elapsed_seconds", invalid_elapsed)

    completed = _run_validator(tmp_path, evidence)

    assert completed.returncode == 1
    assert (
        "offline_preflight.elapsed_seconds" in completed.stderr
        or "non-finite" in completed.stderr
    )


@pytest.mark.parametrize(
    ("path", "invalid_value"),
    [
        ("receiver.pid", 1.5),
        ("receiver.pid", True),
        ("first_sync.sync_run_delta", 1.5),
        ("first_sync.accepted_batch_delta", False),
        ("mid_transfer_outage.queued_uploads_created", 1.5),
        ("cancel.queued_uploads_before_cancel", 1.5),
        ("idempotence.record_delta", 0.0),
        ("recovery.final_queue_count", False),
    ],
)
def test_fresh_device_evidence_validator_rejects_non_integer_counts(
    tmp_path: Path,
    path: str,
    invalid_value: object,
) -> None:
    evidence = _valid_evidence()
    _set_path(evidence, path, invalid_value)

    completed = _run_validator(tmp_path, evidence)

    assert completed.returncode == 1
    assert path in completed.stderr


@pytest.mark.parametrize(
    ("expected_name", "expected_value"),
    [
        ("expected_source_tree", "d" * 40),
        ("expected_app_sha256", "d" * 64),
        ("expected_receiver_sha256", "d" * 64),
    ],
)
def test_fresh_device_evidence_validator_binds_independent_hashes(
    tmp_path: Path,
    expected_name: str,
    expected_value: str,
) -> None:
    kwargs = {expected_name: expected_value}

    completed = _run_validator(tmp_path, _valid_evidence(), **kwargs)  # type: ignore[arg-type]

    assert completed.returncode == 1
    assert "binding mismatch" in completed.stderr


@pytest.mark.parametrize(
    ("path", "malformed"),
    [
        ("candidate.source_tree", f" {'a' * 38} "),
        ("candidate.source_tree", f"{'a' * 38}  "),
        ("candidate.source_tree", f"{'a' * 18}  {'a' * 20}"),
        ("candidate.executable_sha256", f"{'b' * 62}  "),
        ("receiver.executable_sha256", f"{'c' * 30}  {'c' * 32}"),
    ],
)
def test_fresh_device_evidence_validator_rejects_whitespace_in_hashes(
    tmp_path: Path,
    path: str,
    malformed: str,
) -> None:
    evidence = _valid_evidence()
    _set_path(evidence, path, malformed)
    if path == "candidate.source_tree":
        completed = _run_validator(
            tmp_path,
            evidence,
            expected_source_tree=malformed,
        )
    elif path == "candidate.executable_sha256":
        completed = _run_validator(
            tmp_path,
            evidence,
            expected_app_sha256=malformed,
        )
    else:
        completed = _run_validator(
            tmp_path,
            evidence,
            expected_receiver_sha256=malformed,
        )

    assert completed.returncode == 1
    assert "hash field" in completed.stderr


@pytest.mark.parametrize(
    ("path", "invalid_value"),
    [
        ("fresh_install.saved_receiver_present", True),
        ("fresh_install.pending_pairing_present", True),
        ("fresh_install.recovery_banner_present", True),
        ("fresh_install.queued_upload_count", 1),
        ("permissions.local_network_prompt_exercised_by_human", False),
        ("permissions.apple_health_prompt_exercised_by_human", False),
        ("receiver.database_owner", "mac"),
        ("receiver.request_owner", "mac"),
        ("receiver.redemption_owner", "mac"),
        ("receiver.ingest_owner", "mac"),
        ("pairing.redemption_baseline", 1),
        ("pairing.redemption_final", 2),
        ("pairing.redemption_delta", 0),
        ("pairing.active_credential_baseline", 1),
        ("pairing.active_credential_final", 2),
        ("pairing.active_credential_delta", 0),
        ("cancel.exercised", False),
        ("cancel.queued_uploads_before_cancel", 0),
        ("cancel.queued_uploads_after_cancel", 1),
        ("cancel.visible_loading_ended", False),
        ("connection_check.durable_write_delta", 1),
        ("connection_check.outbox_enqueue_delta", 1),
    ],
)
def test_fresh_device_evidence_validator_enforces_each_new_release_gate(
    tmp_path: Path,
    path: str,
    invalid_value: object,
) -> None:
    evidence = _valid_evidence()
    _set_path(evidence, path, invalid_value)

    completed = _run_validator(tmp_path, evidence)

    assert completed.returncode == 1
    assert path in completed.stderr


@pytest.mark.parametrize(
    "path",
    [
        "fresh_install.saved_receiver_present",
        "permissions.local_network_prompt_exercised_by_human",
        "receiver.database_owner",
        "pairing.active_credential_final",
        "cancel.exercised",
        "connection_check.durable_write_delta",
    ],
)
def test_fresh_device_evidence_validator_rejects_missing_mandatory_fields(
    tmp_path: Path,
    path: str,
) -> None:
    evidence = _valid_evidence()
    _delete_path(evidence, path)

    completed = _run_validator(tmp_path, evidence)

    assert completed.returncode == 1
    assert path in completed.stderr


def test_fresh_device_evidence_validator_rejects_unknown_sensitive_fields(
    tmp_path: Path,
) -> None:
    evidence = _valid_evidence()
    pairing = _nested_object(evidence, "pairing")
    pairing["bearer_token"] = "must-not-be-accepted"

    completed = _run_validator(tmp_path, evidence)

    assert completed.returncode == 1
    assert "unknown field" in completed.stderr
    assert "must-not-be-accepted" not in completed.stderr


@pytest.mark.parametrize(
    ("original", "replacement"),
    [
        ('"synthetic": false', '"synthetic": true, "synthetic": false'),
        (
            f'"source_tree": "{EXPECTED_SOURCE_TREE}"',
            _duplicate_json_fields(
                "source_tree", OTHER_SOURCE_TREE, EXPECTED_SOURCE_TREE
            ),
        ),
        (
            f'"executable_sha256": "{EXPECTED_APP_SHA256}"',
            _duplicate_json_fields(
                "executable_sha256", OTHER_SHA256, EXPECTED_APP_SHA256
            ),
        ),
        (
            f'"executable_sha256": "{EXPECTED_RECEIVER_SHA256}"',
            _duplicate_json_fields(
                "executable_sha256", OTHER_SHA256, EXPECTED_RECEIVER_SHA256
            ),
        ),
    ],
)
def test_fresh_device_evidence_validator_rejects_duplicate_json_keys(
    tmp_path: Path,
    original: str,
    replacement: str,
) -> None:
    valid_json = json.dumps(_valid_evidence())
    raw = valid_json.replace(original, replacement, 1)
    assert raw != valid_json

    completed = _run_raw_validator(tmp_path, raw)

    assert completed.returncode == 1
    assert "duplicate field" in completed.stderr


def test_fresh_device_evidence_validator_rejects_nonaggregate_leaf_values(
    tmp_path: Path,
) -> None:
    evidence = _valid_evidence()
    _set_path(evidence, "first_sync.duration_seconds", [1, 2, 3])

    completed = _run_validator(tmp_path, evidence)

    assert completed.returncode == 1
    assert "non-aggregate field" in completed.stderr


def test_fresh_device_evidence_validator_requires_durable_outage_recovery(
    tmp_path: Path,
) -> None:
    evidence = _valid_evidence()
    _set_path(
        evidence,
        "mid_transfer_outage.persisted_after_foreground",
        False,  # noqa: FBT003
    )

    completed = _run_validator(tmp_path, evidence)

    assert completed.returncode == 1
    assert "mid_transfer_outage.persisted_after_foreground" in completed.stderr
