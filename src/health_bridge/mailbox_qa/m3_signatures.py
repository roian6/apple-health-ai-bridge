from __future__ import annotations

import base64
import binascii
import hashlib

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from health_bridge.contract._hbjcs1 import HBJCS1Error, JsonValue, hbjcs1_encode
from health_bridge.mailbox_qa.m3_errors import M3FailureCode, M3ValidationError


def short_fingerprint(domain: bytes, value: str) -> str:
    material = domain + b"\0" + value.encode("utf-8")
    return hashlib.sha256(material).digest()[:8].hex()


def verify_signature(
    document: dict[str, JsonValue],
    signature_text: str,
    public_key_text: str,
    domain: bytes,
) -> None:
    unsigned = dict(document)
    del unsigned["signature"]
    try:
        signature = base64.urlsafe_b64decode(signature_text + "==")
        public_key = base64.urlsafe_b64decode(public_key_text + "=")
        Ed25519PublicKey.from_public_bytes(public_key).verify(
            signature,
            domain + b"\0" + hbjcs1_encode(unsigned),
        )
    except (ValueError, binascii.Error, InvalidSignature, HBJCS1Error) as exc:
        raise M3ValidationError(M3FailureCode.SIGNATURE_INVALID) from exc


__all__ = ["short_fingerprint", "verify_signature"]
