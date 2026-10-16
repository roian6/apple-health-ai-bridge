from __future__ import annotations

import json
import sqlite3
from datetime import date, timedelta
from pathlib import Path
from typing import TYPE_CHECKING

import pytest
from pydantic import TypeAdapter
from typing_extensions import TypedDict

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.ingest import ingest_batch
from health_bridge.queries.daily import get_daily_summary
from health_bridge.queries.sources import explain_sources
from health_bridge.storage import initialize_database

if TYPE_CHECKING:
    from health_bridge.queries.models import DailyObservation


class SamplePayload(TypedDict):
    client_record_id: str
    source_key: str
    type_code: str
    value: float
    unit: str
    start_time: str
    end_time: str
    metadata: dict[str, str]


class CursorPayload(TypedDict):
    source_key: str
    cursor_kind: str
    cursor_value: str


class SyncPayload(TypedDict):
    sync_window: dict[str, str]
    cursors: list[CursorPayload]


class BatchPayload(TypedDict):
    schema_id: str
    schema_version: str
    generated_at: str
    export_window: dict[str, str]
    sources: list[dict[str, str]]
    health_types: list[dict[str, object]]
    samples: list[SamplePayload]
    workouts: list[object]
    sleep_sessions: list[object]
    deleted_records: list[dict[str, str]]
    sync: SyncPayload


BATCH_PAYLOAD = TypeAdapter(BatchPayload)
OBSERVATION_PAYLOAD = TypeAdapter(dict[str, object])

SOURCE = "synthetic.phone.alpha"
TYPE = "flights_climbed"
RAW = "hk-quantity-flights-climbed-00000000-0000-0000-0000-000000000063"
DAILY = "hk-daily-activity-flights-climbed-20260601"
START = "2026-06-01T00:00:00Z"
END = "2026-06-02T00:00:00Z"
NAMESPACE = "synthetic-observation-lineage"


def sample(  # noqa: PLR0913 - synthetic wire fixture dimensions
    identifier: str,
    value: float,
    *,
    daily: bool = False,
    start: str = START,
    end: str = END,
    day: str = "2026-06-01",
    zone: str = "UTC",
    type_code: str = TYPE,
) -> SamplePayload:
    metadata = (
        {
            "aggregation": "daily_sum",
            "aggregation_completeness": "complete",
            "sample_kind": "daily_aggregate",
            "calendar_day": day,
            "time_zone_identifier": zone,
            "source_resolution": "healthkit_statistics_merged_sources",
            "healthkit_query": "HKStatisticsCollectionQuery",
        }
        if daily
        else {
            "aggregation": "sum",
            "sample_kind": "raw_quantity",
            "healthkit_query": "HKAnchoredObjectQuery",
        }
    )
    return {
        "client_record_id": identifier,
        "source_key": SOURCE,
        "type_code": type_code,
        "value": value,
        "unit": "count",
        "start_time": start,
        "end_time": end,
        "metadata": metadata,
    }


def payload(  # noqa: PLR0913 - independent mutation/observation dimensions
    sequence: int | None,
    *,
    samples: list[SamplePayload] | None = None,
    deleted: list[str] | None = None,
    raw_intervals: list[dict[str, str]] | None = None,
    baseline: bool = False,
    statistics: bool = False,
    start: str = START,
    end: str = END,
    generated: str = END,
) -> BatchPayload:
    data = BATCH_PAYLOAD.validate_json(
        Path("fixtures/health_bridge_batch_v1.synthetic.json").read_text()
    )
    data["health_types"].append(
        {
            "type_code": TYPE,
            "display_name": "Floors Climbed",
            "category": "activity",
            "default_unit": "count",
            "sensitivity": "low",
            "aliases": [],
        }
    )
    data.update(
        samples=samples or [],
        workouts=[],
        sleep_sessions=[],
        generated_at=generated,
        deleted_records=[
            {
                "record_family": "sample",
                "source_key": SOURCE,
                "client_record_id": identifier,
                "deleted_at": generated,
            }
            for identifier in deleted or []
        ],
    )
    data["export_window"] = {"start_time": start, "end_time": end}
    data["sync"] = {"sync_window": data["export_window"], "cursors": []}
    if sequence is not None:
        observation = {
            "namespace": NAMESPACE,
            "sequence": sequence,
            "type_code": TYPE,
            "raw_intervals": raw_intervals or [],
            "raw_baseline": data["export_window"] if baseline else None,
            "statistics_window": data["export_window"] if statistics else None,
        }
        data["sync"]["cursors"].append(
            {
                "source_key": SOURCE,
                "cursor_kind": f"daily_projection_observation:{TYPE}",
                "cursor_value": json.dumps(observation, sort_keys=True),
            }
        )
    return data


