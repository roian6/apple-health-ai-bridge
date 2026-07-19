import json
from pathlib import Path
from subprocess import run

from health_bridge.timeseries_catalog import TIMESERIES_BY_TYPE_CODE

SCHEMA_PATH = Path("schemas/health_bridge.batch.v1.schema.json")
FIXTURE_PATH = Path("fixtures/health_bridge_batch_v1.synthetic.json")
APPLE_HEALTH_FIXTURE_PATH = Path(
    "fixtures/health_bridge_batch_v1.apple-health-smoke.json"
)


def test_fixture_matches_public_json_schema() -> None:
    # Given
    command = [
        "uv",
        "run",
        "check-jsonschema",
        "--schemafile",
        str(SCHEMA_PATH),
        str(FIXTURE_PATH),
    ]

    # When
    result = run(command, capture_output=True, text=True, check=False)

    # Then
    assert result.returncode == 0, result.stderr


def test_apple_health_smoke_fixture_matches_public_json_schema() -> None:
    # Given
    command = [
        "uv",
        "run",
        "check-jsonschema",
        "--schemafile",
        str(SCHEMA_PATH),
        str(APPLE_HEALTH_FIXTURE_PATH),
    ]

    # When
    result = run(command, capture_output=True, text=True, check=False)

    # Then
    assert result.returncode == 0, result.stderr


def test_timeseries_catalog_representative_batch_matches_public_json_schema(
    tmp_path: Path,
) -> None:
    # Given
    type_codes = (
        "blood_pressure_systolic",
        "weight",
        "distance_cycling",
        "environmental_audio_exposure",
        "hydration",
    )
    health_types: list[dict[str, object]] = []
    samples: list[dict[str, object]] = []
    for index, type_code in enumerate(type_codes):
        entry = TIMESERIES_BY_TYPE_CODE[type_code]
        health_types.append(
            {
                "type_code": entry.type_code,
                "display_name": entry.description,
                "category": entry.category,
                "default_unit": entry.unit,
                "sensitivity": "moderate" if type_code != "weight" else "high",
                "aliases": [],
            },
        )
        samples.append(
            {
                "client_record_id": f"synthetic-timeseries-catalog-{index}",
                "source_key": "synthetic.phone.alpha",
                "type_code": entry.type_code,
                "start_time": "2026-06-08T09:00:00Z",
                "end_time": "2026-06-08T09:05:00Z",
                "value": 1.0,
                "unit": entry.unit,
                "metadata": {"aggregation": entry.aggregation},
            },
        )
    batch_path = tmp_path / "timeseries_catalog-representative.json"
    _ = batch_path.write_text(
        json.dumps(
            {
                "schema_id": "health_bridge.batch.v1",
                "schema_version": "1.0.0",
                "generated_at": "2026-06-08T10:00:00Z",
                "export_window": {
                    "start_time": "2026-06-08T00:00:00Z",
                    "end_time": "2026-06-09T00:00:00Z",
                },
                "sources": [
                    {
                        "source_key": "synthetic.phone.alpha",
                        "name": "Synthetic Phone Alpha",
                        "kind": "phone",
                    },
                ],
                "health_types": health_types,
                "samples": samples,
                "workouts": [],
                "sleep_sessions": [],
                "deleted_records": [],
                "sync": {
                    "sync_window": {
                        "start_time": "2026-06-08T00:00:00Z",
                        "end_time": "2026-06-09T00:00:00Z",
                    },
                    "cursors": [],
                },
            },
        ),
        encoding="utf-8",
    )
    command = [
        "uv",
        "run",
        "check-jsonschema",
        "--schemafile",
        str(SCHEMA_PATH),
        str(batch_path),
    ]

    # When
    result = run(command, capture_output=True, text=True, check=False)

    # Then
    assert result.returncode == 0, result.stdout + result.stderr


def test_public_schema_rejects_unknown_major_version(tmp_path: Path) -> None:
    # Given
    fixture_text = FIXTURE_PATH.read_text(encoding="utf-8")
    unsupported_path = tmp_path / "unsupported-major.json"
    _ = unsupported_path.write_text(
        fixture_text.replace('"schema_version": "1.0.0"', '"schema_version": "2.0.0"'),
        encoding="utf-8",
    )
    command = [
        "uv",
        "run",
        "check-jsonschema",
        "--schemafile",
        str(SCHEMA_PATH),
        str(unsupported_path),
    ]

    # When
    result = run(command, capture_output=True, text=True, check=False)

    # Then
    assert result.returncode != 0
    assert "schema_version" in result.stdout
