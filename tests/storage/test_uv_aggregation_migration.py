import json
import sqlite3
from contextlib import closing
from pathlib import Path

import pytest
from pydantic import TypeAdapter

from health_bridge.queries import get_daily_summary
from health_bridge.storage import database
from health_bridge.storage.database import initialize_database
from tests.fixture_helpers import initialized_fixture_db

MIGRATION_ID = "014_uv_raw_aggregation"
DAY = "2026-01-02"
ROWS_ADAPTER = TypeAdapter(list[tuple[object, ...]])
SOURCE_ADAPTER = TypeAdapter(tuple[int])
COUNT_ADAPTER = TypeAdapter(tuple[int])
METADATA_ADAPTER = TypeAdapter(dict[str, object])


def _legacy_database(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    with monkeypatch.context() as hooks:
        hooks.setattr(database, "MIGRATION_IDS", database.MIGRATION_IDS[:13])
        db_path = initialized_fixture_db(tmp_path)
    with closing(sqlite3.connect(db_path)) as connection:
        _ = connection.execute(
            """insert into health_types
            (type_code, display_name, category, default_unit, sensitivity)
            values
            ('uv_exposure', 'UV exposure', 'environmental', 'count', 'moderate')""",
        )
        connection.commit()
    for client_id, hour, value, aggregation in (
        ("uv-old", "08", 0.0, "sum"),
        ("uv-new", "09", 8.0, "min_max_average"),
    ):
        _insert_sample(
            db_path,
            client_id,
            json.dumps(
                {
                    "aggregation": aggregation,
                    "sample_kind": "raw_quantity",
                    "healthkit_identifier": "HKQuantityTypeIdentifierUVExposure",
                    "healthkit_object_kind": "quantity",
                    "keep": {"synthetic": True},
                },
            ),
            measurement=(hour, value),
        )
    return db_path


def _insert_sample(
    db_path: Path,
    client_id: str,
    metadata: str,
    *,
    type_code: str = "uv_exposure",
    measurement: tuple[str, float] = ("10", 1.0),
) -> None:
    hour, value = measurement
    timestamp = f"{DAY}T{hour}:00:00Z"
    with closing(sqlite3.connect(db_path)) as connection:
        source_id = SOURCE_ADAPTER.validate_python(
            connection.execute(
                "select source_id from sources order by source_id limit 1",
            ).fetchone(),
        )[0]
        _ = connection.execute(
            """insert into samples
            (source_id, type_code, client_record_id, start_time, end_time,
            value, unit, metadata_json, created_at, updated_at)
            values (?, ?, ?, ?, ?, ?, 'count', ?, ?, ?)""",
            (
                source_id,
                type_code,
                client_id,
                timestamp,
                timestamp,
                value,
                metadata,
                timestamp,
                timestamp,
            ),
        )
        connection.commit()


def _rows(db_path: Path) -> list[tuple[object, ...]]:
    with closing(sqlite3.connect(db_path)) as connection:
        return ROWS_ADAPTER.validate_python(
            connection.execute(
                """select sample_id, source_id, type_code, client_record_id, start_time,
                end_time, value, unit, created_at, updated_at,
                metadata_json
                from samples order by sample_id""",
            ).fetchall(),
        )


def _migration_count(db_path: Path) -> int:
    with closing(sqlite3.connect(db_path)) as connection:
        return COUNT_ADAPTER.validate_python(
            connection.execute(
                "select count(*) from schema_migrations where migration_id = ?",
                (MIGRATION_ID,),
            ).fetchone(),
        )[0]


def test_legacy_uv_metadata_no_longer_sums_a_mixed_day(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = _legacy_database(tmp_path, monkeypatch)
    before = _rows(db_path)

    initialize_database(db_path)

    statistic = (
        get_daily_summary(db_path, DAY, "2026-01-03")
        .days[0]
        .sample_statistics["uv_exposure"]
    )
    assert statistic.aggregation == "min_max_average"
    assert statistic.total is None
    assert (statistic.minimum, statistic.average, statistic.maximum) == (0.0, 4.0, 8.0)
    after = _rows(db_path)
    assert [row[:-1] for row in after] == [row[:-1] for row in before]
    for old, new in zip(before, after, strict=True):
        if old[3] == "uv-old":
            metadata = METADATA_ADAPTER.validate_json(str(old[-1]))
            metadata["aggregation"] = "min_max_average"
            assert METADATA_ADAPTER.validate_json(str(new[-1])) == metadata
        else:
            assert new == old


def test_uv_migration_preserves_other_representations_and_invalid_metadata(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = _legacy_database(tmp_path, monkeypatch)
    for client_id, metadata, type_code in (
        ("other-type", '{"aggregation":"sum","sample_kind":"raw_quantity"}', "steps"),
        (
            "daily-uv",
            '{"aggregation":"sum","sample_kind":"daily_aggregate"}',
            "uv_exposure",
        ),
        ("unmarked-uv", '{"aggregation":"sum"}', "uv_exposure"),
        (
            "latest-uv",
            '{"aggregation":"latest","sample_kind":"raw_quantity"}',
            "uv_exposure",
        ),
        ("invalid-uv", "{invalid", "uv_exposure"),
        ("array-uv", "[]", "uv_exposure"),
        ("null-uv", "null", "uv_exposure"),
    ):
        _insert_sample(db_path, client_id, metadata, type_code=type_code)
    before = [row for row in _rows(db_path) if row[3] != "uv-old"]

    initialize_database(db_path)

    assert [row for row in _rows(db_path) if row[3] != "uv-old"] == before
    assert _migration_count(db_path) == 1


def test_uv_migration_is_idempotent(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    db_path = _legacy_database(tmp_path, monkeypatch)
    initialize_database(db_path)
    before = db_path.read_bytes()

    initialize_database(db_path)

    assert db_path.read_bytes() == before
    assert _migration_count(db_path) == 1


def test_uv_migration_rolls_back_metadata_when_ledger_write_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = _legacy_database(tmp_path, monkeypatch)
    before = _rows(db_path)
    real_connect = sqlite3.connect
    metadata_updates: list[int] = []

    def connect_without_migration_record(path: Path) -> sqlite3.Connection:
        connection = real_connect(path)

        def authorizer(
            action: int,
            table: str | None,
            column: str | None,
            _database_name: str | None,
            _trigger_name: str | None,
        ) -> int:
            if (
                action == sqlite3.SQLITE_UPDATE
                and table == "samples"
                and column == "metadata_json"
            ):
                metadata_updates.append(action)
            if action == sqlite3.SQLITE_INSERT and table == "schema_migrations":
                return sqlite3.SQLITE_DENY
            return sqlite3.SQLITE_OK

        connection.set_authorizer(authorizer)
        return connection

    with monkeypatch.context() as hooks:
        hooks.setattr(sqlite3, "connect", connect_without_migration_record)
        with pytest.raises(sqlite3.DatabaseError, match="not authorized"):
            initialize_database(db_path)

    assert metadata_updates
    assert _rows(db_path) == before
    assert _migration_count(db_path) == 0
    initialize_database(db_path)
    assert _migration_count(db_path) == 1
