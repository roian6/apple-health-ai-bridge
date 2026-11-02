# Client brand assets

Official vendor artwork used in the client setup documentation. These marks
identify the named products; they do not imply vendor endorsement. The
project's license does not grant rights to vendor trademarks.

## Packaged files

`light` and `dark` name the intended background, not the artwork's ink color.
Dimensions below are the original viewBox dimensions; Cursor supplies no fixed
width/height attributes. Preserve aspect ratio and the entire viewBox.

| Product label | File | ViewBox width x height | Intended background |
|---|---|---|---|
| Cursor | `cursor-cube-2d-light.svg` | 466.73 x 532.09 | White/light |
| Cursor | `cursor-cube-2d-dark.svg` | 466.73 x 532.09 | Dark |
| Cursor | `cursor-lockup-horizontal-2d-light.svg` | 2238.7 x 532.09 | White/light |
| Cursor | `cursor-lockup-horizontal-2d-dark.svg` | 2238.7 x 532.09 | Dark |
| OpenCode | `opencode-logo-light.svg` | 240 x 300 | White/light |
| OpenCode | `opencode-logo-dark.svg` | 240 x 300 | Dark |
| Visual Studio Code | `vscode.svg` | 100 x 100 | White/light or dark with adequate contrast |
| Visual Studio Code | `vscode-white.svg` | 100 x 100 | Only where the blue stable icon lacks contrast |
| Antigravity CLI | `antigravity.svg` | 136 x 136 | Original light/dark preference |
| Claude Code | `claude-code-mark.svg` | 266 x 266 | White/light or dark |
| Claude Desktop | `claude-desktop-mark.svg` | 32 x 32 | White/light or dark |
| Codex CLI / ChatGPT Desktop | `codex-openai-mark.svg` | 385 x 385 | White/light or dark |
| Hermes Agent | `hermes-agent.svg` | 1024 x 1024 | Original white tile on either background |
| OpenClaw | `openclaw.svg` | 120 x 120 | White/light or dark |
| LM Studio | `lm-studio.svg` | 192 x 192 | White/light or dark; preserve original tile/transparency |
| Cherry Studio | `cherry-studio.svg` | 167 x 171 | White/light or dark; preserve original tile/transparency |
| Goose | `goose.svg` | 40 x 40 | White/light or dark; preserve original tile/transparency |
| Pi | `pi.svg` | 560 x 560 | Original light/dark preference |
| Warp | `warp.svg` | 96 x 96 | White/light or dark; preserve original tile/transparency |
| Amp | `amp.svg` | 1024 x 1024 | White/light or dark; preserve original tile/transparency |
| Factory Droid | `factory-droid.svg` | 508 x 508 | White/light or dark; preserve original tile/transparency |
| GitHub Copilot | `github-copilot.svg` | 256 x 256 | White/light or dark; preserve original tile/transparency |

Suggested layout sizes, not vendor minimum sizes: cube 28.07 x 32 CSS pixels,
OpenCode 25.6 x 32, VS Code 32 x 32, Cursor horizontal lockup 134.63 x 32.
Use `object-fit: contain` when placing non-square marks in a square image box.
Allow space outside
the image; for VS Code preserve clear space equal to 25% of the fish motif.
Prefer separate image elements rather than inline SVG: official IDs and Cursor
`.st0` classes are intentionally unchanged and could collide in a shared DOM.
Do not recolor, invert, crop, trace, remove filters, or add a background to artwork.
Keep a readable product label beside every mark, including shared family marks.

## Official provenance and reuse conditions

The Cursor, OpenCode and VS Code archive sources below were accessed
**2026-10-23**. Their only packaging change is line-ending normalization and a
terminal newline. Additional sources were accessed **2026-10-24**, as recorded
per file in `provenance.json`, with exact URLs and original/packaged SHA-256 hashes.
New catalog sources were revalidated on **2026-11-02** against the official
pages and download URLs below. No archives or macOS metadata are packaged.
Eight official PNG icons are embedded unchanged in self-contained SVG wrappers;
the other artwork remains native SVG. Factory adds only a terminal newline.
Paths, colors, backgrounds, transparency, viewBoxes, masks and filters are preserved.

### Cursor

Official source: https://cursor.com/brand

Final download URL:
https://ptht05hbb1ssoooe.public.blob.vercel-storage.com/assets/brand/cursor-brand-assets.zip

Members: `General Logos/Cube/SVG/CUBE_2D_LIGHT.svg`,
`General Logos/Cube/SVG/CUBE_2D_DARK.svg`,
`General Logos/Lockup Horizontal/SVG/LOCKUP_HORIZONTAL_2D_LIGHT.svg`,
`General Logos/Lockup Horizontal/SVG/LOCKUP_HORIZONTAL_2D_DARK.svg`.

The public brand page supplies resources to represent Cursor accurately, names
2D as the default, and prefers the horizontal lockup while also supplying the
separate cube. Use the supplied background variant and the exact name Cursor.
This is the basis for bounded, unmodified product identification; the page does
not provide an unrestricted trademark license or Health Bridge endorsement.

### OpenCode

Official source: https://opencode.ai/brand

Final download URL: https://opencode.ai/opencode-brand-assets.zip

Members: `OpenCode Brand Assets/Logo/opencode-logo-light.svg` and
`OpenCode Brand Assets/Logo/opencode-logo-dark.svg`.

