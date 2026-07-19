from pathlib import Path

from health_bridge.receiver.pairing import (
    create_receiver_pairing_bundle,
    pairing_deep_link,
)
from health_bridge.receiver.pairing_setup_page import render_pairing_setup_page


def test_pairing_setup_page_embeds_qr_and_direct_link_without_plaintext_token(
    tmp_path: Path,
) -> None:
    # Given
    bundle = create_receiver_pairing_bundle(
        tmp_path / "receiver.sqlite",
        label="maintainer-iphone",
        receiver_url="https://health-bridge.example.test/v1/batches",
        token="hb_setup_page_secret",
        created_at="2026-06-10T10:00:00Z",
    )
    pairing_url = pairing_deep_link(bundle)

    # When
    html = render_pairing_setup_page(bundle, pairing_url)

    # Then
    assert "<!doctype html>" in html.lower()
    assert "HealthBridge Companion Pairing" in html
    assert "<svg" in html
    assert pairing_url in html
    assert "maintainer-iphone" in html
    assert bundle.token_prefix in html
    assert "Delete this setup page after pairing" in html
    assert "Recommended pairing methods" in html
    assert "Best default" in html
    assert "iPhone Camera" in html
    assert "Already on the iPhone" in html
    assert "Paste setup link in Health Bridge" in html
    assert "trusted screen" in html
    assert "receiver URL must be reachable from the iPhone" in html
    assert "Copy setup link" in html
    assert bundle.bearer_token not in html


def test_pairing_setup_page_qr_layout_is_centered_and_not_clipped(
    tmp_path: Path,
) -> None:
    # Given
    bundle = create_receiver_pairing_bundle(
        tmp_path / "receiver.sqlite",
        label="maintainer-iphone",
        receiver_url="https://health-bridge.example.test/v1/batches",
        token="hb_setup_layout_secret",
        created_at="2026-06-20T05:30:00Z",
    )
    pairing_url = pairing_deep_link(bundle)

    # When
    html = render_pairing_setup_page(bundle, pairing_url)

    # Then
    assert "box-sizing: border-box" in html
    assert "width: min(100% - 2rem, 720px)" in html
    assert "qr-shell" in html
    assert "justify-content: center" in html
    assert "overflow: visible" in html
    assert "max-width: 100%" in html
    assert "viewBox=" in html
    assert "<svg" in html
    svg_tag = html.split("<svg", 1)[1].split(">", 1)[0]
    assert ' width="' not in svg_tag


def test_pairing_setup_page_escapes_bundle_display_fields(tmp_path: Path) -> None:
    # Given
    bundle = create_receiver_pairing_bundle(
        tmp_path / "receiver.sqlite",
        label='"><script>alert(1)</script>',
        receiver_url="https://health-bridge.example.test/v1/batches?device=iphone&mode=pair",
        token="hb_setup_escape_secret",
        created_at="2026-06-10T10:01:00Z",
    )
    pairing_url = pairing_deep_link(bundle)

    # When
    html = render_pairing_setup_page(bundle, pairing_url)

    # Then
    assert "<script>alert(1)</script>" not in html
    assert "&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;" in html
    assert "device=iphone&amp;mode=pair" in html
    assert bundle.bearer_token not in html
