import json
from pathlib import Path
from subprocess import run
from typing import ClassVar, Literal

from pydantic import BaseModel, ConfigDict, TypeAdapter


class AnchoredStepValidationOutput(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid")

    schema_id: Literal["health_bridge.dev.anchored_step_validation.v1"]
    source_key: str
    type_code: Literal["steps"]
    raw_sample_count: int
    legacy_daily_sample_count: int
    sample_tombstone_count: int
    legacy_daily_tombstone_count: int
    has_anchor_cursor: bool
    has_bootstrap_cursor: bool
    latest_raw_sample_end: str | None
    latest_tombstone_deleted_at: str | None
    verdict: str
    missing_data_notes: list[str]


OUTPUT_ADAPTER: TypeAdapter[AnchoredStepValidationOutput] = TypeAdapter(
    AnchoredStepValidationOutput,
)


def test_dev_validate_anchored_steps_reports_receiver_side_raw_samples_and_tombstones(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "anchored-steps.sqlite"
    legacy_fixture = _legacy_daily_steps_batch()
    anchored_fixture = _anchored_steps_batch()
    legacy_path = tmp_path / "legacy-daily-steps.json"
    anchored_path = tmp_path / "anchored-steps.json"
    _ = legacy_path.write_text(json.dumps(legacy_fixture), encoding="utf-8")
    _ = anchored_path.write_text(json.dumps(anchored_fixture), encoding="utf-8")

    for fixture_path in (legacy_path, anchored_path):
        ingest_result = run(
            [
                "uv",
                "run",
                "health-bridge",
                "ingest-fixture",
                "--db",
                str(db_path),
                "--input",
                str(fixture_path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        assert ingest_result.returncode == 0, ingest_result.stderr

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "dev-validate-anchored-steps",
            "--db",
            str(db_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = OUTPUT_ADAPTER.validate_json(result.stdout)

    # Then
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert output.source_key == "apple_health.phone"
    assert output.raw_sample_count == 1
    assert output.legacy_daily_sample_count == 0
    assert output.sample_tombstone_count == 1
    assert output.legacy_daily_tombstone_count == 1
    assert output.has_anchor_cursor is True
    assert output.has_bootstrap_cursor is False
    assert output.latest_raw_sample_end == "2026-06-15T01:10:00Z"
    assert output.latest_tombstone_deleted_at == "2026-06-15T01:30:00Z"
    assert output.verdict == "validated"
    assert output.missing_data_notes == []
    assert "cursor_value" not in result.stdout
    assert "opaque-anchor-1" not in result.stdout
    assert "value" not in result.stdout


def test_dev_validate_anchored_steps_reports_overlapping_legacy_daily_rows(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "overlapping-legacy.sqlite"
    legacy_path = tmp_path / "legacy-daily-steps.json"
    anchored_path = tmp_path / "anchored-steps.json"
    _ = legacy_path.write_text(
        json.dumps(_legacy_daily_steps_batch()), encoding="utf-8"
    )
    _ = anchored_path.write_text(
        json.dumps(_anchored_steps_batch(include_legacy_tombstone=False)),
        encoding="utf-8",
    )

    for fixture_path in (legacy_path, anchored_path):
        ingest_result = run(
            [
                "uv",
                "run",
                "health-bridge",
                "ingest-fixture",
                "--db",
                str(db_path),
                "--input",
                str(fixture_path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        assert ingest_result.returncode == 0, ingest_result.stderr

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "dev-validate-anchored-steps",
            "--db",
            str(db_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = OUTPUT_ADAPTER.validate_json(result.stdout)

    # Then
    assert result.returncode == 0, result.stderr
    assert output.raw_sample_count == 1
    assert output.legacy_daily_sample_count == 1
    assert output.legacy_daily_tombstone_count == 0
    assert output.verdict == "legacy_daily_coexists"
    assert output.missing_data_notes == [
        "Legacy daily Step Count rows still coexist with anchored raw samples."
    ]


def test_dev_validate_anchored_steps_allows_non_overlapping_legacy_daily_rows(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "non-overlapping-legacy.sqlite"
    legacy_fixture = _legacy_daily_steps_batch(
        record_date="20260614",
        window_start="2026-06-14T00:00:00Z",
        window_end="2026-06-15T00:00:00Z",
    )
    legacy_path = tmp_path / "legacy-daily-steps.json"
    anchored_path = tmp_path / "anchored-steps.json"
    _ = legacy_path.write_text(json.dumps(legacy_fixture), encoding="utf-8")
    _ = anchored_path.write_text(json.dumps(_anchored_steps_batch()), encoding="utf-8")

    for fixture_path in (legacy_path, anchored_path):
        ingest_result = run(
            [
                "uv",
                "run",
                "health-bridge",
                "ingest-fixture",
                "--db",
                str(db_path),
                "--input",
                str(fixture_path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        assert ingest_result.returncode == 0, ingest_result.stderr

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "dev-validate-anchored-steps",
            "--db",
            str(db_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = OUTPUT_ADAPTER.validate_json(result.stdout)

    # Then
    assert result.returncode == 0, result.stderr
    assert output.raw_sample_count == 1
    assert output.legacy_daily_sample_count == 1
    assert output.legacy_daily_tombstone_count == 1
    assert output.verdict == "validated"
    assert output.missing_data_notes == []


def test_dev_validate_anchored_steps_reports_missing_data_without_exposing_values(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "empty.sqlite"
    init_result = run(
        ["uv", "run", "health-bridge", "init", "--db", str(db_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert init_result.returncode == 0, init_result.stderr

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "dev-validate-anchored-steps",
            "--db",
            str(db_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = OUTPUT_ADAPTER.validate_json(result.stdout)

    # Then
    assert result.returncode == 0, result.stderr
    assert output.verdict == "no_step_source"
    assert output.raw_sample_count == 0
    assert output.sample_tombstone_count == 0
    assert output.has_anchor_cursor is False
    assert output.missing_data_notes == [
        "No apple_health.phone source has been stored yet.",
        "No anchored Step Count cursor has been stored yet.",
        "No anchored raw Step Count samples have been stored yet.",
    ]
    assert "cursor_value" not in result.stdout
    assert "4321" not in result.stdout


def test_dev_validate_anchored_steps_reports_daily_only_store_as_missing_anchor(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "daily-only.sqlite"
    legacy_path = tmp_path / "legacy-daily-steps.json"
    _ = legacy_path.write_text(
        json.dumps(_legacy_daily_steps_batch()), encoding="utf-8"
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
            str(legacy_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert ingest_result.returncode == 0, ingest_result.stderr

    # When
    result = run(
        [
            "uv",
            "run",
            "health-bridge",
            "dev-validate-anchored-steps",
            "--db",
            str(db_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    output = OUTPUT_ADAPTER.validate_json(result.stdout)

    # Then
    assert result.returncode == 0, result.stderr
    assert output.verdict == "missing_anchor_cursor"
    assert output.raw_sample_count == 0
    assert output.legacy_daily_sample_count == 1
    assert output.missing_data_notes == [
        "No anchored Step Count cursor has been stored yet.",
        "No anchored raw Step Count samples have been stored yet.",
    ]


def _legacy_daily_steps_batch(
    *,
    record_date: str = "20260615",
    window_start: str = "2026-06-15T00:00:00Z",
    window_end: str = "2026-06-16T00:00:00Z",
) -> dict[str, object]:
    return {
        "schema_id": "health_bridge.batch.v1",
        "schema_version": "1.0.0",
        "generated_at": "2026-06-15T00:10:00Z",
        "export_window": {
            "start_time": window_start,
            "end_time": window_end,
        },
        "sources": [_apple_health_source()],
        "health_types": [_steps_type()],
        "samples": [
            {
                "client_record_id": f"hk-steps-{record_date}",
                "source_key": "apple_health.phone",
                "type_code": "steps",
                "start_time": window_start,
                "end_time": window_end,
                "value": 1234,
                "unit": "count",
                "metadata": {
                    "aggregation": "daily_sum",
                    "healthkit_query": "HKStatisticsCollectionQuery",
                },
            }
        ],
        "workouts": [],
        "sleep_sessions": [],
        "deleted_records": [],
        "sync": {
            "sync_window": {
                "start_time": window_start,
                "end_time": window_end,
            },
            "cursors": [
                {
                    "source_key": "apple_health.phone",
                    "cursor_kind": "foreground_daily_steps_sync",
                    "cursor_value": "2026-06-16T00:00:00Z",
                }
            ],
        },
    }


def _anchored_steps_batch(
    *, include_legacy_tombstone: bool = True
) -> dict[str, object]:
    deleted_records: list[dict[str, object]] = [
        {
            "record_family": "sample",
            "source_key": "apple_health.phone",
            "client_record_id": ("hk-step-sample-22222222-2222-2222-2222-222222222222"),
            "deleted_at": "2026-06-15T01:20:00Z",
        }
    ]
    if include_legacy_tombstone:
        deleted_records.append(
            {
                "record_family": "sample",
                "source_key": "apple_health.phone",
                "client_record_id": "hk-steps-20260615",
                "deleted_at": "2026-06-15T01:30:00Z",
            }
        )

    return {
        "schema_id": "health_bridge.batch.v1",
        "schema_version": "1.0.0",
        "generated_at": "2026-06-15T01:30:00Z",
        "export_window": {
            "start_time": "2026-06-15T00:00:00Z",
            "end_time": "2026-06-15T02:00:00Z",
        },
        "sources": [_apple_health_source()],
        "health_types": [_steps_type()],
        "samples": [
            {
                "client_record_id": (
                    "hk-step-sample-11111111-1111-1111-1111-111111111111"
                ),
                "source_key": "apple_health.phone",
                "type_code": "steps",
                "start_time": "2026-06-15T01:00:00Z",
                "end_time": "2026-06-15T01:10:00Z",
                "value": 42,
                "unit": "count",
                "metadata": {
                    "aggregation": "sum",
                    "healthkit_query": "HKAnchoredObjectQuery",
                    "sample_kind": "raw_quantity",
                },
            }
        ],
        "workouts": [],
        "sleep_sessions": [],
        "deleted_records": deleted_records,
        "sync": {
            "sync_window": {
                "start_time": "2026-06-15T00:00:00Z",
                "end_time": "2026-06-15T02:00:00Z",
            },
            "cursors": [
                {
                    "source_key": "apple_health.phone",
                    "cursor_kind": "anchored_step_sync",
                    "cursor_value": "opaque-anchor-1",
                }
            ],
        },
    }


def _apple_health_source() -> dict[str, str]:
    return {
        "source_key": "apple_health.phone",
        "name": "Apple Health on iPhone",
        "kind": "phone",
        "bundle_id": "com.example.HealthBridgeCompanion",
        "device_model": "iPhone",
    }


def _steps_type() -> dict[str, object]:
    return {
        "type_code": "steps",
        "display_name": "Steps",
        "category": "activity",
        "default_unit": "count",
        "sensitivity": "low",
        "aliases": ["HKQuantityTypeIdentifierStepCount"],
    }
