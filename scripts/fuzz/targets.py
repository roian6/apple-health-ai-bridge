from typing import Final

from pydantic import ValidationError

from health_bridge.contract.batch_v1 import HealthBridgeBatchV1
from health_bridge.mcp.tools import DateRangeArgs

MAX_INPUT_BYTES: Final = 4096


def batch(data: bytes) -> bool:
    if len(data) > MAX_INPUT_BYTES:
        return False
    try:
        _ = HealthBridgeBatchV1.model_validate_json(data)
    except ValidationError:
        return False
    return True


def mcp_dates(data: bytes) -> bool:
    if len(data) > MAX_INPUT_BYTES:
        return False
    try:
        _ = DateRangeArgs.model_validate_json(data)
    except ValidationError:
        return False
    return True
