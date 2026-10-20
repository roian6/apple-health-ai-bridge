import json
import sqlite3
from contextlib import closing
from http.client import RemoteDisconnected
from pathlib import Path
from typing import Literal

import pytest
from pydantic import TypeAdapter

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.queries import get_daily_summary
from tests.ingest import test_daily_projection_corrections as root
from tests.mcp.committed_read_support import JSON_OBJECT
from tests.receiver.test_legacy_http_contract import (
    HttpObservation,
    post_raw_batch,
    running_receiver,
)
from tests.receiver.test_receiver_source_binding import (
    INSTALLATION_A,
    TOKEN_A,
    pair,
    with_source_key,
)

COUNTS = TypeAdapter(tuple[int, int, int, int])


def _paired_daily(db: Path) -> HealthBridgeBatchV1:
    pair(db, installation_id=INSTALLATION_A, token=TOKEN_A, suffix="a")
    batch = root.root_batch((root.daily_sample(),), sequence=1, statistics=True)
    batch = batch.model_copy(update={"sources": (batch.sources[0],)})
    return HealthBridgeBatchV1.model_validate_json(
        with_source_key(batch, "apple_health.phone").model_dump_json()
    )


def test_paired_valid_observation_reaches_http_ingest_and_current_query(
    tmp_path: Path,
) -> None:
    db = tmp_path / "http.sqlite"
    valid = _paired_daily(db)
    with running_receiver(db) as port:
        response = post_raw_batch(port, TOKEN_A, valid.model_dump_json().encode())
    assert response.status == 202
    assert JSON_OBJECT.validate_json(response.body)["status"] == "succeeded"
    assert get_daily_summary(db, "2026-06-01", "2026-06-02").days[
        0
    ].daily_activity_totals == {"steps": 6.0}


@pytest.mark.parametrize("fault", ["sequence", "scope"])
def test_invalid_reserved_observation_is_structured_http_refusal_and_rolls_back(
    tmp_path: Path, fault: Literal["sequence", "scope"]
) -> None:
    db = tmp_path / "http.sqlite"
    valid = _paired_daily(db)
    cursor = valid.sync.cursors[0]
    observation = JSON_OBJECT.validate_json(cursor.cursor_value)
    if fault == "sequence":
        observation["sequence"] = 0
    else:
        observation["type_code"] = "weight"
    invalid = valid.model_copy(
        update={
            "sync": valid.sync.model_copy(
                update={
                    "cursors": (
                        cursor.model_copy(
                            update={"cursor_value": json.dumps(observation)}
                        ),
                    )
                }
            )
        }
    )
    outer_valid = HealthBridgeBatchV1.model_validate_json(invalid.model_dump_json())
    response: HttpObservation | None = None
    disconnected = False
    with running_receiver(db) as port:
        try:
            response = post_raw_batch(
                port, TOKEN_A, outer_valid.model_dump_json().encode()
            )
        except RemoteDisconnected:
            disconnected = True
        with closing(sqlite3.connect(db)) as connection, connection:
            counts = COUNTS.validate_python(
                connection.execute(
                    """select (select count(*) from samples),
                    (select count(*) from daily_projection_records),
                    (select count(*) from daily_projection_owners),
                    (select count(*) from daily_projection_fences)"""
                ).fetchone()
            )
        assert counts == (0, 0, 0, 0)
        control = post_raw_batch(port, TOKEN_A, valid.model_dump_json().encode())
        assert control.status == 202
        assert get_daily_summary(db, "2026-06-01", "2026-06-02").days[
            0
        ].daily_activity_totals == {"steps": 6.0}
    assert not disconnected, (
        "Reserved observation disconnected authenticated HTTP without a client refusal"
    )
    assert response is not None
    assert response.status in {400, 422}
    assert response.content_type == "application/json"
    assert JSON_OBJECT.validate_json(response.body).get("error")
