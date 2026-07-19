from pathlib import Path
from typing import Final, TypeAlias

import pytest
from pydantic import TypeAdapter

from health_bridge.receiver.pairing import (
    ReceiverPairingBundleError,
    create_receiver_pairing_bundle,
    create_receiver_pairing_invitation_bundle,
    pairing_bundle_from_deep_link,
    pairing_deep_link,
    pairing_invitation_from_deep_link,
)
from health_bridge.receiver.tokens import authenticate_receiver_token
from health_bridge.storage.database import connect_database

ReceiverTokenRow: TypeAlias = tuple[str, str, str]
CountRow: TypeAlias = tuple[int]
RECEIVER_TOKEN_ROW_ADAPTER: Final[TypeAdapter[ReceiverTokenRow | None]] = TypeAdapter(
    ReceiverTokenRow | None,
)
COUNT_ROW_ADAPTER: Final[TypeAdapter[CountRow | None]] = TypeAdapter(CountRow | None)


def test_pairing_bundle_creates_one_time_token_and_stores_only_hash(
    tmp_path: Path,
) -> None:
    # Given
    db_path = tmp_path / "receiver.sqlite"

    # When
    bundle = create_receiver_pairing_bundle(
        db_path,
        label="maintainer-iphone",
        receiver_url="https://health-bridge.example.test/v1/batches",
        token="hb_pairing_secret",
        created_at="2026-06-10T09:00:00Z",
    )

    # Then
    assert bundle.schema_id == "health_bridge.receiver_pairing.v1"
    assert bundle.schema_version == "1.0.0"
    assert bundle.label == "maintainer-iphone"
    assert bundle.receiver_url == "https://health-bridge.example.test/v1/batches"
    assert bundle.bearer_token == "hb_pairing_secret"
    assert bundle.token_prefix == "hb_pairing_"
    assert bundle.created_at == "2026-06-10T09:00:00Z"
    assert "secret" in bundle.warning.lower()
    assert authenticate_receiver_token(db_path, "hb_pairing_secret")

    with connect_database(db_path) as connection:
        row = RECEIVER_TOKEN_ROW_ADAPTER.validate_python(
            connection.execute(
                "select token_label, token_prefix, token_hash from receiver_tokens",
            ).fetchone(),
        )

    assert row is not None
    assert row[0] == "maintainer-iphone"
    assert row[1] == "hb_pairing_"
    assert row[2] != "hb_pairing_secret"
    assert "hb_pairing_secret" not in row[2]


def test_pairing_deep_link_round_trips_without_losing_secret(tmp_path: Path) -> None:
    # Given
    bundle = create_receiver_pairing_bundle(
        tmp_path / "receiver.sqlite",
        label="ios-companion",
        receiver_url="http://127.0.0.1:8765/v1/batches",
        token="hb_deep_link_secret",
        created_at="2026-06-10T09:01:00Z",
    )

    # When
    deep_link = pairing_deep_link(bundle)
    decoded = pairing_bundle_from_deep_link(deep_link)

    # Then
    assert deep_link.startswith("healthbridge://pair?payload=")
    assert decoded == bundle


def test_pairing_bundle_rejects_non_http_receiver_urls(tmp_path: Path) -> None:
    # When / Then
    with pytest.raises(ReceiverPairingBundleError, match="http or https"):
        _ = create_receiver_pairing_bundle(
            tmp_path / "receiver.sqlite",
            label="ios-companion",
            receiver_url="file:///tmp/receiver",
            token="hb_bad_url_secret",
            created_at="2026-06-10T09:02:00Z",
        )


def test_v2_invitation_bundle_creates_no_receiver_token_before_redeem(
    tmp_path: Path,
) -> None:
    db_path = tmp_path / "receiver.sqlite"

    bundle = create_receiver_pairing_invitation_bundle(
        db_path,
        label="ios-companion",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )

    assert bundle.schema_id == "health_bridge.receiver_pairing_invitation.v2"
    assert bundle.schema_version == "2.0.0"
    assert bundle.redeem_url == "https://health.example.test/v1/pairing/redeem"
    assert bundle.invitation_code == "ABCDE-FGHJK-MNPQR"
    assert bundle.expires_at > bundle.created_at
    with connect_database(db_path) as connection:
        count = COUNT_ROW_ADAPTER.validate_python(
            connection.execute("select count(*) from receiver_tokens").fetchone()
        )
    assert count == (0,)


def test_v2_pairing_deep_link_contains_secret_but_not_human_code(
    tmp_path: Path,
) -> None:
    bundle = create_receiver_pairing_invitation_bundle(
        tmp_path / "receiver.sqlite",
        label="ios-companion",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )

    deep_link = pairing_deep_link(bundle)
    decoded = pairing_invitation_from_deep_link(deep_link)

    assert deep_link.startswith("healthbridge://pair?payload=")
    assert decoded.schema_id == "health_bridge.receiver_pairing_invitation.v2"
    assert decoded.label == bundle.label
    assert decoded.receiver_url == bundle.receiver_url
    assert decoded.redeem_url == bundle.redeem_url
    assert decoded.invitation_secret == bundle.invitation_secret
    assert decoded.expires_at == bundle.expires_at
    assert "ABCDE-FGHJK-MNPQR" not in deep_link
    assert "invitation_code" not in decoded.model_dump(mode="json")


def test_v2_pairing_deep_link_rejects_cross_origin_redeem_url(
    tmp_path: Path,
) -> None:
    bundle = create_receiver_pairing_invitation_bundle(
        tmp_path / "receiver.sqlite",
        label="ios-companion",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )
    tampered = bundle.model_copy(
        update={"redeem_url": "https://attacker.example/v1/pairing/redeem"}
    )

    with pytest.raises(ReceiverPairingBundleError, match="same origin"):
        _ = pairing_invitation_from_deep_link(pairing_deep_link(tampered))
