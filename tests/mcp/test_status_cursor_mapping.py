import json
import sqlite3
from contextlib import closing
from pathlib import Path

import pytest
from typer.testing import CliRunner

from health_bridge.cli import app
from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.contract.batch_v1 import HealthType, SyncCursor
from health_bridge.ingest import ingest_batch
from health_bridge.mcp.server import dispatch_request
from health_bridge.status import BridgeStatusSnapshot
from health_bridge.storage import initialize_database
from tests.fixture_helpers import FIXTURE_PATH
from tests.mcp.committed_read_support import status_payload, status_request


def _ingest_cursors(
    db_path: Path,
    *cursor_kinds: str,
    source_key: str = "synthetic.phone.alpha",
) -> None:
    fixture = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    batch = fixture.model_copy(
        update={
            "samples": (),
            "workouts": (),
            "sleep_sessions": (),
            "deleted_records": (),
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
                HealthType(
                    type_code="energy",
                    display_name="Energy",
                    category="activity",
                    default_unit="kcal",
                    sensitivity="low",
                    aliases=(),
                ),
            ),
            "sync": fixture.sync.model_copy(
                update={
                    "cursors": tuple(
                        SyncCursor(
                            source_key=source_key,
                            cursor_kind=cursor_kind,
                            cursor_value="synthetic-status-checkpoint",
                        )
                        for cursor_kind in cursor_kinds
                    ),
                },
            ),
        },
    )
    validated = HealthBridgeBatchV1.model_validate_json(batch.model_dump_json())

    assert ingest_batch(db_path, validated, "synthetic-status").status == "succeeded"


def _status(db_path: Path) -> BridgeStatusSnapshot:
    response = dispatch_request(db_path, status_request())

    return BridgeStatusSnapshot.model_validate_json(
        json.dumps(status_payload(response))
    )


def test_anchored_steps_cursor_contributes_to_metric_status(tmp_path: Path) -> None:
    db_path = tmp_path / "status.sqlite"
    _ingest_cursors(db_path, "anchored_step_sync")

    snapshot = _status(db_path)

    assert snapshot.metrics["steps"].record_count == 0
    assert snapshot.metrics["steps"].cursor_count == 1
    assert (
        snapshot.metrics["steps"].latest_cursor_updated_at
        == snapshot.sync_cursors[0].updated_at
    )
    assert snapshot.metrics["heart_rate"].cursor_count == 0


@pytest.mark.parametrize(
    ("cursor_kind", "type_code"),
    [
        ("foreground_quantity_sync:steps", "steps"),
        ("anchored_sleep_sync", "sleep_analysis"),
        ("foreground_sleep_sync", "sleep_analysis"),
        ("anchored_workout_sync", "workout"),
        ("foreground_workout_sync", "workout"),
        ("foreground_quantity_sync:heart_rate", "heart_rate"),
        ("healthkit_anchored_quantity:heart_rate", "heart_rate"),
        ("automatic_healthkit_anchored_quantity:heart_rate", "heart_rate"),
        ("foreground_quantity_sync:weight", "weight"),
        ("foreground_quantity_sync:body_mass", "weight"),
        ("healthkit_anchored_quantity:weight", "weight"),
        ("automatic_healthkit_anchored_quantity:weight", "weight"),
        ("foreground_quantity_sync:energy", "energy"),
        ("foreground_quantity_sync:active_energy", "energy"),
        ("healthkit_anchored_quantity:energy", "energy"),
        ("automatic_healthkit_anchored_quantity:energy", "energy"),
    ],
)
def test_current_and_legacy_cursor_families_contribute_only_to_their_metric(
    tmp_path: Path,
    cursor_kind: str,
    type_code: str,
) -> None:
    db_path = tmp_path / "status.sqlite"
    _ingest_cursors(db_path, cursor_kind)

    snapshot = _status(db_path)

    assert len(snapshot.sync_cursors) == 1
    assert snapshot.metrics[type_code].cursor_count == 1
    assert (
        snapshot.metrics[type_code].latest_cursor_updated_at
        == snapshot.sync_cursors[0].updated_at
    )
    assert all(
        metric.cursor_count == 0 and metric.latest_cursor_updated_at is None
        for code, metric in snapshot.metrics.items()
        if code != type_code
    )


