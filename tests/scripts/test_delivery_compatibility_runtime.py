from __future__ import annotations

import hashlib
import json
import sqlite3
from pathlib import Path
from typing import ClassVar, Final

from pydantic import BaseModel, ConfigDict, TypeAdapter

from health_bridge.ingest import ingest_fixture
from health_bridge.mcp.server import mcp_smoke_result
from health_bridge.receiver.pairing import (
    ReceiverPairingBundle,
    ReceiverPairingInvitationPayload,
)
from health_bridge.receiver.tokens import create_receiver_token
from health_bridge.status import read_status_snapshot
from health_bridge.storage.database import initialize_database
from tests.receiver.test_legacy_http_contract import (
    FIXTURE_PATH,
    LEGACY_TOKEN,
    post_raw_batch,
    running_receiver,
)

MATRIX_PATH: Final = Path("fixtures/delivery_compatibility_v1.synthetic.json")
COUNT_ADAPTER: Final[TypeAdapter[int]] = TypeAdapter(int)
NORMALIZED_TIMESTAMP: Final = "2000-01-01T00:00:00Z"


class MatrixModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="ignore", frozen=True)


class MatrixRow(MatrixModel):
    row_id: str
    candidate_sha256: str
    byte_count: int
    response_sha256: str | None
    http_status: int | None
    ingest_count: int


class CompatibilityMatrix(MatrixModel):
    rows: tuple[MatrixRow, ...]


def test_python_raw_http_row_matches_runtime_bytes_and_ingest(tmp_path: Path) -> None:
    # Given: the exact synthetic raw body and a fresh bearer-auth receiver.
    row = _row("python_http_v1_raw_batch")
    db_path = tmp_path / "receiver.sqlite"
    _ = create_receiver_token(db_path, label="task-11", token=LEGACY_TOKEN)
    request_body = FIXTURE_PATH.read_bytes()

    # When: unauthorized and accepted bodies traverse the real raw HTTP surface.
    with running_receiver(db_path) as port:
        unauthorized_body = b"{}"
        unauthorized = post_raw_batch(port, "synthetic-wrong-token", unauthorized_body)
        with sqlite3.connect(db_path) as connection:
            unauthorized_ingest_count = COUNT_ADAPTER.validate_python(
                connection.execute("select count(*) from sync_runs").fetchone()[0]
            )
        response = post_raw_batch(port, LEGACY_TOKEN, request_body)
    with sqlite3.connect(db_path) as connection:
        ingest_count = COUNT_ADAPTER.validate_python(
            connection.execute("select count(*) from sync_runs").fetchone()[0]
        )

    # Then: auth, request, response, status, and ingest counts equal both rows.
    unauthorized_row = _row("python_http_v1_unauthorized")
    assert (_sha256(unauthorized_body), len(unauthorized_body)) == (
        unauthorized_row.candidate_sha256,
        unauthorized_row.byte_count,
    )
    assert (
        _sha256(unauthorized.body),
        unauthorized.status,
        unauthorized_ingest_count,
    ) == (
        unauthorized_row.response_sha256,
        unauthorized_row.http_status,
        unauthorized_row.ingest_count,
    )
    assert _sha256(request_body) == row.candidate_sha256
    assert _sha256(response.body) == row.response_sha256
    assert response.status == row.http_status
    assert ingest_count == row.ingest_count


def test_pairing_v1_and_v2_rows_match_exact_synthetic_bytes() -> None:
    # Given: deterministic public-safe v1 and v2 pairing payloads.
    v1 = ReceiverPairingBundle.build(
        label="synthetic-v1",
        receiver_url="https://receiver-v1.example.test/v1/batches",
        bearer_token="synthetic-legacy-token",
        token_prefix="synthetic_",
        created_at="2026-07-20T00:00:00Z",
    ).model_copy(update={"warning": "Synthetic fixture only."})
    v2 = ReceiverPairingInvitationPayload.build(
        label="synthetic-v2",
        receiver_url="https://receiver-v2.example.test/v1/batches",
        redeem_url="https://receiver-v2.example.test/v1/pairing/redeem",
        invitation_secret="hbi_synthetic_replacement",
        expires_at="2026-07-21T00:00:00Z",
    )

    # When: the unchanged models emit their compact JSON bytes.
    observations = {
        "python_pairing_v1_bundle": v1.model_dump_json().encode(),
        "python_pairing_v2_invitation": v2.model_dump_json().encode(),
    }

    # Then: both versions retain their approved bytes and sizes.
    for row_id, payload in observations.items():
        row = _row(row_id)
        assert (_sha256(payload), len(payload)) == (
            row.candidate_sha256,
            row.byte_count,
        )


def test_status_and_mcp_rows_match_generated_read_only_output(tmp_path: Path) -> None:
    # Given: a fresh synthetic database with one unchanged fixture ingest.
    db_path = tmp_path / "status.sqlite"
    initialize_database(db_path)
    _ = ingest_fixture(db_path, FIXTURE_PATH)

    # When: status and MCP outputs are generated through their read-only models.
    snapshot = read_status_snapshot(db_path)
    assert snapshot.latest_sync is not None
    normalized_status = snapshot.model_copy(
        update={
            "latest_sync": snapshot.latest_sync.model_copy(
                update={
                    "started_at": NORMALIZED_TIMESTAMP,
                    "finished_at": NORMALIZED_TIMESTAMP,
                }
            ),
            "sync_cursors": tuple(
                cursor.model_copy(update={"updated_at": NORMALIZED_TIMESTAMP})
                for cursor in snapshot.sync_cursors
            ),
        }
    )
    status = (normalized_status.model_dump_json() + "\n").encode()
    mcp = (json.dumps(mcp_smoke_result(db_path), separators=(",", ":")) + "\n").encode()

    # Then: both generated byte streams equal their approved matrix rows.
    for row_id, payload in {
        "status_v1_generation": status,
        "mcp_v1_generation": mcp,
    }.items():
        row = _row(row_id)
        assert (_sha256(payload), len(payload)) == (
            row.candidate_sha256,
            row.byte_count,
        )


def test_package_fixture_row_binds_the_public_synthetic_batch() -> None:
    # Given: the public fixture consumed by package smoke.
    row = _row("package_fixture_v1")

    # When: its exact repository bytes are hashed.
    payload = FIXTURE_PATH.read_bytes()

    # Then: package smoke remains bound to the approved bytes.
    assert (_sha256(payload), len(payload)) == (
        row.candidate_sha256,
        row.byte_count,
    )


def _row(row_id: str) -> MatrixRow:
    matrix = CompatibilityMatrix.model_validate_json(MATRIX_PATH.read_bytes())
    return next(row for row in matrix.rows if row.row_id == row_id)


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()