def ingest(db: Path, data: BatchPayload) -> None:
    batch = HealthBridgeBatchV1.model_validate_json(json.dumps(data))
    assert ingest_batch(db, batch, "synthetic-daily-correction").status == "succeeded"


def day(db: Path, calendar_day: str = "2026-06-01") -> DailyObservation:
    return next(
        d
        for d in get_daily_summary(db, calendar_day, "2026-06-04").days
        if d.date == calendar_day
    )


@pytest.fixture
def database(tmp_path: Path) -> Path:
    db = tmp_path / "synthetic.sqlite"
    initialize_database(db)
    ingest(
        db,
        payload(
            1,
            samples=[sample(RAW, 6)],
            baseline=True,
            raw_intervals=[
                {"client_record_id": RAW, "start_time": START, "end_time": END}
            ],
        ),
    )
    ingest(db, payload(2, samples=[sample(DAILY, 6, daily=True)], statistics=True))
    assert day(db).daily_activity_totals == {TYPE: 6}
    return db


@pytest.mark.parametrize("replayed_value", [6.0, 8.0], ids=["changed", "identical"])
def test_unordered_raw_replay_preserves_order_and_fresh_daily_total(
    database: Path, replayed_value: float
) -> None:
    ingest(
        database,
        payload(
            10,
            samples=[sample(RAW, 8)],
            raw_intervals=[
                {"client_record_id": RAW, "start_time": START, "end_time": END}
            ],
        ),
    )
    ingest(
        database, payload(11, samples=[sample(DAILY, 8, daily=True)], statistics=True)
    )
    assert day(database).daily_activity_totals == {TYPE: 8}
    with sqlite3.connect(database) as connection:
        original = TypeAdapter(tuple[float, str]).validate_python(
            connection.execute(
                "select value,metadata_json from samples where client_record_id=?",
                (RAW,),
            ).fetchone()
        )

    for mutation in (
        payload(None, samples=[sample(RAW, replayed_value)]),
        payload(9, samples=[sample(RAW, 7)]),
    ):
        ingest(database, mutation)
        with sqlite3.connect(database) as connection:
            stored = TypeAdapter(tuple[float, str]).validate_python(
                connection.execute(
                    "select value,metadata_json from samples where client_record_id=?",
                    (RAW,),
                ).fetchone()
            )
        assert stored == original
        result = day(database)
        assert result.daily_activity_totals == {TYPE: 8}
        assert result.daily_projection_status == {TYPE: "fresh"}


def test_unordered_raw_without_prior_order_still_accepts_updates(
    tmp_path: Path,
) -> None:
    db = tmp_path / "unordered-raw.sqlite"
    for value in (6.0, 8.0):
        ingest(db, payload(None, samples=[sample(RAW, value)]))
        with sqlite3.connect(db) as connection:
            stored = TypeAdapter(tuple[float, str]).validate_python(
                connection.execute(
                    "select value,metadata_json from samples where client_record_id=?",
                    (RAW,),
                ).fetchone()
            )
        assert stored[0] == value
        assert "_bridge_raw_observation" not in OBSERVATION_PAYLOAD.validate_json(
            stored[1]
        )


def test_raw_deletion_unknown_retains_value_but_excludes_current_total(
    database: Path,
) -> None:
    ingest(database, payload(3, deleted=[RAW]))
    ingest(database, payload(4, statistics=True))
    result = day(database)
    assert result.daily_activity_totals == {}
    assert TYPE not in result.sample_totals
    assert result.sample_statistics[TYPE].total == 6
    assert result.sample_counts[TYPE] == 1
    assert result.model_dump()["daily_projection_status"][TYPE] == "unknown"
    with sqlite3.connect(database) as connection:
        assert connection.execute(
            "select value from samples where client_record_id=?", (DAILY,)
        ).fetchone() == (6,)


def test_zero_and_positive_recover_same_identity_without_clock_order(
    database: Path,
) -> None:
    ingest(database, payload(3, deleted=[RAW], generated=END))
    ingest(
        database,
        payload(
            4, samples=[sample(DAILY, 0, daily=True)], statistics=True, generated=START
        ),
    )
    assert day(database).daily_activity_totals == {TYPE: 0}
    ingest(
        database, payload(2, samples=[sample(DAILY, 6, daily=True)], statistics=True)
    )
    assert day(database).daily_activity_totals == {TYPE: 0}
    ingest(
        database, payload(5, samples=[sample(DAILY, 8, daily=True)], statistics=True)
    )
    assert day(database).daily_activity_totals == {TYPE: 8}


