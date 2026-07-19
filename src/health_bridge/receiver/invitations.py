import hashlib
import hmac
import secrets
import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Final, TypeAlias
from urllib.parse import urlparse, urlunparse
from uuid import UUID, uuid4

from pydantic import TypeAdapter

from health_bridge.receiver.tokens import (
    create_receiver_token_in_connection,
    hash_receiver_token,
)
from health_bridge.storage.database import connect_database, initialize_database

INVITATION_CODE_ALPHABET: Final = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
INVITATION_CODE_SELECTOR_LENGTH: Final = 5
INVITATION_CODE_SECRET_LENGTH: Final = 10
INVITATION_CODE_LENGTH: Final = (
    INVITATION_CODE_SELECTOR_LENGTH + INVITATION_CODE_SECRET_LENGTH
)
INVITATION_DEFAULT_TTL: Final = timedelta(minutes=20)
INVITATION_MIN_TTL: Final = timedelta(minutes=10)
INVITATION_MAX_TTL: Final = timedelta(minutes=30)
INVITATION_MAX_FAILED_ATTEMPTS: Final = 5
INSTALLATION_UUID_VERSION: Final = 4
DEVICE_CREDENTIAL_MIN_SUFFIX_LENGTH: Final = 43
DEVICE_CREDENTIAL_MAX_LENGTH: Final = 256
DEVICE_REF_LENGTH: Final = 12
INVITATION_SECRET_PREFIX: Final = "hbi_"  # noqa: S105 - public prefix, not a secret.
INVITATION_SECRET_BYTES: Final = 32
CODE_SALT_BYTES: Final = 16
CODE_SCRYPT_N: Final = 1 << 14
CODE_SCRYPT_R: Final = 8
CODE_SCRYPT_P: Final = 1
CODE_SCRYPT_DKLEN: Final = 32
CODE_SCRYPT_MAXMEM: Final = 64 * 1024 * 1024
DUMMY_CODE_SALT: Final = bytes.fromhex("00" * CODE_SALT_BYTES)
GENERIC_INVITATION_ERROR: Final = "Pairing invitation is invalid or unavailable."
GENERIC_DEVICE_SELECTION_ERROR: Final = "Device reference is invalid or unavailable."

InvitationLookupRow: TypeAlias = tuple[
    str,
    str,
    str,
    str,
    str,
    int,
    int,
    str,
    str | None,
    str | None,
]
InvitationResultRow: TypeAlias = tuple[str, str]
DeviceIDRow: TypeAlias = tuple[int]
ReceiverDeviceRow: TypeAlias = tuple[str, str, str, str, str | None]
INVITATION_LOOKUP_ROW_ADAPTER: Final[TypeAdapter[InvitationLookupRow | None]] = (
    TypeAdapter(InvitationLookupRow | None)
)
INVITATION_RESULT_ROW_ADAPTER: Final[TypeAdapter[InvitationResultRow | None]] = (
    TypeAdapter(InvitationResultRow | None)
)
DEVICE_ID_ROW_ADAPTER: Final[TypeAdapter[DeviceIDRow | None]] = TypeAdapter(
    DeviceIDRow | None
)
DEVICE_ID_ROWS_ADAPTER: Final[TypeAdapter[list[DeviceIDRow]]] = TypeAdapter(
    list[DeviceIDRow]
)
RECEIVER_DEVICE_ROWS_ADAPTER: Final[TypeAdapter[list[ReceiverDeviceRow]]] = TypeAdapter(
    list[ReceiverDeviceRow]
)


def _sql(*parts: str) -> str:
    return " ".join(parts)


