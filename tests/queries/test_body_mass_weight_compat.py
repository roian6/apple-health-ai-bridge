import sqlite3
from pathlib import Path

import pytest

from health_bridge.queries import get_timeseries
from health_bridge.storage import initialize_database


@pytest.mark.parametrize(
    ("stored_type_code", "stored_record_id", "requested_type_code"),
    [
        ("weight", "hk-quantity-weight-abc123", "body_mass"),
        ("body_mass", "hk-quantity-body-mass-abc123", "weight"),
    ],
)
def test_get_timeseries_resolves_body_mass_and_weight_in_both_directions(
    tmp_path: Path,
    stored_type_code: str,
    stored_record_id: str,
    requested_type_code: str,
) -> None:
    db_path = tmp_path / "body-mass-weight-query.sqlite"
    initialize_database(db_path)
    with sqlite3.connect(db_path) as connection:
        source = connection.execute(
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
        assert source.lastrowid is not None
        _ = connection.execute(
            """
            insert into samples (
                source_id, type_code, client_record_id, start_time, end_time,
                value, unit, metadata_json
            ) values (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                source.lastrowid,
                stored_type_code,
                stored_record_id,
                "2026-07-18T00:10:00Z",
                "2026-07-18T00:10:00Z",
                72.0,
                "kg",
                "{}",
            ),
        )

    result = get_timeseries(
        db_path,
        type_codes=(requested_type_code,),
        start_time="2026-07-18T00:00:00Z",
        end_time="2026-07-18T01:00:00Z",
    )

    assert result.requested_types == (requested_type_code,)
    assert [(point.type_code, point.value, point.unit) for point in result.points] == [
        (stored_type_code, 72.0, "kg"),
    ]