def test_duplicate_raw_and_deletion_replay_do_not_reinvalidate_fresh(
    database: Path,
) -> None:
    ingest(
        database,
        payload(
            1,
            samples=[sample(RAW, 6)],
            baseline=True,
            raw_intervals=[
                {"client_record_id": RAW, "start_time": START, "end_time": END}
            ],
        ),
    )
    assert day(database).daily_activity_totals == {TYPE: 6}
    deletion = payload(3, deleted=[RAW])
    ingest(database, deletion)
    ingest(
        database, payload(4, samples=[sample(DAILY, 0, daily=True)], statistics=True)
    )
    ingest(database, deletion)
    assert day(database).daily_activity_totals == {TYPE: 0}


def test_cold_legacy_unknown_deletion_does_not_invent_a_day(tmp_path: Path) -> None:
    db = tmp_path / "cold.sqlite"
    ingest(db, payload(None, samples=[sample(DAILY, 6, daily=True)]))
    ingest(db, payload(1, deleted=[RAW]))
    result = day(db)
    assert result.daily_activity_totals == {}
    assert result.sample_statistics[TYPE].total == 6
    assert result.model_dump()["daily_projection_status"][TYPE] == "legacy_unknown"
    ingest(db, payload(2, baseline=True))
    ingest(db, payload(3, samples=[sample(DAILY, 0, daily=True)], statistics=True))
    assert day(db).daily_activity_totals == {TYPE: 0}


def test_unknown_uuid_preserves_rows_and_reports_unresolved_scope(
    database: Path,
) -> None:
    ingest(database, payload(3, deleted=[RAW + "-unrelated"]))
    assert day(database).daily_activity_totals == {}
    assert day(database).last_known_daily_activity_totals == {TYPE: 6}
    assert any(
        "unresolved" in note.lower()
        for note in get_daily_summary(
            database, "2026-06-01", "2026-06-02"
        ).missing_data_notes
    )


def test_same_batch_mutation_then_authoritative_zero(database: Path) -> None:
    ingest(
        database,
        payload(
            3, deleted=[RAW], samples=[sample(DAILY, 0, daily=True)], statistics=True
        ),
    )
    assert day(database).daily_activity_totals == {TYPE: 0}


def test_raw_correction_invalidates_old_and_new_interval_only(database: Path) -> None:
    next_start, next_end = END, "2026-06-03T00:00:00Z"
    ingest(database, payload(3, baseline=True, start=START, end=next_end))
    second = "hk-daily-activity-flights-climbed-20260602"
    ingest(
        database,
        payload(
            4,
            samples=[
                sample(
                    second,
                    9,
                    daily=True,
                    start=next_start,
                    end=next_end,
                    day="2026-06-02",
                )
            ],
            statistics=True,
            start=next_start,
            end=next_end,
        ),
    )
    ingest(
        database,
        payload(
            5,
            samples=[sample(RAW, 7, start=next_start, end=next_end)],
            raw_intervals=[
                {
                    "client_record_id": RAW,
                    "start_time": next_start,
                    "end_time": next_end,
                }
            ],
        ),
    )
    assert day(database).daily_activity_totals == {}
    assert day(database, "2026-06-02").daily_activity_totals == {}


def test_ingest_rollback_restores_raw_projection_and_freshness(database: Path) -> None:
    with sqlite3.connect(database) as connection:
        sql = (
            "create trigger reject_delete before insert on deleted_records "
            "begin select raise(ABORT, 'synthetic rollback'); end"
        )
        _ = connection.execute(sql)
    with pytest.raises(sqlite3.DatabaseError):
        ingest(database, payload(3, deleted=[RAW]))
    assert day(database).daily_activity_totals == {TYPE: 6}
    with sqlite3.connect(database) as connection:
        assert connection.execute(
            "select count(*) from samples where client_record_id=?", (RAW,)
        ).fetchone() == (1,)


