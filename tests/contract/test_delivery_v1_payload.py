import pytest

from health_bridge.contract import delivery_v1 as delivery
from tests.contract.delivery_v1_support import (
    BATCH,
    Contexts,
    authenticated_oversize_envelope,
    error_code,
)

pytest_plugins = ("tests.contract.delivery_v1_fixtures",)


@pytest.mark.parametrize(
    "alternate",
    [
        BATCH.replace(b',"export_window"', b', "export_window"', 1),
        BATCH.replace(
            b'"schema_id":"health_bridge.batch.v1","schema_version":"1.0.0"',
            b'"schema_version":"1.0.0","schema_id":"health_bridge.batch.v1"',
        ),
        BATCH.replace(b"Synthetic Phone", b"Synthetic\\u0020Phone"),
        BATCH.replace(b'"value":1.25', b'"value":1.2500'),
        BATCH.replace(b'"value":1.25', b'"value":125e-2'),
    ],
)
def test_receiver_accepts_alternate_valid_json_without_reserialization(
    contexts: Contexts, alternate: bytes
) -> None:
    # Given
    seal, opening, _, _ = contexts
    envelope = delivery.create_delivery_envelope(alternate, seal)
    # When
    opened = delivery.open_delivery_envelope(envelope.to_bytes(), opening)
    # Then
    assert opened.plaintext == alternate


@pytest.mark.parametrize(
    ("payload", "code"),
    [
        (b"\xff", "payload_invalid"),
        (b'{"schema_id":', "payload_invalid"),
        (BATCH + b" trailing", "payload_invalid"),
        (
            BATCH.replace(
                b'{"deleted_records":[]',
                b'{"schema_id":"health_bridge.batch.v1","deleted_records":[]',
            ),
            "payload_invalid",
        ),
        (
            BATCH.replace(
                b'{"end_time":"2026-06-09T00:00:00Z","start_time"',
                b'{"end_time":"2026-06-09T00:00:00Z","end_time":"2026-06-09T00:00:00Z","start_time"',
                1,
            ),
            "payload_invalid",
        ),
        (
            BATCH.replace(
                b'{"client_record_id":"synthetic-sample-1"',
                b'{"unit":"count","client_record_id":"synthetic-sample-1"',
                1,
            ),
            "payload_invalid",
        ),
        (BATCH.replace(b'"value":1.25', b'"value":NaN'), "payload_invalid"),
        (BATCH.replace(b'"value":1.25', b'"value":Infinity'), "payload_invalid"),
        (BATCH.replace(b'"value":1.25', b'"value":-Infinity'), "payload_invalid"),
        (
            BATCH.replace(b'"schema_version":"1.0.0"', b'"schema_version":"2.0.0"'),
            "payload_invalid",
        ),
    ],
    ids=[
        "invalid-utf8",
        "malformed",
        "trailing",
        "duplicate-root",
        "duplicate-nested",
        "duplicate-array-object",
        "nan",
        "infinity",
        "negative-infinity",
        "strict-batch-schema",
    ],
)
def test_receiver_framing_maps_each_invalid_payload_to_closed_error(
    contexts: Contexts, payload: bytes, code: str
) -> None:
    # Given
    seal, opening, _, _ = contexts
    envelope = delivery.create_delivery_envelope(payload, seal)
    # When / Then
    with pytest.raises(delivery.DeliveryProtocolError) as exc:
        _ = delivery.open_delivery_envelope(envelope.to_bytes(), opening)
    assert error_code(exc) == code


def test_sender_rejects_payload_over_plaintext_limit(
    contexts: Contexts,
) -> None:
    # Given
    seal, _, _, _ = contexts
    # When / Then
    with pytest.raises(delivery.DeliveryProtocolError) as exc:
        _ = delivery.create_delivery_envelope(b" " * 1_048_577, seal)
    assert error_code(exc) == "payload_oversize"


def test_receiver_rejects_authenticated_payload_over_plaintext_limit(
    contexts: Contexts,
) -> None:
    # Given
    _, opening, _, _ = contexts
    envelope = authenticated_oversize_envelope(b" " * 1_048_577)
    # When / Then
    with pytest.raises(delivery.DeliveryProtocolError) as exc:
        _ = delivery.open_delivery_envelope(envelope, opening)
    assert error_code(exc) == "payload_oversize"
