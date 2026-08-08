import sys
from pathlib import Path
from typing import Final

import typer

from health_bridge.contract._delivery_ack import (
    create_delivery_ack,
    open_delivery_ack,
)
from health_bridge.contract._delivery_common import (
    ACK_AAD_DOMAIN,
    ACK_ID_DOMAIN,
    ACK_KEY_DOMAIN,
    ACK_NONCE_DOMAIN,
    ACK_SALT_DOMAIN,
    ACK_SIGNATURE_DOMAIN,
    DELIVERY_AAD_DOMAIN,
    DELIVERY_KEY_DOMAIN,
    DELIVERY_SALT_DOMAIN,
    DELIVERY_SIGNATURE_DOMAIN,
    DeliveryProtocolError,
    key_id,
)
from health_bridge.contract._delivery_envelope import (
    create_delivery_envelope,
    open_delivery_envelope,
)
from health_bridge.contract._delivery_models import (
    AckOpenParams,
    AckSealParams,
    DeliveryAckV1,
    DeliveryCreateParams,
    DeliveryEnvelopeV1,
    DeliveryOpenParams,
    DeliveryReceiptV1,
    DevicePrincipal,
    OpaqueBinding,
    OpenedDeliveryV1,
)
from health_bridge.contract._delivery_self_test import run_self_test
from health_bridge.contract._hbjcs1 import HBJCS1Error, hbjcs1_decode, hbjcs1_encode

_SELF_TEST_ARGC: Final = 3

__all__ = [
    "ACK_AAD_DOMAIN",
    "ACK_ID_DOMAIN",
    "ACK_KEY_DOMAIN",
    "ACK_NONCE_DOMAIN",
    "ACK_SALT_DOMAIN",
    "ACK_SIGNATURE_DOMAIN",
    "DELIVERY_AAD_DOMAIN",
    "DELIVERY_KEY_DOMAIN",
    "DELIVERY_SALT_DOMAIN",
    "DELIVERY_SIGNATURE_DOMAIN",
    "AckOpenParams",
    "AckSealParams",
    "DeliveryAckV1",
    "DeliveryCreateParams",
    "DeliveryEnvelopeV1",
    "DeliveryOpenParams",
    "DeliveryProtocolError",
    "DeliveryReceiptV1",
    "DevicePrincipal",
    "HBJCS1Error",
    "OpaqueBinding",
    "OpenedDeliveryV1",
    "create_delivery_ack",
    "create_delivery_envelope",
    "hbjcs1_decode",
    "hbjcs1_encode",
    "key_id",
    "open_delivery_ack",
    "open_delivery_envelope",
]


def _main() -> int:
    if len(sys.argv) != _SELF_TEST_ARGC or sys.argv[1] != "--self-test":
        typer.echo("payload_invalid")
        return 2
    try:
        counts = run_self_test(Path(sys.argv[2]))
    except DeliveryProtocolError as exc:
        typer.echo(exc.code)
        return 2
    typer.echo(counts.to_bytes().decode("ascii"))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
