from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from pathlib import Path
from sqlite3 import IntegrityError
from typing import Final, NoReturn, TypeAlias

import pytest
from pydantic import TypeAdapter

import health_bridge.receiver.invitations as invitation_module
from health_bridge.receiver.invitations import (
    PairingInvitationError,
    PairingRedemptionCompletion,
    ReceiverDeviceSelectionError,
    create_pairing_invitation,
    list_receiver_devices,
    revoke_pairing_invitation,
    revoke_receiver_device,
)
from health_bridge.receiver.invitations import (
    redeem_pairing_invitation as _redeem_pairing_invitation,
)
from health_bridge.receiver.tokens import (
    authenticate_receiver_token,
    hash_receiver_token,
)
from health_bridge.storage.database import connect_database

StoredInvitationRow: TypeAlias = tuple[str, str, str, str, str]
CountRow: TypeAlias = tuple[int]
AttemptRow: TypeAlias = tuple[int, int]
RedemptionStateRow: TypeAlias = tuple[str | None, str | None]
TokenPrefixRow: TypeAlias = tuple[str]
STORED_INVITATION_ROW_ADAPTER: Final[TypeAdapter[StoredInvitationRow | None]] = (
    TypeAdapter(StoredInvitationRow | None)
)
COUNT_ROW_ADAPTER: Final[TypeAdapter[CountRow | None]] = TypeAdapter(CountRow | None)
ATTEMPT_ROW_ADAPTER: Final[TypeAdapter[AttemptRow | None]] = TypeAdapter(
    AttemptRow | None
)
REDEMPTION_STATE_ROW_ADAPTER: Final[TypeAdapter[RedemptionStateRow | None]] = (
    TypeAdapter(RedemptionStateRow | None)
)
TOKEN_PREFIX_ROW_ADAPTER: Final[TypeAdapter[TokenPrefixRow | None]] = TypeAdapter(
    TokenPrefixRow | None
)
SYNTHETIC_INSTALLATION_ID: Final = "00000000-0000-4000-8000-000000000001"
SYNTHETIC_DEVICE_CREDENTIAL: Final = "hb_" + "a" * 64
SECOND_INSTALLATION_ID: Final = "00000000-0000-4000-8000-000000000002"
SECOND_DEVICE_CREDENTIAL: Final = "hb_" + "b" * 64
STORED_INVITATION_SQL: Final = """
select invitation_secret_hash, invitation_code_selector,
       invitation_code_hash, invitation_code_salt, expires_at
from pairing_invitations
"""
ATTEMPT_ROW_SQL: Final = """
select failed_attempt_count, max_failed_attempts
from pairing_invitations
"""


def redeem_pairing_invitation(  # noqa: PLR0913 - test wrapper mirrors production API.
    db_path: Path,
    *,
    invitation_secret: str | None = None,
    invitation_code: str | None = None,
    now: datetime | None = None,
    installation_id: str = SYNTHETIC_INSTALLATION_ID,
    device_credential: str = SYNTHETIC_DEVICE_CREDENTIAL,
) -> PairingRedemptionCompletion:
    return _redeem_pairing_invitation(
        db_path,
        invitation_secret=invitation_secret,
        invitation_code=invitation_code,
        now=now,
        installation_id=installation_id,
        device_credential=device_credential,
        platform="ios",
    )


