from pathlib import Path

import pytest

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.contract.batch_v1 import (
    DeletedRecord,
    HealthType,
    Source,
    SyncCursor,
)
from health_bridge.ingest import ingest_batch
from health_bridge.queries import explain_sources, get_timeseries, list_synced_metrics
from health_bridge.queries.models import Period
from health_bridge.storage import initialize_database
from health_bridge.storage.database import connect_database
from tests.fixture_helpers import (
    FIXTURE_PATH,
    initialized_fixture_db,
)
from tests.queries.catalogue_fixtures import catalogue_batch


@pytest.mark.parametrize("has_later_record", [True, False])
def test_catalogue_separates_retained_extents_from_latest_batch_window(
    tmp_path: Path,
    has_later_record: bool,
) -> None:
    db = tmp_path / "synthetic.sqlite"
    for day in (1, 7):
        batch = catalogue_batch(day)
        if day == 7 and not has_later_record:
            batch = batch.model_copy(update={"samples": ()})
        assert ingest_batch(db, batch, "synthetic-catalogue").status == "succeeded"

    result = list_synced_metrics(db)

    assert result.metrics[0].record_count == (2 if has_later_record else 1)
    assert result.period == Period(
        start="2026-06-07T00:00:00Z", end="2026-06-08T00:00:00Z"
    )
    assert result.stored_coverage == Period(
        start="2026-06-01T12:00:00Z",
        end="2026-06-07T12:00:05Z" if has_later_record else "2026-06-01T12:00:05Z",
    )
    assert result.latest_sync_window == result.period
    assert (
        len(
            get_timeseries(
                db, ("heart_rate",), "2026-06-01T00:00:00Z", "2026-06-02T00:00:00Z"
            ).points
        )
        == 1
    )
    notes = " ".join(result.missing_data_notes)
    assert "requested period" not in notes
    assert "not continuous coverage" in notes
    assert "deprecated" in notes


def test_catalogue_bounds_follow_record_families_and_instantaneous_samples(
    tmp_path: Path,
) -> None:
    result = list_synced_metrics(initialized_fixture_db(tmp_path))

    assert {
        metric.type_code: (
            metric.record_count,
            metric.first_record_start,
            metric.latest_record_end,
        )
        for metric in result.metrics
    } == {
        "heart_rate": (1, "2026-06-01T12:00:00Z", "2026-06-01T12:00:05Z"),
        "steps": (1, "2026-06-01T00:00:00Z", "2026-06-02T00:00:00Z"),
        "weight": (1, "2026-06-02T07:30:00Z", "2026-06-02T07:30:00Z"),
        "workout": (1, "2026-06-03T18:00:00Z", "2026-06-03T18:32:00Z"),
        "sleep_analysis": (1, "2026-06-04T03:10:00Z", "2026-06-04T10:45:00Z"),
    }
    assert result.stored_coverage == Period(
        start="2026-06-01T00:00:00Z", end="2026-06-04T10:45:00Z"
    )


@pytest.mark.parametrize("has_cursor", [True, False])
def test_catalogue_definitions_without_observations_get_empty_coverage_notes(
    tmp_path: Path,
    has_cursor: bool,
) -> None:
    db = tmp_path / "synthetic.sqlite"
    batch = catalogue_batch(7).model_copy(update={"samples": ()})
    if has_cursor:
        batch = batch.model_copy(
            update={
                "sync": batch.sync.model_copy(
                    update={
                        "cursors": (
                            SyncCursor(
                                source_key=batch.sources[0].source_key,
                                cursor_kind="anchored_object_query",
                                cursor_value="synthetic-catalogue-cursor",
                            ),
                        ),
                    }
                )
            }
        )
    assert ingest_batch(db, batch, "synthetic-empty").status == "succeeded"

    result = list_synced_metrics(db)

    assert result.metrics[0].record_count == 0
    assert result.metrics[0].first_record_start is None
    assert result.metrics[0].latest_record_end is None
    assert result.stored_coverage is None
    assert result.latest_sync_window == Period(
        start="2026-06-07T00:00:00Z", end="2026-06-08T00:00:00Z"
    )
    notes = " ".join(result.missing_data_notes)
    assert "No matching records were found" in notes
    assert "requested period" not in notes
    assert "unknown" in notes


def test_fresh_empty_catalogue_has_no_stored_extents_or_batch_window(
    tmp_path: Path,
) -> None:
    db = tmp_path / "synthetic.sqlite"
    initialize_database(db)

    result = list_synced_metrics(db)

    assert result.metrics == ()
    assert result.period == Period(start="", end="")
    assert result.stored_coverage is None
    assert result.latest_sync_window is None
    assert "No matching records were found" in " ".join(result.missing_data_notes)


