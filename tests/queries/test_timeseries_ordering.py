import sqlite3
from contextlib import closing
from pathlib import Path

import pytest

from health_bridge.ingest import ingest_batch
from health_bridge.queries import get_timeseries
from tests.queries.catalogue_fixtures import catalogue_batch


@pytest.mark.parametrize("has_coverage_index", [False, True])
@pytest.mark.parametrize(
    "requested_types", [("heart_rate",), ("body_mass", "heart_rate")]
)
def test_timestamp_ties_have_stable_capped_selection_across_query_plans(
    tmp_path: Path,
    has_coverage_index: bool,
    requested_types: tuple[str, ...],
) -> None:
    db_path = tmp_path / "synthetic-timestamp-ties.sqlite"
    batch = catalogue_batch(1)
    source = batch.sources[0]
    other_source = source.model_copy(update={"source_key": "synthetic.other"})
    sample = batch.samples[0]
    samples = tuple(
        sample.model_copy(
            update={
                "client_record_id": f"synthetic-tie-{index}",
                "source_key": (
                    source.source_key if index % 2 else other_source.source_key
                ),
                "end_time": (
                    f"2026-06-01T12:{(599 - index) // 60:02d}:{(599 - index) % 60:02d}Z"
                ),
                "value": float(index),
            }
        )
        for index in range(600)
    )
    weight = sample.model_copy(
        update={
            "type_code": "weight",
            "client_record_id": "synthetic-weight-tie",
            "end_time": sample.start_time,
            "value": 999.0,
            "unit": "kg",
        }
    )
    health_type = batch.health_types[0].model_copy(
        update={"type_code": "weight", "default_unit": "kg"}
    )
    batch = batch.model_copy(
        update={
            "sources": (source, other_source),
            "health_types": (*batch.health_types, health_type),
            "samples": (weight, *samples),
        }
    )
    assert ingest_batch(db_path, batch, "synthetic-ties").status == "succeeded"

    with closing(sqlite3.connect(db_path)) as connection, connection:
        if not has_coverage_index:
            _ = connection.execute("drop index if exists samples_type_coverage")
        # A competing covering plan orders end times opposite to sample identity.
        _ = connection.execute(
            """create index synthetic_tie_plan
            on samples(type_code, start_time, end_time, sample_id)"""
        )
        if has_coverage_index:
            _ = connection.execute("drop index synthetic_tie_plan")

    result = get_timeseries(
        db_path, requested_types, "2026-06-01T00:00:00Z", "2026-06-02T00:00:00Z"
    )

    assert [point.value for point in result.points] == list(range(500))
    assert {point.type_code for point in result.points} == {"heart_rate"}
    assert {point.source.source_key for point in result.points} == {
        source.source_key,
        other_source.source_key,
    }
    assert result.truncated

    complete = get_timeseries(
        db_path,
        requested_types,
        "2026-06-01T00:00:00Z",
        "2026-06-02T00:00:00Z",
        limit=601,
    )
    expected = [float(index) for index in range(600)]
    if len(requested_types) > 1:
        expected.append(999.0)
    assert [point.value for point in complete.points] == expected
    assert not complete.truncated
