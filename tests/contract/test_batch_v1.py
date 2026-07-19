import json
from pathlib import Path
from typing import Final, cast

import pytest
from pydantic import ValidationError

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.mcp.types import (
    JsonObject,
    JsonValue,
    required_list,
    required_object,
)
from health_bridge.timeseries_catalog import TIMESERIES_BY_TYPE_CODE

FIXTURE_PATH = Path("fixtures/health_bridge_batch_v1.synthetic.json")
HEALTHKIT_STEP_ALIAS: Final = "HKQuantityTypeIdentifierStepCount"
DUPLICATE_ALIAS_REPLACEMENT: Final = (
    f'"aliases": ["{HEALTHKIT_STEP_ALIAS}", "{HEALTHKIT_STEP_ALIAS}"]'
)
JsonPathPart = str | int
SemanticCase = tuple[tuple[JsonPathPart, ...], JsonValue, str]
SEMANTIC_CASES: Final[tuple[SemanticCase, ...]] = (
    (("generated_at",), "2026-02-30T09:00:00Z", "valid UTC timestamp"),
    (
        ("export_window", "start_time"),
        "2026-06-09T00:00:00Z",
        "start_time must not be after end_time",
    ),
    (
        ("samples", 0, "start_time"),
        "2026-06-03T00:00:00Z",
        "start_time must not be after end_time",
    ),
    (
        ("workouts", 0, "duration_seconds"),
        999999,
        "duration_seconds must not exceed workout interval",
    ),
    (
        ("sleep_sessions", 0, "stage_intervals", 0, "start_time"),
        "2026-06-04T03:00:00Z",
        "sleep stage must be contained within its session",
    ),
    (
        ("sync", "sync_window", "start_time"),
        "2026-05-31T23:59:59Z",
        "sync window must be contained within export window",
    ),
)


def _fixture_object() -> JsonObject:
    return required_object(
        cast("JsonValue", json.loads(FIXTURE_PATH.read_text(encoding="utf-8")))
    )


def _set_json_path(
    payload: JsonObject,
    path: tuple[JsonPathPart, ...],
    value: JsonValue,
) -> None:
    current: JsonValue = payload
    for part in path[:-1]:
        if isinstance(part, str):
            current = required_object(current)[part]
        else:
            current = required_list(current)[part]
    last = path[-1]
    if isinstance(last, str):
        required_object(current)[last] = value
    else:
        required_list(current)[last] = value


@pytest.mark.parametrize(
    ("existing", "replacement"),
    [
        ('"schema_version": "1.0.0"', '"schema_version": "1.not-semver"'),
        ('"generated_at": "2026-06-08T09:00:00Z"', '"generated_at": "not-a-time"'),
        ('"source_key": "synthetic.phone.alpha"', '"source_key": "real.phone"'),
        ('"duration_seconds": 1920', '"duration_seconds": -1'),
        (',\n  "samples": [', ',\n  "missing_samples": ['),
        (',\n      "aliases": [', ',\n      "missing_aliases": ['),
        (',\n      "stage_intervals": [', ',\n      "missing_stage_intervals": ['),
        (',\n    "cursors": [', ',\n    "missing_cursors": ['),
        (
            '"bundle_id": "com.example.synthetic.healthbridge"',
            '"bundle_id": null',
        ),
        ('"energy_kcal": 140.5', '"energy_kcal": null'),
        (
            '"aliases": ["HKQuantityTypeIdentifierStepCount"]',
            DUPLICATE_ALIAS_REPLACEMENT,
        ),
    ],
)
def test_batch_rejects_values_outside_public_schema(
    existing: str,
    replacement: str,
) -> None:
    # Given
    fixture_text = FIXTURE_PATH.read_text(encoding="utf-8")
    invalid_text = fixture_text.replace(existing, replacement, 1)

    # When / Then
    with pytest.raises(ValidationError):
        _ = HealthBridgeBatchV1.model_validate_json(invalid_text)


