import hashlib
import sqlite3
from collections.abc import Generator
from contextlib import closing, contextmanager
from dataclasses import dataclass
from http.client import HTTPConnection
from pathlib import Path
from threading import Thread
from typing import Final, TypeAlias

import pytest
from pydantic import TypeAdapter

from health_bridge.receiver.server import build_receiver_server, server_port
from health_bridge.receiver.tokens import create_receiver_token
from health_bridge.status import read_status_snapshot

FIXTURE_PATH: Final = Path("fixtures/health_bridge_batch_v1.synthetic.json")
FIXTURE_SHA256: Final = (
    "63bd969e3b0844c4c58af1a8c538a34e316e59166377178bdb2d2efacc03a3bf"
)
LEGACY_TOKEN: Final = "hb_legacy_characterization_secret"
SUCCESS_BODY: Final = (
    b'{"deleted_record_count":1,"health_type_count":4,"sample_count":3,'
    b'"sleep_session_count":1,"source":"receiver","source_count":2,'
    b'"status":"succeeded","sync_cursor_count":2,"workout_count":1}'
)
UNAUTHORIZED_BODY: Final = b'{"error":"unauthorized"}'
MALFORMED_BODY: Final = (
    b'{"error":"payload does not match health_bridge.batch.v1 schema"}'
)

LogicalCounts: TypeAlias = tuple[int, int, int, int, int, int, int, int, int]
SyncRun: TypeAlias = tuple[int, str, str, int, int, int, int, int, int, int]
LOGICAL_COUNTS_ADAPTER: Final[TypeAdapter[LogicalCounts]] = TypeAdapter(LogicalCounts)
SYNC_RUNS_ADAPTER: Final[TypeAdapter[list[SyncRun]]] = TypeAdapter(list[SyncRun])


@dataclass(frozen=True, slots=True)
class HttpObservation:
    status: int
    content_type: str | None
    content_length: str | None
    www_authenticate: str | None
    body: bytes


@contextmanager
def running_receiver(db_path: Path) -> Generator[int, None, None]:
    server = build_receiver_server(db_path, host="127.0.0.1", port=0)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server_port(server)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def post_raw_batch(port: int, token: str, body: bytes) -> HttpObservation:
    with closing(HTTPConnection("127.0.0.1", port, timeout=5)) as connection:
        connection.request(
            "POST",
            "/v1/batches",
            body=body,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
        )
        response = connection.getresponse()
        return HttpObservation(
            status=response.status,
            content_type=response.getheader("Content-Type"),
            content_length=response.getheader("Content-Length"),
            www_authenticate=response.getheader("WWW-Authenticate"),
            body=response.read(),
        )


@pytest.mark.parametrize(
    ("authorized", "expected"),
    [
        pytest.param(
            False,
            HttpObservation(
                status=401,
                content_type="application/json",
                content_length="24",
                www_authenticate="Bearer",
                body=UNAUTHORIZED_BODY,
            ),
            id="invalid-bearer-is-rejected-before-body-parse",
        ),
        pytest.param(
            True,
            HttpObservation(
                status=422,
                content_type="application/json",
                content_length="64",
                www_authenticate=None,
                body=MALFORMED_BODY,
            ),
            id="authenticated-malformed-body-reaches-strict-parser",
        ),
    ],
)
def test_legacy_malformed_body_status_reflects_authentication_order(
    tmp_path: Path,
    *,
    authorized: bool,
    expected: HttpObservation,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    _ = create_receiver_token(
        db_path,
        label="legacy-characterization",
        token=LEGACY_TOKEN,
    )
    presented_token = LEGACY_TOKEN if authorized else "synthetic-invalid-token"

    # When
    with running_receiver(db_path) as port:
        observed = post_raw_batch(port, presented_token, b"{}")

    # Then
    assert observed == expected


def test_legacy_identical_raw_body_is_accepted_twice_without_logical_duplicates(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    request_body = FIXTURE_PATH.read_bytes()
    _ = create_receiver_token(
        db_path,
        label="legacy-characterization",
        token=LEGACY_TOKEN,
    )
    assert len(request_body) == 4_689
    assert hashlib.sha256(request_body).hexdigest() == FIXTURE_SHA256

    # When
    with running_receiver(db_path) as port:
        observations = (
            post_raw_batch(port, LEGACY_TOKEN, request_body),
            post_raw_batch(port, LEGACY_TOKEN, request_body),
        )

    # Then
    expected = HttpObservation(
        status=202,
        content_type="application/json",
        content_length="187",
        www_authenticate=None,
        body=SUCCESS_BODY,
    )
    assert observations == (expected, expected)
    assert b"delivery" not in SUCCESS_BODY

    with sqlite3.connect(db_path) as connection:
        logical_counts = LOGICAL_COUNTS_ADAPTER.validate_python(
            connection.execute(
                """
                select (select count(*) from sources),
                       (select count(*) from health_types),
                       (select count(*) from samples),
                       (select count(*) from workouts),
                       (select count(*) from sleep_sessions),
                       (select count(*) from sleep_stage_intervals),
                       (select count(*) from deleted_records),
                       (select count(*) from sync_cursors),
                       (select count(*) from delivery_receipts)
                """
            ).fetchone()
        )
        sync_runs = SYNC_RUNS_ADAPTER.validate_python(
            connection.execute(
                """
                select sync_run_id, status, fixture_name, source_count,
                       health_type_count, sample_count, workout_count,
                       sleep_session_count, deleted_record_count, sync_cursor_count
                from sync_runs order by sync_run_id
                """
            ).fetchall()
        )

    assert logical_counts == (2, 4, 3, 1, 1, 5, 1, 2, 0)
    assert sync_runs == [
        (1, "succeeded", "receiver", 2, 4, 3, 1, 1, 1, 2),
        (2, "succeeded", "receiver", 2, 4, 3, 1, 1, 1, 2),
    ]


def test_legacy_ingest_generates_existing_redacted_status_without_receipts(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    _ = create_receiver_token(
        db_path,
        label="legacy-characterization",
        token=LEGACY_TOKEN,
    )

    # When
    with running_receiver(db_path) as port:
        response = post_raw_batch(port, LEGACY_TOKEN, FIXTURE_PATH.read_bytes())
    snapshot = read_status_snapshot(db_path)

    # Then
    assert response.status == 202
    assert snapshot.schema_id == "health_bridge.status.v1"
    assert snapshot.counts == {
        "sources": 2,
        "health_types": 4,
        "samples": 3,
        "workouts": 1,
        "sleep_sessions": 1,
        "deleted_records": 1,
        "sync_cursors": 2,
        "sync_runs": 1,
    }
    assert snapshot.latest_sync is not None
    assert snapshot.latest_sync.sync_run_id == 1
    assert snapshot.latest_sync.status == "succeeded"
    assert snapshot.latest_sync.started_at == snapshot.latest_sync.finished_at
    assert snapshot.latest_sync.sync_window_start == "2026-06-01T00:00:00Z"
    assert snapshot.latest_sync.sync_window_end == "2026-06-08T00:00:00Z"
    assert "delivery" not in snapshot.model_dump_json()
