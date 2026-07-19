import sqlite3
from pathlib import Path

from pydantic import TypeAdapter

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.contract.batch_v1 import (
    DeletedRecord,
    HealthType,
    Sample,
    Source,
    SyncContext,
    SyncCursor,
    TimeWindow,
)
from health_bridge.ingest import ingest_batch
from health_bridge.storage import initialize_database

SOURCE_KEY = "apple_health.phone"
WINDOW = TimeWindow(
    start_time="2026-07-18T00:00:00Z",
    end_time="2026-07-18T01:00:00Z",
)
CURSOR_ROW_ADAPTER = TypeAdapter(tuple[str])


def _batch(  # noqa: PLR0913
    *,
    type_code: str,
    client_record_id: str,
    value: float | None = 72.0,
    deleted_client_record_id: str | None = None,
    cursor_kind: str | None = None,
    cursor_value: str = "2026-07-18T01:00:00Z",
) -> HealthBridgeBatchV1:
    samples = ()
    if value is not None:
        samples = (
            Sample(
                client_record_id=client_record_id,
                source_key=SOURCE_KEY,
                type_code=type_code,
                start_time="2026-07-18T00:10:00Z",
                end_time="2026-07-18T00:10:00Z",
                value=value,
                unit="kg",
            ),
        )
    deleted_records = ()
    if deleted_client_record_id is not None:
        deleted_records = (
            DeletedRecord(
                record_family="sample",
                source_key=SOURCE_KEY,
                client_record_id=deleted_client_record_id,
                deleted_at="2026-07-18T00:20:00Z",
            ),
        )
    cursors = ()
    if cursor_kind is not None:
        cursors = (
            SyncCursor(
                source_key=SOURCE_KEY,
                cursor_kind=cursor_kind,
                cursor_value=cursor_value,
            ),
        )
    return HealthBridgeBatchV1(
        schema_id="health_bridge.batch.v1",
        schema_version="1.0.0",
        generated_at="2026-07-18T01:00:00Z",
        export_window=WINDOW,
        sources=(
            Source(
                source_key=SOURCE_KEY,
                name="Synthetic Phone",
                kind="phone",
                bundle_id="dev.example.HealthBridgeCompanion",
                device_model="SyntheticPhone",
            ),
        ),
        health_types=(
            HealthType(
                type_code=type_code,
                display_name="Weight",
                category="body",
                default_unit="kg",
                sensitivity="high",
                aliases=("HKQuantityTypeIdentifierBodyMass",),
            ),
        ),
        samples=samples,
        workouts=(),
        sleep_sessions=(),
        deleted_records=deleted_records,
        sync=SyncContext(sync_window=WINDOW, cursors=cursors),
    )


def test_body_mass_upgrade_delete_and_replay_share_one_weight_namespace(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "body-mass-weight-upgrade.sqlite"
    initialize_database(db_path)
    with sqlite3.connect(db_path) as connection:
        source = connection.execute(
            """
            insert into sources (source_key, name, kind, bundle_id, device_model)
            values (?, ?, ?, ?, ?)
            """,
            (
                SOURCE_KEY,
                "Synthetic Phone",
                "phone",
                "dev.example.HealthBridgeCompanion",
                "SyntheticPhone",
            ),
        )
        assert source.lastrowid is not None
        source_id = source.lastrowid
        _ = connection.execute(
            """
            insert into health_types (
                type_code, display_name, category, default_unit, sensitivity
            ) values (?, ?, ?, ?, ?)
            """,
            ("body_mass", "Body Mass", "body", "kg", "high"),
        )
        _ = connection.execute(
            """
            insert into samples (
                source_id, type_code, client_record_id, start_time, end_time,
                value, unit, metadata_json
            ) values (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                source_id,
                "body_mass",
                "hk-quantity-body-mass-abc123",
                "2026-07-18T00:10:00Z",
                "2026-07-18T00:10:00Z",
                71.0,
                "kg",
                "{}",
            ),
        )
        _ = connection.execute(
            """
            insert into sync_cursors (source_id, cursor_kind, cursor_value)
            values (?, ?, ?)
            """,
            (
                source_id,
                "foreground_quantity_sync:body_mass",
                "2026-07-18T02:00:00Z",
            ),
        )

    upgrade = ingest_batch(
        db_path,
        _batch(
            type_code="weight",
            client_record_id="hk-quantity-weight-abc123",
            cursor_kind="foreground_quantity_sync:weight",
        ),
        "body-mass-upgrade",
    )

    with sqlite3.connect(db_path) as connection:
        upgraded_samples = connection.execute(
            """
            select type_code, client_record_id, value
            from samples order by sample_id
            """,
        ).fetchall()
        canonical_cursor = CURSOR_ROW_ADAPTER.validate_python(
            connection.execute(
                """
                select sync_cursors.cursor_value
                from sync_cursors
                join sources on sources.source_id = sync_cursors.source_id
                where sources.source_key = ? and sync_cursors.cursor_kind = ?
                """,
                (SOURCE_KEY, "foreground_quantity_sync:weight"),
            ).fetchone()
        )

    deletion = ingest_batch(
        db_path,
        _batch(
            type_code="weight",
            client_record_id="hk-quantity-weight-abc123",
            value=None,
            deleted_client_record_id="hk-quantity-weight-abc123",
        ),
        "body-mass-delete",
    )
    replay = ingest_batch(
        db_path,
        _batch(
            type_code="body_mass",
            client_record_id="hk-quantity-body-mass-abc123",
            value=73.0,
        ),
        "body-mass-legacy-replay",
    )

    with sqlite3.connect(db_path) as connection:
        remaining_samples = connection.execute(
            "select type_code, client_record_id from samples",
        ).fetchall()
        tombstones = connection.execute(
            "select client_record_id from deleted_records",
        ).fetchall()

    assert upgrade.status == "succeeded"
    assert upgraded_samples == [("weight", "hk-quantity-weight-abc123", 72.0)]
    assert canonical_cursor == ("2026-07-18T02:00:00Z",)
    assert deletion.status == "succeeded"
    assert replay.status == "succeeded"
    assert remaining_samples == []
    assert tombstones == [("hk-quantity-weight-abc123",)]