@pytest.mark.parametrize("type_code", ["weight", "energy"])
@pytest.mark.parametrize("newest_kind_index", [0, 1, 2, 3])
def test_mixed_cursor_families_count_sources_and_use_newest_timestamp(
    tmp_path: Path,
    type_code: str,
    newest_kind_index: int,
) -> None:
    db_path = tmp_path / "status.sqlite"
    kinds = (
        f"foreground_quantity_sync:{type_code}",
        f"healthkit_anchored_quantity:{type_code}",
        f"automatic_healthkit_anchored_quantity:{type_code}",
    )
    _ingest_cursors(db_path, *kinds)
    _ingest_cursors(db_path, kinds[1], source_key="synthetic.watch.bravo")

    with closing(sqlite3.connect(db_path)) as connection, connection:
        _ = connection.execute("update sources set name = 'Synthetic Same Name'")
        _ = connection.execute(
            "update sync_cursors set updated_at = '2026-06-08T09:00:00Z'",
        )
        legacy_kind = (
            "foreground_quantity_sync:body_mass"
            if type_code == "weight"
            else "foreground_quantity_sync:active_energy"
        )
        # Retained aliases can coexist with canonical rows in an older store.
        _ = connection.execute(
            """insert into sync_cursors
               (source_id, cursor_kind, cursor_value, updated_at)
               select source_id, ?, ?, ? from sources where source_key = ?""",
            (
                legacy_kind,
                "synthetic-status-checkpoint",
                "2026-06-08T08:00:00Z",
                "synthetic.phone.alpha",
            ),
        )
        _ = connection.execute(
            """update sync_cursors set updated_at = '2026-06-08T10:00:00Z'
               where cursor_kind = ? and source_id =
               (select source_id from sources where source_key = ?)""",
            ((*kinds, legacy_kind)[newest_kind_index], "synthetic.phone.alpha"),
        )

    snapshot = _status(db_path)

    assert snapshot.metrics[type_code].cursor_count == 2
    assert (
        snapshot.metrics[type_code].latest_cursor_updated_at == "2026-06-08T10:00:00Z"
    )
    assert len(snapshot.sync_cursors) == 5


