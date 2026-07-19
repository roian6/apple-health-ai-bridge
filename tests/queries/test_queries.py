import sqlite3
from pathlib import Path

from pydantic import TypeAdapter

from health_bridge.queries import (
    explain_sources,
    get_daily_summary,
    get_sleep_summary,
    get_timeseries,
    get_workouts,
    list_synced_metrics,
)
from health_bridge.storage import initialize_database
from tests.fixture_helpers import initialized_fixture_db

SOURCE_ID_ROW_ADAPTER: TypeAdapter[tuple[int] | None] = TypeAdapter(tuple[int] | None)


def test_list_synced_metrics_returns_catalog_with_provenance_when_fixture_ingested(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    result = list_synced_metrics(db_path)

    # Then
    metrics_by_type = {metric.type_code: metric for metric in result.metrics}
    assert set(metrics_by_type) == {
        "weight",
        "heart_rate",
        "sleep_analysis",
        "steps",
        "workout",
    }
    assert metrics_by_type["workout"].record_count == 1
    assert metrics_by_type["sleep_analysis"].record_count == 1
    assert result.period.start == "2026-06-01T00:00:00Z"
    assert result.period.end == "2026-06-08T00:00:00Z"
    assert [source.source_key for source in result.sources_used] == [
        "synthetic.phone.alpha",
        "synthetic.watch.bravo",
    ]
    assert result.missing_data_notes != ()
    assert result.truncated is False


def test_get_timeseries_returns_requested_points_with_sources_when_records_exist(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    result = get_timeseries(
        db_path,
        type_codes=("steps", "heart_rate"),
        start_time="2026-06-01T00:00:00Z",
        end_time="2026-06-08T00:00:00Z",
    )

    # Then
    assert [(point.type_code, point.value, point.unit) for point in result.points] == [
        ("steps", 4321.0, "count"),
        ("heart_rate", 72.0, "count/min"),
    ]
    assert result.period.start == "2026-06-01T00:00:00Z"
    assert result.period.end == "2026-06-08T00:00:00Z"
    assert {source.source_key for source in result.sources_used} == {
        "synthetic.phone.alpha",
        "synthetic.watch.bravo",
    }
    assert result.truncated is False


def test_get_timeseries_resolves_legacy_active_energy_requests(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "legacy-active-energy-query.sqlite"
    initialize_database(db_path)
    with sqlite3.connect(db_path) as connection:
        source_cursor = connection.execute(
            """
            insert into sources (source_key, name, kind, bundle_id, device_model)
            values (?, ?, ?, ?, ?)
            """,
            (
                "apple_health.phone",
                "Synthetic Phone",
                "phone",
                "dev.example.HealthBridgeCompanion",
                "SyntheticPhone",
            ),
        )
        _ = connection.execute(
            """
            insert into samples (
                source_id, type_code, client_record_id, start_time, end_time,
                value, unit, metadata_json
            )
            values (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                source_cursor.lastrowid,
                "energy",
                "hk-quantity-energy-abc123",
                "2026-06-16T00:10:00Z",
                "2026-06-16T00:15:00Z",
                42.0,
                "kcal",
                "{}",
            ),
        )

    # When
    result = get_timeseries(
        db_path,
        type_codes=("active_energy",),
        start_time="2026-06-16T00:00:00Z",
        end_time="2026-06-16T01:00:00Z",
    )

    # Then
    assert result.requested_types == ("active_energy",)
    assert [(point.type_code, point.value, point.unit) for point in result.points] == [
        ("energy", 42.0, "kcal"),
    ]


def test_get_timeseries_includes_pre_migration_active_energy_rows(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "pre-migration-active-energy-query.sqlite"
    initialize_database(db_path)
    with sqlite3.connect(db_path) as connection:
        source_cursor = connection.execute(
            """
            insert into sources (source_key, name, kind, bundle_id, device_model)
            values (?, ?, ?, ?, ?)
            """,
            (
                "apple_health.phone",
                "Synthetic Phone",
                "phone",
                "dev.example.HealthBridgeCompanion",
                "SyntheticPhone",
            ),
        )
        _ = connection.execute(
            """
            insert into samples (
                source_id, type_code, client_record_id, start_time, end_time,
                value, unit, metadata_json
            )
            values (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                source_cursor.lastrowid,
                "active_energy",
                "hk-quantity-active-energy-abc123",
                "2026-06-16T00:10:00Z",
                "2026-06-16T00:15:00Z",
                21.0,
                "kcal",
                "{}",
            ),
        )

    # When
    result = get_timeseries(
        db_path,
        type_codes=("active_energy",),
        start_time="2026-06-16T00:00:00Z",
        end_time="2026-06-16T01:00:00Z",
    )

    # Then
    assert [(point.type_code, point.value, point.unit) for point in result.points] == [
        ("active_energy", 21.0, "kcal"),
    ]


def test_get_timeseries_exposes_sample_metadata_for_agent_source_decisions(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "timeseries-metadata-query.sqlite"
    initialize_database(db_path)
    with sqlite3.connect(db_path) as connection:
        source_cursor = connection.execute(
            """
            insert into sources (source_key, name, kind, bundle_id, device_model)
            values (?, ?, ?, ?, ?)
            """,
            (
                "apple_health.phone",
                "Apple Health on iPhone",
                "phone",
                "dev.example.HealthBridgeCompanion",
                "iPhone",
            ),
        )
        _ = connection.execute(
            """
            insert into samples (
                source_id, type_code, client_record_id, start_time, end_time,
                value, unit, metadata_json
            )
            values (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                source_cursor.lastrowid,
                "steps",
                "hk-step-sample-watch-1",
                "2026-07-05T01:00:00Z",
                "2026-07-05T01:05:00Z",
                120.0,
                "count",
                (
                    '{"sample_kind":"raw_quantity",'
                    '"healthkit_source_name":"Fixture Owner Apple Watch",'
                    '"healthkit_device_model":"Watch7,1"}'
                ),
            ),
        )

    # When
    result = get_timeseries(
        db_path,
        type_codes=("steps",),
        start_time="2026-07-05T00:00:00Z",
        end_time="2026-07-06T00:00:00Z",
    )

    # Then
    point = result.points[0]
    assert point.metadata["sample_kind"] == "raw_quantity"
    assert point.metadata["healthkit_source_name"] == "Fixture Owner Apple Watch"
    assert point.metadata["healthkit_device_model"] == "Watch7,1"


def test_get_timeseries_returns_unknown_availability_caveat_when_no_rows(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    result = get_timeseries(
        db_path,
        type_codes=("steps",),
        start_time="2026-06-20T00:00:00Z",
        end_time="2026-06-21T00:00:00Z",
    )

    # Then
    assert result.points == ()
    assert result.sources_used == ()
    assert "availability is unknown" in result.missing_data_notes[0]


def test_get_timeseries_returns_caveat_when_no_types_are_requested(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    result = get_timeseries(
        db_path,
        type_codes=(),
        start_time="2026-06-01T00:00:00Z",
        end_time="2026-06-08T00:00:00Z",
    )

    # Then
    assert result.points == ()
    assert result.sources_used == ()
    assert "availability is unknown" in result.missing_data_notes[0]


def test_get_workouts_returns_fixture_workout_with_provenance_when_in_range(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    result = get_workouts(
        db_path,
        start_date="2026-06-01",
        end_date="2026-06-08",
    )

    # Then
    assert len(result.workouts) == 1
    assert result.workouts[0].workout_type == "walking"
    assert result.workouts[0].duration_seconds == 1920
    assert result.sources_used[0].source_key == "synthetic.watch.bravo"
    assert result.period.start == "2026-06-01"
    assert result.period.end == "2026-06-08"


def test_date_range_queries_return_unknown_availability_caveats_when_no_rows(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    workouts = get_workouts(
        db_path,
        start_date="2026-06-20",
        end_date="2026-06-21",
    )
    sleep = get_sleep_summary(
        db_path,
        start_date="2026-06-20",
        end_date="2026-06-21",
    )
    daily = get_daily_summary(
        db_path,
        start_date="2026-06-20",
        end_date="2026-06-21",
    )

    # Then
    assert workouts.workouts == ()
    assert sleep.session_count == 0
    assert daily.days[0].sample_totals == {}
    assert "availability is unknown" in workouts.missing_data_notes[0]
    assert "availability is unknown" in sleep.missing_data_notes[0]
    assert "availability is unknown" in daily.missing_data_notes[0]


def test_get_sleep_summary_returns_stage_totals_when_sleep_session_in_range(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    result = get_sleep_summary(
        db_path,
        start_date="2026-06-01",
        end_date="2026-06-08",
    )

    # Then
    assert result.session_count == 1
    assert result.stage_seconds == {
        "awake": 1200,
        "core": 12900,
        "deep": 4200,
        "in_bed": 900,
        "rem": 8100,
    }
    assert result.sources_used[0].source_key == "synthetic.watch.bravo"
    assert result.truncated is False


def test_get_daily_summary_returns_observations_without_interpretation(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    result = get_daily_summary(
        db_path,
        start_date="2026-06-01",
        end_date="2026-06-08",
    )

    # Then
    assert result.days[0].date == "2026-06-01"
    assert result.days[0].sample_totals["steps"] == 4321.0
    assert result.days[0].sample_statistics["steps"].aggregation == "sum"
    assert result.days[2].workout_count == 1
    assert result.days[3].sleep_session_count == 1
    assert result.missing_data_notes != ()
    assert result.truncated is False


def test_get_daily_summary_uses_type_aware_sample_statistics(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)
    _insert_metric_samples(db_path)

    # When
    result = get_daily_summary(
        db_path,
        start_date="2026-06-06",
        end_date="2026-06-07",
    )

    # Then
    day = result.days[0]
    assert day.sample_totals["active_energy"] == 150.0
    assert "heart_rate" not in day.sample_totals
    assert "body_mass" not in day.sample_totals

    heart_rate = day.sample_statistics["heart_rate"]
    assert heart_rate.aggregation == "min_max_average"
    assert heart_rate.unit == "count/min"
    assert heart_rate.count == 2
    assert heart_rate.minimum == 60.0
    assert heart_rate.maximum == 80.0
    assert heart_rate.average == 70.0
    assert heart_rate.total is None
    assert heart_rate.latest is None

    body_mass = day.sample_statistics["body_mass"]
    assert body_mass.aggregation == "latest"
    assert body_mass.unit == "kg"
    assert body_mass.count == 2
    assert body_mass.latest == 71.5
    assert body_mass.latest_time == "2026-06-06T21:00:00Z"
    assert body_mass.total is None

    active_energy = day.sample_statistics["active_energy"]
    assert active_energy.aggregation == "sum"
    assert active_energy.unit == "kcal"
    assert active_energy.count == 2
    assert active_energy.total == 150.0


def test_get_daily_summary_preserves_units_and_rejects_mixed_unit_totals(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)
    _insert_mixed_unit_samples(db_path)

    # When
    result = get_daily_summary(
        db_path,
        start_date="2026-06-07",
        end_date="2026-06-08",
    )

    # Then
    day = result.days[0]
    body_mass = day.sample_statistics["body_mass"]
    assert body_mass.aggregation == "latest"
    assert body_mass.unit == "lb"
    assert body_mass.count == 2
    assert body_mass.latest == 155.0
    assert body_mass.latest_time == "2026-06-07T21:00:00Z"

    active_energy = day.sample_statistics["active_energy"]
    assert active_energy.aggregation == "mixed_units"
    assert active_energy.unit == "mixed"
    assert active_energy.count == 2
    assert active_energy.total is None
    assert active_energy.average is None
    assert "active_energy" not in day.sample_totals


def test_get_daily_summary_uses_timeseries_catalog_type_semantics(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)
    _insert_timeseries_catalog_metric_samples(db_path)

    # When
    result = get_daily_summary(
        db_path,
        start_date="2026-06-08",
        end_date="2026-06-09",
    )

    # Then
    day = result.days[0]
    assert day.sample_totals["energy"] == 150.0
    assert day.sample_totals["distance_cycling"] == 1250.0
    assert day.sample_totals["hydration"] == 750.0
    assert "blood_pressure_systolic" not in day.sample_totals
    assert "weight" not in day.sample_totals

    weight = day.sample_statistics["weight"]
    assert weight.aggregation == "latest"
    assert weight.unit == "kg"
    assert weight.latest == 71.5
    assert weight.latest_time == "2026-06-08T21:00:00Z"

    systolic = day.sample_statistics["blood_pressure_systolic"]
    assert systolic.aggregation == "min_max_average"
    assert systolic.unit == "mmHg"
    assert systolic.average == 121.0
    assert systolic.minimum == 118.0
    assert systolic.maximum == 124.0


def test_get_daily_summary_distinguishes_raw_sample_sums_from_daily_aggregates(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)
    _insert_activity_semantics_samples(db_path)

    # When
    result = get_daily_summary(
        db_path,
        start_date="2026-06-09",
        end_date="2026-06-10",
    )

    # Then
    day = result.days[0]
    assert day.sample_totals["steps"] == 12824.0
    assert day.sample_totals["distance_walking_running"] == 9000.0
    assert day.sample_total_semantics["steps"] == "mixed_sum_semantics"
    assert day.sample_total_semantics["distance_walking_running"] == "daily_aggregate"
    assert day.daily_activity_totals["steps"] == 11824.0
    assert day.daily_activity_totals["distance_walking_running"] == 9000.0


def test_get_daily_summary_uses_calendar_day_metadata_for_daily_aggregates(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)
    with sqlite3.connect(db_path) as connection:
        source_id = _sample_source_id(connection)
        _ = connection.execute(
            """
            insert or replace into health_types
            (type_code, display_name, category, default_unit, sensitivity)
            values (?, ?, ?, ?, ?)
            """,
            ("steps", "Step Count", "activity", "count", "low"),
        )
        _ = connection.execute(
            """
            insert or replace into samples
            (source_id, type_code, client_record_id, start_time, end_time,
             value, unit, metadata_json)
            values (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                source_id,
                "steps",
                "hk-daily-activity-steps-20260625",
                "2026-06-24T15:00:00Z",
                "2026-06-25T15:00:00Z",
                9684.0,
                "count",
                '{"aggregation":"daily_sum","healthkit_query":"HKStatisticsCollectionQuery","sample_kind":"daily_aggregate","calendar_day":"2026-06-25","time_zone_identifier":"Asia/Tokyo"}',
            ),
        )

    # When
    result = get_daily_summary(
        db_path,
        start_date="2026-06-25",
        end_date="2026-06-26",
    )

    # Then
    day = result.days[0]
    assert day.date == "2026-06-25"
    assert day.daily_activity_totals["steps"] == 9684.0
    assert day.sample_total_semantics["steps"] == "daily_aggregate"
    assert day.sample_counts["steps"] == 1


def _insert_metric_samples(db_path: Path) -> None:
    with sqlite3.connect(db_path) as connection:
        source_id = _sample_source_id(connection)
        _upsert_sample_health_types(connection)
        upsert_sample_sql = """
            insert or replace into samples
            (source_id, type_code, client_record_id, start_time, end_time,
             value, unit, metadata_json)
            values (?, ?, ?, ?, ?, ?, ?, ?)
        """
        _ = connection.executemany(
            upsert_sample_sql,
            [
                (
                    source_id,
                    "heart_rate",
                    "query-hr-1",
                    "2026-06-06T09:00:00Z",
                    "2026-06-06T09:00:05Z",
                    60.0,
                    "count/min",
                    '{"aggregation":"min_max_average"}',
                ),
                (
                    source_id,
                    "heart_rate",
                    "query-hr-2",
                    "2026-06-06T10:00:00Z",
                    "2026-06-06T10:00:05Z",
                    80.0,
                    "count/min",
                    '{"aggregation":"min_max_average"}',
                ),
                (
                    source_id,
                    "body_mass",
                    "query-body-1",
                    "2026-06-06T07:00:00Z",
                    "2026-06-06T07:00:00Z",
                    72.0,
                    "kg",
                    '{"aggregation":"latest"}',
                ),
                (
                    source_id,
                    "body_mass",
                    "query-body-2",
                    "2026-06-06T21:00:00Z",
                    "2026-06-06T21:00:00Z",
                    71.5,
                    "kg",
                    '{"aggregation":"latest"}',
                ),
                (
                    source_id,
                    "active_energy",
                    "query-active-1",
                    "2026-06-06T11:00:00Z",
                    "2026-06-06T11:30:00Z",
                    100.0,
                    "kcal",
                    '{"aggregation":"sum"}',
                ),
                (
                    source_id,
                    "active_energy",
                    "query-active-2",
                    "2026-06-06T12:00:00Z",
                    "2026-06-06T12:30:00Z",
                    50.0,
                    "kcal",
                    '{"aggregation":"sum"}',
                ),
            ],
        )


def _insert_activity_semantics_samples(db_path: Path) -> None:
    with sqlite3.connect(db_path) as connection:
        source_id = _sample_source_id(connection)
        upsert_health_type_sql = """
            insert or replace into health_types
            (type_code, display_name, category, default_unit, sensitivity)
            values (?, ?, ?, ?, ?)
        """
        _ = connection.executemany(
            upsert_health_type_sql,
            [
                ("steps", "Step Count", "activity", "count", "low"),
                (
                    "distance_walking_running",
                    "Walking + Running Distance",
                    "activity",
                    "m",
                    "low",
                ),
            ],
        )
        upsert_sample_sql = """
            insert or replace into samples
            (source_id, type_code, client_record_id, start_time, end_time,
             value, unit, metadata_json)
            values (?, ?, ?, ?, ?, ?, ?, ?)
        """
        _ = connection.executemany(
            upsert_sample_sql,
            [
                (
                    source_id,
                    "steps",
                    "activity-raw-steps-1",
                    "2026-06-09T09:00:00Z",
                    "2026-06-09T09:10:00Z",
                    400.0,
                    "count",
                    '{"aggregation":"sum","healthkit_query":"HKAnchoredObjectQuery","sample_kind":"raw_quantity"}',
                ),
                (
                    source_id,
                    "steps",
                    "activity-raw-steps-2",
                    "2026-06-09T10:00:00Z",
                    "2026-06-09T10:15:00Z",
                    600.0,
                    "count",
                    '{"aggregation":"sum","healthkit_query":"HKAnchoredObjectQuery","sample_kind":"raw_quantity"}',
                ),
                (
                    source_id,
                    "steps",
                    "activity-daily-steps",
                    "2026-06-09T00:00:00Z",
                    "2026-06-10T00:00:00Z",
                    11824.0,
                    "count",
                    '{"aggregation":"daily_sum","healthkit_query":"HKStatisticsCollectionQuery","sample_kind":"daily_aggregate"}',
                ),
                (
                    source_id,
                    "distance_walking_running",
                    "activity-daily-distance",
                    "2026-06-09T00:00:00Z",
                    "2026-06-10T00:00:00Z",
                    9000.0,
                    "m",
                    '{"aggregation":"daily_sum","healthkit_query":"HKStatisticsCollectionQuery"}',
                ),
            ],
        )


def _insert_mixed_unit_samples(db_path: Path) -> None:
    with sqlite3.connect(db_path) as connection:
        source_id = _sample_source_id(connection)
        _upsert_sample_health_types(connection)
        upsert_sample_sql = """
            insert or replace into samples
            (source_id, type_code, client_record_id, start_time, end_time,
             value, unit, metadata_json)
            values (?, ?, ?, ?, ?, ?, ?, ?)
        """
        _ = connection.executemany(
            upsert_sample_sql,
            [
                (
                    source_id,
                    "body_mass",
                    "query-mixed-body-kg",
                    "2026-06-07T07:00:00Z",
                    "2026-06-07T07:00:00Z",
                    70.0,
                    "kg",
                    '{"aggregation":"latest"}',
                ),
                (
                    source_id,
                    "body_mass",
                    "query-mixed-body-lb",
                    "2026-06-07T21:00:00Z",
                    "2026-06-07T21:00:00Z",
                    155.0,
                    "lb",
                    '{"aggregation":"latest"}',
                ),
                (
                    source_id,
                    "active_energy",
                    "query-mixed-energy-kcal",
                    "2026-06-07T11:00:00Z",
                    "2026-06-07T11:30:00Z",
                    100.0,
                    "kcal",
                    '{"aggregation":"sum"}',
                ),
                (
                    source_id,
                    "active_energy",
                    "query-mixed-energy-kj",
                    "2026-06-07T12:00:00Z",
                    "2026-06-07T12:30:00Z",
                    418.4,
                    "kJ",
                    '{"aggregation":"sum"}',
                ),
            ],
        )


def _insert_timeseries_catalog_metric_samples(db_path: Path) -> None:
    with sqlite3.connect(db_path) as connection:
        source_id = _sample_source_id(connection)
        upsert_health_type_sql = """
            insert or replace into health_types
            (type_code, display_name, category, default_unit, sensitivity)
            values (?, ?, ?, ?, ?)
        """
        _ = connection.executemany(
            upsert_health_type_sql,
            [
                ("energy", "Energy", "activity", "kcal", "moderate"),
                (
                    "distance_cycling",
                    "Cycling Distance",
                    "activity",
                    "meters",
                    "moderate",
                ),
                ("hydration", "Hydration", "other", "mL", "moderate"),
                ("weight", "Weight", "body", "kg", "high"),
                (
                    "blood_pressure_systolic",
                    "Blood Pressure Systolic",
                    "heart",
                    "mmHg",
                    "high",
                ),
            ],
        )
        upsert_sample_sql = """
            insert or replace into samples
            (source_id, type_code, client_record_id, start_time, end_time,
             value, unit, metadata_json)
            values (?, ?, ?, ?, ?, ?, ?, ?)
        """
        _ = connection.executemany(
            upsert_sample_sql,
            [
                (
                    source_id,
                    "energy",
                    "catalog-energy-1",
                    "2026-06-08T09:00:00Z",
                    "2026-06-08T09:30:00Z",
                    100.0,
                    "kcal",
                    "{}",
                ),
                (
                    source_id,
                    "energy",
                    "catalog-energy-2",
                    "2026-06-08T10:00:00Z",
                    "2026-06-08T10:30:00Z",
                    50.0,
                    "kcal",
                    "{}",
                ),
                (
                    source_id,
                    "distance_cycling",
                    "catalog-distance-1",
                    "2026-06-08T11:00:00Z",
                    "2026-06-08T11:30:00Z",
                    1000.0,
                    "meters",
                    "{}",
                ),
                (
                    source_id,
                    "distance_cycling",
                    "catalog-distance-2",
                    "2026-06-08T12:00:00Z",
                    "2026-06-08T12:30:00Z",
                    250.0,
                    "meters",
                    "{}",
                ),
                (
                    source_id,
                    "hydration",
                    "catalog-hydration-1",
                    "2026-06-08T13:00:00Z",
                    "2026-06-08T13:05:00Z",
                    500.0,
                    "mL",
                    "{}",
                ),
                (
                    source_id,
                    "hydration",
                    "catalog-hydration-2",
                    "2026-06-08T14:00:00Z",
                    "2026-06-08T14:05:00Z",
                    250.0,
                    "mL",
                    "{}",
                ),
                (
                    source_id,
                    "weight",
                    "catalog-weight-1",
                    "2026-06-08T07:00:00Z",
                    "2026-06-08T07:00:00Z",
                    72.0,
                    "kg",
                    "{}",
                ),
                (
                    source_id,
                    "weight",
                    "catalog-weight-2",
                    "2026-06-08T21:00:00Z",
                    "2026-06-08T21:00:00Z",
                    71.5,
                    "kg",
                    "{}",
                ),
                (
                    source_id,
                    "blood_pressure_systolic",
                    "catalog-systolic-1",
                    "2026-06-08T08:00:00Z",
                    "2026-06-08T08:00:00Z",
                    118.0,
                    "mmHg",
                    "{}",
                ),
                (
                    source_id,
                    "blood_pressure_systolic",
                    "catalog-systolic-2",
                    "2026-06-08T20:00:00Z",
                    "2026-06-08T20:00:00Z",
                    124.0,
                    "mmHg",
                    "{}",
                ),
            ],
        )


def _sample_source_id(connection: sqlite3.Connection) -> int:
    source_row = SOURCE_ID_ROW_ADAPTER.validate_python(
        connection.execute(
            "select source_id from sources where source_key = ?",
            ("synthetic.phone.alpha",),
        ).fetchone(),
    )
    assert source_row is not None
    return source_row[0]


def _upsert_sample_health_types(connection: sqlite3.Connection) -> None:
    upsert_health_type_sql = """
        insert or replace into health_types
        (type_code, display_name, category, default_unit, sensitivity)
        values (?, ?, ?, ?, ?)
    """
    _ = connection.executemany(
        upsert_health_type_sql,
        [
            ("heart_rate", "Heart Rate", "heart", "count/min", "moderate"),
            ("body_mass", "Body Mass", "body", "kg", "high"),
            ("active_energy", "Active Energy", "activity", "kcal", "moderate"),
        ],
    )


def test_get_daily_summary_uses_only_sources_observed_in_requested_range(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    result = get_daily_summary(
        db_path,
        start_date="2026-06-02",
        end_date="2026-06-03",
    )

    # Then
    assert [source.source_key for source in result.sources_used] == [
        "synthetic.phone.alpha",
    ]


def test_explain_sources_returns_source_catalog_and_sync_cursors(
    tmp_path: Path,
) -> None:
    # Given
    db_path = initialized_fixture_db(tmp_path)

    # When
    result = explain_sources(db_path)

    # Then
    assert [source.source_key for source in result.sources] == [
        "synthetic.phone.alpha",
        "synthetic.watch.bravo",
    ]
    assert {cursor.cursor_kind for cursor in result.sync_cursors} == {
        "anchored_object_query",
    }
    assert result.missing_data_notes != ()
    assert result.truncated is False
