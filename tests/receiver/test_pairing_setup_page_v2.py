from pathlib import Path

from health_bridge.receiver.pairing import (
    create_receiver_pairing_invitation_bundle,
    pairing_deep_link,
)
from health_bridge.receiver.pairing_setup_page import render_pairing_setup_page


def test_v2_setup_page_is_qr_first_with_manual_code_fallback(tmp_path: Path) -> None:
    bundle = create_receiver_pairing_invitation_bundle(
        tmp_path / "receiver.sqlite",
        label="ios-companion",
        receiver_url="https://health.example.test/v1/batches",
        invitation_secret="hbi_synthetic_secret",
        invitation_code="ABCDE-FGHJK-MNPQR",
    )
    pairing_url = pairing_deep_link(bundle)

    page = render_pairing_setup_page(bundle, pairing_url)

    assert "<svg" in page
    assert 'href="healthbridge://pair?payload=' in page
    assert "Scan with iPhone Camera" in page
    assert "Use a code instead" in page
    assert "health.example.test" in page
    assert "ABCDE-FGHJK-MNPQR" in page
    assert bundle.expires_at in page
    assert bundle.invitation_secret not in page
    assert "Token prefix" not in page
    assert "bearer-token" not in page
    assert "temporary, single-use invitation" in page
