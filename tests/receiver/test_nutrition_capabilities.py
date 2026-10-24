from contextlib import closing
from http.client import HTTPConnection
from pathlib import Path
from typing import Final

import pytest
from pydantic import ValidationError

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.contract.batch_v1 import HealthType, Sample
from health_bridge.contract.receiver_capabilities import ReceiverCapabilitiesV1
from health_bridge.queries import get_daily_summary
from health_bridge.receiver.tokens import create_receiver_token
from health_bridge.status import read_status_snapshot
from tests.receiver.test_legacy_http_contract import (
    HttpObservation,
    post_raw_batch,
    running_receiver,
)

TOKEN: Final = "hb_synthetic_nutrition_capability"
NUTRIENTS: Final = (
    ("dietary_energy_consumed", "kcal", 400.0),
    ("dietary_protein", "g", 20.0),
    ("dietary_carbohydrates", "g", 45.0),
    ("dietary_fat_total", "g", 10.0),
    ("dietary_fiber", "g", 0.0),
)


@pytest.fixture
def nutrition_batch() -> HealthBridgeBatchV1:
    batch = HealthBridgeBatchV1.model_validate_json(
        Path("fixtures/health_bridge_batch_v1.synthetic.json").read_bytes()
    )
    return batch.model_copy(
        update={
            "health_types": batch.health_types
            + tuple(
                HealthType(
                    type_code=code,
                    display_name=code,
                    category="nutrition",
                    default_unit=unit,
                    sensitivity="moderate",
                    aliases=(),
                )
                for code, unit, _ in NUTRIENTS
            ),
            "samples": batch.samples
            + tuple(
                Sample(
                    client_record_id=f"synthetic-{code.replace('_', '-')}",
                    source_key=batch.sources[0].source_key,
                    type_code=code,
                    start_time="2026-06-01T12:00:00Z",
                    end_time="2026-06-01T12:00:00Z",
                    value=value,
                    unit=unit,
                    metadata={"sample_kind": "raw_quantity", "aggregation": "sum"},
                )
                for code, unit, value in NUTRIENTS
            ),
        }
    )


def get_capabilities(
    port: int, authorization: str, path: str = "/v1/capabilities"
) -> HttpObservation:
    with closing(HTTPConnection("127.0.0.1", port, timeout=5)) as connection:
        connection.request("GET", path, headers={"Authorization": authorization})
        response = connection.getresponse()
        return HttpObservation(
            status=response.status,
            content_type=response.getheader("Content-Type"),
            content_length=response.getheader("Content-Length"),
            www_authenticate=response.getheader("WWW-Authenticate"),
            body=response.read(),
        )


