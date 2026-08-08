#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import hashlib
import re
import sys
from pathlib import Path
from typing import ClassVar, Final, Literal, final

from pydantic import BaseModel, ConfigDict, ValidationError, model_validator
from pydantic_core import PydanticCustomError

BASELINE_FILENAME: Final = "delivery_compatibility_v1.synthetic.json"
BASELINE_SHA256: Final = (
    "6211a8a4302ebb20995467d552961d8c4f1e8a718c33a8ed8a4e02709a35ad1c"
)
SHA256_PATTERN: Final = re.compile(r"^[0-9a-f]{64}$")
RAW_BATCH_SHA256: Final = (
    "63bd969e3b0844c4c58af1a8c538a34e316e59166377178bdb2d2efacc03a3bf"
)
SWIFT_PAYLOAD_SHA256: Final = (
    "3ad1b8c41d0dff1ab6bc8e39ffcd98720ed2b97a70a09b42d304e26a9f1cd93a"
)
V3_PAYLOAD_SHA256: Final = (
    "bcce52a6353d58f0e515ef0d9a5df2c2d690826dd47669d66068120ab722612b"
)
STATUS_SHA256: Final = (
    "8fc30a841ca71533df4154b11c7f99415b7e413c7e0efd4f9f31ea36bace5058"
)
MCP_SHA256: Final = "6d6e5b295be8bced6abbeef4e847d0470ec6e4c9d18178750f35ac1fb4378ac7"
EXPECTED_ROWS: Final = {
    "python_http_v1_raw_batch": ("python_http", "v1", "unchanged"),
    "python_http_v1_unauthorized": ("python_http", "v1", "unchanged"),
    "python_pairing_v1_bundle": ("python_pairing", "v1", "unchanged"),
    "python_pairing_v2_invitation": ("python_pairing", "v2", "unchanged"),
    "swift_direct_upload_v1": ("swift_direct_upload", "v1", "unchanged"),
    "swift_file_outbox_v3_read": ("swift_file_outbox", "v3", "unchanged"),
    "swift_file_outbox_v4_read": ("swift_file_outbox", "v4", "exact"),
    "package_fixture_v1": ("python_package", "v1", "unchanged"),
    "status_v1_generation": ("python_status", "v1", "unchanged"),
    "mcp_v1_generation": ("python_mcp", "v1", "unchanged"),
    "swift_encoder_file_outbox_direct_http_exact_bytes": (
        "swift_exact_bytes",
        "v1",
        "exact",
    ),
    "swift_file_outbox_delivery_plaintext_exact_bytes": (
        "swift_exact_bytes",
        "v1",
        "exact",
    ),
}
SWIFT_ROWS: Final = frozenset(
    {
        "swift_direct_upload_v1",
        "swift_file_outbox_v4_read",
        "swift_encoder_file_outbox_direct_http_exact_bytes",
        "swift_file_outbox_delivery_plaintext_exact_bytes",
    }
)
RAW_BATCH_ROWS: Final = frozenset({"python_http_v1_raw_batch", "package_fixture_v1"})


class CompatibilityModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )


class Ownership(CompatibilityModel):
    auth: Literal[
        "bearer_boundary",
        "none",
        "pairing_v1_bundle",
        "pairing_v2_invitation",
        "read_only_local_db",
        "receiver_signed_ack",
    ]
    ingest: Literal["legacy_strict_batch_parser", "none", "shared_acceptance"]
    generation: Literal[
        "file_outbox_manifest",
        "mcp_v1",
        "receiver_settings",
        "receiver_token_store",
        "sqlite_schema",
        "status_v1",
    ]
    finalization: Literal[
        "direct_mark_uploaded",
        "mailbox_committed_ack",
        "none",
        "package_smoke",
        "read_only",
    ]


class CompatibilityRow(CompatibilityModel):
    row_id: str
    surface: str
    protocol: str
    comparison: Literal["unchanged", "exact"]
    baseline_sha256: str
    candidate_sha256: str
    byte_count: int
    response_sha256: str | None
    http_status: int | None
    ingest_count: int
    connection_generation: int | None
    post_enqueue_encoder_invocations: int
    ownership: Ownership

    @model_validator(mode="after")
    def valid_values(self) -> CompatibilityRow:
        digests = (self.baseline_sha256, self.candidate_sha256)
        if self.response_sha256 is not None:
            digests = (*digests, self.response_sha256)
        if any(SHA256_PATTERN.fullmatch(value) is None for value in digests):
            error_type, error_message = "sha256", "invalid sha256"
            raise PydanticCustomError(error_type, error_message)
        counts = (
            self.byte_count,
            self.ingest_count,
            self.post_enqueue_encoder_invocations,
        )
        if min(counts) < 0:
            error_type, error_message = "count", "invalid count"
            raise PydanticCustomError(error_type, error_message)
        if self.connection_generation is not None and self.connection_generation < 0:
            error_type, error_message = "generation", "invalid generation"
            raise PydanticCustomError(error_type, error_message)
        return self


