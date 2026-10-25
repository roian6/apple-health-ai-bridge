"""Explicit Receiver support, independent of package or component versions."""

from typing import ClassVar, Final, Literal

from pydantic import BaseModel, ConfigDict


class ReceiverCapabilitiesV1(BaseModel):
    """Require explicit evidence; missing fields never imply nutrition support."""

    model_config: ClassVar[ConfigDict] = ConfigDict(
        frozen=True, strict=True, extra="ignore"
    )

    schema_id: Literal["health_bridge.receiver_capabilities.v1"]
    batch_schema_id: Literal["health_bridge.batch.v1"]
    nutrition_supported: bool


RECEIVER_CAPABILITIES: Final = ReceiverCapabilitiesV1(
    schema_id="health_bridge.receiver_capabilities.v1",
    batch_schema_id="health_bridge.batch.v1",
    nutrition_supported=True,
)