def test_create_invitation_stores_only_hashes_and_expires_in_twenty_minutes(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    now = datetime(2026, 7, 12, 6, 0, tzinfo=UTC)

    invitation = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        now=now,
        invitation_secret="hbi_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )

    assert invitation.invitation_code == "ABCDE-FGHJK-MNPQR"
    assert invitation.expires_at == "2026-07-12T06:20:00Z"
    assert invitation.redeem_url == "https://health.example.test/v1/pairing/redeem"
    with connect_database(db_path) as connection:
        row = STORED_INVITATION_ROW_ADAPTER.validate_python(
            connection.execute(STORED_INVITATION_SQL).fetchone()
        )
    assert row is not None
    assert row[0] != invitation.invitation_secret
    assert row[1] == "ABCDE"
    assert row[2] != invitation.invitation_code
    assert len(row[2]) == 64
    assert len(row[3]) == 32
    assert invitation.invitation_secret not in row
    assert invitation.invitation_code not in row


def test_generated_invitation_uses_unambiguous_grouped_code_and_high_entropy_secret(
    tmp_path: Path,
) -> None:
    invitation = create_pairing_invitation(
        tmp_path / "receiver.sqlite",
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
    )

    unambiguous = set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    code = invitation.invitation_code.replace("-", "")
    assert len(code) == 15
    assert set(code) <= unambiguous
    assert invitation.invitation_code[5] == "-"
    assert invitation.invitation_code[11] == "-"
    assert invitation.invitation_secret.startswith("hbi_")
    assert len(invitation.invitation_secret) >= 46


def test_generated_manual_code_retries_selector_collision(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    _ = create_pairing_invitation(
        db_path,
        label="first-device",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_first_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )
    generated_codes = iter(("ABCDE-22222-22222", "RSTUV-WXYZ2-34567"))
    monkeypatch.setattr(
        invitation_module,
        "_generate_invitation_code",
        lambda: next(generated_codes),
    )

    invitation = create_pairing_invitation(
        db_path,
        label="second-device",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_second_synthetic_secret",
    )

    assert invitation.invitation_code == "RSTUV-WXYZ2-34567"


def test_redemption_stores_only_device_and_credential_hashes(tmp_path: Path) -> None:
    db_path = tmp_path / "receiver.sqlite"
    invitation = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )

    _ = redeem_pairing_invitation(
        db_path,
        invitation_secret=invitation.invitation_secret,
    )

    database_bytes = db_path.read_bytes()
    assert SYNTHETIC_INSTALLATION_ID.encode() not in database_bytes
    assert SYNTHETIC_DEVICE_CREDENTIAL.encode() not in database_bytes
    assert SYNTHETIC_DEVICE_CREDENTIAL[:11].encode() not in database_bytes
    with connect_database(db_path) as connection:
        token_prefix = TOKEN_PREFIX_ROW_ADAPTER.validate_python(
            connection.execute("select token_prefix from receiver_tokens").fetchone()
        )
        device_count = COUNT_ROW_ADAPTER.validate_python(
            connection.execute("select count(*) from receiver_devices").fetchone()
        )
        mapping_count = COUNT_ROW_ADAPTER.validate_python(
            connection.execute("select count(*) from receiver_token_devices").fetchone()
        )
        redemption_count = COUNT_ROW_ADAPTER.validate_python(
            connection.execute(
                "select count(*) from pairing_invitation_redemptions"
            ).fetchone()
        )
    expected_lookup_prefix = (
        f"sha256:{hash_receiver_token(SYNTHETIC_DEVICE_CREDENTIAL)[:16]}"
    )
    assert token_prefix == (expected_lookup_prefix,)
    assert device_count == (1,)
    assert mapping_count == (1,)
    assert redemption_count == (1,)


def test_creating_new_invitation_revokes_previous_active_invitation_for_label(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    first = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_first_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )

    _ = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_second_synthetic_secret",
        invitation_code="STUVW-XYZ23-45678",
    )

    with pytest.raises(PairingInvitationError):
        _ = redeem_pairing_invitation(
            db_path,
            invitation_secret=first.invitation_secret,
        )


def test_redeem_by_secret_registers_staged_device_token_idempotently(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    invitation = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )

    completion = redeem_pairing_invitation(
        db_path,
        invitation_secret=invitation.invitation_secret,
    )

    assert completion.label == "personal-iphone"
    assert completion.receiver_url == invitation.receiver_url
    assert authenticate_receiver_token(db_path, SYNTHETIC_DEVICE_CREDENTIAL)

    retry = redeem_pairing_invitation(
        db_path,
        invitation_secret=invitation.invitation_secret,
    )
    assert retry == completion

    with pytest.raises(PairingInvitationError):
        _ = redeem_pairing_invitation(
            db_path,
            invitation_secret=invitation.invitation_secret,
            installation_id=SECOND_INSTALLATION_ID,
            device_credential=SECOND_DEVICE_CREDENTIAL,
        )


def test_revoke_receiver_device_revokes_mapped_token_and_fails_closed(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    invitation = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )
    _ = redeem_pairing_invitation(
        db_path,
        invitation_secret=invitation.invitation_secret,
    )

    devices = list_receiver_devices(db_path)
    assert len(devices) == 1
    device = devices[0]
    assert device.label == "personal-iphone"
    assert len(device.device_ref) == 12
    assert SYNTHETIC_INSTALLATION_ID not in repr(device)

    revoked_token_count = revoke_receiver_device(db_path, device.device_ref)

    assert revoked_token_count == 1
    assert not authenticate_receiver_token(db_path, SYNTHETIC_DEVICE_CREDENTIAL)
    assert list_receiver_devices(db_path) == []
    revoked_devices = list_receiver_devices(db_path, include_revoked=True)
    assert len(revoked_devices) == 1
    assert revoked_devices[0].revoked_at is not None
    with pytest.raises(ReceiverDeviceSelectionError):
        _ = revoke_receiver_device(db_path, device.device_ref)


