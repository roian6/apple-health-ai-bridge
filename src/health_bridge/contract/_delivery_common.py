from __future__ import annotations

import base64
import binascii
import hashlib
import re
from typing import TYPE_CHECKING, Final, Literal, Never, TypeAlias

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

if TYPE_CHECKING:
    from health_bridge.contract._hbjcs1 import JsonValue

DELIVERY_SALT_DOMAIN: Final = b"health-bridge/mailbox/v1/delivery/salt"
DELIVERY_KEY_DOMAIN: Final = b"health-bridge/mailbox/v1/delivery/key"
DELIVERY_AAD_DOMAIN: Final = b"health-bridge/mailbox/v1/delivery/aad"
DELIVERY_SIGNATURE_DOMAIN: Final = b"health-bridge/mailbox/v1/delivery/signature"
ACK_ID_DOMAIN: Final = b"health-bridge/mailbox/v1/ack/id"
ACK_SALT_DOMAIN: Final = b"health-bridge/mailbox/v1/ack/salt"
ACK_KEY_DOMAIN: Final = b"health-bridge/mailbox/v1/ack/key"
ACK_NONCE_DOMAIN: Final = b"health-bridge/mailbox/v1/ack/nonce"
ACK_AAD_DOMAIN: Final = b"health-bridge/mailbox/v1/ack/aad"
ACK_SIGNATURE_DOMAIN: Final = b"health-bridge/mailbox/v1/ack/signature"

MAX_ENVELOPE_BYTES: Final = 2_097_152
MAX_PAYLOAD_BYTES: Final = 1_048_576
MAX_ACK_BYTES: Final = 65_536
CONTENT_TYPE: Final = "application/vnd.health-bridge.batch-v1+json"

ProtocolErrorCode: TypeAlias = Literal[
    "authentication_failed", "payload_invalid", "payload_oversize"
]
Result: TypeAlias = Literal["committed", "retryable", "terminal"]
RetryableCode: TypeAlias = Literal[
    "receiver_busy", "storage_unavailable", "quota_exceeded", "internal_retry"
]
TerminalCode: TypeAlias = Literal[
    "payload_invalid",
    "payload_oversize",
    "duplicate_conflict",
    "principal_mismatch",
    "binding_mismatch",
    "generation_mismatch",
    "key_revoked",
]
ReceiptErrorCode: TypeAlias = RetryableCode | TerminalCode

RETRYABLE_CODES: Final = frozenset(
    {"receiver_busy", "storage_unavailable", "quota_exceeded", "internal_retry"}
)
TERMINAL_CODES: Final = frozenset(
    {
        "payload_invalid",
        "payload_oversize",
        "duplicate_conflict",
        "principal_mismatch",
        "binding_mismatch",
        "generation_mismatch",
        "key_revoked",
    }
)
_HEX_16_PATTERN: Final = re.compile(r"^[0-9a-f]{32}$")
_SHA256_PATTERN: Final = re.compile(r"^[0-9a-f]{64}$")
_B64_PATTERN: Final = re.compile(r"^[A-Za-z0-9_-]*$")
_RAW_PUBLIC_KEY_BYTES: Final = 32


class DeliveryProtocolError(Exception):
    """A closed, redacted delivery protocol failure."""

    code: ProtocolErrorCode

    def __init__(self, code: ProtocolErrorCode) -> None:
        self.code = code
        super().__init__(code)


def fail(code: ProtocolErrorCode) -> Never:
    raise DeliveryProtocolError(code=code)


def b64encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def b64decode(value: str, *, length: int | None = None) -> bytes:
    if _B64_PATTERN.fullmatch(value) is None or "=" in value:
        fail("authentication_failed")
    try:
        decoded = base64.b64decode(
            value + "=" * (-len(value) % 4), altchars=b"-_", validate=True
        )
    except (ValueError, binascii.Error):
        fail("authentication_failed")
    if b64encode(decoded) != value or (length is not None and len(decoded) != length):
        fail("authentication_failed")
    return decoded


def raw_id(value: str) -> bytes:
    if _HEX_16_PATTERN.fullmatch(value) is None:
        fail("authentication_failed")
    return bytes.fromhex(value)


def require_sha256(value: str) -> None:
    if _SHA256_PATTERN.fullmatch(value) is None:
        fail("authentication_failed")


def key_id(algorithm: str, raw_public_key: bytes) -> str:
    if (
        algorithm not in {"ed25519", "x25519"}
        or len(raw_public_key) != _RAW_PUBLIC_KEY_BYTES
    ):
        fail("authentication_failed")
    return (
        hashlib.sha256(algorithm.encode("ascii") + b"\0" + raw_public_key)
        .digest()[:16]
        .hex()
    )


def derive_key(shared: bytes, salt: bytes, info: bytes) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(
        shared
    )


def derive_nonce(shared: bytes, salt: bytes, info: bytes) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=12, salt=salt, info=info).derive(
        shared
    )


def require_i64(value: int) -> None:
    if isinstance(value, bool) or not -(2**63) <= value <= 2**63 - 1:
        fail("authentication_failed")


def require_nonnegative_i64(value: int) -> None:
    if isinstance(value, bool) or not 0 <= value <= 2**63 - 1:
        fail("authentication_failed")


def require_object(value: JsonValue, fields: frozenset[str]) -> dict[str, JsonValue]:
    if not isinstance(value, dict):
        fail("authentication_failed")
    if frozenset(value) != fields:
        fail("authentication_failed")
    return value


def require_string(mapping: dict[str, JsonValue], name: str) -> str:
    value = mapping[name]
    if isinstance(value, str):
        return value
    fail("authentication_failed")


def require_integer(mapping: dict[str, JsonValue], name: str) -> int:
    value = mapping[name]
    if isinstance(value, bool):
        fail("authentication_failed")
    if isinstance(value, int):
        return value
    fail("authentication_failed")