@pytest.mark.parametrize(
    ("start", "end", "calendar_day", "zone"),
    [
        (
            "2026-03-08T05:00:00Z",
            "2026-03-09T04:00:00Z",
            "2026-03-08",
            "America/New_York",
        ),
        (
            "2026-11-01T04:00:00Z",
            "2026-11-02T05:00:00Z",
            "2026-11-01",
            "America/New_York",
        ),
        (
            "2018-11-04T03:00:00Z",
            "2018-11-05T02:00:00Z",
            "2018-11-04",
            "America/Sao_Paulo",
        ),
        (
            "2026-11-01T04:00:00Z",
            "2026-11-02T05:00:00Z",
            "2026-11-01",
            "America/Havana",
        ),
    ],
)
def test_dst_full_local_day_and_half_open_mutation_scope(
    tmp_path: Path,
    start: str,
    end: str,
    calendar_day: str,
    zone: str,
) -> None:
    db = tmp_path / "dst.sqlite"
    daily_id = "hk-daily-activity-flights-climbed-" + calendar_day.replace("-", "")
    ingest(
        db,
        payload(
            1,
            baseline=True,
            start=start,
            end=end,
            raw_intervals=[
                {"client_record_id": RAW, "start_time": start, "end_time": start}
            ],
        ),
    )
    ingest(
        db,
        payload(
            2,
            samples=[
                sample(
                    daily_id,
                    6,
                    daily=True,
                    start=start,
                    end=end,
                    day=calendar_day,
                    zone=zone,
                )
            ],
            statistics=True,
            start=start,
            end=end,
        ),
    )
    summary = get_daily_summary(
        db,
        calendar_day,
        (date.fromisoformat(calendar_day) + timedelta(days=1)).isoformat(),
    )
    assert summary.days[0].daily_activity_totals == {TYPE: 6}
    ingest(db, payload(3, deleted=[RAW], start=start, end=end))
    summary = get_daily_summary(db, calendar_day, summary.period.end)
    assert summary.days[0].daily_activity_totals == {}
    assert summary.days[0].last_known_daily_activity_totals == {TYPE: 6}


def test_alias_raw_deletion_uses_canonical_scope_and_source(tmp_path: Path) -> None:
    db = tmp_path / "alias.sqlite"
    raw_id = "hk-quantity-active-energy-00000000-0000-0000-0000-000000000063"
    daily_id = "hk-daily-activity-energy-20260601"

    def energy(data: BatchPayload) -> BatchPayload:
        data["health_types"].append(
            {
                "type_code": "energy",
                "display_name": "Active Energy",
                "category": "activity",
                "default_unit": "kcal",
                "sensitivity": "low",
                "aliases": ["active_energy"],
            }
        )
        observation = OBSERVATION_PAYLOAD.validate_json(
            data["sync"]["cursors"][0]["cursor_value"]
        )
        observation["type_code"] = "active_energy"
        data["sync"]["cursors"][0]["cursor_kind"] = (
            "daily_projection_observation:active_energy"
        )
        data["sync"]["cursors"][0]["cursor_value"] = json.dumps(observation)
        for record in data["samples"]:
            record["type_code"] = "active_energy"
            record["unit"] = "kcal"
        return data

    ingest(
        db,
        energy(
            payload(
                1,
                samples=[sample(raw_id, 6)],
                baseline=True,
                raw_intervals=[
                    {"client_record_id": raw_id, "start_time": START, "end_time": END}
                ],
            )
        ),
    )
    ingest(
        db,
        energy(payload(2, samples=[sample(daily_id, 6, daily=True)], statistics=True)),
    )
    assert day(db).daily_activity_totals == {"energy": 6}
    ingest(db, energy(payload(3, deleted=[raw_id])))
    assert day(db).daily_activity_totals == {}


def test_other_source_and_display_name_do_not_change_projection_identity(
    database: Path,
) -> None:
    data = payload(3, deleted=[RAW])
    data["sources"].append(
        {"source_key": "synthetic.phone.other", "name": "Other phone", "kind": "phone"}
    )
    data["deleted_records"][0]["source_key"] = "synthetic.phone.other"
    data["sync"]["cursors"][0]["source_key"] = "synthetic.phone.other"
    data["sources"][0]["name"] = "Renamed synthetic phone"
    ingest(database, data)
    assert day(database).daily_activity_totals == {TYPE: 6}


def test_partial_projection_cannot_poison_a_completed_current_total(
    database: Path,
) -> None:
    partial = sample(DAILY + "-partial", 20, daily=True, end="2026-06-01T12:00:00Z")
    partial["metadata"]["aggregation_completeness"] = "partial"
    ingest(
        database,
        payload(3, samples=[sample(DAILY, 6, daily=True), partial], statistics=True),
    )
    assert day(database).daily_activity_totals == {TYPE: 6}
    assert day(database).sample_statistics[TYPE].total == 32
    assert day(database).sample_counts[TYPE] == 3


