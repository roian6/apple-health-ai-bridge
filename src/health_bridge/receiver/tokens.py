import hashlib
import hmac
import secrets
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Final, TypeAlias

from pydantic import TypeAdapter

from health_bridge.storage.database import connect_database, initialize_database

TOKEN_PREFIX: Final = "hb_"  # noqa: S105 - public token prefix, not a secret.
TOKEN_PREFIX_LENGTH: Final = 11
HASH_LOOKUP_PREFIX_LENGTH: Final = 16
HASH_LOOKUP_PREFIX_MARKER: Final = "sha256:"
GENERATED_TOKEN_BYTES: Final = 32


def _sql(*parts: str) -> str:
    return " ".join(parts)


INSERT_RECEIVER_TOKEN_SQL: Final = _sql(
    "insert into receiver_tokens",
    "(token_label, token_prefix, token_hash)",
    "values (?, ?, ?)",
)
SELECT_ACTIVE_TOKEN_PRINCIPALS_SQL: Final = _sql(
    "select token.token_hash, mapping.receiver_device_id, device.installation_id_hash",
    "from receiver_tokens token",
    "left join receiver_token_devices mapping",
    "on mapping.receiver_token_id = token.receiver_token_id",
    "left join receiver_devices device",
    "on device.receiver_device_id = mapping.receiver_device_id",
    "and device.revoked_at is null",
    "where token.token_prefix in (?, ?) and token.revoked_at is null",
)
MARK_TOKEN_USED_SQL: Final = _sql(
    "update receiver_tokens",
    "set last_used_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')",
    "where token_hash = ? and revoked_at is null",
)
REVOKE_TOKEN_SQL: Final = _sql(
    "update receiver_tokens",
    "set revoked_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')",
    "where token_prefix = ? and revoked_at is null",
)
TokenPrincipalRow: TypeAlias = tuple[str, int | None, str | None]
TOKEN_PRINCIPAL_ROWS_ADAPTER: Final[TypeAdapter[list[TokenPrincipalRow]]] = TypeAdapter(
    list[TokenPrincipalRow],
)


@dataclass(frozen=True)
class IssuedReceiverToken:
    token_id: int
    label: str
    token: str
    token_prefix: str


@dataclass(frozen=True)
class ReceiverTokenPrincipal:
    installation_id_hash: str | None

    @property
    def is_device_bound(self) -> bool:
        return self.installation_id_hash is not None


def create_receiver_token(
    db_path: Path,
    label: str,
    token: str | None = None,
) -> IssuedReceiverToken:
    initialize_database(db_path)
    with connect_database(db_path) as connection:
        return create_receiver_token_in_connection(
            connection,
            label=label,
            token=token,
        )


def create_receiver_token_in_connection(
    connection: sqlite3.Connection,
    *,
    label: str,
    token: str | None = None,
    hash_derived_prefix: bool = False,
) -> IssuedReceiverToken:
    """Issue a receiver token inside the caller's existing transaction."""
    receiver_token = token if token is not None else _generate_token()
    token_hash = hash_receiver_token(receiver_token)
    token_prefix = (
        _hash_lookup_prefix(token_hash)
        if hash_derived_prefix
        else _token_prefix(receiver_token)
    )
    cursor = connection.execute(
        INSERT_RECEIVER_TOKEN_SQL,
        (label, token_prefix, token_hash),
    )
    token_id = cursor.lastrowid
    if token_id is None:
        message = "Receiver token insert did not return a row id."
        raise sqlite3.IntegrityError(message)
    return IssuedReceiverToken(
        token_id=token_id,
        label=label,
        token=receiver_token,
        token_prefix=token_prefix,
    )


def authenticate_receiver_token(db_path: Path, token: str) -> bool:
    return authenticate_receiver_token_principal(db_path, token) is not None


def authenticate_receiver_token_principal(
    db_path: Path,
    token: str,
) -> ReceiverTokenPrincipal | None:
    initialize_database(db_path)
    token_hash = hash_receiver_token(token)
    legacy_token_prefix = _token_prefix(token)
    hash_lookup_prefix = _hash_lookup_prefix(token_hash)
    with connect_database(db_path) as connection:
        rows = TOKEN_PRINCIPAL_ROWS_ADAPTER.validate_python(
            connection.execute(
                SELECT_ACTIVE_TOKEN_PRINCIPALS_SQL,
                (legacy_token_prefix, hash_lookup_prefix),
            ).fetchall(),
        )
        for stored_hash, mapped_device_id, installation_id_hash in rows:
            if not hmac.compare_digest(stored_hash, token_hash):
                continue
            if mapped_device_id is not None and installation_id_hash is None:
                return None
            _ = connection.execute(MARK_TOKEN_USED_SQL, (token_hash,))
            return ReceiverTokenPrincipal(
                installation_id_hash=installation_id_hash,
            )
    return None


def revoke_receiver_token(db_path: Path, token_prefix: str) -> None:
    initialize_database(db_path)
    with connect_database(db_path) as connection:
        _ = connection.execute(
            REVOKE_TOKEN_SQL,
            (token_prefix,),
        )


def _generate_token() -> str:
    return f"{TOKEN_PREFIX}{secrets.token_urlsafe(GENERATED_TOKEN_BYTES)}"


def _token_prefix(token: str) -> str:
    return token[:TOKEN_PREFIX_LENGTH]


def _hash_lookup_prefix(token_hash: str) -> str:
    return f"{HASH_LOOKUP_PREFIX_MARKER}{token_hash[:HASH_LOOKUP_PREFIX_LENGTH]}"


def hash_receiver_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()
