import json
import struct
from pathlib import Path
from typing import cast
from xml.etree import ElementTree as ET

BRAND = Path("assets/brand")
APPICONSET = Path(
    "ios/HealthBridgeCompanion/App/Assets.xcassets/AppIcon.appiconset",
)
XCODE_PROJECT = Path(
    "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj",
)

CANONICAL_BRAND_PNGS = {
    BRAND / "health-bridge-lockup.png": (1440, 360),
    BRAND / "health-bridge-social-card.png": (1280, 640),
    BRAND / "health-bridge-mark-1024.png": (1024, 1024),
    BRAND / "health-bridge-mark-512.png": (512, 512),
    BRAND / "apple-touch-icon.png": (180, 180),
    BRAND / "favicon-48.png": (48, 48),
    BRAND / "favicon-32.png": (32, 32),
    BRAND / "favicon-16.png": (16, 16),
}

CANONICAL_SVGS = (
    BRAND / "health-bridge-mark.svg",
    BRAND / "health-bridge-mark-inverted.svg",
    BRAND / "health-bridge-mark-dark.svg",
    BRAND / "health-bridge-tile-charcoal.svg",
    BRAND / "health-bridge-tile-near-black.svg",
    BRAND / "favicon.svg",
    BRAND / "health-bridge-lockup.svg",
)

FORBIDDEN_EXPLORATION_DIRS = (
    "illustration-pass",
    "logo-lane",
    "logo-lane-expanded",
    "logo-dark-focus",
    "logo-14d-validation",
    "logo-14d-color-small-size",
    "open-design-banner-matrix",
    "open-design-native",
    "positioning-redo",
    "reference-gallery",
    "selected-reference-candidates",
)


def _png_header(path: Path) -> tuple[int, int, int, int]:
    data = path.read_bytes()
    assert data.startswith(b"\x89PNG\r\n\x1a\n")
    width, height = cast("tuple[int, int]", struct.unpack(">II", data[16:24]))
    bit_depth = data[24]
    color_type = data[25]
    return width, height, bit_depth, color_type


def test_canonical_brand_pngs_are_present_opaque_rgb_and_expected_size() -> None:
    for path, expected_size in CANONICAL_BRAND_PNGS.items():
        width, height, bit_depth, color_type = _png_header(path)
        assert (width, height) == expected_size
        assert bit_depth == 8
        assert color_type == 2


def test_brand_svgs_are_parseable_and_use_scaling_strokes() -> None:
    for path in CANONICAL_SVGS:
        text = path.read_text(encoding="utf-8")
        _ = ET.parse(path)  # noqa: S314 - trusted repo-local SVG asset
        assert "vector-effect" not in text


def test_ios_app_icon_catalog_is_complete_and_bundled() -> None:
    contents = cast(
        "dict[str, object]",
        json.loads((APPICONSET / "Contents.json").read_text(encoding="utf-8")),
    )
    images = cast("list[dict[str, str]]", contents["images"])
    assert len(images) == 18

    for image in images:
        filename = image["filename"]
        point_size = float(image["size"].split("x", 1)[0])
        scale = int(image["scale"].rstrip("x"))
        expected_pixels = round(point_size * scale)
        width, height, bit_depth, color_type = _png_header(APPICONSET / filename)
        assert (width, height) == (expected_pixels, expected_pixels)
        assert bit_depth == 8
        assert color_type == 2

    project = XCODE_PROJECT.read_text(encoding="utf-8")
    assert "Assets.xcassets in Resources" in project
    assert "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" in project


def test_visual_assets_are_public_minimal_not_exploration_dump() -> None:
    assert all(not (BRAND / name).exists() for name in FORBIDDEN_EXPLORATION_DIRS)
    assert Path("docs/brand.md").exists()
    assert not Path("docs/open-design-pilot.md").exists()
    assert not Path("docs/social-banner-exploration-brief.md").exists()


def test_brand_generator_is_self_contained_for_canonical_outputs() -> None:
    generator = Path("tools/generate_brand_assets.py").read_text(encoding="utf-8")
    assert "illustration-pass" not in generator
    assert "source_path" not in generator
    assert "health-bridge-social-card.html" in generator


def test_readme_uses_canonical_lockup_and_brand_guide() -> None:
    readme = Path("README.md").read_text(encoding="utf-8")
    assert '<img src="assets/brand/health-bridge-lockup.png"' in readme
    assert "docs/brand.md" in readme


def test_public_release_audit_only_allows_canonical_visual_binaries() -> None:
    audit = Path("scripts/public-release-audit.py").read_text(encoding="utf-8")
    for path in CANONICAL_BRAND_PNGS:
        assert f'Path("{path.as_posix()}")' in audit
    assert "ios/HealthBridgeCompanion/App/Assets.xcassets/AppIcon.appiconset/" in audit
    assert "reference-gallery" not in audit