def test_fixture_parses_when_batch_contract_is_v1() -> None:
    # Given
    fixture_bytes = FIXTURE_PATH.read_bytes()

    # When
    batch = HealthBridgeBatchV1.model_validate_json(fixture_bytes)

    # Then
    assert batch.schema_id == "health_bridge.batch.v1"
    assert batch.schema_version == "1.0.0"
    assert len(batch.sources) == 2
    assert len(batch.health_types) == 4
    assert len(batch.samples) == 3
    assert len(batch.workouts) == 1
    assert len(batch.sleep_sessions) == 1
    assert len(batch.sleep_sessions[0].stage_intervals) == 5
    assert len(batch.deleted_records) == 1
    assert len(batch.sync.cursors) == 2


def test_batch_accepts_apple_health_source_and_stable_healthkit_record_ids() -> None:
    # Given
    fixture_text = FIXTURE_PATH.read_text(encoding="utf-8")
    apple_health_text = (
        fixture_text.replace("synthetic.phone.alpha", "apple_health.phone")
        .replace("synthetic-sample-steps-20260601", "hk-sample-steps-20260601")
        .replace("synthetic-sample-body-mass-20260602", "hk-sample-body-mass-20260602")
        .replace(
            "synthetic-sample-steps-removed-20260605",
            "hk-sample-steps-removed-20260605",
        )
        .replace(
            "com.example.synthetic.healthbridge",
            "com.example.HealthBridgeCompanion",
        )
        .replace("Synthetic Phone Alpha", "Apple Health on iPhone")
    )

    # When
    batch = HealthBridgeBatchV1.model_validate_json(apple_health_text)

    # Then
    assert batch.sources[0].source_key == "apple_health.phone"
    assert batch.samples[0].client_record_id == "hk-sample-steps-20260601"
    assert (
        batch.deleted_records[0].client_record_id == "hk-sample-steps-removed-20260605"
    )


def test_batch_accepts_timeseries_catalog_representative_categories() -> None:
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
                "aliases": (),
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
    payload = {
        "schema_id": "health_bridge.batch.v1",
        "schema_version": "1.0.0",
        "generated_at": "2026-06-08T10:00:00Z",
        "export_window": {
            "start_time": "2026-06-08T00:00:00Z",
            "end_time": "2026-06-09T00:00:00Z",
        },
        "sources": (
            {
                "source_key": "synthetic.phone.alpha",
                "name": "Synthetic Phone Alpha",
                "kind": "phone",
            },
        ),
        "health_types": tuple(health_types),
        "samples": tuple(samples),
        "workouts": (),
        "sleep_sessions": (),
        "deleted_records": (),
        "sync": {
            "sync_window": {
                "start_time": "2026-06-08T00:00:00Z",
                "end_time": "2026-06-09T00:00:00Z",
            },
            "cursors": (),
        },
    }

    # When
    batch = HealthBridgeBatchV1.model_validate(payload)

    # Then
    assert [health_type.type_code for health_type in batch.health_types] == list(
        type_codes
    )
    assert len(batch.samples) == len(type_codes)


def test_batch_rejects_unknown_major_version() -> None:
    # Given
    fixture_text = FIXTURE_PATH.read_text(encoding="utf-8")
    unsupported_text = fixture_text.replace(
        '"schema_version": "1.0.0"',
        '"schema_version": "2.0.0"',
    )

    # When / Then
    with pytest.raises(ValidationError, match="major version 1"):
        _ = HealthBridgeBatchV1.model_validate_json(unsupported_text)


@pytest.mark.parametrize(
    ("path", "value", "message"),
    SEMANTIC_CASES,
)
def test_batch_rejects_semantically_invalid_times_and_intervals(
    path: tuple[JsonPathPart, ...],
    value: JsonValue,
    message: str,
) -> None:
    payload = _fixture_object()
    _set_json_path(payload, path, value)

    with pytest.raises(ValidationError, match=message):
        _ = HealthBridgeBatchV1.model_validate_json(json.dumps(payload))


@pytest.mark.parametrize("value", [float("nan"), float("inf"), float("-inf")])
def test_batch_rejects_non_finite_sample_values(value: float) -> None:
    payload = _fixture_object()
    _set_json_path(payload, ("samples", 0, "value"), value)

    with pytest.raises(ValidationError, match="finite number"):
        _ = HealthBridgeBatchV1.model_validate_json(json.dumps(payload))