@pytest.mark.parametrize(
    ("deleted_days", "expected_count", "expected_start", "expected_end"),
    [
        ((1,), 1, "2026-06-07T12:00:00Z", "2026-06-07T12:00:05Z"),
        ((7,), 1, "2026-06-01T12:00:00Z", "2026-06-01T12:00:05Z"),
        ((1, 7), 0, None, None),
    ],
)
def test_deletion_only_batches_shrink_or_empty_retained_extents(
    tmp_path: Path,
    deleted_days: tuple[int, ...],
    expected_count: int,
    expected_start: str | None,
    expected_end: str | None,
) -> None:
    db = tmp_path / "synthetic.sqlite"
    for day in (1, 7):
        _ = ingest_batch(db, catalogue_batch(day), "synthetic-catalogue")
    batch = catalogue_batch(9)
    deletion = batch.model_copy(
        update={
            "samples": (),
            "deleted_records": tuple(
                DeletedRecord(
                    record_family="sample",
                    source_key=batch.sources[0].source_key,
                    client_record_id=f"synthetic-catalogue-heart-{day}",
                    deleted_at="2026-06-09T12:00:00Z",
                )
                for day in deleted_days
            ),
        }
    )
    assert ingest_batch(db, deletion, "synthetic-deletion").status == "succeeded"

    result = list_synced_metrics(db)

    assert result.metrics[0].record_count == expected_count
    assert result.metrics[0].first_record_start == expected_start
    assert result.metrics[0].latest_record_end == expected_end
    assert result.stored_coverage == (
        Period(start=expected_start, end=expected_end)
        if expected_start is not None and expected_end is not None
        else None
    )
    assert result.latest_sync_window == Period(
        start="2026-06-09T00:00:00Z", end="2026-06-10T00:00:00Z"
    )
    assert result.period == result.latest_sync_window


def test_retained_extents_combine_sources_without_treating_bounds_as_continuous(
    tmp_path: Path,
) -> None:
    db = tmp_path / "synthetic.sqlite"
    _ = ingest_batch(db, catalogue_batch(1), "synthetic-watch")
    batch = catalogue_batch(7)
    phone = Source(
        source_key="synthetic.catalogue.phone", name="Synthetic Phone", kind="phone"
    )
    batch = batch.model_copy(
        update={
            "sources": (phone,),
            "samples": (
                batch.samples[0].model_copy(update={"source_key": phone.source_key}),
            ),
        }
    )
    _ = ingest_batch(db, batch, "synthetic-phone")

    result = list_synced_metrics(db)

    assert len(result.sources_used) == 2
    assert result.metrics[0].record_count == 2
    assert result.metrics[0].first_record_start == "2026-06-01T12:00:00Z"
    assert result.metrics[0].latest_record_end == "2026-06-07T12:00:05Z"
    assert "not continuous coverage" in " ".join(result.missing_data_notes)


@pytest.mark.parametrize(
    "latest_metadata", ["failed", "windowless", "start_only", "end_only", "none"]
)
def test_sync_window_metadata_fallback_preserves_legacy_period(
    tmp_path: Path,
    latest_metadata: str,
) -> None:
    db = tmp_path / "synthetic.sqlite"
    for day in (1, 7):
        _ = ingest_batch(db, catalogue_batch(day), "synthetic-catalogue")
    with connect_database(db) as connection:
        if latest_metadata == "failed":
            _ = connection.execute(
                "update sync_runs set status='failed' where sync_run_id=2"
            )
        elif latest_metadata == "windowless":
            _ = connection.execute(
                """update sync_runs set sync_window_start=null, sync_window_end=null
                where sync_run_id=2"""
            )
        elif latest_metadata == "start_only":
            _ = connection.execute(
                "update sync_runs set sync_window_end=null where sync_run_id=2"
            )
        elif latest_metadata == "end_only":
            _ = connection.execute(
                "update sync_runs set sync_window_start=null where sync_run_id=2"
            )
        else:
            _ = connection.execute("delete from sync_runs")

    result = list_synced_metrics(db)

    assert result.stored_coverage == Period(
        start="2026-06-01T12:00:00Z", end="2026-06-07T12:00:05Z"
    )

    if latest_metadata == "none":
        assert result.latest_sync_window is None
        assert result.period == result.stored_coverage
    else:
        assert result.latest_sync_window == Period(
            start="2026-06-01T00:00:00Z", end="2026-06-02T00:00:00Z"
        )
        assert result.period == result.latest_sync_window

    assert explain_sources(db).period == result.period


