# ruff: noqa: ANN001, E501, INP001, S101, S314, T201
"""Generate canonical Health Bridge brand assets.

Run from the repository root or any directory with:

    python3 tools/generate_brand_assets.py

This script writes the canonical logo direction and regenerates the iOS
AppIcon catalog from the same
proportional-stroke SVG mark. It intentionally avoids
``vector-effect: non-scaling-stroke`` so favicon/app-icon exports scale as a
single mark.

Requires Pillow and Playwright's Python package with a Chromium executable.
"""

from __future__ import annotations

import json
import os
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

from PIL import Image
from playwright.sync_api import sync_playwright

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

BRAND.mkdir(parents=True, exist_ok=True)
APPICONS.mkdir(parents=True, exist_ok=True)
ASSET_ROOT.mkdir(parents=True, exist_ok=True)

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
  <path d="M48 14L76 31V65L48 82L20 65V31L48 14Z" fill="rgba(255,255,255,.048)" stroke="rgba(255,255,255,.15)" stroke-width="2"/>
  <path d="M48 14L76 31L48 48L20 31L48 14Z" fill="rgba(255,255,255,.055)"/>
  <path d="M20 31L48 48V82L20 65V31Z" fill="rgba(255,255,255,.032)"/>
  <path d="M76 31L48 48V82L76 65V31Z" fill="rgba(255,255,255,.022)"/>
  <path d="M32.5 40L48 48.5L63.5 40" fill="none" stroke="#F7F8FA" stroke-width="4.6" stroke-linecap="round" stroke-linejoin="round" opacity=".9"/>
  <path d="M31.5 58C41.5 50.5 54.5 50.5 64.5 58" fill="none" stroke="#3ECF8E" stroke-width="5.6" stroke-linecap="round"/>
  <path d="M39 64H57" fill="none" stroke="#7AB7FF" stroke-width="3.8" stroke-linecap="round" opacity=".78"/>
""".strip()

MARK_DARK_INNER = """
  <path d="M48 14L76 31V65L48 82L20 65V31L48 14Z" fill="rgba(17,21,29,.045)" stroke="rgba(17,21,29,.18)" stroke-width="2"/>
  <path d="M48 14L76 31L48 48L20 31L48 14Z" fill="rgba(17,21,29,.075)"/>
  <path d="M20 31L48 48V82L20 65V31Z" fill="rgba(17,21,29,.050)"/>
  <path d="M76 31L48 48V82L76 65V31Z" fill="rgba(17,21,29,.036)"/>
  <path d="M32.5 40L48 48.5L63.5 40" fill="none" stroke="#11151D" stroke-width="4.6" stroke-linecap="round" stroke-linejoin="round" opacity=".9"/>
  <path d="M31.5 58C41.5 50.5 54.5 50.5 64.5 58" fill="none" stroke="#3ECF8E" stroke-width="5.6" stroke-linecap="round"/>
  <path d="M39 64H57" fill="none" stroke="#2563EB" stroke-width="3.8" stroke-linecap="round" opacity=".78"/>
""".strip()


def svg_doc(
    body: str,
    *,
    label: str,
    view_box: str = "0 0 96 96",
    width: int = 96,
    height: int = 96,
) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view_box}" '
        f'width="{width}" height="{height}" role="img" aria-label="{label}">\n'
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
    mark_group = f"""
  <g transform="translate(84 80) scale(2.0833333333)">
    <rect width="96" height="96" rx="22" fill="{CHARCOAL}"/>
{indent(MARK_INNER, "    ")}
  </g>
""".rstrip()
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1440 360" role="img" aria-labelledby="title desc">
  <title id="title">Apple Health AI Bridge lockup</title>
  <desc id="desc">A folded package bridge mark with the Apple Health AI Bridge wordmark and product-value tagline.</desc>
  <rect width="1440" height="360" rx="40" fill="{SURFACE}"/>
  <rect x="1" y="1" width="1438" height="358" rx="39" fill="none" stroke="{BORDER}"/>
{mark_group}
  <text x="336" y="150" fill="{INK}" font-family="Geist, Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif" font-size="66" font-weight="700" letter-spacing="-3.2">Apple Health AI Bridge</text>
  <text x="339" y="207" fill="{MUTED}" font-family="Geist, Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif" font-size="27" font-weight="440" letter-spacing="-.55">Apple Health for your AI tools.</text>
  <text x="339" y="252" fill="#8490A3" font-family="Geist, Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif" font-size="20" font-weight="480" letter-spacing="-.25">Open-source · local-first · read-only by default</text>
</svg>
"""


def indent(text: str, prefix: str) -> str:
    return "\n".join(prefix + line if line else line for line in text.splitlines())


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
        path.write_text(content, encoding="utf-8")
        ET.parse(path)
        assert "vector-effect" not in content