def test_revoke_receiver_device_rolls_back_token_revoke_on_device_failure(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    invitation = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )
    _ = redeem_pairing_invitation(
        db_path,
        invitation_secret=invitation.invitation_secret,
    )
    device_ref = list_receiver_devices(db_path)[0].device_ref
    with connect_database(db_path) as connection:
        _ = connection.execute(
            """
            create trigger fail_device_revoke before update of revoked_at
            on receiver_devices when new.revoked_at is not null
            begin
                select raise(abort, 'synthetic device revoke failure');
            end
            """
        )

    with pytest.raises(IntegrityError):
        _ = revoke_receiver_device(db_path, device_ref)

    assert authenticate_receiver_token(db_path, SYNTHETIC_DEVICE_CREDENTIAL)
    assert len(list_receiver_devices(db_path)) == 1


def test_redeem_normalizes_human_code(tmp_path: Path) -> None:
    db_path = tmp_path / "receiver.sqlite"
    _ = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )

    _ = redeem_pairing_invitation(
        db_path,
        invitation_code=" abcde fghjk mnpqr ",
    )

    assert authenticate_receiver_token(db_path, SYNTHETIC_DEVICE_CREDENTIAL)


def test_redeem_rejects_ambiguous_or_missing_credentials(tmp_path: Path) -> None:
    db_path = tmp_path / "receiver.sqlite"

    with pytest.raises(PairingInvitationError, match="exactly one"):
        _ = redeem_pairing_invitation(db_path)
    with pytest.raises(PairingInvitationError, match="exactly one"):
        _ = redeem_pairing_invitation(
            db_path,
            invitation_secret="hbi_synthetic_secret",
            invitation_code="ABCDE-FGHJK-MNPQR",
        )


def test_invitation_ttl_accepts_inclusive_ten_to_thirty_minute_boundaries(
    tmp_path: Path,
) -> None:
    for minutes in (10, 20, 30):
        invitation = create_pairing_invitation(
            tmp_path / f"receiver-accepted-{minutes}.sqlite",
            label="personal-iphone",
            receiver_url="https://health.example.test/v1/batches",
            expires_in=timedelta(minutes=minutes),
        )
        assert invitation.expires_at > invitation.created_at


def test_invitation_ttl_rejects_values_outside_ten_to_thirty_minutes(
    tmp_path: Path,
) -> None:
    for minutes in (9, 31):
        with pytest.raises(PairingInvitationError, match="10 and 30"):
            _ = create_pairing_invitation(
                tmp_path / f"receiver-{minutes}.sqlite",
                label="personal-iphone",
                receiver_url="https://health.example.test/v1/batches",
                expires_in=timedelta(minutes=minutes),
            )


def test_five_wrong_secrets_for_known_code_selector_lock_invitation(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    invitation = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )

    for _index in range(5):
        with pytest.raises(PairingInvitationError):
            _ = redeem_pairing_invitation(
                db_path,
                invitation_code="ABCDE-22222-22222",
            )

    with pytest.raises(PairingInvitationError):
        _ = redeem_pairing_invitation(
            db_path,
            invitation_code=invitation.invitation_code,
        )
    with connect_database(db_path) as connection:
        row = ATTEMPT_ROW_ADAPTER.validate_python(
            connection.execute(ATTEMPT_ROW_SQL).fetchone()
        )
    assert row == (5, 5)


