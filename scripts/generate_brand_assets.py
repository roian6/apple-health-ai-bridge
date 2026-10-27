# ruff: noqa: E501, INP001, S101, S314, T201
"""Generate canonical Health Bridge brand assets.

Run from the repository root or any directory with:

    python3 scripts/generate_brand_assets.py

This script writes the canonical logo direction and regenerates the iOS
AppIcon catalog from the same
proportional-stroke SVG mark. It intentionally avoids
``vector-effect: non-scaling-stroke`` so favicon/app-icon exports scale as a
single mark.

Requires Pillow and Playwright's Python package with a Chromium executable.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from PIL import Image
    from playwright.sync_api import Browser, sync_playwright

ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT / "assets" / "brand"
APPICONS = (
    ROOT
    / "ios"
    / "HealthBridgeCompanion"
    / "App"
    / "Assets.xcassets"
    / "AppIcon.appiconset"
)
ASSET_ROOT = APPICONS.parent
CHROME_ENV = os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE")
CHROME = Path(CHROME_ENV) if CHROME_ENV else None

INK = "#111827"
NEAR_BLACK = "#080A0F"
CHARCOAL = "#111827"
GREEN = "#3ECF8E"
BLUE = "#7AB7FF"
MUTED = "#64748B"
BORDER = "#D8DEE4"
SURFACE = "#FFFFFF"
CANVAS = "#FBFCFD"

MARK_INNER = """
  <g transform="translate(48 52) scale(1.3) translate(-48 -52)">
  <path d="M32.5 40L48 48.5L63.5 40" fill="none" stroke="#F7F8FA" stroke-width="4.6" stroke-linecap="round" stroke-linejoin="round" opacity=".9"/>
  <path d="M31.5 58C41.5 50.5 54.5 50.5 64.5 58" fill="none" stroke="#3ECF8E" stroke-width="5.6" stroke-linecap="round"/>
  <path d="M39 64H57" fill="none" stroke="#7AB7FF" stroke-width="3.8" stroke-linecap="round" opacity=".78"/>
  </g>
""".strip()

MARK_DARK_INNER = MARK_INNER.replace("#F7F8FA", "#11151D").replace("#7AB7FF", "#2563EB")
FONT = 'system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif'


def svg_doc(
    body: str,
    *,
    label: str,
) -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96" '
        f'width="96" height="96" role="img" aria-label="{label}">\n'
        f"{body}\n</svg>\n"
    )


def tile_svg(fill: str = CHARCOAL) -> str:
    return svg_doc(
        f'  <rect width="96" height="96" rx="22" fill="{fill}"/>\n{MARK_INNER}',
        label="Apple Health AI Bridge logo tile",
    )


def transparent_light_mark_svg() -> str:
    return svg_doc(MARK_INNER, label="Apple Health AI Bridge light mark")


def transparent_dark_mark_svg() -> str:
    return svg_doc(MARK_DARK_INNER, label="Apple Health AI Bridge dark mark")


def lockup_svg() -> str:
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1440 360" role="img" aria-labelledby="title desc">
  <title id="title">Apple Health AI Bridge lockup</title>
  <desc id="desc">Bridge mark, product name and Your Apple Health, connected to your AI.</desc>
  <defs>
    <radialGradient id="mint" gradientUnits="userSpaceOnUse" cx="0" cy="0" r="1" gradientTransform="matrix(892.8 0 0 504 0 0)">
      <stop stop-color="#0f9f82" stop-opacity=".1"/><stop offset=".78" stop-color="#0f9f82" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="blue" gradientUnits="userSpaceOnUse" cx="0" cy="0" r="1" gradientTransform="matrix(864 0 0 468 1440 0)">
      <stop stop-color="#2563eb" stop-opacity=".07"/><stop offset=".78" stop-color="#2563eb" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="1440" height="360" fill="{SURFACE}"/>
  <rect width="1440" height="360" fill="url(#blue)"/>
  <rect width="1440" height="360" fill="url(#mint)"/>
  <g transform="translate(88 92) scale(1.8333333333333333)">
    <rect width="96" height="96" rx="22" fill="{CHARCOAL}"/>
    {MARK_INNER}
  </g>
  <g font-family='{FONT}'>
    <text x="308" y="171.84375" fill="{INK}" font-size="64" font-weight="700" letter-spacing="-2.5">Apple Health AI Bridge</text>
    <text x="308" y="237.953125" fill="#475569" font-size="36" letter-spacing="-.7">Your Apple Health, connected to your AI.</text>
  </g>
</svg>
"""


