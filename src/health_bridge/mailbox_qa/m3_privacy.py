from __future__ import annotations

from typing import TYPE_CHECKING, Final

if TYPE_CHECKING:
    from health_bridge.contract._hbjcs1 import JsonValue

FORBIDDEN_IDENTIFIER_KEYS: Final = frozenset(
    {
        "receiver_id",
        "device_id",
        "device_signing_key_id",
        "device_agreement_key_id",
        "receiver_signing_key_id",
        "receiver_agreement_key_id",
        "sender_signing_key_id",
        "sender_agreement_key_id",
    }
)
FORBIDDEN_FRAGMENTS: Final = (
    "token",
    "secret",
    "payload",
    "envelope",
    "ack_bytes",
    "digest",
    "public_key",
    "database",
    "cursor",
    "outbox_path",
    "pairing_url",
    "setup_page",
)
SAFE_ATTESTATION_KEYS: Final = frozenset(
    {
        "envelope_sha256",
        "envelope_reuse_count",
        "synthetic_payload_sha256",
    }
)


class M3ForbiddenIdentifierError(Exception):
    pass


class M3ForbiddenDataError(Exception):
    pass


def scan_evidence_privacy(
    value: JsonValue,
    *,
    full_identifiers: frozenset[str],
) -> None:
    match value:
        case dict() as mapping:
            for key, child in mapping.items():
                if key in FORBIDDEN_IDENTIFIER_KEYS:
                    raise M3ForbiddenIdentifierError
                if key not in SAFE_ATTESTATION_KEYS and any(
                    fragment in key for fragment in FORBIDDEN_FRAGMENTS
                ):
                    raise M3ForbiddenDataError
                scan_evidence_privacy(child, full_identifiers=full_identifiers)
        case list() as items:
            for child in items:
                scan_evidence_privacy(child, full_identifiers=full_identifiers)
        case str() as scalar:
            if scalar in full_identifiers:
                raise M3ForbiddenIdentifierError
        case bool() | int() | float() | bytes() | None:
            return


def scan_parent_receipt_privacy(
    content: bytes,
    *,
    full_identifiers: frozenset[str],
) -> None:
    if any(identifier.encode() in content for identifier in full_identifiers):
        raise M3ForbiddenIdentifierError