class CompatibilityMatrix(CompatibilityModel):
    schema_id: Literal["health_bridge.delivery_compatibility.v1"]
    schema_version: Literal[1]
    approved_baseline: Literal["m2-v1-v2-synthetic"]
    plan_sha256: Literal[
        "f6e982dc6804c03dd4138a05fc9fad4905073fb070f67b19697b4340478e0aaf"
    ]
    rows: tuple[CompatibilityRow, ...]

    @model_validator(mode="after")
    def exact_rows(self) -> CompatibilityMatrix:
        row_ids = [row.row_id for row in self.rows]
        if len(row_ids) != len(set(row_ids)) or set(row_ids) != set(EXPECTED_ROWS):
            error_type, error_message = "rows", "invalid rows"
            raise PydanticCustomError(error_type, error_message)
        return self


class DeliveryVector(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="ignore", frozen=True)

    plaintext: str
    payload_sha256: str


@final
class CliArgs(argparse.Namespace):
    def __init__(self) -> None:
        super().__init__()
        self.fixtures = Path("fixtures")
        self.strict = False


def load_matrix(path: Path) -> CompatibilityMatrix | None:
    try:
        return CompatibilityMatrix.model_validate_json(path.read_bytes())
    except (OSError, ValidationError):
        return None


def validate_matrix(matrix: CompatibilityMatrix, fixtures: Path) -> str | None:
    rows = {row.row_id: row for row in matrix.rows}
    checks = (
        _validate_rows(rows),
        _validate_fixture_hashes(rows, fixtures),
        _validate_ownership(rows),
    )
    return next((failure for failure in checks if failure is not None), None)


def _validate_rows(rows: dict[str, CompatibilityRow]) -> str | None:
    for row_id, metadata in EXPECTED_ROWS.items():
        row = rows[row_id]
        if (
            (row.surface, row.protocol, row.comparison) != metadata
            or row.baseline_sha256 != row.candidate_sha256
            or row.post_enqueue_encoder_invocations != 0
        ):
            return row_id
    fixed_digests = {
        "swift_file_outbox_v3_read": V3_PAYLOAD_SHA256,
        "status_v1_generation": STATUS_SHA256,
        "mcp_v1_generation": MCP_SHA256,
    }
    return next(
        (
            row_id
            for row_id, digest in fixed_digests.items()
            if rows[row_id].candidate_sha256 != digest
        ),
        None,
    )


def _validate_fixture_hashes(
    rows: dict[str, CompatibilityRow],
    fixtures: Path,
) -> str | None:
    raw_batch = _file_digest(fixtures / "health_bridge_batch_v1.synthetic.json")
    swift_payload = _swift_payload_digest(fixtures / "delivery_v1_swift.synthetic.json")
    row_digests = (
        *((row_id, raw_batch) for row_id in RAW_BATCH_ROWS),
        *((row_id, swift_payload) for row_id in SWIFT_ROWS),
    )
    return next(
        (
            row_id
            for row_id, digest in row_digests
            if rows[row_id].candidate_sha256 != digest
        ),
        None,
    )


def _validate_ownership(rows: dict[str, CompatibilityRow]) -> str | None:
    direct_id = "swift_encoder_file_outbox_direct_http_exact_bytes"
    mailbox_id = "swift_file_outbox_delivery_plaintext_exact_bytes"
    if rows[direct_id].ownership.finalization != "direct_mark_uploaded":
        return direct_id
    if rows[mailbox_id].ownership.finalization != "mailbox_committed_ack":
        return mailbox_id
    return None


def _file_digest(path: Path) -> str | None:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None


def _swift_payload_digest(path: Path) -> str | None:
    try:
        vector = DeliveryVector.model_validate_json(path.read_bytes())
        padded = vector.plaintext + "=" * (-len(vector.plaintext) % 4)
        plaintext = base64.urlsafe_b64decode(padded.encode("ascii"))
    except (OSError, ValidationError, ValueError):
        return None
    digest = hashlib.sha256(plaintext).hexdigest()
    return digest if digest == vector.payload_sha256 == SWIFT_PAYLOAD_SHA256 else None


def main() -> int:
    parser = argparse.ArgumentParser()
    _ = parser.add_argument("--fixtures", type=Path, default=Path("fixtures"))
    _ = parser.add_argument("--strict", action="store_true")
    args = parser.parse_args(namespace=CliArgs())
    if not args.strict:
        _ = sys.stdout.write("FAIL compatibility unsupported_invocation\n")
        return 1
    baseline = args.fixtures / BASELINE_FILENAME
    if not baseline.is_file():
        _ = sys.stdout.write("FAIL compatibility missing_approved_baseline\n")
        return 1
    matrix = load_matrix(baseline)
    if matrix is None:
        _ = sys.stdout.write("FAIL compatibility invalid_baseline\n")
        return 1
    failure = validate_matrix(matrix, args.fixtures)
    if failure is None and _file_digest(baseline) != BASELINE_SHA256:
        failure = "approved_baseline_digest"
    if failure is not None:
        _ = sys.stdout.write(f"FAIL compatibility {failure}\n")
        return 1
    _ = sys.stdout.write("PASS compatibility\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