LOOKUP_BY_SECRET_SQL: Final = _sql(
    "select pairing_invitation_id, invitation_label, receiver_url,",
    "invitation_code_hash, invitation_code_salt,",
    "failed_attempt_count, max_failed_attempts, expires_at, redeemed_at, revoked_at",
    "from pairing_invitations where invitation_secret_hash = ?",
)
LOOKUP_BY_CODE_SELECTOR_SQL: Final = _sql(
    "select pairing_invitation_id, invitation_label, receiver_url,",
    "invitation_code_hash, invitation_code_salt,",
    "failed_attempt_count, max_failed_attempts, expires_at, redeemed_at, revoked_at",
    "from pairing_invitations where invitation_code_selector = ?",
)
RECORD_FAILED_CODE_ATTEMPT_SQL: Final = _sql(
    "update pairing_invitations",
    "set failed_attempt_count = failed_attempt_count + 1, last_failed_at = ?",
    "where pairing_invitation_id = ? and redeemed_at is null",
    "and revoked_at is null and expires_at > ?",
    "and failed_attempt_count < max_failed_attempts",
)
CONSUME_INVITATION_SQL: Final = _sql(
    "update pairing_invitations set redeemed_at = ?",
    "where pairing_invitation_id = ? and redeemed_at is null",
    "and revoked_at is null and expires_at > ?",
    "and failed_attempt_count < max_failed_attempts",
    "returning invitation_label, receiver_url",
)
IDEMPOTENT_REDEMPTION_SQL: Final = _sql(
    "select invitation.invitation_label, invitation.receiver_url",
    "from pairing_invitation_redemptions redemption",
    "join pairing_invitations invitation",
    "on invitation.pairing_invitation_id = redemption.pairing_invitation_id",
    "join receiver_devices device",
    "on device.receiver_device_id = redemption.receiver_device_id",
    "join receiver_tokens token",
    "on token.receiver_token_id = redemption.receiver_token_id",
    "where redemption.pairing_invitation_id = ?",
    "and device.installation_id_hash = ? and token.token_hash = ?",
    "and device.revoked_at is null and token.revoked_at is null",
)


class PairingInvitationError(ValueError):
    pass


class ReceiverDeviceSelectionError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class ReceiverDeviceSummary:
    device_ref: str
    label: str
    platform: str
    last_paired_at: str
    revoked_at: str | None


@dataclass(frozen=True, slots=True)
class IssuedPairingInvitation:
    invitation_id: str
    label: str
    receiver_url: str
    redeem_url: str
    invitation_secret: str
    invitation_code: str
    created_at: str
    expires_at: str


@dataclass(frozen=True, slots=True)
class PairingRedemptionCompletion:
    label: str
    receiver_url: str


