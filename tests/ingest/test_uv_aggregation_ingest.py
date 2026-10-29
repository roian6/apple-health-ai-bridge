import json
import sqlite3
from contextlib import closing
from pathlib import Path

import pytest
from pydantic import TypeAdapter

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.ingest import ingest_batch
from health_bridge.queries import get_daily_summary
from health_bridge.storage import initialize_database
from health_bridge.storage.sqlite_rows import fetch_one_int

ROWS_ADAPTER = TypeAdapter(list[tuple[float, str]])
METADATA_ADAPTER = TypeAdapter(dict[str, str])


def _batch(type_code: str, metadata: dict[str, str]) -> HealthBridgeBatchV1:
    return HealthBridgeBatchV1.model_validate_json(
        json.dumps(
            {
                "schema_id": "health_bridge.batch.v1",
                "schema_version": "1.0.0",
                "generated_at": "2026-06-08T20:00:00Z",
                "export_window": {
                    "start_time": "2026-06-08T00:00:00Z",
                    "end_time": "2026-06-09T00:00:00Z",
                },
                "sources": [
                    {
                        "source_key": "synthetic.uv.phone",
                        "name": "Synthetic UV Phone",
                        "kind": "phone",
                    },
                ],
                "health_types": [
                    {
                        "type_code": type_code,
                        "display_name": "Synthetic quantity",
                        "category": "activity"
                        if type_code == "steps"
                        else "environmental",
                        "default_unit": "count",
                        "sensitivity": "moderate",
                        "aliases": [],
                    },
                ],
                "samples": [
                    {
                        "client_record_id": f"synthetic-quantity-{index}",
                        "source_key": "synthetic.uv.phone",
                        "type_code": type_code,
                        "start_time": f"2026-06-08T{12 + index}:00:00Z",
                        "end_time": f"2026-06-08T{12 + index}:00:00Z",
                        "value": value,
                        "unit": "count",
                        "metadata": metadata,
                    }
                    for index, value in enumerate((0.0, 8.0))
                ],
                "workouts": [],
                "sleep_sessions": [],
                "deleted_records": [],
                "sync": {
                    "sync_window": {
                        "start_time": "2026-06-08T00:00:00Z",
                        "end_time": "2026-06-09T00:00:00Z",
                    },
                    "cursors": [],
                },
            },
        ),
    )


@pytest.mark.parametrize(
    ("type_code", "metadata", "expected_aggregation"),
    [
        (
            "uv_exposure",
            {"sample_kind": "raw_quantity", "aggregation": "sum"},
            "min_max_average",
        ),
        (
            "uv_exposure",
            {"sample_kind": "raw_quantity", "aggregation": "min_max_average"},
            "min_max_average",
        ),
        (
            "uv_exposure",
            {"sample_kind": "raw_quantity", "aggregation": "latest"},
            "latest",
        ),
        (
            "uv_exposure",
            {"sample_kind": "daily_aggregate", "aggregation": "sum"},
            "sum",
        ),
        ("uv_exposure", {"aggregation": "sum"}, "sum"),
        ("uv_exposure", {"sample_kind": "raw_quantity"}, None),
        ("steps", {"sample_kind": "raw_quantity", "aggregation": "sum"}, "sum"),
    ],
)
def test_ingest_normalizes_only_legacy_raw_uv_after_migration(
    tmp_path: Path,
    type_code: str,
    metadata: dict[str, str],
    expected_aggregation: str | None,
) -> None:
    db_path = tmp_path / "uv.sqlite"
    initialize_database(db_path)
    with closing(sqlite3.connect(db_path)) as connection:
        assert (
            fetch_one_int(
                connection,
                "select count(*) from schema_migrations where migration_id = ?",
                ("014_uv_raw_aggregation",),
            )
            == 1
        )
    metadata = {**metadata, "synthetic_marker": "keep"}
    batch = _batch(type_code, metadata)
    original_payload = batch.model_dump_json()

    result = ingest_batch(db_path, batch, "synthetic-legacy-uv")
    _ = ingest_batch(db_path, batch, "synthetic-legacy-uv-repeat")

    assert result.status == "succeeded"
    assert result.sample_count == 2
    assert batch.model_dump_json() == original_payload
    with closing(sqlite3.connect(db_path)) as connection:
        rows = ROWS_ADAPTER.validate_python(
            connection.execute(
                """select value, metadata_json from samples
                where type_code = ? order by client_record_id""",
                (type_code,),
            ).fetchall(),
        )
    assert [value for value, _ in rows] == [0.0, 8.0]
    expected_metadata = dict(metadata)
    if expected_aggregation is not None:
        expected_metadata["aggregation"] = expected_aggregation
    for _, stored_metadata in rows:
        assert METADATA_ADAPTER.validate_json(stored_metadata) == expected_metadata
    if type_code == "uv_exposure" and expected_aggregation == "min_max_average":
        summary = get_daily_summary(db_path, "2026-06-08", "2026-06-09")
        statistic = summary.days[0].sample_statistics["uv_exposure"]
        assert statistic.total is None
        assert (statistic.minimum, statistic.average, statistic.maximum) == (
            0.0,
            4.0,
            8.0,
        )
