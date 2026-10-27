import json
from pathlib import Path
from typing import Final

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.ingest import ingest_batch
from health_bridge.queries import get_daily_summary
from health_bridge.timeseries_catalog import (
    TIMESERIES_BY_TYPE_CODE,
    timeseries_aggregation_for,
)

SOURCE_KEY: Final = "synthetic.phone.nutrition"
DIETARY_UNITS: Final = {
    "dietary_energy_consumed": "kcal",
    "dietary_protein": "g",
    "dietary_carbohydrates": "g",
    "dietary_fat_total": "g",
    "dietary_fiber": "g",
}
# Synthetic values only; two raw samples per type on the same calendar day.
SYNTHETIC_VALUES: Final = {
    "dietary_energy_consumed": (400.0, 250.0),
    "dietary_protein": (20.0, 12.5),
    "dietary_carbohydrates": (45.0, 30.0),
    "dietary_fat_total": (10.0, 7.5),
    "dietary_fiber": (4.0, 3.0),
}


def _batch() -> HealthBridgeBatchV1:
    health_types: list[dict[str, object]] = [
        {
            "type_code": type_code,
            "display_name": TIMESERIES_BY_TYPE_CODE[type_code].description,
            "category": "nutrition",
            "default_unit": unit,
            "sensitivity": "moderate",
            "aliases": [],
        }
        for type_code, unit in DIETARY_UNITS.items()
    ]
    samples: list[dict[str, object]] = [
        {
            "client_record_id": f"synthetic-{type_code.replace('_', '-')}-{index}",
            "source_key": SOURCE_KEY,
            "type_code": type_code,
            "start_time": f"2026-06-08T{12 + index}:00:00Z",
            "end_time": f"2026-06-08T{12 + index}:00:00Z",
            "value": value,
            "unit": DIETARY_UNITS[type_code],
            "metadata": {"sample_kind": "raw_quantity", "aggregation": "sum"},
        }
        for type_code, values in SYNTHETIC_VALUES.items()
        for index, value in enumerate(values)
    ]
    return HealthBridgeBatchV1.model_validate_json(
        json.dumps(
            {
                "schema_id": "health_bridge.batch.v1",
                "schema_version": "1.0.0",
                "generated_at": "2026-06-08T20:00:00Z",
                "export_window": {
                    "start_time": "2026-06-08T00:00:00Z",
                    "end_time": "2026-06-09T00:00:00Z",
                },
                "sources": [
                    {
                        "source_key": SOURCE_KEY,
                        "name": "Synthetic Nutrition Phone",
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
    )


def test_dietary_types_use_nutrition_category_and_sum_aggregation() -> None:
    for type_code, unit in DIETARY_UNITS.items():
        entry = TIMESERIES_BY_TYPE_CODE[type_code]
        assert entry.unit == unit
        assert entry.category == "nutrition"
        assert entry.aggregation == "sum"
        assert timeseries_aggregation_for(type_code) == "sum"


def test_dietary_batch_ingests_and_sums_into_daily_summary(tmp_path: Path) -> None:
    # Given
    db_path = tmp_path / "synthetic.sqlite"
    batch = _batch()

    # When
    result = ingest_batch(db_path, batch, "synthetic-nutrition")
    summary = get_daily_summary(
        db_path,
        start_date="2026-06-08",
        end_date="2026-06-09",
    )

    # Then
    assert result.status == "succeeded"
    day = summary.days[0]
    for type_code, values in SYNTHETIC_VALUES.items():
        assert day.sample_totals[type_code] == sum(values)
        statistics = day.sample_statistics[type_code]
        assert statistics.aggregation == "sum"
        assert statistics.unit == DIETARY_UNITS[type_code]
        assert statistics.count == len(values)
        assert type_code not in day.daily_activity_totals
