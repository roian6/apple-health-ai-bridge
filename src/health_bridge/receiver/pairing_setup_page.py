# pyright: reportMissingTypeStubs=false, reportUnknownArgumentType=false, reportUnknownMemberType=false, reportUnknownVariableType=false

import html
from io import BytesIO
from typing import Final

import segno

from health_bridge.receiver.pairing import (
    ReceiverPairingBundle,
    ReceiverPairingInvitationBundle,
)

SETUP_PAGE_TITLE: Final = "HealthBridge Companion Pairing"
SETUP_PAGE_DELETE_NOTICE: Final = "Delete this setup page after pairing."


def render_pairing_setup_page(
    bundle: ReceiverPairingBundle | ReceiverPairingInvitationBundle,
    pairing_url: str,
) -> str:
    if isinstance(bundle, ReceiverPairingInvitationBundle):
        return _render_invitation_setup_page(bundle, pairing_url)
    return _render_legacy_setup_page(bundle, pairing_url)


def _render_invitation_setup_page(
    bundle: ReceiverPairingInvitationBundle,
    pairing_url: str,
) -> str:
    qr_svg = _pairing_qr_svg(pairing_url)
    escaped_label = html.escape(bundle.label, quote=True)
    escaped_receiver_url = html.escape(bundle.receiver_url, quote=True)
    escaped_code = html.escape(bundle.invitation_code, quote=True)
    escaped_expires_at = html.escape(bundle.expires_at, quote=True)
    escaped_warning = html.escape(bundle.warning, quote=True)
    escaped_pairing_url = html.escape(pairing_url, quote=True)
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{SETUP_PAGE_TITLE}</title>
  <style>
    :root {{ color-scheme: light dark; font-family: -apple-system, sans-serif; }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0; min-height: 100vh; display: grid; place-items: center;
      padding: 1rem; background: #111827; color: #f9fafb;
    }}
    main {{
      width: min(100% - 1rem, 720px); padding: clamp(1.25rem, 4vw, 2rem);
      border: 1px solid #374151; border-radius: 24px; background: #1f2937;
      box-shadow: 0 24px 80px rgba(0, 0, 0, 0.35);
    }}
    h1 {{ margin-top: 0; font-size: clamp(1.8rem, 5vw, 2.8rem); }}
    .eyebrow {{ color: #93c5fd; font-weight: 700; }}
    .qr-shell {{ display: grid; place-items: center; margin: 1.25rem 0; }}
    .qr {{ padding: 1rem; border-radius: 20px; background: #fff; color: #111; }}
    .qr svg {{
      width: min(76vw, 340px); max-width: 100%; height: auto; display: block;
    }}
    .button {{
      display: inline-block; padding: 0.85rem 1rem; border-radius: 999px;
      background: #60a5fa; color: #111827; font-weight: 750; text-decoration: none;
    }}
    .fallback {{
      margin-top: 1.5rem; padding: 1rem; border: 1px solid #4b5563;
      border-radius: 16px; background: #111827;
    }}
    dl {{ display: grid; grid-template-columns: max-content 1fr; gap: .5rem 1rem; }}
    dt {{ color: #9ca3af; }} dd {{ margin: 0; overflow-wrap: anywhere; }}
    code {{ font-size: 1.25rem; letter-spacing: .08em; color: #fde68a; }}
    textarea {{
      width: 100%; min-height: 6rem; padding: .75rem; border-radius: 12px;
      border: 1px solid #4b5563; background: #0b1220; color: #e5e7eb;
    }}
    button {{
      margin: .5rem 0; padding: .7rem .9rem; border: 0; border-radius: 12px;
      background: #374151; color: #f9fafb; font-weight: 700;
    }}
    .warning {{ border-left: 4px solid #fbbf24; padding-left: 1rem; color: #fde68a; }}
  </style>
</head>
<body>
  <main>
    <p class="eyebrow">Temporary invitation · single use</p>
    <h1>Connect HealthBridge Companion</h1>
    <h2>Scan with iPhone Camera</h2>
    <p>Open this page on a trusted screen, then scan the QR code.</p>
    <div class="qr-shell">
      <div class="qr" aria-label="Pairing QR code">{qr_svg}</div>
    </div>
    <p>
      <a class="button" href="{escaped_pairing_url}">Open in Health Bridge</a>
    </p>
    <section class="fallback">
      <h2>Use a code instead</h2>
      <p>In Health Bridge, choose manual pairing and enter:</p>
      <dl>
        <dt>Device</dt><dd>{escaped_label}</dd>
        <dt>Server</dt><dd>{escaped_receiver_url}</dd>
        <dt>Code</dt><dd><code>{escaped_code}</code></dd>
        <dt>Expires</dt><dd>{escaped_expires_at}</dd>
      </dl>
    </section>
    <p class="warning">
      <strong>Private setup artifact.</strong> {escaped_warning}
      {SETUP_PAGE_DELETE_NOTICE}
    </p>
    <details>
      <summary>Copy setup link</summary>
      <button type="button" onclick="copyPairingLink()">Copy setup link</button>
      <textarea id="pairing-url" readonly>{escaped_pairing_url}</textarea>
    </details>
  </main>
  <script>
    async function copyPairingLink() {{
      const field = document.getElementById('pairing-url');
      field.focus(); field.select();
      try {{ await navigator.clipboard.writeText(field.value); }}
      catch (_) {{ document.execCommand('copy'); }}
    }}
  </script>
</body>
</html>
"""


def _render_legacy_setup_page(
    bundle: ReceiverPairingBundle,
    pairing_url: str,
) -> str:
    qr_svg = _pairing_qr_svg(pairing_url)
    escaped_label = html.escape(bundle.label, quote=True)
    escaped_receiver_url = html.escape(bundle.receiver_url, quote=True)
    escaped_token_prefix = html.escape(bundle.token_prefix, quote=True)
    escaped_warning = html.escape(bundle.warning, quote=True)
    escaped_pairing_url = html.escape(pairing_url, quote=True)
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{SETUP_PAGE_TITLE}</title>
  <style>
    :root {{
      color-scheme: light dark;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      padding: 1rem;
      background:
        radial-gradient(
          circle at top left,
          rgba(96, 165, 250, 0.22),
          transparent 34rem
        ),
        #111827;
      color: #f9fafb;
    }}
    main {{
      width: min(100% - 2rem, 720px);
      margin: 1rem auto;
      padding: clamp(1.25rem, 4vw, 2rem);
      border: 1px solid rgba(255, 255, 255, 0.08);
      border-radius: 24px;
      background: #1f2937;
      box-shadow: 0 24px 80px rgba(0, 0, 0, 0.35);
      overflow: visible;
    }}
    h1 {{ margin-top: 0; font-size: clamp(1.8rem, 5vw, 3rem); }}
    .qr-shell {{
      display: flex;
      justify-content: center;
      align-items: center;
      width: 100%;
      margin: 1.5rem 0;
      overflow: visible;
    }}
    .qr {{
      display: block;
      max-width: 100%;
      padding: clamp(0.75rem, 3vw, 1.25rem);
      border-radius: 22px;
      background: #fff;
      color: #111;
      box-shadow: 0 16px 40px rgba(0, 0, 0, 0.28);
      overflow: visible;
    }}
    .qr svg {{
      width: min(76vw, 340px);
      max-width: 100%;
      height: auto;
      display: block;
      overflow: visible;
    }}
    dl {{
      display: grid;
      grid-template-columns: max-content 1fr;
      gap: 0.45rem 1rem;
      margin: 1.5rem 0;
    }}
    ol.methods {{
      margin: 1rem 0 1.5rem;
      padding-left: 1.5rem;
    }}
    ol.methods li {{ margin: 0.7rem 0; }}
    dt {{ color: #9ca3af; }}
    dd {{ margin: 0; overflow-wrap: anywhere; }}
    a.button {{
      display: inline-block;
      margin: 1rem 0;
      padding: 0.8rem 1rem;
      border-radius: 999px;
      background: #60a5fa;
      color: #111827;
      font-weight: 700;
      text-decoration: none;
    }}
    textarea {{
      box-sizing: border-box;
      width: 100%;
      min-height: 7rem;
      border-radius: 14px;
      border: 1px solid #4b5563;
      padding: 0.8rem;
      background: #111827;
      color: #e5e7eb;
    }}
    button.copy {{
      display: inline-block;
      margin: 0.5rem 0 1rem;
      padding: 0.7rem 0.9rem;
      border: 0;
      border-radius: 12px;
      background: #374151;
      color: #f9fafb;
      font-weight: 700;
    }}
    .hint {{ color: #cbd5e1; }}
    .warning {{
      border-left: 4px solid #fbbf24;
      padding-left: 1rem;
      color: #fde68a;
    }}
  </style>
</head>
<body>
  <main>
    <h1>{SETUP_PAGE_TITLE}</h1>
    <p>
      Open this page only from a trusted screen or browser session. The setup link
      contains a receiver credential; keep it private and delete this file after
      pairing.
    </p>
    <h2>Recommended pairing methods</h2>
    <ol class="methods">
      <li>
        <strong>Best default:</strong> open this page on a trusted laptop, desktop,
        tablet, or another screen the iPhone can see, then scan the QR code with
        the iPhone Camera.
      </li>
      <li>
        <strong>Already on the iPhone:</strong> tap the button below to open Health
        Bridge directly.
      </li>
      <li>
        <strong>If browser handoff fails:</strong> copy the setup link and choose
        <em>Paste setup link in Health Bridge</em>.
      </li>
    </ol>
    <div class="qr-shell">
      <div class="qr" aria-label="Pairing QR code">{qr_svg}</div>
    </div>
    <p class="hint">
      The receiver URL must be reachable from the iPhone. Local machines, cloud
      hosts, LAN, and private networks can all work when routing/firewall
      settings allow it.
    </p>
    <p>
      <a class="button" href="{escaped_pairing_url}">
        Open HealthBridge Companion
      </a>
    </p>
    <dl>
      <dt>Device label</dt><dd>{escaped_label}</dd>
      <dt>Receiver URL</dt><dd>{escaped_receiver_url}</dd>
      <dt>Token prefix</dt><dd>{escaped_token_prefix}</dd>
    </dl>
    <p class="warning">
      <strong>Secret setup file.</strong>
      {escaped_warning} {SETUP_PAGE_DELETE_NOTICE}
    </p>
    <label for="pairing-url">Direct link fallback</label>
    <button class="copy" type="button" onclick="copyPairingLink()">
      Copy setup link
    </button>
    <textarea id="pairing-url" readonly>{escaped_pairing_url}</textarea>
  </main>
  <script>
    async function copyPairingLink() {{
      const field = document.getElementById('pairing-url');
      field.focus();
      field.select();
      try {{
        await navigator.clipboard.writeText(field.value);
      }} catch (_) {{
        document.execCommand('copy');
      }}
    }}
  </script>
</body>
</html>
"""


def _pairing_qr_svg(pairing_url: str) -> str:
    buffer = BytesIO()
    qr_code = segno.make(pairing_url, error="m")
    qr_code.save(
        buffer,
        kind="svg",
        scale=8,
        xmldecl=False,
        svgns=True,
        omitsize=True,
    )
    return buffer.getvalue().decode("utf-8")
