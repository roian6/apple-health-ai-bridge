from pathlib import Path
from typing import Final, TypeAlias

from pydantic import TypeAdapter

from health_bridge.receiver.tokens import (
    authenticate_receiver_token,
    create_receiver_token,
    revoke_receiver_token,
)
from health_bridge.storage import initialize_database
from health_bridge.storage.database import connect_database

ReceiverTokenRow: TypeAlias = tuple[str, str, str, str | None]
SELECT_RECEIVER_TOKEN_ROW_SQL: Final = (
    "select token_label, token_prefix, token_hash, revoked_at from receiver_tokens"
)
RECEIVER_TOKEN_ROW_ADAPTER: Final[TypeAdapter[ReceiverTokenRow | None]] = TypeAdapter(
    ReceiverTokenRow | None,
)


def test_receiver_token_is_stored_hashed_and_authenticates(tmp_path: Path) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    initialize_database(db_path)

    # When
    issued = create_receiver_token(db_path, label="ios-dev", token="hb_test_secret")

    # Then
    assert issued.token == "hb_test_secret"
    assert issued.label == "ios-dev"
    assert issued.token_prefix == "hb_test_sec"
    assert authenticate_receiver_token(db_path, "hb_test_secret")
    assert not authenticate_receiver_token(db_path, "hb_wrong_secret")

    with connect_database(db_path) as connection:
        row = RECEIVER_TOKEN_ROW_ADAPTER.validate_python(
            connection.execute(
                SELECT_RECEIVER_TOKEN_ROW_SQL,
            ).fetchone(),
        )

    assert row is not None
    assert row[0] == "ios-dev"
    assert row[1] == "hb_test_sec"
    assert row[2] != "hb_test_secret"
    assert "hb_test_secret" not in row[2]
    assert row[3] is None


def test_revoked_receiver_token_no_longer_authenticates(tmp_path: Path) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"
    initialize_database(db_path)
    issued = create_receiver_token(
        db_path,
        label="old-phone",
        token="hb_revoked_secret",
    )

    # When
    revoke_receiver_token(db_path, issued.token_prefix)

    # Then
    assert not authenticate_receiver_token(db_path, "hb_revoked_secret")