def social_card_source() -> str:
    return """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Apple Health AI Bridge social card</title>
<style>
:root{
  --page:#e7e9ee;
  --ink:#f8fafc;
  --muted:#aab3c2;
  --dark:#101318;
  --line:rgba(255,255,255,.11);
  --green:#3ecf8e;
  --blue:#7ab7ff;
  --r-lg:28px;
}
*{box-sizing:border-box}
body{margin:0;padding:0;background:#101318;font-family:Inter,system-ui,-apple-system,Segoe UI,sans-serif;font-feature-settings:"liga" 1;color:#11151d}
.card{width:1280px;height:640px;overflow:hidden;margin:0;box-shadow:none;background:var(--dark);color:var(--ink)}
.inner{height:100%;padding:64px;display:grid;grid-template-columns:minmax(0,1fr) 470px;gap:64px;align-items:center}
.copy{display:flex;flex-direction:column;gap:22px;min-width:0}
.brand{font-size:15px;line-height:1;font-weight:600;letter-spacing:-.03em;color:var(--muted)}
h1{margin:0;font-size:86px;line-height:.94;letter-spacing:-.078em;font-weight:700;text-wrap:balance;max-width:760px}
.sub{margin:0;max-width:570px;color:#c4ccd8;font-size:23px;line-height:1.28;letter-spacing:-.035em;font-weight:400}
.visual{min-width:0}.surface{border:1px solid var(--line);border-radius:var(--r-lg);background:linear-gradient(180deg,rgba(255,255,255,.06),rgba(255,255,255,.025));box-shadow:0 28px 90px rgba(0,0,0,.28)}
.glow{background:radial-gradient(760px 420px at 82% 20%,rgba(62,207,142,.14),transparent 62%),#101318}
.context-keywords{height:434px;padding:28px;display:grid;grid-template-rows:1fr auto;gap:22px}
.context-map{position:relative;border:1px solid var(--line);border-radius:24px;background:radial-gradient(circle at 50% 48%,rgba(62,207,142,.13),transparent 44%),rgba(255,255,255,.026);display:grid;place-items:center;overflow:hidden}
.context-map::before{content:"";position:absolute;inset:42px;border:1px solid rgba(255,255,255,.075);border-radius:999px}
.context-map::after{content:"";position:absolute;inset:82px;border:1px solid rgba(62,207,142,.18);border-radius:999px}
.hub{position:relative;z-index:2;width:186px;height:116px;border-radius:34px;border:1px solid rgba(62,207,142,.32);background:linear-gradient(180deg,rgba(62,207,142,.16),rgba(255,255,255,.045));display:grid;place-items:center;text-align:center;color:#effaf4;font-size:22px;line-height:1.02;letter-spacing:-.055em;font-weight:700}
.node{position:absolute;z-index:3;padding:11px 14px;border-radius:999px;border:1px solid rgba(255,255,255,.13);background:rgba(12,15,20,.78);backdrop-filter:blur(10px);color:#dce5ef;font-size:14px;line-height:1;font-weight:600;letter-spacing:-.025em}
.node.a{left:28px;top:52px}.node.b{right:24px;top:70px}.node.c{left:52px;bottom:56px}.node.d{right:34px;bottom:54px}
.context-keyline{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}
.value{min-height:76px;border:1px solid var(--line);border-radius:18px;background:rgba(255,255,255,.035);padding:17px 16px;display:flex;flex-direction:column;justify-content:center;gap:6px}
.value strong{font-size:17px;line-height:1.1;letter-spacing:-.04em}.value span{color:#8793a3;font-size:13px;line-height:1.2;letter-spacing:-.015em}
@media (max-width:900px){body{padding:12px}.card{width:100%;height:auto}.inner{min-height:640px;grid-template-columns:1fr!important}.visual{display:none}}
</style>
</head>
<body>
<section class="card glow" id="social-card">
  <div class="inner">
    <div class="copy">
      <div class="brand">Apple Health AI Bridge</div>
      <h1>Apple Health for your AI tools.</h1>
      <p class="sub">An open-source bridge that turns health history into useful AI context.</p>
    </div>
    <div class="visual surface context-keywords" aria-hidden="true">
      <div class="context-map">
        <div class="node a">Apple Health history</div>
        <div class="node b">AI tools</div>
        <div class="node c">your questions</div>
        <div class="node d">your control</div>
        <div class="hub">health context<br>for AI</div>
      </div>
      <div class="context-keyline">
        <div class="value"><strong>Bring the history</strong><span>Apple Health fits your workflow</span></div>
        <div class="value"><strong>Ask with context</strong><span>AI tools get useful background</span></div>
        <div class="value"><strong>Keep control</strong><span>read-only, open source</span></div>
      </div>
    </div>
  </div>
</section>
</body>
</html>
"""