The public brand page expressly offers brand resources with SVG download
controls. Its official download handler at
https://opencode.ai/_build/assets/index-C0pyOv_e.js
identifies the archive and the matching light/dark SVGs. Archive originals were
used, not PNG previews or a third-party recreation.
Use these unmodified for factual OpenCode identification. The page establishes
an offered brand asset, not an additional catalog-specific trademark grant;
do not infer trademark permission from the project's source-code license.
No express prior-approval requirement was found on this brand page.

### Visual Studio Code

Official source: https://code.visualstudio.com/brand

Final download URL:
https://code.visualstudio.com/assets/branding/visual-studio-code-icons.zip

Members: `visual-studio-code-icons/vscode.svg` and
`visual-studio-code-icons/vscode-alt.svg` (packaged as `vscode-white.svg`).

The policy allows documentation/tutorial use about Visual Studio Code and
linking the icon to its official website. Use here is limited to that
documentation context, not a promotional partner badge. Use the blue stable
icon by default; use the white alternate only when blue lacks contrast.
Preserve the specified clear space. Do not use the Insiders, app, or vintage
icons, create a name/icon lockup, combine it into Health Bridge branding, or
imply Microsoft association. First mention: Visual Studio Code; later: VS Code.

### Additional client identifiers

| Label | Official identity source | Artwork role |
| --- | --- | --- |
| Antigravity CLI | https://antigravity.google/ | Official product-family favicon; not a distinct CLI logo or Gemini consumer mark |
| Claude Code | https://code.claude.com/docs/en/vs-code | Anthropic's published extension icon, using the Claude family asterisk |
| Claude Desktop | https://www.claude.com/download | Shared Claude family favicon; not an extracted native desktop app icon |
| Codex CLI | https://developers.openai.com/codex/ide/ | OpenAI's published Codex extension icon, using the shared OpenAI family mark |
| Hermes Agent | https://github.com/NousResearch/hermes-agent | Official documentation favicon |
| OpenClaw | https://github.com/openclaw/openclaw | Official static Linux app icon |

Codex and Claude Code use the image supplied by their official extension
listings. The Codex listing retains the package identifier `openai.chatgpt`;
its displayed product is Codex, not the ChatGPT consumer app. Distinct visible
labels identify CLI, Code and Desktop products even when a family symbol is shared.
The 32px Claude Desktop source is intended for the 24/32px documentation slots.
Do not enlarge it into hero artwork or synthesize a higher-resolution replacement.
The Antigravity SVG keeps its original color-scheme rule; Hermes keeps its white
tile; the Codex icon keeps its black square. No CSS filter or recoloring is needed.

### Catalog additions (2026-11-02)

| Label | Official identity page | Exact download URL | Source role |
| --- | --- | --- | --- |
| LM Studio | https://lmstudio.ai/ | https://lmstudio.ai/assets/marketing/logo-192x192.png | Official LM Studio product favicon and marketing logo. |
| Cherry Studio | https://cherryai.com/ | https://cherryai.com/assets/favicon-BmbgeFTf.png | Official Cherry Studio product favicon. |
| Goose | https://goose-docs.ai/ | https://goose-docs.ai/img/favicon.ico | Official Goose documentation favicon. |
| Pi | https://pi.dev/ | https://pi.dev/favicon.svg | Official Pi coding-agent product favicon; not the unrelated Inflection Pi assistant. |
| Warp | https://warp.dev/ | https://warp.dev/favicon-96x96.png | Official Warp product-family favicon; not a separate CLI-specific mark. |
| Amp | https://ampcode.com/ | https://ampcode.com/app-icon.svg?v=4 | Official Amp product app icon, also published as the site favicon. |
| Factory Droid | https://factory.com/ | https://factory.com/favicon.svg | Shared Factory family favicon used to identify Factory Droid; not a unique Droid-specific symbol. |
| GitHub Copilot | https://marketplace.visualstudio.com/items?itemName=GitHub.copilot | https://GitHub.gallerycdn.vsassets.io/extensions/github/copilot/1.388.0/1761326434179/Microsoft.VisualStudio.Services.Icons.Default | GitHub-published Copilot extension product icon; not the GitHub Octocat. |

Goose's `.ico` URL and server MIME claim ICO, but its signature and decoded
contents are PNG (40 x 40); the wrapper correctly uses `data:image/png`.
Cherry Studio is 167 x 171, not square; preserve that aspect ratio. Warp redirects
to `www.warp.dev`, recorded in provenance. The Copilot icon is the original
256px gray-and-white icon published by GitHub's official extension listing, not Octocat or a
recolored monochrome substitute. Keep its original background and transparency.
Pi retains its vendor-authored `prefers-color-scheme` styles; match its surrounding
surface to the browser color scheme, since a light surface in dark mode gives
poor contrast. Do not replace the styles with local inversion.
Goose's 40px favicon is for small documentation slots,
not hero enlargement. Factory Droid uses a shared Factory family mark.

ChatGPT Desktop reuses `codex-openai-mark.svg` with a distinct visible product
label. This is the shared OpenAI family mark supplied for the Codex extension,
not a claim that it is ChatGPT Desktop's native app icon. No duplicate is needed.

These published icons establish source authenticity, not an unrestricted
trademark license. Retain vendor ownership, visible product labels and the
bounded documentation use described above; no endorsement is implied.
