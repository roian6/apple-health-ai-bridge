from __future__ import annotations

import base64
from typing import Annotated, ClassVar, Final, Self

from pydantic import BaseModel, ConfigDict, StringConstraints, model_validator

Base64URL32 = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{43}$")]
DeviceCredential = Annotated[
    str,
    StringConstraints(pattern=r"^hb_[A-Za-z0-9_-]{43}$"),
]
Hex32 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{32}$")]
MAX_NAMESPACE_LENGTH: Final = 64
KEY_BYTES: Final = 32


class QAPairingRedeemRequest(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )

    invitation_secret: str
    device_credential: DeviceCredential
    installation_id: str
    device_signing_public_key: Base64URL32
    device_agreement_public_key: Base64URL32
    namespace: str
    run_id: Hex32
    challenge: Base64URL32

    @model_validator(mode="after")
    def isolated_namespace(self) -> Self:
        if (
            not self.namespace.startswith("qa-")
            or len(self.namespace) > MAX_NAMESPACE_LENGTH
        ):
            raise ValueError
        return self


def base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def decode32(value: str) -> bytes:
    decoded = base64.urlsafe_b64decode(value + "=")
    if len(decoded) != KEY_BYTES:
        raise ValueError
    return decoded


__all__ = ["QAPairingRedeemRequest", "base64url", "decode32"]
