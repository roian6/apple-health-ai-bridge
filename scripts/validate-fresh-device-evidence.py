#!/usr/bin/env python3
# ruff: noqa: ANN401,EM101,EM102,FBT003,T201,TRY003,TRY004
"""Validate private aggregate evidence for the fresh-device release gate.

The input must remain private and contain only the strict aggregate schema below.
Expected source/app/receiver hashes come from independent command-line arguments,
not from the evidence document itself. Output includes field names but never values.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path
from typing import Any

MAX_OFFLINE_PREFLIGHT_SECONDS = 8.0
LEAF = None
EVIDENCE_SCHEMA: dict[str, Any] = {
    "schema_version": LEAF,
    "synthetic": LEAF,
    "candidate": {
        "marketing_version": LEAF,
        "build_number": LEAF,
        "source_tree": LEAF,
        "executable_sha256": LEAF,
    },
    "fresh_install": {
        "bundle_absent_before_install": LEAF,
        "launched_without_payload": LEAF,
        "first_screen_not_connected": LEAF,
        "saved_receiver_present": LEAF,
        "pending_pairing_present": LEAF,
        "recovery_banner_present": LEAF,
        "queued_upload_count": LEAF,
        "identity_freshness": LEAF,
    },
    "permissions": {
        "local_network_prompt_exercised_by_human": LEAF,
        "apple_health_prompt_exercised_by_human": LEAF,
    },
    "receiver": {
        "owner": LEAF,
        "pid": LEAF,
        "executable_sha256": LEAF,
        "health_url_verified_from_iphone": LEAF,
        "mac_receiver_substituted": LEAF,
        "database_owner": LEAF,
        "request_owner": LEAF,
        "redemption_owner": LEAF,
        "ingest_owner": LEAF,
    },
    "pairing": {
        "method": LEAF,
        "payload_url_shortcut_used": LEAF,
        "app_relaunched_before_commit": LEAF,
        "redemption_baseline": LEAF,
        "redemption_final": LEAF,
        "redemption_delta": LEAF,
        "active_credential_baseline": LEAF,
        "active_credential_final": LEAF,
        "active_credential_delta": LEAF,
    },
    "first_sync": {
        "history_scope": LEAF,
        "completed": LEAF,
        "duration_seconds": LEAF,
        "sync_run_delta": LEAF,
        "accepted_batch_delta": LEAF,
    },
    "idempotence": {
        "completed": LEAF,
        "record_delta": LEAF,
        "duplicate_device_count": LEAF,
        "duplicate_credential_count": LEAF,
        "duplicate_record_count": LEAF,
    },
    "offline_preflight": {
        "elapsed_seconds": LEAF,
        "health_collection_delta": LEAF,
        "outbox_enqueue_delta": LEAF,
        "lane_upload_attempts": LEAF,
        "visible_loading_ended": LEAF,
    },
    "mid_transfer_outage": {
        "queued_uploads_created": LEAF,
        "persisted_in_background": LEAF,
        "persisted_after_foreground": LEAF,
    },
    "cancel": {
        "exercised": LEAF,
        "queued_uploads_before_cancel": LEAF,
        "queued_uploads_after_cancel": LEAF,
        "visible_loading_ended": LEAF,
    },
    "connection_check": {
        "durable_write_delta": LEAF,
        "outbox_enqueue_delta": LEAF,
    },
    "recovery": {
        "same_receiver": LEAF,
        "final_queue_count": LEAF,
        "duplicate_device_count": LEAF,
        "duplicate_credential_count": LEAF,
        "duplicate_record_count": LEAF,
    },
}


def _reject_nonfinite_json_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number is forbidden: {value}")


def _reject_duplicate_object_pairs(
    pairs: list[tuple[str, Any]],
) -> dict[str, Any]:
    document: dict[str, Any] = {}
    for key, value in pairs:
        if key in document:
            raise ValueError(f"duplicate field: {key}")
        document[key] = value
    return document


def _validate_structure(value: Any, schema: Any, path: str = "evidence") -> None:
    if schema is LEAF:
        if isinstance(value, (dict, list)):
            raise ValueError(f"non-aggregate field: {path}")
        return
    if not isinstance(value, dict):
        raise ValueError(f"invalid object: {path}")
    expected_keys = set(schema)
    actual_keys = set(value)
    missing = expected_keys - actual_keys
    unknown = actual_keys - expected_keys
    if missing:
        raise ValueError(f"missing required field: {path}.{sorted(missing)[0]}")
    if unknown:
        raise ValueError(f"unknown field: {path}.{sorted(unknown)[0]}")
    for key, child_schema in schema.items():
        _validate_structure(value[key], child_schema, f"{path}.{key}")


def _value(document: dict[str, Any], path: str) -> Any:
    current: Any = document
    for part in path.split("."):
        if not isinstance(current, dict) or part not in current:
            raise ValueError(f"missing required field: {path}")
        current = current[part]
    return current


def _require_equal(document: dict[str, Any], path: str, expected: Any) -> None:
    actual = _value(document, path)
    if type(actual) is not type(expected) or actual != expected:
        raise ValueError(f"invalid field: {path}")


def _require_integer(
    document: dict[str, Any],
    path: str,
    *,
    minimum: int = 0,
) -> int:
    value = _value(document, path)
    if type(value) is not int or value < minimum:
        raise ValueError(f"invalid integer field: {path}")
    return value


def _require_finite_number(
    document: dict[str, Any],
    path: str,
    *,
    minimum: float = 0,
    maximum: float | None = None,
) -> float:
    value = _value(document, path)
    if type(value) not in {int, float}:
        raise ValueError(f"invalid numeric field: {path}")
    numeric = float(value)
    if not math.isfinite(numeric) or numeric < minimum:
        raise ValueError(f"invalid numeric field: {path}")
    if maximum is not None and numeric > maximum:
        raise ValueError(f"invalid numeric field: {path}")
    return numeric


def _require_hex_value(value: Any, path: str, length: int) -> str:
    pattern = rf"[0-9a-fA-F]{{{length}}}"
    if not isinstance(value, str) or re.fullmatch(pattern, value) is None:
        raise ValueError(f"invalid hash field: {path}")
    return value.lower()


def _require_bound_hash(
    document: dict[str, Any],
    path: str,
    expected: str,
    length: int,
) -> None:
    actual = _require_hex_value(_value(document, path), path, length)
    expected_normalized = _require_hex_value(expected, f"expected {path}", length)
    if actual != expected_normalized:
        raise ValueError(f"candidate binding mismatch: {path}")


def validate(  # noqa: PLR0915
    document: dict[str, Any],
    *,
    expected_source_tree: str,
    expected_app_sha256: str,
    expected_receiver_sha256: str,
) -> None:
    _validate_structure(document, EVIDENCE_SCHEMA)
    _require_equal(document, "schema_version", 1)
    _require_equal(document, "synthetic", False)
    _require_equal(document, "candidate.marketing_version", "1.0.0")
    _require_equal(document, "candidate.build_number", 15)
    _require_bound_hash(document, "candidate.source_tree", expected_source_tree, 40)
    _require_bound_hash(
        document,
        "candidate.executable_sha256",
        expected_app_sha256,
        64,
    )

    _require_equal(document, "fresh_install.bundle_absent_before_install", True)
    _require_equal(document, "fresh_install.launched_without_payload", True)
    _require_equal(document, "fresh_install.first_screen_not_connected", True)
    _require_equal(document, "fresh_install.saved_receiver_present", False)
    _require_equal(document, "fresh_install.pending_pairing_present", False)
    _require_equal(document, "fresh_install.recovery_banner_present", False)
    _require_equal(document, "fresh_install.queued_upload_count", 0)
    freshness = _value(document, "fresh_install.identity_freshness")
    if freshness not in {
        "container-clean-keychain-unproven",
        "never-installed-or-erased-device",
    }:
        raise ValueError("invalid field: fresh_install.identity_freshness")

    _require_equal(
        document,
        "permissions.local_network_prompt_exercised_by_human",
        True,
    )
    _require_equal(
        document,
        "permissions.apple_health_prompt_exercised_by_human",
        True,
    )

    for path in (
        "receiver.owner",
        "receiver.database_owner",
        "receiver.request_owner",
        "receiver.redemption_owner",
        "receiver.ingest_owner",
    ):
        _require_equal(document, path, "linux")
    _require_integer(document, "receiver.pid", minimum=1)
    _require_bound_hash(
        document,
        "receiver.executable_sha256",
        expected_receiver_sha256,
        64,
    )
    _require_equal(document, "receiver.health_url_verified_from_iphone", True)
    _require_equal(document, "receiver.mac_receiver_substituted", False)

    _require_equal(document, "pairing.method", "camera-qr")
    _require_equal(document, "pairing.payload_url_shortcut_used", False)
    _require_equal(document, "pairing.app_relaunched_before_commit", False)
    for path, expected in (
        ("pairing.redemption_baseline", 0),
        ("pairing.redemption_final", 1),
        ("pairing.redemption_delta", 1),
        ("pairing.active_credential_baseline", 0),
        ("pairing.active_credential_final", 1),
        ("pairing.active_credential_delta", 1),
    ):
        _require_equal(document, path, expected)

    _require_equal(document, "first_sync.history_scope", "all")
    _require_equal(document, "first_sync.completed", True)
    _require_finite_number(document, "first_sync.duration_seconds")
    _require_integer(document, "first_sync.sync_run_delta", minimum=1)
    _require_integer(document, "first_sync.accepted_batch_delta", minimum=1)

    _require_equal(document, "idempotence.completed", True)
    for path in (
        "idempotence.record_delta",
        "idempotence.duplicate_device_count",
        "idempotence.duplicate_credential_count",
        "idempotence.duplicate_record_count",
    ):
        _require_equal(document, path, 0)

    _require_finite_number(
        document,
        "offline_preflight.elapsed_seconds",
        maximum=MAX_OFFLINE_PREFLIGHT_SECONDS,
    )
    for path in (
        "offline_preflight.health_collection_delta",
        "offline_preflight.outbox_enqueue_delta",
        "offline_preflight.lane_upload_attempts",
    ):
        _require_equal(document, path, 0)
    _require_equal(document, "offline_preflight.visible_loading_ended", True)

    _require_integer(
        document,
        "mid_transfer_outage.queued_uploads_created",
        minimum=1,
    )
    _require_equal(document, "mid_transfer_outage.persisted_in_background", True)
    _require_equal(document, "mid_transfer_outage.persisted_after_foreground", True)

    _require_equal(document, "cancel.exercised", True)
    queued_before_cancel = _require_integer(
        document,
        "cancel.queued_uploads_before_cancel",
        minimum=1,
    )
    queued_after_cancel = _require_integer(
        document,
        "cancel.queued_uploads_after_cancel",
        minimum=1,
    )
    if queued_after_cancel != queued_before_cancel:
        raise ValueError("invalid field: cancel.queued_uploads_after_cancel")
    _require_equal(document, "cancel.visible_loading_ended", True)

    _require_equal(document, "connection_check.durable_write_delta", 0)
    _require_equal(document, "connection_check.outbox_enqueue_delta", 0)

    _require_equal(document, "recovery.same_receiver", True)
    for path in (
        "recovery.final_queue_count",
        "recovery.duplicate_device_count",
        "recovery.duplicate_credential_count",
        "recovery.duplicate_record_count",
    ):
        _require_equal(document, path, 0)


def _parse_document(path: Path) -> dict[str, Any]:
    raw = json.loads(
        path.read_text(encoding="utf-8"),
        parse_constant=_reject_nonfinite_json_constant,
        object_pairs_hook=_reject_duplicate_object_pairs,
    )
    if not isinstance(raw, dict):
        raise ValueError("evidence root must be an object")
    return raw


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--expected-source-tree", required=True)
    parser.add_argument("--expected-app-sha256", required=True)
    parser.add_argument("--expected-receiver-sha256", required=True)
    args = parser.parse_args()
    try:
        validate(
            _parse_document(args.evidence),
            expected_source_tree=args.expected_source_tree,
            expected_app_sha256=args.expected_app_sha256,
            expected_receiver_sha256=args.expected_receiver_sha256,
        )
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"fresh-device evidence: FAIL ({exc})", file=sys.stderr)
        return 1
    print("fresh-device evidence: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
