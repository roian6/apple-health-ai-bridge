import pytest

from health_bridge.contract import delivery_v1 as delivery
from tests.contract.delivery_v1_support import (
    BATCH,
    Contexts,
    error_code,
    receipt,
)

pytest_plugins = ("tests.contract.delivery_v1_fixtures",)


@pytest.mark.parametrize(
    "principal", ["", "space forbidden", "a" * 129, "snowman-\u2603"]
)
def test_device_principal_rejects_invalid_pattern_or_length(
    principal: str,
) -> None:
    # Given / When / Then
    with pytest.raises(delivery.DeliveryProtocolError):
        _ = delivery.DevicePrincipal(principal)


@pytest.mark.parametrize("binding", [bytes(31), bytes(33)])
def test_opaque_binding_requires_exactly_32_bytes(
    binding: bytes,
) -> None:
    # Given / When / Then
    with pytest.raises(delivery.DeliveryProtocolError):
        _ = delivery.OpaqueBinding(binding)


def test_delivery_and_ack_cannot_be_opened_in_wrong_direction(
    contexts: Contexts,
) -> None:
    # Given
    seal, _, _, ack_open = contexts
    envelope = delivery.create_delivery_envelope(BATCH, seal)
    # When / Then
    with pytest.raises(delivery.DeliveryProtocolError) as exc:
        _ = delivery.open_delivery_ack(envelope.to_bytes(), ack_open)
    assert error_code(exc) == "authentication_failed"


def test_ack_cannot_be_opened_as_delivery(
    contexts: Contexts,
) -> None:
    # Given
    _, opening, ack_seal, _ = contexts
    ack = delivery.create_delivery_ack(receipt(), ack_seal)
    # When / Then
    with pytest.raises(delivery.DeliveryProtocolError) as exc:
        _ = delivery.open_delivery_envelope(ack.to_bytes(), opening)
    assert error_code(exc) == "authentication_failed"
