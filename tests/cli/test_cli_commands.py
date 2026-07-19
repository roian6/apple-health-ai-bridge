import os
import re
import sqlite3
from pathlib import Path
from subprocess import run
from typing import ClassVar, Final

import pytest
from pydantic import BaseModel, ConfigDict, TypeAdapter

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.storage.sqlite_rows import fetch_one_int

FIXTURE_PATH = Path("fixtures/health_bridge_batch_v1.synthetic.json")
ERROR_ROW_ADAPTER: Final[TypeAdapter[tuple[str, str] | None]] = TypeAdapter(
    tuple[str, str] | None,
)
SOURCE_ID_ROW_ADAPTER: Final[TypeAdapter[tuple[int] | None]] = TypeAdapter(
    tuple[int] | None,
)
LEGACY_DEV_COMMANDS: Final = (
    "dev-receiver-systemd",
    "dev-device-session",
    "dev-app-review-demo",
    "dev-validate-anchored-steps",
    "dev-watch-sync-runs",
)
ANSI_SGR_PATTERN: Final = re.compile(r"\x1b\[[0-9;]*m")


class CliModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)


class IssuedTokenOutput(CliModel):
    token: str
    token_prefix: str


class LatestSyncOutput(CliModel):
    sync_run_id: int
    status: str


class ReceiverStatusOutput(CliModel):
    has_active_token: bool
    active_token_count: int