def test_unordered_legacy_daily_replay_cannot_replace_a_known_zero(
    database: Path,
) -> None:
    ingest(
        database, payload(3, samples=[sample(DAILY, 0, daily=True)], statistics=True)
    )
    ingest(database, payload(None, samples=[sample(DAILY, 6, daily=True)]))
    assert day(database).daily_activity_totals == {TYPE: 0}
    assert day(database).last_known_daily_activity_totals == {TYPE: 0}


def test_new_outbox_lineage_retires_old_replays(
    database: Path,
) -> None:
    baseline = payload(1, baseline=True)
    encoded = OBSERVATION_PAYLOAD.validate_json(
        baseline["sync"]["cursors"][0]["cursor_value"]
    )
    encoded["namespace"] = "synthetic-relaunched-outbox"
    baseline["sync"]["cursors"][0]["cursor_value"] = json.dumps(encoded)
    ingest(database, baseline)
    fresh = payload(2, samples=[sample(DAILY, 0, daily=True)], statistics=True)
    encoded = OBSERVATION_PAYLOAD.validate_json(
        fresh["sync"]["cursors"][0]["cursor_value"]
    )
    encoded["namespace"] = "synthetic-relaunched-outbox"
    fresh["sync"]["cursors"][0]["cursor_value"] = json.dumps(encoded)
    ingest(database, fresh)
    assert day(database).daily_activity_totals == {TYPE: 0}
    ingest(database, payload(99, baseline=True))
    ingest(
        database, payload(100, samples=[sample(DAILY, 6, daily=True)], statistics=True)
    )
    assert day(database).daily_activity_totals == {TYPE: 0}


def test_source_explanation_does_not_expose_internal_raw_identity_index(
    database: Path,
) -> None:
    result = explain_sources(database)
    assert result.sources_used
    assert all(
        not c.cursor_kind.startswith("daily_projection_") for c in result.sync_cursors
    )


def test_late_first_daily_projection_cannot_precede_scoped_raw_mutation(
    tmp_path: Path,
) -> None:
    db = tmp_path / "late-first.sqlite"
    ingest(
        db,
        payload(
            1,
            baseline=True,
            samples=[sample(RAW, 6)],
            raw_intervals=[
                {"client_record_id": RAW, "start_time": START, "end_time": END}
            ],
        ),
    )
    ingest(
        db,
        payload(
            4,
            samples=[sample(RAW, 8)],
            raw_intervals=[
                {"client_record_id": RAW, "start_time": START, "end_time": END}
            ],
        ),
    )
    ingest(db, payload(3, samples=[sample(DAILY, 6, daily=True)], statistics=True))
    assert day(db).daily_activity_totals == {}
    ingest(db, payload(5, samples=[sample(DAILY, 8, daily=True)], statistics=True))
    assert day(db).daily_activity_totals == {TYPE: 8}


def test_late_first_daily_projection_cannot_precede_raw_deletion(
    tmp_path: Path,
) -> None:
    db = tmp_path / "late-deletion.sqlite"
    ingest(
        db,
        payload(
            1,
            baseline=True,
            samples=[sample(RAW, 6)],
            raw_intervals=[
                {"client_record_id": RAW, "start_time": START, "end_time": END}
            ],
        ),
    )
    ingest(db, payload(4, deleted=[RAW]))
    ingest(db, payload(3, samples=[sample(DAILY, 6, daily=True)], statistics=True))
    assert day(db).daily_activity_totals == {}
    ingest(db, payload(5, samples=[sample(DAILY, 0, daily=True)], statistics=True))
    assert day(db).daily_activity_totals == {TYPE: 0}


def test_authoritative_zero_recovers_legacy_without_readable_raw_baseline(
    tmp_path: Path,
) -> None:
    db = tmp_path / "statistics-zero.sqlite"
    ingest(db, payload(None, samples=[sample(DAILY, 6, daily=True)]))
    ingest(db, payload(1, samples=[sample(DAILY, 0, daily=True)], statistics=True))
    assert day(db).daily_activity_totals == {TYPE: 0}