def test_newer_aggregate_checkpoints_do_not_refresh_sample_metrics(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "status.sqlite"
    _ingest_cursors(
        db_path,
        "anchored_step_sync",
        "healthkit_anchored_quantity:energy",
        "foreground_daily_steps_sync",
        "foreground_daily_activity_aggregate_sync",
    )
    with closing(sqlite3.connect(db_path)) as connection, connection:
        _ = connection.execute(
            """update sync_cursors set updated_at = case
               when cursor_kind in ('anchored_step_sync',
               'healthkit_anchored_quantity:energy') then '2026-06-08T09:00:00Z'
               else '2026-06-08T11:00:00Z' end""",
        )

    snapshot = _status(db_path)

    assert snapshot.metrics["steps"].cursor_count == 1
    assert snapshot.metrics["steps"].latest_cursor_updated_at == "2026-06-08T09:00:00Z"
    assert snapshot.metrics["energy"].cursor_count == 1
    assert snapshot.metrics["energy"].latest_cursor_updated_at == "2026-06-08T09:00:00Z"
    assert snapshot.metrics["weight"].cursor_count == 0
    assert len(snapshot.sync_cursors) == 4


def test_workout_cursor_matches_metric_synthesized_from_records(tmp_path: Path) -> None:
    db_path = tmp_path / "status.sqlite"
    fixture = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    batch = fixture.model_copy(
        update={
            "samples": (),
            "sleep_sessions": (),
            "deleted_records": (),
            "sync": fixture.sync.model_copy(
                update={
                    "cursors": (
                        SyncCursor(
                            source_key=fixture.workouts[0].source_key,
                            cursor_kind="anchored_workout_sync",
                            cursor_value="synthetic-workout-checkpoint",
                        ),
                    ),
                },
            ),
        },
    )
    validated = HealthBridgeBatchV1.model_validate_json(batch.model_dump_json())
    assert ingest_batch(db_path, validated, "synthetic-workout").status == "succeeded"

    snapshot = _status(db_path)

    assert "workout" in snapshot.metrics
    assert snapshot.metrics["workout"].record_count == 1
    assert snapshot.metrics["workout"].cursor_count == 1


@pytest.mark.parametrize(
    "cursor_kind",
    [
        "anchored_object_query",
        "connection_test",
        "anchored_step_bootstrap_start",
        "anchored_workout_bootstrap_start",
        "anchored_sleep_baseline_reset",
        "anchored_step_sync:extra",
        "healthkit_anchored_quantity:",
        "healthkit_anchored_quantity:heart_rate:extra",
        "automatic_healthkit_anchored_quantity:uncatalogued",
        "healthkit_anchored_quantity:workout",
        "foreground_quantity_sync:sleep_analysis",
        "foreground_daily_steps_sync",
        "foreground_daily_activity_aggregate_sync",
    ],
)
def test_unattributed_cursor_kinds_remain_top_level_only(
    tmp_path: Path,
    cursor_kind: str,
) -> None:
    db_path = tmp_path / "status.sqlite"
    _ingest_cursors(db_path)

    # Isolate reporting from the separate reset and bootstrap ingestion contracts.
    with closing(sqlite3.connect(db_path)) as connection, connection:
        _ = connection.execute(
            """insert into sync_cursors
               (source_id, cursor_kind, cursor_value, updated_at)
               select source_id, ?, ?, ? from sources where source_key = ?""",
            (
                cursor_kind,
                "synthetic-status-checkpoint",
                "2026-06-08T11:00:00Z",
                "synthetic.phone.alpha",
            ),
        )

    snapshot = _status(db_path)

    assert len(snapshot.sync_cursors) == 1
    assert snapshot.sync_cursors[0].cursor_kind == cursor_kind
    assert "uncatalogued" not in snapshot.metrics
    assert all(
        metric.cursor_count == 0 and metric.latest_cursor_updated_at is None
        for metric in snapshot.metrics.values()
    )


def test_empty_and_catalog_only_stores_have_no_metric_progress(tmp_path: Path) -> None:
    db_path = tmp_path / "status.sqlite"
    initialize_database(db_path)

    empty = _status(db_path)

    assert empty.metrics == {}
    assert empty.sync_cursors == ()

    _ingest_cursors(db_path)
    catalogued = _status(db_path)

    assert catalogued.metrics
    assert catalogued.sync_cursors == ()
    assert all(
        metric.record_count == 0
        and metric.cursor_count == 0
        and metric.latest_cursor_updated_at is None
        for metric in catalogued.metrics.values()
    )


def test_status_preserves_cursor_values_ownership_and_database_files(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "status.sqlite"
    _ingest_cursors(
        db_path,
        "healthkit_anchored_quantity:heart_rate",
        "automatic_healthkit_anchored_quantity:heart_rate",
    )
    before_bytes = db_path.read_bytes()
    before_stat = db_path.stat()
    before_entries = set(tmp_path.iterdir())

    snapshot = _status(db_path)
    serialized = snapshot.model_dump_json()
    runner = CliRunner()
    cli_json = runner.invoke(app, ["status", "--db", str(db_path), "--json"])
    cli_markdown = runner.invoke(app, ["status", "--db", str(db_path), "--markdown"])

    assert snapshot.metrics["heart_rate"].cursor_count == 1
    assert len(snapshot.sync_cursors) == 2
    assert cli_json.exit_code == 0
    assert BridgeStatusSnapshot.model_validate_json(cli_json.stdout) == snapshot
    assert cli_markdown.exit_code == 0
    metric_lines = cli_markdown.stdout.split("- heart_rate\n", maxsplit=1)[1].split(
        "\n- ", maxsplit=1
    )[0]
    assert "  - cursor_count: 1" in metric_lines
    latest_timestamp = snapshot.metrics["heart_rate"].latest_cursor_updated_at
    assert f"  - latest_cursor_updated_at: {latest_timestamp}" in metric_lines
    for output in (serialized, cli_json.stdout, cli_markdown.stdout):
        assert "synthetic-status-checkpoint" not in output
        assert "cursor_value" not in output

    assert db_path.read_bytes() == before_bytes
    assert db_path.stat().st_mode == before_stat.st_mode
    assert db_path.stat().st_mtime_ns == before_stat.st_mtime_ns
    assert set(tmp_path.iterdir()) == before_entries