def write_svg_assets() -> None:
    files = {
        "health-bridge-mark.svg": tile_svg(CHARCOAL),
        "health-bridge-mark-inverted.svg": transparent_light_mark_svg(),
        "health-bridge-mark-dark.svg": transparent_dark_mark_svg(),
        "health-bridge-tile-charcoal.svg": tile_svg(CHARCOAL),
        "health-bridge-tile-near-black.svg": tile_svg(NEAR_BLACK),
        "favicon.svg": tile_svg(CHARCOAL),
        "health-bridge-lockup.svg": lockup_svg(),
    }
    for name, content in files.items():
        path = BRAND / name
        _ = path.write_text(content, encoding="utf-8")
        _ = ET.parse(path)
        assert "vector-effect" not in content


def social_card_source(size: tuple[int, int] = (1280, 640)) -> str:
    width, height = size
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Apple Health AI Bridge social card</title>
<style>
*{{box-sizing:border-box}}
html,body{{margin:0;width:{width}px;height:{height}px;background:{CANVAS}}}
body{{font-family:{FONT};color:{INK}}}
.card{{width:100%;height:100%;padding:64px;display:flex;flex-direction:column;background:radial-gradient(ellipse 70% 110% at 0% 0%,rgba(15,159,130,.18),rgba(15,159,130,0) 75%),radial-gradient(ellipse 65% 100% at 100% 0%,rgba(37,99,235,.12),rgba(37,99,235,0) 75%),{CANVAS}}}
.brand{{display:flex;align-items:center;gap:24px;font-size:28px;font-weight:600;letter-spacing:-.03em}}
.brand svg{{width:64px;height:64px;flex:none}}
.copy{{margin:auto 0}}
h1{{margin:0;font-size:80px;line-height:1.04;letter-spacing:-.04em;font-weight:700}}
.sub{{margin:28px 0 0;font-size:40px;line-height:1.4;letter-spacing:-.02em;color:#475569}}
.address{{margin:0;padding-top:24px;border-top:1px solid {BORDER};font-size:20px;line-height:1.4;color:{MUTED}}}
</style>
</head>
<body>
<main class="card" id="social-card">
  <div class="brand">{tile_svg()}<span>Apple Health AI Bridge</span></div>
  <div class="copy">
    <h1>Your Apple Health,<br>connected to your AI.</h1>
    <p class="sub">Ask your AI about your sleep, workouts and activity.</p>
  </div>
  <p class="address">healthbridge.chanhyo.dev</p>
</main>
</body>
</html>
"""


def lockup_html_source() -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Apple Health AI Bridge lockup</title>
<style>
*{{box-sizing:border-box}}
html,body{{margin:0;width:1440px;height:360px;overflow:hidden;background:#fff}}
body{{font-family:{FONT};color:{INK}}}
.lockup{{width:1440px;height:360px;display:flex;align-items:center;padding:0 88px;gap:44px;background:radial-gradient(ellipse 62% 140% at 0% 0%,rgba(15,159,130,.1),rgba(15,159,130,0) 78%),radial-gradient(ellipse 60% 130% at 100% 0%,rgba(37,99,235,.07),rgba(37,99,235,0) 78%),#fff}}
.mark,.mark svg{{display:block;width:176px;height:176px;flex:none}}
h1{{font-size:64px;line-height:1.08;letter-spacing:-2.5px;font-weight:700;margin:0}}
p{{font-size:36px;line-height:1.2;letter-spacing:-.7px;color:#475569;margin:20px 0 0}}
</style>
</head>
<body>
  <main class="lockup" id="lockup">
    <div class="mark">{tile_svg()}</div>
    <div>
      <h1>Apple Health AI Bridge</h1>
      <p>Your Apple Health, connected to your AI.</p>
    </div>
  </main>
</body>
</html>
"""


def save_rgb(path: Path) -> None:
    with Image.open(path) as image:
        image.convert("RGB").save(path)


def render_svg_to_png(browser: Browser, out_path: Path, size: int) -> None:
    html = f"""<!doctype html><html><head><meta charset='utf-8'><style>
html,body{{margin:0;width:{size}px;height:{size}px;overflow:hidden;background:#111827}}
svg{{display:block;width:{size}px;height:{size}px}}
</style></head><body>{tile_svg()}</body></html>"""
    page = browser.new_page(
        viewport={"width": size, "height": size}, device_scale_factor=1
    )
    page.set_content(html, wait_until="load")
    _ = page.locator("svg").screenshot(path=str(out_path), omit_background=False)
    page.close()
    save_rgb(out_path)


def render_html(browser: Browser, html_path: Path, size: tuple[int, int]) -> None:
    """Export text artwork at twice its CSS size without changing its layout."""
    width, height = size
    page = browser.new_page(
        viewport={"width": width, "height": height}, device_scale_factor=2
    )
    _ = page.goto(html_path.as_uri(), wait_until="load")
    _ = page.locator("main").screenshot(path=str(html_path.with_suffix(".png")))
    save_rgb(html_path.with_suffix(".png"))
    page.close()


def app_icon_entries() -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []

    def add(idiom: str, size: float, scale: int) -> None:
        label = (
            str(size).rstrip("0").rstrip(".") if isinstance(size, float) else str(size)
        )
        filename = (
            "Icon-1024.png"
            if idiom == "ios-marketing"
            else f"Icon-{label}@{scale}x.png"
        )
        entries.append(
            {
                "idiom": idiom,
                "size": f"{label}x{label}",
                "scale": f"{scale}x",
                "filename": filename,
            }
        )

    for pt in [20, 29, 40, 60]:
        for scale in [2, 3]:
            add("iphone", pt, scale)
    for pt, scales in [
        (20, [1, 2]),
        (29, [1, 2]),
        (40, [1, 2]),
        (76, [1, 2]),
        (83.5, [2]),
    ]:
        for scale in scales:
            add("ipad", pt, scale)
    add("ios-marketing", 1024, 1)
    return entries


def export_site_assets(site_root: Path) -> None:
    for name in ("health-bridge-mark.svg", "favicon.svg", "apple-touch-icon.png"):
        _ = shutil.copyfile(BRAND / name, site_root / "assets" / name)


def render_rasters(site_root: Path | None = None) -> None:
    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True, executable_path=str(CHROME) if CHROME is not None else None
        )
        for size, name in [
            (1024, "health-bridge-mark-1024.png"),
            (512, "health-bridge-mark-512.png"),
            (180, "apple-touch-icon.png"),
            (48, "favicon-48.png"),
            (32, "favicon-32.png"),
            (16, "favicon-16.png"),
        ]:
            render_svg_to_png(browser, BRAND / name, size)
        entries = app_icon_entries()
        for entry in entries:
            px = round(
                float(entry["size"].split("x", 1)[0]) * int(entry["scale"].rstrip("x"))
            )
            render_svg_to_png(browser, APPICONS / entry["filename"], px)
        lockup = BRAND / "health-bridge-lockup.html"
        _ = lockup.write_text(lockup_html_source(), encoding="utf-8")
        render_html(browser, lockup, (1440, 360))
        for directory, size in [(BRAND, (1280, 640))] + (
            [(site_root / "assets", (1200, 630))] if site_root is not None else []
        ):
            card = directory / "health-bridge-social-card.html"
            _ = card.write_text(social_card_source(size), encoding="utf-8")
            render_html(browser, card, size)
        if site_root is not None:
            export_site_assets(site_root)
        browser.close()

    _ = (APPICONS / "Contents.json").write_text(
        json.dumps(
            {"images": app_icon_entries(), "info": {"author": "xcode", "version": 1}},
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    _ = (ASSET_ROOT / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )


class Arguments(argparse.Namespace):
    site_root: Path | None = None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    _ = parser.add_argument("--site-root", type=Path, help="Export shared site assets.")
    args = parser.parse_args(namespace=Arguments())
    site_root = args.site_root.resolve() if args.site_root is not None else None
    if site_root is not None and not (site_root / "assets").is_dir():
        parser.error("--site-root must contain an assets directory")
    BRAND.mkdir(parents=True, exist_ok=True)
    APPICONS.mkdir(parents=True, exist_ok=True)
    write_svg_assets()
    render_rasters(site_root)
    print("Generated canonical Health Bridge visual assets:")
    for rel in [
        "assets/brand/health-bridge-mark.svg",
        "assets/brand/health-bridge-lockup.svg",
        "assets/brand/health-bridge-lockup.html",
        "assets/brand/health-bridge-lockup.png",
        "assets/brand/health-bridge-social-card.html",
        "assets/brand/health-bridge-social-card.png",
        "assets/brand/health-bridge-mark-1024.png",
        "ios/HealthBridgeCompanion/App/Assets.xcassets/AppIcon.appiconset/Contents.json",
    ]:
        print(f"- {rel}")
    return 0


if __name__ == "__main__":
    from PIL import Image
    from playwright.sync_api import sync_playwright

    raise SystemExit(main())
