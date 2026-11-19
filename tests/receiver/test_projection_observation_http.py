import json
import sqlite3
from contextlib import closing
from http.client import RemoteDisconnected
from pathlib import Path
from typing import Literal

import pytest
from pydantic import TypeAdapter

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.contract.batch_v1 import SyncCursor
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
TOMBSTONE_TIME: TypeAdapter[tuple[str] | None] = TypeAdapter(tuple[str] | None)


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


@pytest.mark.parametrize(
    ("legacy_id", "generated_tombstone", "unknown_raw", "expected"),
    [
        pytest.param("hk-steps-20260602", True, False, 6.0, id="paired-legacy"),
        pytest.param("hk-steps-20260602", True, True, None, id="genuine-unknown"),
        pytest.param("hk-steps-20260601", True, False, None, id="wrong-day"),
        pytest.param("hk-steps-20260602", False, False, None, id="wrong-timestamp"),
    ],
)
def test_raw_steps_tombstone_preserves_only_unrelated_current_totals(
    tmp_path: Path,
    legacy_id: str,
    generated_tombstone: bool,
    unknown_raw: bool,
    expected: float | None,
) -> None:
    db = tmp_path / "http.sqlite"
    pair(db, installation_id=INSTALLATION_A, token=TOKEN_A, suffix="a")
    june_second = "2026-06-02"
    raw = root.raw_sample(day=june_second).model_copy(
        update={
            "client_record_id": "hk-step-sample-00000000-0000-0000-0000-000000000058",
            "metadata": {
                "sample_kind": "raw_quantity",
                "aggregation": "sum",
                "healthkit_query": "HKAnchoredObjectQuery",
            },
        },
    )
    seed = root.root_batch(
        (root.daily_sample(), root.daily_sample(10.0, june_second)),
        sequence=1,
        statistics=True,
    )
    legacy = root.raw_deletion().model_copy(
        update={
            "client_record_id": legacy_id,
            "deleted_at": seed.generated_at
            if generated_tombstone
            else root.raw_deletion().deleted_at,
        },
    )
    unknown = legacy.model_copy(
        update={
            "client_record_id": "hk-step-sample-00000000-0000-0000-0000-000000000059",
        }
    )
    deletes = (unknown, legacy) if unknown_raw else (legacy,)
    change = root.root_batch((raw,), deleted=deletes, sequence=2)
    anchor = SyncCursor(
        source_key=raw.source_key,
        cursor_kind="anchored_step_sync",
        cursor_value="synthetic-raw-steps-anchor",
    )
    change = change.model_copy(
        update={
            "sync": change.sync.model_copy(
                update={"cursors": (*change.sync.cursors, anchor)}
            )
        }
    )
    complete = root.root_batch(
        (root.daily_sample(12.0, june_second),), sequence=3, statistics=True
    )
    cursor = complete.sync.cursors[0]
    observation = JSON_OBJECT.validate_json(cursor.cursor_value)
    observation["statistics_window"] = {
        "start_time": f"{june_second}T00:00:00Z",
        "end_time": "2026-06-03T00:00:00Z",
    }
    cursor = cursor.model_copy(update={"cursor_value": json.dumps(observation)})
    complete = complete.model_copy(
        update={"sync": complete.sync.model_copy(update={"cursors": (cursor,)})}
    )
    totals: list[tuple[float | None, ...]] = []
    with running_receiver(db) as port:
        for batch in (seed, change, complete):
            single_source = batch.model_copy(update={"sources": (batch.sources[0],)})
            wire = with_source_key(single_source, "apple_health.phone")
            response = post_raw_batch(port, TOKEN_A, wire.model_dump_json().encode())
            assert response.status == 202
            assert JSON_OBJECT.validate_json(response.body)["status"] == "succeeded"
            totals.append(
                tuple(
                    day.daily_activity_totals.get("steps")
                    for day in get_daily_summary(db, "2026-06-01", "2026-06-03").days
                )
            )
    assert totals == [(6.0, 10.0), (expected, None), (expected, 12.0)]
    with closing(sqlite3.connect(db)) as connection:
        persisted = TOMBSTONE_TIME.validate_python(
            connection.execute(
                """select deleted_at from deleted_records
                where record_family='sample' and client_record_id=?""",
                (legacy_id,),
            ).fetchone()
        )
    assert persisted == (legacy.deleted_at,)


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
