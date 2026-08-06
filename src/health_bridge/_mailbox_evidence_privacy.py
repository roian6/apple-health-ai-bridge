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
_FORBIDDEN_KEY_FRAGMENTS: Final = (
    "payload",
    "digest",
    "public_key",
    "secret",
    "token",
    "health_data",
    "cursor",
    "outbox",
    "database",
    "locator",
    "path",
)


class ForbiddenDataError(Exception):
    pass


class ForbiddenIdentifierError(Exception):
    pass


def scan_report_privacy(
    value: JsonValue,
    *,
    full_identifiers: frozenset[str],
) -> None:
    match value:
        case dict() as mapping:
            for key, child in mapping.items():
                if key in FORBIDDEN_IDENTIFIER_KEYS or any(
                    fragment in key for fragment in _FORBIDDEN_KEY_FRAGMENTS
                ):
                    raise ForbiddenDataError
                scan_report_privacy(child, full_identifiers=full_identifiers)
        case list() as items:
            for child in items:
                scan_report_privacy(child, full_identifiers=full_identifiers)
        case str() as scalar:
            if scalar in full_identifiers:
                raise ForbiddenIdentifierError
        case bool() | int() | float() | bytes() | None:
            return
