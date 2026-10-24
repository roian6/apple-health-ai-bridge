import json

import pytest
from pydantic import ValidationError

from health_bridge.contract.receiver_capabilities import ReceiverCapabilitiesV1


@pytest.mark.parametrize(
    "payload",
    [
        "{}",
        '{"version":"1.2.0"}',
        '{"nutrition_supported":true}',
        """{"schema_id":"health_bridge.receiver_capabilities.v1",
        "batch_schema_id":"health_bridge.batch.v1"}""",
        """{"schema_id":"health_bridge.receiver_capabilities.v2",
        "batch_schema_id":"health_bridge.batch.v1","nutrition_supported":true}""",
        """{"schema_id":"health_bridge.receiver_capabilities.v1",
        "batch_schema_id":"health_bridge.batch.v2","nutrition_supported":true}""",
        "null",
        "[]",
        "not-json",
    ],
)
def test_missing_or_unknown_contract_is_not_support_evidence(payload: str) -> None:
    # Given / When / Then
    with pytest.raises(ValidationError):
        _ = ReceiverCapabilitiesV1.model_validate_json(payload)


@pytest.mark.parametrize("value", ['"true"', '"false"', "1", "0", "null", "[]", "{}"])
def test_nutrition_support_rejects_coercion(value: str) -> None:
    # Given
    payload = f"""{{
        "schema_id":"health_bridge.receiver_capabilities.v1",
        "batch_schema_id":"health_bridge.batch.v1",
        "nutrition_supported":{value}
    }}"""

    # When / Then
    with pytest.raises(ValidationError):
        _ = ReceiverCapabilitiesV1.model_validate_json(payload)


@pytest.mark.parametrize("supported", [False, True])
def test_explicit_support_preserves_boolean_and_ignores_future_fields(
    *, supported: bool
) -> None:
    # Given
    payload = json.dumps(
        {
            "schema_id": "health_bridge.receiver_capabilities.v1",
            "batch_schema_id": "health_bridge.batch.v1",
            "nutrition_supported": supported,
            "future_capability": True,
        }
    )

    # When
    capability = ReceiverCapabilitiesV1.model_validate_json(payload)

    # Then
    assert capability.nutrition_supported is supported