@pytest.mark.parametrize("include_existing", [False, True])
def test_advertised_nutrition_is_ingested_and_retried_without_double_counting(
    tmp_path: Path,
    nutrition_batch: HealthBridgeBatchV1,
    *,
    include_existing: bool,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    _ = create_receiver_token(db_path, label="synthetic", token=TOKEN)
    batch = nutrition_batch
    if not include_existing:
        batch = batch.model_copy(
            update={
                "health_types": tuple(
                    entry
                    for entry in batch.health_types
                    if entry.category == "nutrition"
                ),
                "samples": tuple(
                    sample
                    for sample in batch.samples
                    if sample.type_code.startswith("dietary_")
                ),
                "workouts": (),
                "sleep_sessions": (),
                "deleted_records": (),
            }
        )

    # When: discovery followed by delivery and an identical retry over real HTTP.
    with running_receiver(db_path) as port:
        capability = get_capabilities(port, f"Bearer {TOKEN}")
        assert capability.status == 200
        assert capability.content_type == "application/json"
        supported = ReceiverCapabilitiesV1.model_validate_json(capability.body)
        assert supported.nutrition_supported is True
        body = batch.model_dump_json(by_alias=True).encode()
        responses = (
            post_raw_batch(port, TOKEN, body),
            post_raw_batch(port, TOKEN, body),
        )
    day = get_daily_summary(
        db_path, start_date="2026-06-01", end_date="2026-06-02"
    ).days[0]

    # Then: all five advertised types, including an observed zero, remain distinct.
    assert [response.status for response in responses] == [202, 202]
    for code, unit, value in NUTRIENTS:
        assert day.sample_totals[code] == value
        assert day.sample_statistics[code].count == 1
        assert day.sample_statistics[code].unit == unit
        assert code not in day.daily_activity_totals
    if include_existing:
        assert day.sample_totals["steps"] == 4321


def test_nutrition_catalog_without_samples_is_accepted_without_inventing_zero(
    tmp_path: Path, nutrition_batch: HealthBridgeBatchV1
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    _ = create_receiver_token(db_path, label="synthetic", token=TOKEN)
    body = nutrition_batch.model_copy(update={"samples": ()}).model_dump_json().encode()

    # When
    with running_receiver(db_path) as port:
        response = post_raw_batch(port, TOKEN, body)
    snapshot = read_status_snapshot(db_path)

    # Then
    assert response.status == 202
    assert snapshot.counts["health_types"] == len(nutrition_batch.health_types)
    assert snapshot.counts["samples"] == 0
    day = get_daily_summary(
        db_path, start_date="2026-06-01", end_date="2026-06-02"
    ).days[0]
    assert day.sample_totals == {}
    assert day.sample_statistics == {}


@pytest.mark.parametrize(
    "authorization", ["", "Bearer", "Basic synthetic", "Bearer invalid"]
)
def test_capabilities_reject_missing_malformed_and_invalid_credentials(
    tmp_path: Path, authorization: str
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    _ = create_receiver_token(db_path, label="synthetic", token=TOKEN)

    # When
    with running_receiver(db_path) as port:
        response = get_capabilities(port, authorization)

    # Then
    assert response.status == 401
    assert response.www_authenticate == "Bearer"
    with pytest.raises(ValidationError):
        _ = ReceiverCapabilitiesV1.model_validate_json(response.body)
    assert read_status_snapshot(db_path).counts["samples"] == 0


def test_capability_response_prevents_shared_cache_reuse(tmp_path: Path) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    _ = create_receiver_token(db_path, label="synthetic", token=TOKEN)

    # When
    with (
        running_receiver(db_path) as port,
        closing(HTTPConnection("127.0.0.1", port, timeout=5)) as connection,
    ):
        connection.request(
            "GET", "/v1/capabilities", headers={"Authorization": f"Bearer {TOKEN}"}
        )
        response = connection.getresponse()
        cache_control = response.getheader("Cache-Control")
        _ = response.read()

    # Then
    assert response.status == 200
    assert cache_control == "no-store"


@pytest.mark.parametrize("path", ["/health", "/v0/capabilities"])
def test_legacy_health_and_unknown_routes_are_not_capability_evidence(
    tmp_path: Path, path: str
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"

    # When
    with running_receiver(db_path) as port:
        response = get_capabilities(port, "", path)

    # Then
    assert response.status == (200 if path == "/health" else 404)
    with pytest.raises(ValidationError):
        _ = ReceiverCapabilitiesV1.model_validate_json(response.body)


@pytest.mark.parametrize(
    "request_case",
    [("invalid", False, 401), (TOKEN, True, 422)],
)
def test_nutrition_rejection_preserves_the_entire_mixed_batch(
    tmp_path: Path,
    nutrition_batch: HealthBridgeBatchV1,
    request_case: tuple[str, bool, int],
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    _ = create_receiver_token(db_path, label="synthetic", token=TOKEN)
    token, malformed, expected_status = request_case
    body = nutrition_batch.model_dump_json().encode()
    if malformed:
        body = body.replace(b'"category":"nutrition"', b'"category":"unknown"')

    # When
    with running_receiver(db_path) as port:
        response = post_raw_batch(port, token, body)

    # Then
    assert response.status == expected_status
    snapshot = read_status_snapshot(db_path)
    assert snapshot.counts["samples"] == 0
    assert snapshot.counts["health_types"] == 0