def lockup_html_source() -> str:
    mark = tile_svg(CHARCOAL)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Apple Health AI Bridge lockup</title>
<style>
*{{box-sizing:border-box}}
html,body{{margin:0;width:1440px;height:360px;overflow:hidden;background:#fff}}
body{{font-family:Inter,system-ui,-apple-system,Segoe UI,sans-serif;color:{INK};font-feature-settings:"liga" 1}}
.lockup{{width:1440px;height:360px;border-radius:40px;background:#fff;border:1px solid {BORDER};display:flex;align-items:center;padding:80px 84px;gap:52px}}
.mark{{width:200px;height:200px;flex:0 0 auto}}
.mark svg{{display:block;width:200px;height:200px}}
.text{{display:flex;flex-direction:column;justify-content:center;min-width:0;padding-top:2px}}
.wordmark{{font-size:66px;line-height:.98;font-weight:700;letter-spacing:-3.2px;color:{INK};white-space:nowrap}}
.tagline{{margin-top:23px;font-size:27px;line-height:1;font-weight:440;letter-spacing:-.55px;color:{MUTED}}}
.meta{{margin-top:25px;font-size:20px;line-height:1;font-weight:480;letter-spacing:-.25px;color:#8490a3}}
</style>
</head>
<body>
  <div class="lockup" id="lockup">
    <div class="mark" aria-hidden="true">{mark}</div>
    <div class="text">
      <div class="wordmark">Apple Health AI Bridge</div>
      <div class="tagline">Apple Health for your AI tools.</div>
      <div class="meta">Open-source · local-first · read-only by default</div>
    </div>
  </div>
</body>
</html>
"""


def render_svg_to_png(page, svg_text: str, out_path: Path, size: int) -> None:
    html = f"""<!doctype html><html><head><meta charset='utf-8'><style>
html,body{{margin:0;width:{size}px;height:{size}px;overflow:hidden;background:#111827}}
svg{{display:block;width:{size}px;height:{size}px}}
</style></head><body>{svg_text}</body></html>"""
    page.set_viewport_size({"width": size, "height": size})
    page.set_content(html, wait_until="load")
    page.screenshot(path=str(out_path), omit_background=False)
    Image.open(out_path).convert("RGB").save(out_path)


def render_social_card(browser) -> None:
    html_path = BRAND / "health-bridge-social-card.html"
    html_path.write_text(social_card_source(), encoding="utf-8")
    page = browser.new_page(
        viewport={"width": 1280, "height": 640}, device_scale_factor=1
    )
    page.goto(html_path.as_uri(), wait_until="networkidle")
    page.locator("#social-card").screenshot(
        path=str(BRAND / "health-bridge-social-card.png")
    )
    Image.open(BRAND / "health-bridge-social-card.png").convert("RGB").save(
        BRAND / "health-bridge-social-card.png"
    )
    page.close()


def render_lockup(browser) -> None:
    html_path = BRAND / "health-bridge-lockup.html"
    html_path.write_text(lockup_html_source(), encoding="utf-8")
    page = browser.new_page(
        viewport={"width": 1440, "height": 360}, device_scale_factor=1
    )
    page.goto(html_path.as_uri(), wait_until="networkidle")
    page.locator("#lockup").screenshot(path=str(BRAND / "health-bridge-lockup.png"))
    Image.open(BRAND / "health-bridge-lockup.png").convert("RGB").save(
        BRAND / "health-bridge-lockup.png"
    )
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


def render_rasters() -> None:
    launch_args: dict[str, Any] = {"headless": True}
    if CHROME is not None and CHROME.exists():
        launch_args["executable_path"] = str(CHROME)
    with sync_playwright() as p:
        browser = p.chromium.launch(**launch_args)
        page = browser.new_page(device_scale_factor=1)
        svg_text = tile_svg(CHARCOAL)
        for size, name in [
            (1024, "health-bridge-mark-1024.png"),
            (512, "health-bridge-mark-512.png"),
            (180, "apple-touch-icon.png"),
            (48, "favicon-48.png"),
            (32, "favicon-32.png"),
            (16, "favicon-16.png"),
        ]:
            render_svg_to_png(page, svg_text, BRAND / name, size)
        entries = app_icon_entries()
        for entry in entries:
            px = round(
                float(entry["size"].split("x", 1)[0]) * int(entry["scale"].rstrip("x"))
            )
            render_svg_to_png(page, svg_text, APPICONS / entry["filename"], px)
        page.close()
        render_lockup(browser)
        render_social_card(browser)
        browser.close()

    (APPICONS / "Contents.json").write_text(
        json.dumps(
            {"images": app_icon_entries(), "info": {"author": "xcode", "version": 1}},
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    (ASSET_ROOT / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    write_svg_assets()
    render_rasters()
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
    raise SystemExit(main())