def create_pairing_invitation(  # noqa: PLR0913 - test hooks allow deterministic credentials and time.
    db_path: Path,
    *,
    label: str,
    receiver_url: str,
    now: datetime | None = None,
    expires_in: timedelta = INVITATION_DEFAULT_TTL,
    invitation_secret: str | None = None,
    invitation_code: str | None = None,
) -> IssuedPairingInvitation:
    normalized_url = _validate_receiver_url(receiver_url)
    issued_at = _normalized_now(now)
    if not INVITATION_MIN_TTL <= expires_in <= INVITATION_MAX_TTL:
        message = "Pairing invitation expiry must be between 10 and 30 minutes."
        raise PairingInvitationError(message)
    expires_at = issued_at + expires_in
    secret = (
        _generate_invitation_secret()
        if invitation_secret is None
        else _normalize_secret(invitation_secret)
    )
    generated_code = invitation_code is None
    invitation_id = str(uuid4())
    issued_at_text = _format_utc(issued_at)
    expires_at_text = _format_utc(expires_at)

    initialize_database(db_path)
    for _attempt in range(8 if generated_code else 1):
        code = (
            _generate_invitation_code()
            if generated_code
            else _format_invitation_code(invitation_code or "")
        )
        normalized_code = _normalize_code(code)
        code_selector, code_secret = _split_code(normalized_code)
        code_salt = secrets.token_bytes(CODE_SALT_BYTES)
        try:
            with connect_database(db_path) as connection:
                _ = connection.execute("begin immediate")
                _ = connection.execute(
                    _sql(
                        "update pairing_invitations set revoked_at = ?",
                        "where invitation_label = ? and redeemed_at is null",
                        "and revoked_at is null and expires_at > ?",
                    ),
                    (issued_at_text, label, issued_at_text),
                )
                _ = connection.execute(
                    _sql(
                        "insert into pairing_invitations",
                        "(pairing_invitation_id, invitation_label, receiver_url,",
                        "invitation_secret_hash, invitation_code_selector,",
                        "invitation_code_hash, invitation_code_salt,",
                        "created_at, expires_at, max_failed_attempts)",
                        "values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    ),
                    (
                        invitation_id,
                        label,
                        normalized_url,
                        _hash_invitation_secret(secret),
                        code_selector,
                        _hash_code_secret(code_selector, code_secret, code_salt),
                        code_salt.hex(),
                        issued_at_text,
                        expires_at_text,
                        INVITATION_MAX_FAILED_ATTEMPTS,
                    ),
                )
        except sqlite3.IntegrityError:
            if not generated_code or not _code_selector_exists(db_path, code_selector):
                raise
            continue

        return IssuedPairingInvitation(
            invitation_id=invitation_id,
            label=label,
            receiver_url=normalized_url,
            redeem_url=_redeem_url(normalized_url),
            invitation_secret=secret,
            invitation_code=code,
            created_at=issued_at_text,
            expires_at=expires_at_text,
        )

    message = "Could not allocate a unique pairing code. Create a new invitation."
    raise PairingInvitationError(message)


def redeem_pairing_invitation(  # noqa: PLR0913 - explicit wire fields are security boundaries.
    db_path: Path,
    *,
    installation_id: str,
    device_credential: str,
    platform: str,
    invitation_secret: str | None = None,
    invitation_code: str | None = None,
    now: datetime | None = None,
) -> PairingRedemptionCompletion:
    if (invitation_secret is None) == (invitation_code is None):
        message = "Provide exactly one pairing invitation credential."
        raise PairingInvitationError(message)
    normalized_installation_id = _normalize_installation_id(installation_id)
    normalized_device_credential = _normalize_device_credential(device_credential)
    normalized_platform = _normalize_platform(platform)
    installation_id_hash = _hash_installation_id(normalized_installation_id)
    device_credential_hash = hash_receiver_token(normalized_device_credential)
    timestamp = _format_utc(_normalized_now(now))

    initialize_database(db_path)
    with connect_database(db_path) as connection:
        _ = connection.execute("begin immediate")
        if invitation_secret is not None:
            lookup = INVITATION_LOOKUP_ROW_ADAPTER.validate_python(
                connection.execute(
                    LOOKUP_BY_SECRET_SQL,
                    (_hash_invitation_secret(_normalize_secret(invitation_secret)),),
                ).fetchone()
            )
        else:
            normalized_code = _normalize_code(invitation_code or "")
            code_selector, code_secret = _split_code(normalized_code)
            lookup = INVITATION_LOOKUP_ROW_ADAPTER.validate_python(
                connection.execute(
                    LOOKUP_BY_CODE_SELECTOR_SQL,
                    (code_selector,),
                ).fetchone()
            )
            if lookup is None:
                _ = _hash_code_secret(code_selector, code_secret, DUMMY_CODE_SALT)
                connection.commit()
                raise PairingInvitationError(GENERIC_INVITATION_ERROR)
            candidate_hash = _hash_code_secret(
                code_selector,
                code_secret,
                bytes.fromhex(lookup[4]),
            )
            if not hmac.compare_digest(candidate_hash, lookup[3]):
                _ = connection.execute(
                    RECORD_FAILED_CODE_ATTEMPT_SQL,
                    (timestamp, lookup[0], timestamp),
                )
                connection.commit()
                raise PairingInvitationError(GENERIC_INVITATION_ERROR)

        if lookup is None:
            connection.commit()
            raise PairingInvitationError(GENERIC_INVITATION_ERROR)

        (
            invitation_id,
            invitation_label,
            _receiver_url,
            _stored_code_hash,
            _stored_code_salt,
            failed_attempt_count,
            max_failed_attempts,
            expires_at,
            redeemed_at,
            revoked_at,
        ) = lookup
        if redeemed_at is not None:
            completion = INVITATION_RESULT_ROW_ADAPTER.validate_python(
                connection.execute(
                    IDEMPOTENT_REDEMPTION_SQL,
                    (invitation_id, installation_id_hash, device_credential_hash),
                ).fetchone()
            )
            connection.commit()
            if completion is None:
                raise PairingInvitationError(GENERIC_INVITATION_ERROR)
            return PairingRedemptionCompletion(
                label=completion[0],
                receiver_url=completion[1],
            )

        if (
            revoked_at is not None
            or expires_at <= timestamp
            or failed_attempt_count >= max_failed_attempts
        ):
            connection.commit()
            raise PairingInvitationError(GENERIC_INVITATION_ERROR)

        completion = INVITATION_RESULT_ROW_ADAPTER.validate_python(
            connection.execute(
                CONSUME_INVITATION_SQL,
                (timestamp, invitation_id, timestamp),
            ).fetchone()
        )
        if completion is None:
            connection.commit()
            raise PairingInvitationError(GENERIC_INVITATION_ERROR)

        device_id = _upsert_receiver_device(
            connection,
            installation_id_hash=installation_id_hash,
            label=invitation_label,
            platform=normalized_platform,
            timestamp=timestamp,
        )
        _revoke_active_v2_tokens_for_device(connection, device_id, timestamp)
        issued = create_receiver_token_in_connection(
            connection,
            label=invitation_label,
            token=normalized_device_credential,
            hash_derived_prefix=True,
        )
        _ = connection.execute(
            """
            insert into receiver_token_devices
                (receiver_token_id, receiver_device_id, paired_at)
            values (?, ?, ?)
            """,
            (issued.token_id, device_id, timestamp),
        )
        _ = connection.execute(
            """
            insert into pairing_invitation_redemptions (
                pairing_invitation_id,
                receiver_device_id,
                receiver_token_id,
                redeemed_at
            )
            values (?, ?, ?, ?)
            """,
            (invitation_id, device_id, issued.token_id, timestamp),
        )
        return PairingRedemptionCompletion(
            label=completion[0],
            receiver_url=completion[1],
        )


def revoke_pairing_invitation(db_path: Path, invitation_id: str) -> None:
    initialize_database(db_path)
    timestamp = _format_utc(_normalized_now(None))
    with connect_database(db_path) as connection:
        _ = connection.execute(
            _sql(
                "update pairing_invitations set revoked_at = ?",
                "where pairing_invitation_id = ? and redeemed_at is null",
                "and revoked_at is null",
            ),
            (timestamp, invitation_id),
        )


def list_receiver_devices(
    db_path: Path,
    *,
    include_revoked: bool = False,
) -> list[ReceiverDeviceSummary]:
    initialize_database(db_path)
    where_clause = "" if include_revoked else "where revoked_at is null"
    with connect_database(db_path) as connection:
        rows = RECEIVER_DEVICE_ROWS_ADAPTER.validate_python(
            connection.execute(
                _sql(
                    "select substr(installation_id_hash, 1, ?), device_label,",
                    "platform, last_paired_at, revoked_at from receiver_devices",
                    where_clause,
                    "order by last_paired_at desc, receiver_device_id desc",
                ),
                (DEVICE_REF_LENGTH,),
            ).fetchall()
        )
    return [
        ReceiverDeviceSummary(
            device_ref=row[0],
            label=row[1],
            platform=row[2],
            last_paired_at=row[3],
            revoked_at=row[4],
        )
        for row in rows
    ]


def revoke_receiver_device(db_path: Path, device_ref: str) -> int:
    normalized_ref = device_ref.strip().lower()
    if len(normalized_ref) != DEVICE_REF_LENGTH or any(
        character not in "0123456789abcdef" for character in normalized_ref
    ):
        raise ReceiverDeviceSelectionError(GENERIC_DEVICE_SELECTION_ERROR)
    initialize_database(db_path)
    timestamp = _format_utc(_normalized_now(None))
    with connect_database(db_path) as connection:
        _ = connection.execute("begin immediate")
        rows = DEVICE_ID_ROWS_ADAPTER.validate_python(
            connection.execute(
                _sql(
                    "select receiver_device_id from receiver_devices",
                    "where substr(installation_id_hash, 1, ?) = ?",
                    "and revoked_at is null limit 2",
                ),
                (DEVICE_REF_LENGTH, normalized_ref),
            ).fetchall()
        )
        if len(rows) != 1:
            raise ReceiverDeviceSelectionError(GENERIC_DEVICE_SELECTION_ERROR)
        device_id = rows[0][0]
        token_cursor = connection.execute(
            _sql(
                "update receiver_tokens set revoked_at = ?",
                "where revoked_at is null and receiver_token_id in",
                "(select receiver_token_id from receiver_token_devices",
                "where receiver_device_id = ?)",
            ),
            (timestamp, device_id),
        )
        _ = connection.execute(
            _sql(
                "update receiver_devices set revoked_at = ?",
                "where receiver_device_id = ? and revoked_at is null",
            ),
            (timestamp, device_id),
        )
        return token_cursor.rowcount


def _code_selector_exists(db_path: Path, selector: str) -> bool:
    with connect_database(db_path) as connection:
        row = DEVICE_ID_ROW_ADAPTER.validate_python(
            connection.execute(
                "select 1 from pairing_invitations where invitation_code_selector = ?",
                (selector,),
            ).fetchone()
        )
    return row is not None


def _normalize_installation_id(value: str) -> str:
    try:
        parsed = UUID(value.strip())
    except ValueError as error:
        raise PairingInvitationError(GENERIC_INVITATION_ERROR) from error
    if parsed.version != INSTALLATION_UUID_VERSION:
        raise PairingInvitationError(GENERIC_INVITATION_ERROR)
    return str(parsed)


def _normalize_device_credential(value: str) -> str:
    normalized = value.strip()
    suffix = normalized.removeprefix("hb_")
    if (
        not normalized.startswith("hb_")
        or len(suffix) < DEVICE_CREDENTIAL_MIN_SUFFIX_LENGTH
        or len(normalized) > DEVICE_CREDENTIAL_MAX_LENGTH
        or any(
            not (character.isascii() and (character.isalnum() or character in "_-"))
            for character in normalized
        )
    ):
        raise PairingInvitationError(GENERIC_INVITATION_ERROR)
    return normalized


def _normalize_platform(value: str) -> str:
    normalized = value.strip().lower()
    if normalized != "ios":
        raise PairingInvitationError(GENERIC_INVITATION_ERROR)
    return normalized


def _hash_installation_id(value: str) -> str:
    material = f"health-bridge-pairing:installation:{value}".encode()
    return hashlib.sha256(material).hexdigest()


def _upsert_receiver_device(
    connection: sqlite3.Connection,
    *,
    installation_id_hash: str,
    label: str,
    platform: str,
    timestamp: str,
) -> int:
    row = DEVICE_ID_ROW_ADAPTER.validate_python(
        connection.execute(
            """
            insert into receiver_devices (
                installation_id_hash,
                device_label,
                platform,
                created_at,
                last_paired_at
            )
            values (?, ?, ?, ?, ?)
            on conflict(installation_id_hash) do update set
                device_label = excluded.device_label,
                platform = excluded.platform,
                last_paired_at = excluded.last_paired_at,
                revoked_at = null
            returning receiver_device_id
            """,
            (installation_id_hash, label, platform, timestamp, timestamp),
        ).fetchone()
    )
    if row is None:
        message = "Receiver device upsert did not return a row id."
        raise sqlite3.IntegrityError(message)
    return row[0]


def _revoke_active_v2_tokens_for_device(
    connection: sqlite3.Connection,
    device_id: int,
    timestamp: str,
) -> None:
    _ = connection.execute(
        """
        update receiver_tokens
        set revoked_at = ?
        where revoked_at is null
          and receiver_token_id in (
              select receiver_token_id
              from receiver_token_devices
              where receiver_device_id = ?
          )
        """,
        (timestamp, device_id),
    )


def _generate_invitation_secret() -> str:
    return f"{INVITATION_SECRET_PREFIX}{secrets.token_urlsafe(INVITATION_SECRET_BYTES)}"


def _generate_invitation_code() -> str:
    code = "".join(
        secrets.choice(INVITATION_CODE_ALPHABET) for _ in range(INVITATION_CODE_LENGTH)
    )
    return _format_normalized_code(code)


def _normalize_secret(value: str) -> str:
    normalized = value.strip()
    if not normalized:
        raise PairingInvitationError(GENERIC_INVITATION_ERROR)
    return normalized


def _normalize_code(value: str) -> str:
    normalized = "".join(
        character
        for character in value.upper()
        if not character.isspace() and character != "-"
    )
    if len(normalized) != INVITATION_CODE_LENGTH or any(
        character not in INVITATION_CODE_ALPHABET for character in normalized
    ):
        raise PairingInvitationError(GENERIC_INVITATION_ERROR)
    return normalized


def _format_invitation_code(value: str) -> str:
    return _format_normalized_code(_normalize_code(value))


def _format_normalized_code(value: str) -> str:
    return f"{value[:5]}-{value[5:10]}-{value[10:]}"


def _split_code(value: str) -> tuple[str, str]:
    return (
        value[:INVITATION_CODE_SELECTOR_LENGTH],
        value[INVITATION_CODE_SELECTOR_LENGTH:],
    )


def _hash_invitation_secret(value: str) -> str:
    return hashlib.sha256(f"health-bridge-pairing:secret:{value}".encode()).hexdigest()


def _hash_code_secret(selector: str, secret: str, salt: bytes) -> str:
    material = f"health-bridge-pairing:code:{selector}:{secret}".encode()
    return hashlib.scrypt(
        material,
        salt=salt,
        n=CODE_SCRYPT_N,
        r=CODE_SCRYPT_R,
        p=CODE_SCRYPT_P,
        maxmem=CODE_SCRYPT_MAXMEM,
        dklen=CODE_SCRYPT_DKLEN,
    ).hex()


def _validate_receiver_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        message = "Receiver URL must use http or https and include a host."
        raise PairingInvitationError(message)
    return value


def _redeem_url(receiver_url: str) -> str:
    parsed = urlparse(receiver_url)
    return urlunparse((parsed.scheme, parsed.netloc, "/v1/pairing/redeem", "", "", ""))


def _normalized_now(value: datetime | None) -> datetime:
    now = datetime.now(tz=UTC) if value is None else value
    if now.tzinfo is None:
        message = "Pairing invitation time must include a timezone."
        raise PairingInvitationError(message)
    return now.astimezone(UTC).replace(microsecond=0)


def _format_utc(value: datetime) -> str:
    return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