def test_deleting_all_record_families_leaves_definitions_with_null_extents(
    tmp_path: Path,
) -> None:
    db = tmp_path / "synthetic.sqlite"
    fixture = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    fixture = fixture.model_copy(
        update={
            "samples": tuple(
                sample.model_copy(update={"metadata": {}}) for sample in fixture.samples
            ),
            "health_types": (
                *fixture.health_types,
                HealthType(
                    type_code="workout",
                    display_name="Workouts",
                    category="activity",
                    default_unit="session",
                    sensitivity="moderate",
                    aliases=(),
                ),
            ),
        }
    )
    _ = ingest_batch(db, fixture, "synthetic-all-families")
    deletions = (
        tuple(
            DeletedRecord(
                record_family="sample",
                source_key=record.source_key,
                client_record_id=record.client_record_id,
                deleted_at="2026-06-09T12:00:00Z",
            )
            for record in fixture.samples
        )
        + tuple(
            DeletedRecord(
                record_family="workout",
                source_key=record.source_key,
                client_record_id=record.client_record_id,
                deleted_at="2026-06-09T12:00:00Z",
            )
            for record in fixture.workouts
        )
        + tuple(
            DeletedRecord(
                record_family="sleep_session",
                source_key=record.source_key,
                client_record_id=record.client_record_id,
                deleted_at="2026-06-09T12:00:00Z",
            )
            for record in fixture.sleep_sessions
        )
    )
    batch = catalogue_batch(9)
    deletion = batch.model_copy(
        update={
            "sources": fixture.sources,
            "health_types": fixture.health_types,
            "samples": (),
            "deleted_records": deletions,
        }
    )
    assert ingest_batch(db, deletion, "synthetic-delete-all").status == "succeeded"

    result = list_synced_metrics(db)

    assert len(result.metrics) == 5
    assert len(result.sources_used) == 2
    assert all(metric.record_count == 0 for metric in result.metrics)
    assert all(
        metric.first_record_start is None and metric.latest_record_end is None
        for metric in result.metrics
    )
    assert result.stored_coverage is None
    assert result.latest_sync_window == Period(
        start="2026-06-09T00:00:00Z", end="2026-06-10T00:00:00Z"
    )
    assert "No matching records were found" in " ".join(result.missing_data_notes)


def test_latest_batch_window_uses_ingestion_order_instead_of_calendar_order(
    tmp_path: Path,
) -> None:
    db = tmp_path / "synthetic.sqlite"
    for day in (7, 1):
        _ = ingest_batch(db, catalogue_batch(day), "synthetic-backfill")

    result = list_synced_metrics(db)

    assert result.latest_sync_window == Period(
        start="2026-06-01T00:00:00Z", end="2026-06-02T00:00:00Z"
    )
    assert result.stored_coverage == Period(
        start="2026-06-01T12:00:00Z", end="2026-06-07T12:00:05Z"
    )


@pytest.mark.parametrize("type_code", ["workout", "sleep_analysis"])
def test_global_extents_include_samples_with_dedicated_session_type_codes(
    tmp_path: Path,
    type_code: str,
) -> None:
    db = tmp_path / "synthetic.sqlite"
    batch = catalogue_batch(1)
    batch = batch.model_copy(
        update={
            "health_types": (
                batch.health_types[0].model_copy(update={"type_code": type_code}),
            ),
            "samples": (batch.samples[0].model_copy(update={"type_code": type_code}),),
        }
    )
    _ = ingest_batch(db, batch, "synthetic-reserved-type")

    result = list_synced_metrics(db)

    assert result.metrics[0].type_code == type_code
    assert result.metrics[0].record_count == 0
    assert result.metrics[0].first_record_start is None
    assert result.stored_coverage == Period(
        start="2026-06-01T12:00:00Z", end="2026-06-01T12:00:05Z"
    )
    assert "No matching records were found" not in " ".join(result.missing_data_notes)


@pytest.mark.parametrize(
    ("alias", "canonical", "unit"),
    [("active_energy", "energy", "kcal"), ("body_mass", "weight", "kg")],
)
def test_catalogue_extents_preserve_canonicalized_sample_aliases(
    tmp_path: Path,
    alias: str,
    canonical: str,
    unit: str,
) -> None:
    db = tmp_path / "synthetic.sqlite"
    for day, type_code in ((1, alias), (7, canonical)):
        batch = catalogue_batch(day)
        batch = batch.model_copy(
            update={
                "health_types": (
                    batch.health_types[0].model_copy(
                        update={
                            "type_code": type_code,
                            "default_unit": unit,
                        }
                    ),
                ),
                "samples": (
                    batch.samples[0].model_copy(
                        update={
                            "type_code": type_code,
                            "unit": unit,
                        }
                    ),
                ),
            }
        )
        _ = ingest_batch(db, batch, "synthetic-alias")

    result = list_synced_metrics(db)

    assert len(result.metrics) == 1
    assert result.metrics[0].type_code == canonical
    assert result.metrics[0].record_count == 2
    assert result.metrics[0].first_record_start == "2026-06-01T12:00:00Z"
    assert result.metrics[0].latest_record_end == "2026-06-07T12:00:05Z"
    assert result.stored_coverage == Period(
        start="2026-06-01T12:00:00Z", end="2026-06-07T12:00:05Z"
    )
