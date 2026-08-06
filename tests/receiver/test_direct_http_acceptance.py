from __future__ import annotations

import sqlite3
from contextlib import closing
from http.client import HTTPConnection
from typing import TYPE_CHECKING

from health_bridge.receiver.batch_acceptance import BatchAcceptanceCore
from health_bridge.receiver.server import MAX_BATCH_BYTES
from health_bridge.receiver.tokens import create_receiver_token
from tests.receiver.test_legacy_http_contract import (
    FIXTURE_PATH,
    LEGACY_TOKEN,
    HttpObservation,
    post_raw_batch,
    running_receiver,
)

if TYPE_CHECKING:
    from pathlib import Path

    import pytest

    from health_bridge.receiver.batch_acceptance import PreparedBatch
    from health_bridge.storage.models import IngestResult


def test_direct_http_preserves_exact_five_megabyte_framing_boundary(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "framing.sqlite"
    _ = create_receiver_token(db_path, label="framing", token=LEGACY_TOKEN)
    exact_limit_body = b" " * (MAX_BATCH_BYTES - 2) + b"{}"

    # When
    with running_receiver(db_path) as port:
        at_limit = post_raw_batch(port, LEGACY_TOKEN, exact_limit_body)
        with closing(HTTPConnection("127.0.0.1", port, timeout=5)) as connection:
            connection.request(
                "POST",
                "/v1/batches",
                body=b"",
                headers={
                    "Authorization": f"Bearer {LEGACY_TOKEN}",
                    "Content-Length": str(MAX_BATCH_BYTES + 1),
                    "Content-Type": "application/json",
                },
            )
            response = connection.getresponse()
            above_limit = HttpObservation(
                status=response.status,
                content_type=response.getheader("Content-Type"),
                content_length=response.getheader("Content-Length"),
                www_authenticate=response.getheader("WWW-Authenticate"),
                body=response.read(),
            )

    # Then
    assert at_limit == HttpObservation(
        status=422,
        content_type="application/json",
        content_length="64",
        www_authenticate=None,
        body=b'{"error":"payload does not match health_bridge.batch.v1 schema"}',
    )
    assert above_limit == HttpObservation(
        status=413,
        content_type="application/json",
        content_length="27",
        www_authenticate=None,
        body=b'{"error":"batch_too_large"}',
    )


def test_direct_http_preserves_exact_storage_failure_mapping(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Given
    db_path = tmp_path / "storage.sqlite"
    _ = create_receiver_token(db_path, label="storage", token=LEGACY_TOKEN)

    def fail_commit(
        _db_path: Path,
        _prepared: PreparedBatch,
        _source_name: str,
    ) -> IngestResult:
        message = "synthetic direct storage failure"
        raise sqlite3.OperationalError(message)

    monkeypatch.setattr(BatchAcceptanceCore, "commit", fail_commit)

    # When
    with running_receiver(db_path) as port:
        observed = post_raw_batch(port, LEGACY_TOKEN, FIXTURE_PATH.read_bytes())

    # Then
    assert observed == HttpObservation(
        status=500,
        content_type="application/json",
        content_length="39",
        www_authenticate=None,
        body=b'{"error":"records could not be stored"}',
    )
