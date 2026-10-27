from pathlib import Path

import pytest

from health_bridge.receiver.invitations import PairingInvitationError
from health_bridge.receiver.pairing import (
    create_receiver_pairing_invitation_bundle,
    pairing_deep_link,
    pairing_invitation_from_deep_link,
)


def test_explicit_mailbox_invitation_roundtrips_without_receiver_url(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("HOME", str(tmp_path))
    try:
        invitation = create_receiver_pairing_invitation_bundle(
            tmp_path / "receiver.sqlite",
            label="synthetic",
            receiver_url=None,
            transport="mailbox",
        )
    except PairingInvitationError:
        pytest.fail("explicit native Mailbox still requires a receiver URL")
    decoded = pairing_invitation_from_deep_link(pairing_deep_link(invitation))
    assert decoded.receiver_url is None
    assert decoded.redeem_url is None
    assert "mailbox_bootstrap" in decoded.model_dump()


def test_direct_still_requires_receiver_url(tmp_path: Path) -> None:
    with pytest.raises(PairingInvitationError):
        _ = create_receiver_pairing_invitation_bundle(
            tmp_path / "receiver.sqlite", label="synthetic", receiver_url=None
        )
