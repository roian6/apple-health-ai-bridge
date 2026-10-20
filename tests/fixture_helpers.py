import json
import sqlite3
from contextlib import closing
from pathlib import Path
from typing import TYPE_CHECKING

from pydantic import TypeAdapter

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.contract.batch_v1 import HealthType, Sample, Source, SyncCursor
from health_bridge.ingest import ingest_batch
from health_bridge.storage import initialize_database

if TYPE_CHECKING:
    from health_bridge.mcp.types import JsonObject

FIXTURE_PATH = Path("fixtures/health_bridge_batch_v1.synthetic.json")


def initialized_fixture_db(tmp_path: Path) -> Path:
    db_path = tmp_path / "fixture.sqlite"
    initialize_database(db_path)
    fixture = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    _ = ingest_batch(db_path, with_projection_observations(fixture), FIXTURE_PATH.name)
    return db_path


def with_projection_observations(
    batch: HealthBridgeBatchV1, sequence: int = 1
) -> HealthBridgeBatchV1:
    scopes = {
        (sample.source_key, sample.type_code)
        for sample in batch.samples
        if sample.metadata.get("aggregation") == "daily_sum"
        or sample.metadata.get("healthkit_query") == "HKStatisticsCollectionQuery"
    }
    cursors = list(batch.sync.cursors)
    for source, code in sorted(scopes):
        samples = [
            sample
            for sample in batch.samples
            if sample.source_key == source and sample.type_code == code
        ]
        observation: JsonObject = {
            "namespace": "synthetic-current-fixture",
            "sequence": sequence,
            "type_code": code,
            "raw_intervals": [
                {
                    "client_record_id": sample.client_record_id,
                    "start_time": sample.start_time,
                    "end_time": sample.end_time,
                }
                for sample in samples
                if sample.metadata.get("aggregation") != "daily_sum"
                and sample.metadata.get("healthkit_query")
                != "HKStatisticsCollectionQuery"
            ],
            "statistics_window": {
                "start_time": min(sample.start_time for sample in samples),
                "end_time": max(sample.end_time for sample in samples),
            },
        }
        cursors.append(
            SyncCursor(
                source_key=source,
                cursor_kind="daily_projection_observation:" + code,
                cursor_value=json.dumps(observation),
            )
        )
    return batch.model_copy(
        update={"sync": batch.sync.model_copy(update={"cursors": tuple(cursors)})}
    )


def qualify_stored_daily_projections(db: Path) -> None:
    row_adapter = TypeAdapter(list[tuple[str, str, str, str, str, float, str, str]])
    source_adapter = TypeAdapter(list[tuple[str, str, str]])
    with closing(sqlite3.connect(db)) as connection, connection:
        rows = row_adapter.validate_python(
            connection.execute(
                """select sources.source_key, type_code, client_record_id, start_time,
                end_time, value, unit, metadata_json
                from samples join sources on sources.source_id=samples.source_id"""
            ).fetchall()
        )
        sources = source_adapter.validate_python(
            connection.execute("select source_key,name,kind from sources").fetchall()
        )
    metadata_adapter = TypeAdapter(dict[str, str])
    samples = tuple(
        Sample(
            source_key=source,
            type_code=code,
            client_record_id=identity,
            start_time=start,
            end_time=end,
            value=value,
            unit=unit,
            metadata=metadata_adapter.validate_json(metadata),
        )
        for source, code, identity, start, end, value, unit, metadata in rows
    )
    fixture = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    source_models = tuple(
        Source.model_validate({"source_key": key, "name": name, "kind": kind})
        for key, name, kind in sources
    )
    registry = {
        sample.type_code: HealthType(
            type_code=sample.type_code,
            display_name=sample.type_code,
            category="activity",
            default_unit=sample.unit,
            sensitivity="moderate",
            aliases=(),
        )
        for sample in samples
    }
    batch = fixture.model_copy(
        update={
            "sources": source_models,
            "health_types": tuple(registry.values()),
            "samples": samples,
            "workouts": (),
            "sleep_sessions": (),
            "deleted_records": (),
            "sync": fixture.sync.model_copy(update={"cursors": ()}),
        }
    )
    _ = ingest_batch(
        db,
        with_projection_observations(batch, sequence=2),
        "synthetic-current-sql-fixture",
    )
