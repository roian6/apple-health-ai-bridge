# Apple Health AI Bridge visual identity

This identity is a restrained public-release baseline for Apple Health AI Bridge: a local-first, read-only bridge that turns Apple Health history into useful context for AI tools.

It is intentionally developer-tool oriented rather than consumer wellness or clinical branding.

## Core assets

| Asset | Path | Use |
| --- | --- | --- |
| Default mark SVG | [`assets/brand/health-bridge-mark.svg`](../assets/brand/health-bridge-mark.svg) | Default repo/avatar/app-tile mark |
| Light mark SVG | [`assets/brand/health-bridge-mark-inverted.svg`](../assets/brand/health-bridge-mark-inverted.svg) | Mark on controlled dark surfaces when the tile background is supplied elsewhere |
| Dark mark SVG | [`assets/brand/health-bridge-mark-dark.svg`](../assets/brand/health-bridge-mark-dark.svg) | Mark on light/neutral surfaces |
| Charcoal tile SVG | [`assets/brand/health-bridge-tile-charcoal.svg`](../assets/brand/health-bridge-tile-charcoal.svg) | Preferred dark tile/export source |
| Near-black tile SVG | [`assets/brand/health-bridge-tile-near-black.svg`](../assets/brand/health-bridge-tile-near-black.svg) | Stronger dark fallback |
| Favicon SVG | [`assets/brand/favicon.svg`](../assets/brand/favicon.svg) | Browser/favicon source; same mark family, proportional strokes |
| Logo lockup HTML | [`assets/brand/health-bridge-lockup.html`](../assets/brand/health-bridge-lockup.html) | Browser-rendered source for the README/repository lockup |
| Logo lockup PNG | [`assets/brand/health-bridge-lockup.png`](../assets/brand/health-bridge-lockup.png) | README/repository header; rasterized to avoid SVG font fallback on GitHub |
| Logo lockup SVG | [`assets/brand/health-bridge-lockup.svg`](../assets/brand/health-bridge-lockup.svg) | Editable vector fallback; do not use as the README image unless text is outlined |
| Social card HTML | [`assets/brand/health-bridge-social-card.html`](../assets/brand/health-bridge-social-card.html) | Browser-rendered source for repo social preview |
| Social card PNG | [`assets/brand/health-bridge-social-card.png`](../assets/brand/health-bridge-social-card.png) | GitHub/OpenGraph upload candidate |
| iOS app icon set | [`ios/HealthBridgeCompanion/App/Assets.xcassets/AppIcon.appiconset`](../ios/HealthBridgeCompanion/App/Assets.xcassets/AppIcon.appiconset) | Xcode app icon source, regenerated from the default mark |
| Asset generator | [`tools/generate_brand_assets.py`](../tools/generate_brand_assets.py) | Regenerate canonical SVG/PNG/app-icon assets |

## Regenerating assets

The canonical files are generated from `tools/generate_brand_assets.py` and should
stay reproducible from the repo root:

```bash
uv run --with pillow --with playwright python tools/generate_brand_assets.py
```

If Playwright has no Chromium browser on a fresh machine, install one with
`uv run --with playwright python -m playwright install chromium` before
regenerating rasters. If Chromium is already installed outside Playwright's
current cache, set `PLAYWRIGHT_CHROMIUM_EXECUTABLE=/absolute/path/to/chrome`.

## Asset direction

- **Logo:** folded-package bridge mark.
- **Primary tile:** `#111827` charcoal blue.
- **Fallback dark tile:** `#080A0F` near black.
- **Accent:** `#3ECF8E` green with small `#7AB7FF` blue support.
- **Core line:** `Apple Health for your AI tools.`

The mark is meant to read as a package/bridge/context object, not as a medical symbol. It should stay dark-first, simple, and infrastructure-like.

## Copy guidance

Primary public copy:

- `Apple Health for your AI tools.`
- `An open-source bridge that turns health history into useful AI context.`
- `Open-source · local-first · read-only by default`

Use implementation details as secondary proof, not hero copy. Avoid leading public visuals with `HealthKit`, `SQLite`, `MCP`, arrows, or cloud/no-cloud claims unless the surface is explicitly technical documentation.

## Color tokens

| Token | Hex | Use |
| --- | --- | --- |
| Charcoal tile | `#111827` | Default logo tile, app icon, repo avatar |
| Near black | `#080A0F` | Darker fallback surface |
| Ink | `#111827` | Headings, wordmark, primary text |
| Canvas | `#fbfcfd` | Light docs/social surface |
| Surface | `#ffffff` | Cards and README lockup background |
| Muted text | `#64748b` | Secondary descriptions |
| Border | `#d8dee4` | Hairline borders |
| Accent green | `#3ECF8E` | Bridge/accent stroke |
| Accent blue | `#7AB7FF` | Secondary support stroke |

## Small-size rules

- Keep the current mark as the single maintained mark family for now.
- Do **not** use `vector-effect: non-scaling-stroke` in the logo SVG; internal strokes must scale with the viewBox.
- Export favicon/app-icon rasters from the SVG source at the target size, not by CSS-scaling a screenshot.
- Re-check 16/24/32px output whenever mark geometry changes.

## Usage rules

Do:

- Use the charcoal tile for avatars, App Store icon, GitHub profile-style surfaces, and dark lockups.
- Use the lockup PNG for README/repository header contexts. GitHub-rendered SVG text cannot rely on the design font, so the PNG is the font-safe public surface.
- Use the social-card PNG/HTML for GitHub social preview and announcement drafts.
- Keep screenshots synthetic or scrubbed; never show real health values or private receiver/setup material.

Do not:

- imply Apple affiliation;
- use the Apple logo, Apple Health app icon language, red heart mark, ECG line, medical cross, hospital motif, or clinical imagery;
- suggest diagnosis, emergency use, coaching decisions, recovery scoring, or medical interpretation;
- show real HealthKit values, receiver endpoints, pairing URLs, bearer tokens, token hashes, cursor values, local outbox contents, or screenshots with personal health values;
- make the implementation nouns the main visual message.

## QA requirements

Before publishing or committing visual changes:

1. Parse SVG/XML and asset catalog JSON.
2. Verify every AppIcon PNG listed in `Contents.json` exists at the expected pixel size.
3. Confirm iOS AppIcon PNGs are opaque RGB square images; iOS applies the mask.
4. Inspect the social card, lockup, 1024px app icon, and favicon sizes visually.
5. Confirm no logo SVG contains `vector-effect: non-scaling-stroke`.
6. Check that public preview images contain no real health data, tokens, endpoints, pairing material, or private screenshots.