def test_top_level_help_groups_developer_helpers_without_legacy_dev_commands() -> None:
    # Given / When
    result = run(
        ["uv", "run", "health-bridge", "--help"],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert result.returncode == 0, result.stderr
    plain_stdout = ANSI_SGR_PATTERN.sub("", result.stdout)
    assert " dev " in plain_stdout
    for command in LEGACY_DEV_COMMANDS:
        assert command not in plain_stdout


def test_public_dev_help_hides_app_review_release_helper() -> None:
    result = run(
        ["uv", "run", "health-bridge", "dev", "--help"],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    plain_stdout = ANSI_SGR_PATTERN.sub("", result.stdout)
    assert "app-review-demo" not in plain_stdout


class MetricStatusOutput(CliModel):
    record_count: int
    cursor_count: int
    latest_cursor_updated_at: str | None


class SyncCursorStatusOutput(CliModel):
    cursor_kind: str


class BridgeStatusOutput(CliModel):
    schema_id: str
    counts: dict[str, int]
    latest_sync: LatestSyncOutput
    receiver: ReceiverStatusOutput
    metrics: dict[str, MetricStatusOutput]
    sync_cursors: list[SyncCursorStatusOutput]
    missing_data_notes: list[str]


def test_cli_init_ingest_and_status_report_counts_when_fixture_is_valid(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "test.sqlite"

    # When
    init_result = run(
        ["uv", "run", "health-bridge", "init", "--db", str(db_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    ingest_result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "ingest-fixture",
            "--db",
            str(db_path),
            "--input",
            str(FIXTURE_PATH),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    duplicate_result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "ingest-fixture",
            "--db",
            str(db_path),
            "--input",
            str(FIXTURE_PATH),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    status_result = run(
        ["uv", "run", "health-bridge", "status", "--db", str(db_path)],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert init_result.returncode == 0, init_result.stderr
    assert ingest_result.returncode == 0, ingest_result.stderr
    assert duplicate_result.returncode == 0, duplicate_result.stderr
    assert status_result.returncode == 0, status_result.stderr
    assert "samples: 3" in status_result.stdout
    assert "sync_runs: 2" in status_result.stdout
    assert "last_sync_status: succeeded" in status_result.stdout

    with sqlite3.connect(db_path) as connection:
        sample_count = fetch_one_int(connection, "select count(*) from samples")
        sync_run_count = fetch_one_int(connection, "select count(*) from sync_runs")

    assert sample_count == 3
    assert sync_run_count == 2


@pytest.mark.skipif(os.name != "posix", reason="POSIX directory mode semantics")
def test_cli_init_reports_unsafe_parent_without_traceback(tmp_path: Path) -> None:
    unsafe_parent = tmp_path / "shared"
    unsafe_parent.mkdir()
    unsafe_parent.chmod(0o775)
    db_path = unsafe_parent / "missing-private" / "test.sqlite"

    result = run(
        ["uv", "run", "health-bridge", "init", "--db", str(db_path)],
        capture_output=True,
        text=True,
        check=False,
    )

    output = f"{result.stdout}\n{result.stderr}"
    assert result.returncode == 1
    assert "owner-only directory" in output
    assert "chmod 700" in output
    assert "Traceback" not in output


def test_cli_status_json_reports_structured_redacted_agent_snapshot(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "status-json.sqlite"
    _ = run(
        ["uv", "run", "health-bridge", "init", "--db", str(db_path)],
        capture_output=True,
        text=True,
        check=True,
    )
    _ = run(
        [
            "uv",
            "run",
            "health-bridge",
            "ingest-fixture",
            "--db",
            str(db_path),
            "--input",
            str(FIXTURE_PATH),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    token_result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "create-token",
            "--db",
            str(db_path),
            "--label",
            "ios-companion",
            "--print-secret",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    issued_token = IssuedTokenOutput.model_validate_json(token_result.stdout)
    with sqlite3.connect(db_path) as connection:
        source_row = SOURCE_ID_ROW_ADAPTER.validate_python(
            connection.execute(
                "select source_id from sources where source_key = ?",
                ("synthetic.phone.alpha",),
            ).fetchone()
        )
        assert source_row is not None
        source_id = source_row[0]
        insert_cursor_sql = "insert into sync_cursors (source_id, cursor_kind, cursor_value, updated_at) values (?, ?, ?, ?)"  # noqa: E501
        _ = connection.execute(
            insert_cursor_sql,
            (
                source_id,
                "foreground_quantity_sync:body_mass",
                "synthetic-cursor-body-mass-secret",
                "2026-06-08T09:30:00Z",
            ),
        )

    # When
    status_result = run(
        ["uv", "run", "health-bridge", "status", "--db", str(db_path), "--json"],
        capture_output=True,
        text=True,
        check=False,
    )
    payload = BridgeStatusOutput.model_validate_json(status_result.stdout)
    output_text = status_result.stdout

    # Then
    assert status_result.returncode == 0, status_result.stderr
    assert payload.schema_id == "health_bridge.status.v1"
    assert payload.counts["samples"] == 3
    assert payload.latest_sync.status == "succeeded"
    assert payload.latest_sync.sync_run_id == 1
    assert payload.receiver.has_active_token is True
    assert payload.receiver.active_token_count == 1
    assert payload.metrics["heart_rate"].record_count == 1
    assert payload.metrics["weight"].cursor_count == 1
    assert payload.metrics["weight"].latest_cursor_updated_at == "2026-06-08T09:30:00Z"
    assert payload.metrics["workout"].record_count == 1
    assert payload.metrics["sleep_analysis"].record_count == 1
    assert payload.sync_cursors[0].cursor_kind == "anchored_object_query"
    assert "secret" not in output_text.lower()
    assert "token_hash" not in output_text
    assert issued_token.token not in output_text
    assert issued_token.token_prefix not in output_text
    assert "synthetic-cursor" not in output_text


def test_cli_status_json_notes_optional_only_sync_without_core_daily_lanes(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "optional-only-status.sqlite"
    _ = run(
        ["uv", "run", "health-bridge", "init", "--db", str(db_path)],
        capture_output=True,
        text=True,
        check=True,
    )
    insert_source_sql = """
        insert into sources (source_key, name, kind)
        values (?, ?, ?)
        returning source_id
    """
    insert_health_type_sql = """
        insert into health_types
        (type_code, display_name, category, default_unit, sensitivity)
        values (?, ?, ?, ?, ?)
    """
    insert_sample_sql = """
        insert into samples
        (source_id, type_code, client_record_id, start_time, end_time,
         value, unit, metadata_json)
        values (?, ?, ?, ?, ?, ?, ?, ?)
    """
    insert_sync_run_sql = """
        insert into sync_runs
        (started_at, finished_at, status, schema_id, schema_version,
         fixture_name, source_count, health_type_count, sample_count,
         workout_count, sleep_session_count, deleted_record_count,
         sync_cursor_count)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """
    with sqlite3.connect(db_path) as connection:
        source_row = SOURCE_ID_ROW_ADAPTER.validate_python(
            connection.execute(
                insert_source_sql,
                ("apple_health.phone", "Apple Health on iPhone", "phone"),
            ).fetchone()
        )
        assert source_row is not None
        source_id = source_row[0]
        _ = connection.executemany(
            insert_health_type_sql,
            (
                (
                    "physical_effort",
                    "Physical Effort",
                    "activity",
                    "kcal/kg/hr",
                    "moderate",
                ),
                ("steps", "Steps", "activity", "count", "low"),
                ("workout", "Workouts", "activity", "session", "moderate"),
                ("sleep_analysis", "Sleep Analysis", "sleep", "stage", "moderate"),
            ),
        )
        _ = connection.execute(
            insert_sample_sql,
            (
                source_id,
                "physical_effort",
                "hk-physical-effort-1",
                "2026-06-29T00:00:00Z",
                "2026-06-29T00:05:00Z",
                1.0,
                "kcal/kg/hr",
                "{}",
            ),
        )
        _ = connection.execute(
            insert_sync_run_sql,
            (
                "2026-06-29T01:23:58Z",
                "2026-06-29T01:23:58Z",
                "succeeded",
                "health_bridge.batch.v1",
                "1",
                "receiver",
                1,
                4,
                1,
                0,
                0,
                0,
                1,
            ),
        )

    # When
    status_result = run(
        ["uv", "run", "health-bridge", "status", "--db", str(db_path), "--json"],
        capture_output=True,
        text=True,
        check=False,
    )
    payload = BridgeStatusOutput.model_validate_json(status_result.stdout)

    # Then
    assert status_result.returncode == 0, status_result.stderr
    assert payload.latest_sync.status == "succeeded"
    assert payload.metrics["physical_effort"].record_count == 1
    assert payload.metrics["steps"].record_count == 0
    assert payload.metrics["workout"].record_count == 0
    assert payload.metrics["sleep_analysis"].record_count == 0
    assert any(
        "core daily lanes have no records yet" in note
        for note in payload.missing_data_notes
    )
    assert "sample values" in payload.missing_data_notes[0]
    assert "token_hash" not in status_result.stdout
    assert "bearer_token" not in status_result.stdout


def test_cli_status_markdown_reports_redacted_agent_context(tmp_path: Path) -> None:
    # Given
    db_path = tmp_path / "status-markdown.sqlite"
    _ = run(
        ["uv", "run", "health-bridge", "init", "--db", str(db_path)],
        capture_output=True,
        text=True,
        check=True,
    )
    _ = run(
        [
            "uv",
            "run",
            "health-bridge",
            "ingest-fixture",
            "--db",
            str(db_path),
            "--input",
            str(FIXTURE_PATH),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    token_result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "receiver",
            "create-token",
            "--db",
            str(db_path),
            "--label",
            "ios-companion",
            "--print-secret",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    issued_token = IssuedTokenOutput.model_validate_json(token_result.stdout)

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "status",
            "--db",
            str(db_path),
            "--markdown",
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert result.returncode == 0, result.stderr
    assert "# Health Bridge Context" in result.stdout
    assert "## Store Counts" in result.stdout
    assert "samples: 3" in result.stdout
    assert "## Latest Sync" in result.stdout
    assert "status: succeeded" in result.stdout
    assert "## Synced Metrics" in result.stdout
    assert "heart_rate" in result.stdout
    assert "workout" in result.stdout
    assert "record_count: 1" in result.stdout
    assert "cursor_count:" in result.stdout
    assert "latest_cursor_updated_at:" in result.stdout
    assert "## Cursor Freshness" in result.stdout
    assert "anchored_object_query" in result.stdout
    assert "## Redaction Notes" in result.stdout
    assert "sample values" in result.stdout
    assert issued_token.token not in result.stdout
    assert issued_token.token_prefix not in result.stdout
    assert "synthetic-cursor" not in result.stdout
    assert "token_hash" not in result.stdout
    assert "bearer_token" not in result.stdout


def test_cli_status_markdown_reports_empty_store_notes(tmp_path: Path) -> None:
    # Given
    db_path = tmp_path / "empty-status-markdown.sqlite"
    _ = run(
        ["uv", "run", "health-bridge", "init", "--db", str(db_path)],
        capture_output=True,
        text=True,
        check=True,
    )

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "status",
            "--db",
            str(db_path),
            "--markdown",
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert result.returncode == 0, result.stderr
    assert "# Health Bridge Context" in result.stdout
    assert "- status: none" in result.stdout
    assert "- none" in result.stdout
    assert "No sync runs have been recorded yet." in result.stdout
    assert "No active receiver token is configured" in result.stdout
    assert "token_hash" not in result.stdout
    assert "bearer_token" not in result.stdout


def test_cli_status_markdown_writes_redacted_context_output_file(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "status-output.sqlite"
    output_path = tmp_path / "exports" / "bridge-context.md"
    _ = run(
        ["uv", "run", "health-bridge", "init", "--db", str(db_path)],
        capture_output=True,
        text=True,
        check=True,
    )
    _ = run(
        [
            "uv",
            "run",
            "health-bridge",
            "ingest-fixture",
            "--db",
            str(db_path),
            "--input",
            str(FIXTURE_PATH),
        ],
        capture_output=True,
        text=True,
        check=True,
    )

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "status",
            "--db",
            str(db_path),
            "--markdown",
            "--output",
            str(output_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output_text = output_path.read_text(encoding="utf-8")

    # Then
    assert result.returncode == 0, result.stderr
    assert result.stdout == f"wrote: {output_path}\n"
    assert "# Health Bridge Context" in output_text
    assert "heart_rate" in output_text
    assert "synthetic-cursor" not in output_text
    assert "bearer_token" not in output_text


def test_cli_status_output_rejects_directory_without_traceback(tmp_path: Path) -> None:
    # Given
    db_path = tmp_path / "status-output-directory.sqlite"
    output_path = tmp_path / "exports"
    output_path.mkdir()
    _ = run(
        ["uv", "run", "health-bridge", "init", "--db", str(db_path)],
        capture_output=True,
        text=True,
        check=True,
    )

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "status",
            "--db",
            str(db_path),
            "--markdown",
            "--output",
            str(output_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert result.returncode == 1
    assert result.stdout == ""
    assert f"Cannot write status output to directory: {output_path}" in result.stderr
    assert "Traceback" not in result.stderr
    assert "bearer_token" not in result.stderr
    assert "token_hash" not in result.stderr


def test_cli_status_output_rejects_file_parent_without_traceback(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "status-output-file-parent.sqlite"
    parent_file = tmp_path / "not-a-directory"
    _ = parent_file.write_text("not a directory", encoding="utf-8")
    output_path = parent_file / "bridge-context.md"
    _ = run(
        ["uv", "run", "health-bridge", "init", "--db", str(db_path)],
        capture_output=True,
        text=True,
        check=True,
    )

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "status",
            "--db",
            str(db_path),
            "--markdown",
            "--output",
            str(output_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert result.returncode == 1
    assert result.stdout == ""
    assert f"Cannot create status output directory: {parent_file}" in result.stderr
    assert "Traceback" not in result.stderr
    assert "bearer_token" not in result.stderr
    assert "token_hash" not in result.stderr


def test_cli_ingest_fixture_fails_cleanly_when_fixture_is_malformed(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "test.sqlite"
    malformed_path = tmp_path / "malformed.json"
    _ = malformed_path.write_text(
        '{"schema_id": "health_bridge.batch.v1", "secret": "do-not-print"',
        encoding="utf-8",
    )

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "ingest-fixture",
            "--db",
            str(db_path),
            "--input",
            str(malformed_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert result.returncode == 1
    assert "Fixture ingest failed: malformed JSON fixture." in result.stderr
    assert "do-not-print" not in result.stderr

    with sqlite3.connect(db_path) as connection:
        row = ERROR_ROW_ADAPTER.validate_python(
            connection.execute(
                "select status, error_summary from sync_runs",
            ).fetchone(),
        )

    assert row is not None
    assert row == ("failed", "Fixture JSON could not be decoded.")


def test_cli_ingest_fixture_fails_cleanly_when_storage_write_fails(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "test.sqlite"
    invalid_storage_path = tmp_path / "invalid-storage.json"
    batch = HealthBridgeBatchV1.model_validate_json(FIXTURE_PATH.read_bytes())
    invalid_sample = batch.samples[0].model_copy(
        update={"source_key": "synthetic.missing.source"},
    )
    invalid_batch = batch.model_copy(update={"samples": (invalid_sample,)})
    _ = invalid_storage_path.write_text(
        invalid_batch.model_dump_json(),
        encoding="utf-8",
    )

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "ingest-fixture",
            "--db",
            str(db_path),
            "--input",
            str(invalid_storage_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    # Then
    assert result.returncode == 1
    assert "Fixture ingest failed: records could not be stored." in result.stderr
    assert "synthetic.missing.source" not in result.stderr

    with sqlite3.connect(db_path) as connection:
        row = ERROR_ROW_ADAPTER.validate_python(
            connection.execute(
                "select status, error_summary from sync_runs",
            ).fetchone(),
        )

    assert row is not None
    assert row == ("failed", "Fixture records could not be stored.")