def test_expired_and_revoked_invitations_do_not_issue_tokens(tmp_path: Path) -> None:
    db_path = tmp_path / "receiver.sqlite"
    now = datetime(2026, 7, 12, 6, 0, tzinfo=UTC)
    expired = create_pairing_invitation(
        db_path,
        label="expired-iphone",
        receiver_url="https://health.example.test/v1/batches",
        now=now,
        invitation_secret="hbi_expired_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )
    revoked = create_pairing_invitation(
        db_path,
        label="revoked-iphone",
        receiver_url="https://health.example.test/v1/batches",
        now=now,
        invitation_secret="hbi_revoked_synthetic_secret",
        invitation_code="STUVW-XYZ23-45678",
    )
    revoke_pairing_invitation(db_path, revoked.invitation_id)

    with pytest.raises(PairingInvitationError):
        _ = redeem_pairing_invitation(
            db_path,
            invitation_secret=expired.invitation_secret,
            now=now + timedelta(minutes=21),
        )
    with pytest.raises(PairingInvitationError):
        _ = redeem_pairing_invitation(
            db_path,
            invitation_secret=revoked.invitation_secret,
            now=now + timedelta(minutes=1),
        )


def test_concurrent_redeem_issues_exactly_one_device_token(tmp_path: Path) -> None:
    db_path = tmp_path / "receiver.sqlite"
    invitation = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_concurrent_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )

    def redeem(index: int) -> bool:
        try:
            _ = redeem_pairing_invitation(
                db_path,
                invitation_secret=invitation.invitation_secret,
                installation_id=f"00000000-0000-4000-8000-{index + 1:012d}",
                device_credential="hb_" + f"{index:x}" * 64,
            )
        except PairingInvitationError:
            return False
        return True

    with ThreadPoolExecutor(max_workers=8) as executor:
        results = list(executor.map(redeem, range(8)))

    assert results.count(True) == 1
    assert results.count(False) == 7
    with connect_database(db_path) as connection:
        active_tokens = COUNT_ROW_ADAPTER.validate_python(
            connection.execute(
                "select count(*) from receiver_tokens where revoked_at is null"
            ).fetchone()
        )
    assert active_tokens == (1,)


def test_token_insert_failure_rolls_back_invitation_consumption(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    invitation = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_rollback_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )

    failure_message = "synthetic token insert failure"

    def fail_token_insert(*_args: object, **_kwargs: object) -> NoReturn:
        raise RuntimeError(failure_message)

    with monkeypatch.context() as scoped_monkeypatch:
        scoped_monkeypatch.setattr(
            invitation_module,
            "create_receiver_token_in_connection",
            fail_token_insert,
        )
        with pytest.raises(RuntimeError, match="synthetic token insert failure"):
            _ = redeem_pairing_invitation(
                db_path,
                invitation_secret=invitation.invitation_secret,
            )

    _ = redeem_pairing_invitation(
        db_path,
        invitation_secret=invitation.invitation_secret,
    )
    assert authenticate_receiver_token(db_path, SYNTHETIC_DEVICE_CREDENTIAL)


def test_device_mapping_failure_rolls_back_consume_and_previous_token_revoke(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    first = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_synthetic_first_mapping_rollback_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )
    _ = redeem_pairing_invitation(
        db_path,
        invitation_secret=first.invitation_secret,
    )
    second = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_synthetic_second_mapping_rollback_secret",
        invitation_code="RSTUV-WXYZ2-34567",
    )
    replacement_credential = "hb_" + "b" * 64
    with connect_database(db_path) as connection:
        _ = connection.execute(
            """
            create trigger fail_pairing_device_mapping
            before insert on receiver_token_devices
            begin
                select raise(abort, 'synthetic mapping failure');
            end
            """
        )

    with pytest.raises(IntegrityError, match="synthetic mapping failure"):
        _ = redeem_pairing_invitation(
            db_path,
            invitation_secret=second.invitation_secret,
            device_credential=replacement_credential,
        )

    assert authenticate_receiver_token(db_path, SYNTHETIC_DEVICE_CREDENTIAL)
    assert not authenticate_receiver_token(db_path, replacement_credential)
    with connect_database(db_path) as connection:
        redeemed_row = REDEMPTION_STATE_ROW_ADAPTER.validate_python(
            connection.execute(
                (
                    "select redeemed_at, revoked_at from pairing_invitations "
                    "where pairing_invitation_id = ?"
                ),
                (second.invitation_id,),
            ).fetchone()
        )
        _ = connection.execute("drop trigger fail_pairing_device_mapping")
    assert redeemed_row == (None, None)

    _ = redeem_pairing_invitation(
        db_path,
        invitation_secret=second.invitation_secret,
        device_credential=replacement_credential,
    )
    assert not authenticate_receiver_token(db_path, SYNTHETIC_DEVICE_CREDENTIAL)
    assert authenticate_receiver_token(db_path, replacement_credential)


def test_failed_new_invitation_insert_rolls_back_previous_revocation(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"
    first = create_pairing_invitation(
        db_path,
        label="personal-iphone",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_first_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )

    with pytest.raises(IntegrityError):
        _ = create_pairing_invitation(
            db_path,
            label="personal-iphone",
            receiver_url="https://health.example.test/v1/batches",
            invitation_secret="hbi_second_synthetic_secret",
            invitation_code="ABCDE-22222-22222",
        )

    _ = redeem_pairing_invitation(
        db_path,
        invitation_secret=first.invitation_secret,
    )
    assert authenticate_receiver_token(db_path, SYNTHETIC_DEVICE_CREDENTIAL)