def test_unresolved_deletion_changes_query_confidence_without_inferred_day(
    database: Path,
) -> None:
    ingest(database, payload(3, deleted=[RAW + "-no-date"]))
    result = day(database)
    assert result.daily_activity_totals == {}
    assert result.last_known_daily_activity_totals == {TYPE: 6}
    assert result.daily_projection_status == {TYPE: "unknown"}
    with sqlite3.connect(database) as connection:
        metadata = TypeAdapter(tuple[str]).validate_python(
            connection.execute(
                "select metadata_json from samples where client_record_id=?", (DAILY,)
            ).fetchone()
        )
        encoded = metadata[0]
    state = OBSERVATION_PAYLOAD.validate_python(
        OBSERVATION_PAYLOAD.validate_json(encoded)["_bridge_daily_projection"]
    )
    assert state["status"] == "fresh"
    ingest(
        database, payload(4, samples=[sample(DAILY, 0, daily=True)], statistics=True)
    )
    assert day(database).daily_activity_totals == {TYPE: 0}


def test_unordered_unknown_deletion_invalidates_without_inventing_day(
    database: Path,
) -> None:
    missing = "hk-quantity-flights-climbed-00000000-0000-0000-0000-000000000064"
    counts = day(database).sample_counts
    mutation = payload(None, deleted=[missing])
    ingest(database, mutation)
    result = day(database)
    assert result.daily_activity_totals == {}
    assert result.last_known_daily_activity_totals == {TYPE: 6}
    assert result.daily_projection_status == {TYPE: "unknown"}
    assert result.sample_counts == counts

    ingest(
        database, payload(3, samples=[sample(DAILY, 0, daily=True)], statistics=True)
    )
    assert day(database).daily_activity_totals == {TYPE: 0}
    ingest(database, mutation)
    assert day(database).daily_activity_totals == {TYPE: 0}


def test_unresolved_marker_replay_cannot_replace_newer_confidence_boundary(
    database: Path,
) -> None:
    ingest(database, payload(4, deleted=[RAW + "-unknown-new"]))
    ingest(database, payload(3, deleted=[RAW + "-unknown-old"]))
    assert day(database).daily_activity_totals == {}
    ingest(
        database, payload(5, samples=[sample(DAILY, 0, daily=True)], statistics=True)
    )
    assert day(database).daily_activity_totals == {TYPE: 0}


def test_authoritative_statistics_can_establish_new_lineage_without_raw_values(
    database: Path,
) -> None:
    data = payload(1, samples=[sample(DAILY, 0, daily=True)], statistics=True)
    observation = OBSERVATION_PAYLOAD.validate_json(
        data["sync"]["cursors"][0]["cursor_value"]
    )
    observation["namespace"] = "synthetic-authoritative-new-lineage"
    data["sync"]["cursors"][0]["cursor_value"] = json.dumps(observation)
    ingest(database, data)
    assert day(database).daily_activity_totals == {TYPE: 0}
    ingest(
        database, payload(99, samples=[sample(DAILY, 6, daily=True)], statistics=True)
    )
    assert day(database).daily_activity_totals == {TYPE: 0}


@pytest.mark.parametrize("sequence", [None, 3])
def test_unresolved_typed_uuid_does_not_change_another_type_confidence(
    database: Path,
    sequence: int | None,
) -> None:
    steps = payload(1, baseline=True)
    encoded = OBSERVATION_PAYLOAD.validate_json(
        steps["sync"]["cursors"][0]["cursor_value"]
    )
    encoded["type_code"] = "steps"
    steps["sync"]["cursors"][0]["cursor_kind"] = "daily_projection_observation:steps"
    steps["sync"]["cursors"][0]["cursor_value"] = json.dumps(encoded)
    ingest(database, steps)
    steps = payload(
        2,
        statistics=True,
        samples=[
            sample("hk-daily-activity-steps-20260601", 9, daily=True, type_code="steps")
        ],
    )
    encoded["sequence"] = 2
    encoded["statistics_window"] = encoded.pop("raw_baseline")
    steps["sync"]["cursors"][0]["cursor_kind"] = "daily_projection_observation:steps"
    steps["sync"]["cursors"][0]["cursor_value"] = json.dumps(encoded)
    ingest(database, steps)
    mutation = payload(sequence, deleted=[RAW + "-missing"])
    encoded: dict[str, object] = {
        "namespace": NAMESPACE,
        "sequence": 3,
        "type_code": "steps",
        "raw_intervals": [],
    }
    mutation["sync"]["cursors"].append(
        {
            "source_key": SOURCE,
            "cursor_kind": "daily_projection_observation:steps",
            "cursor_value": json.dumps(encoded),
        }
    )
    ingest(database, mutation)
    assert day(database).daily_activity_totals == {"steps": 9}
