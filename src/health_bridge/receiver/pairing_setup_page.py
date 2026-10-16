# pyright: reportMissingTypeStubs=false, reportUnknownArgumentType=false, reportUnknownMemberType=false, reportUnknownVariableType=false

import hashlib
import html
import json
import re
from io import BytesIO
from pathlib import Path
from typing import Final

import segno

from health_bridge.receiver.invitations import SetupProgress
from health_bridge.receiver.pairing import (
    ReceiverPairingBundle,
    ReceiverPairingBundleError,
    ReceiverPairingInvitationBundle,
    ReceiverPairingInvitationPayload,
    pairing_invitation_from_deep_link,
)

SETUP_PAGE_TITLE: Final = "Connect Health Bridge for AI (companion app)"
SETUP_PAGE_DELETE_NOTICE: Final = "Delete this setup page after pairing."
PROGRESS_COPY: Final = {
    "pending": (
        "Connect your iPhone",
        "Save the Apple Health data you choose on the computer where you ran setup.",
    ),
    "paired": (
        "iPhone connected",
        (
            "Next, choose what the app may read and turn on sync to save data on "
            "your computer."
        ),
    ),
    "received": (
        "Health records stored",
        (
            "Health records from your iPhone are saved on the computer where you "
            "ran setup."
        ),
    ),
    "unavailable": (
        "Connection page unavailable",
        (
            "This link expired or is no longer available. Return to your setup "
            "terminal and rerun the same setup command to continue. "
            "An iPhone already connected stays connected."
        ),
    ),
}


def read_invitation_page(path: Path) -> tuple[str, ReceiverPairingInvitationPayload]:
    page = path.read_text(encoding="utf-8")
    return page, pairing_invitation_from_deep_link(_page_pairing_url(page))


def _page_pairing_url(page: str) -> str:
    match = re.search(r'href="(healthbridge://pair\?payload=[^"]+)"', page)
    if match is None:
        message = "Setup page has no invitation link."
        raise ReceiverPairingBundleError(message)
    return html.unescape(match[1])


def invitation_page_route(invitation: ReceiverPairingInvitationPayload) -> str:
    capability = hashlib.sha256(
        ("health-bridge-setup:" + invitation.invitation_secret).encode()
    ).hexdigest()
    return "/setup/" + capability


def render_hosted_setup_page(
    page: str, invitation: ReceiverPairingInvitationPayload, progress: SetupProgress
) -> str:
    code = re.search(r"<dt>Code</dt><dd><code>([^<]+)</code></dd>", page)
    return render_pairing_setup_page(
        invitation,
        _page_pairing_url(page),
        progress=progress,
        manual_code=html.unescape(code[1]) if code else "",
    )


def render_pairing_setup_page(
    bundle: ReceiverPairingBundle
    | ReceiverPairingInvitationBundle
    | ReceiverPairingInvitationPayload
    | None,
    pairing_url: str,
    *,
    progress: SetupProgress | None = None,
    manual_code: str = "",
    unavailable_message: str | None = None,
) -> str:
    progress = progress or SetupProgress()
    expires_at = ""
    credential_details = ""
    warning = ""
    pending = ""
    match bundle:
        case ReceiverPairingInvitationBundle() | ReceiverPairingInvitationPayload():
            expires_at = bundle.expires_at
            if isinstance(bundle, ReceiverPairingInvitationBundle):
                manual_code = bundle.invitation_code
            if bundle.mailbox_bootstrap is not None:
                manual_code = ""
            credential_details = (
                f"<dt>Code</dt><dd><code>{html.escape(manual_code)}</code></dd>"
                if manual_code
                else ""
            )
            credential_details += f"<dt>Expires</dt><dd>{html.escape(expires_at)}</dd>"
            warning = (
                "Keep this single-use invitation private. Sharing it before use "
                "lets someone else connect an iPhone. Progress stays available "
                "until the link expires."
            )
            fallback_instruction = (
                "To connect with a code, open manual pairing in Health Bridge for AI "
                "(companion app) and enter the computer address and code below."
            )
            if bundle.mailbox_bootstrap is not None:
                fallback_instruction = (
                    "Paste this setup link in the iPhone app to pair using iCloud."
                )
        case ReceiverPairingBundle():
            credential_details = (
                f"<dt>Token prefix</dt><dd>{html.escape(bundle.token_prefix)}</dd>"
            )
            warning = f"{bundle.warning} {SETUP_PAGE_DELETE_NOTICE}"
            fallback_instruction = (
                "Paste this setup link in Health Bridge for AI (companion app)."
            )
        case None:
            fallback_instruction = ""
    if bundle is not None and progress.pairing_status == "pending":
        escaped_pairing_url = html.escape(pairing_url, quote=True)
        pending = f"""
    <section id="pending">
      <div class="connect">
        <div class="qr-shell">
          <div class="qr" aria-label="Pairing QR code">
            {_pairing_qr_svg(pairing_url)}</div>
        </div>
        <div>
          <h2>Viewing this on your computer?</h2>
          <p>Scan the QR code with iPhone Camera to open
            Health Bridge for AI (companion app).</p>
          <h2>Already on your iPhone?</h2>
          <p>Tap below to connect the app to your computer.</p>
          <a class="button" href="{escaped_pairing_url}">
            Open in Health Bridge for AI</a>
          <p>Need the app? <a href="https://apps.apple.com/app/id6786152806"
            rel="noreferrer">Install Health Bridge for AI (companion app)</a>,
            then return here and tap Open in Health Bridge for AI.</p>
        </div>
      </div>
      <details>
        <summary>Connect with a code or copied link</summary>
        <p>{fallback_instruction}</p>
        <dl>
          <dt>Connection name</dt><dd>{html.escape(bundle.label, quote=True)}</dd>
          <dt>Computer address</dt>
          <dd>{html.escape(bundle.receiver_url or "iCloud", quote=True)}</dd>
          {credential_details}
        </dl>
        <label for="pairing-url">Setup link</label>
        <textarea id="pairing-url" readonly>{escaped_pairing_url}</textarea>
        <button type="button" id="copy-link">Copy setup link</button>
        <p id="copy-result" role="status"></p>
      </details>
    </section>"""
    stored = progress.data_receipt_status == "received"
    paired = progress.pairing_status == "paired"
    state = (
        "unavailable"
        if bundle is None
        else "received"
        if stored
        else "paired"
        if paired
        else "pending"
    )
    title, description = PROGRESS_COPY[state]
    if unavailable_message is not None:
        description = unavailable_message
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="referrer" content="no-referrer">
  <title>{SETUP_PAGE_TITLE}</title>
  <style>
    :root {{
      color-scheme: light dark;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      --surface: #ffffff; --ink: #202124; --muted: #555b64;
      --line: #c8ccd2; --action: #1559a5; --hover: #10457f;
      --space: 1rem; --radius: 0.35rem;
    }}
    @media (prefers-color-scheme: dark) {{
      :root {{ --surface: #181a1d; --ink: #f1f3f5; --muted: #b8bec6;
        --line: #646b75; --action: #9ac7ff; --hover: #c4dfff; }}
    }}
    * {{ box-sizing: border-box; }}
    [hidden] {{ display: none !important; }}
    body {{ margin: 0; background: var(--surface); color: var(--ink);
      font-size: 1rem; line-height: 1.55; }}
    main {{ width: min(100% - 2rem, 720px); margin: 3rem auto;
      padding-bottom: 2rem; }}
    h1 {{ font-size: 1.75rem; line-height: 1.25; margin: 0 0 var(--space); }}
    h2 {{ font-size: 1.125rem; line-height: 1.35; margin: 0 0 0.5rem; }}
    p {{ margin: 0.75rem 0; max-width: 65ch; }}
    a {{ color: var(--action); text-underline-offset: 0.2em; }}
    a:hover {{ color: var(--hover); }}
    .connect {{ display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
      align-items: center; gap: 2rem; margin: 2rem 0; }}
    .qr-shell {{ display: flex; justify-content: center; overflow: visible; }}
    .qr {{ width: 100%; max-width: 280px; padding: 0.75rem;
      background: #fff; color: #111; }}
    .qr svg {{ display: block; width: 100%; max-width: 100%; height: auto; }}
    button, .button {{ display: inline-block; font: inherit; font-weight: 600;
      padding: 0.65rem 1rem; min-height: 44px; border: 1px solid var(--action);
      border-radius: var(--radius); background: var(--surface);
      color: var(--action); cursor: pointer; text-decoration: none; }}
    button:hover, .button:hover {{ border-color: var(--hover); color: var(--hover); }}
    button:disabled {{ opacity: 0.6; cursor: wait; }}
    :focus-visible {{ outline: 2px solid var(--action); outline-offset: 3px; }}
    details {{ border-top: 1px solid var(--line); padding: var(--space) 0; }}
    summary {{ cursor: pointer; min-height: 44px; padding: 0.5rem 0; }}
    dl {{ display: grid; grid-template-columns: max-content minmax(0, 1fr);
      gap: 0.5rem var(--space); }}
    dt, .hint {{ color: var(--muted); }}
    dd {{ margin: 0; overflow-wrap: anywhere; }}
    textarea {{ width: 100%; min-height: 6rem; padding: 0.75rem; margin: 0.5rem 0;
      border: 1px solid var(--line); border-radius: var(--radius);
      background: var(--surface); color: var(--ink); font: inherit; }}
    #health, #stored {{ margin: 2rem 0; }}
    code {{ overflow-wrap: anywhere; }}
    @media (max-width: 560px) {{
      main {{ margin-top: 1.5rem; }}
      .connect {{ grid-template-columns: minmax(0, 1fr); gap: var(--space); }}
      .connect > :last-child {{ grid-row: 1; }}
      .button {{ width: 100%; text-align: center; }}
      .qr {{ max-width: 240px; }}
    }}
  </style>
</head>
<body>
  <main data-expires="{html.escape(expires_at)}"
    data-state="{state}">
    <h1 id="heading">{title}</h1>
    <p id="progress" role="status">{description}</p>
    {pending}
    <section id="health"{" hidden" if not paired or stored or bundle is None else ""}>
      <h2>Choose data and start syncing</h2>
      <p>Tap <strong>Allow Health Access</strong> and choose the Apple Health
        data you want the app to read, one kind at a time. Then turn on
        <strong>Automatic Sync</strong> to send it to your computer.
        The app cannot change your Apple Health data.</p>
      <p>To send available records now, tap <strong>Sync Now</strong>.
        Keep your computer awake and connected. If no records arrive,
        check the app's Health access and sync settings.</p>
    </section>
    <section id="stored"{" hidden" if not stored or bundle is None else ""}>
      <h2>Read your stored data</h2>
      <p>Your setup terminal shows the exact command to list the saved kinds of
        data and their dates. Run that command on the computer where you ran setup.</p>
      <p>To ask AI about these records, give your AI command access to that computer
        and the Health Bridge Skill.</p>
      <p class="hint">New records may arrive later; your iPhone controls background
        sync timing. Check the saved dates before asking about a recent period.</p>
    </section>
    <p class="hint" id="privacy">{html.escape(warning)}</p>
    <noscript><p>Reload this page to check progress. If you opened a saved HTML file,
      return to your setup terminal and rerun the same setup command to check
      instead.</p></noscript>
  </main>
  <script>
    const main = document.querySelector('main');
    const heading = document.getElementById('heading');
    const statusText = document.getElementById('progress');
    const health = document.getElementById('health');
    const stored = document.getElementById('stored');
    const messages = {json.dumps(PROGRESS_COPY)};
    const hosted = /^\\/setup\\/[a-f0-9]{{64}}$/.test(location.pathname);
    let finished = ['received', 'unavailable'].includes(main.dataset.state);
    let timer;
    let controller;
    function unavailable(message, terminal = false) {{
      const pending = document.getElementById('pending');
      if (pending) pending.hidden = true;
      health.hidden = true;
      stored.hidden = true;
      heading.textContent = 'Cannot check progress yet';
      statusText.textContent = message;
      if (terminal) finished = true;
    }}
    function showProgress(state) {{
      const paired = state.pairing_status === 'paired';
      const received = state.data_receipt_status === 'received';
      const pending = document.getElementById('pending');
      if (paired && pending) pending.remove();
      else if (pending) pending.hidden = false;
      health.hidden = !paired || received;
      stored.hidden = !received;
      const stateName = received ? 'received' : paired ? 'paired' : 'pending';
      [heading.textContent, statusText.textContent] = messages[stateName];
      finished = received;
    }}
    async function poll() {{
      clearTimeout(timer);
      if (!hosted || finished || document.hidden || controller) return;
      if (Date.now() >= Date.parse(main.dataset.expires)) {{
        unavailable(messages.unavailable[1], true);
        return;
      }}
      controller = new AbortController();
      const timeout = setTimeout(() => controller?.abort(), 4000);
      try {{
        const response = await fetch(location.pathname, {{
          headers: {{Accept: 'application/json'}}, cache: 'no-store',
          credentials: 'omit', signal: controller.signal
        }});
        if (response.status === 404) {{
          unavailable(messages.unavailable[1], true);
        }} else if (!response.ok) {{
          unavailable('Health Bridge could not check for saved records. ' +
            'Keep your computer awake. This page will retry automatically.');
        }} else {{
          const state = await response.json();
          if (!['pending', 'paired'].includes(state.pairing_status) ||
              !['not_received', 'received'].includes(state.data_receipt_status) ||
              (state.pairing_status === 'pending' &&
               state.data_receipt_status === 'received')) {{
            throw new Error('Invalid progress');
          }}
          showProgress(state);
        }}
      }} catch (_) {{
        unavailable('Cannot reach your computer. Keep it awake and connected. ' +
          'If you use Tailscale, turn it on on both devices. ' +
          'This page will retry automatically.');
      }} finally {{
        clearTimeout(timeout);
        controller = null;
        if (!finished && !document.hidden) timer = setTimeout(poll, 5000);
      }}
    }}
    document.addEventListener('visibilitychange', () => {{
      clearTimeout(timer);
      if (document.hidden) controller?.abort();
      else void poll();
    }});
    document.getElementById('copy-link')?.addEventListener('click', async () => {{
      const field = document.getElementById('pairing-url');
      const button = document.getElementById('copy-link');
      const result = document.getElementById('copy-result');
      button.disabled = true;
      let copied = false;
      try {{ await navigator.clipboard.writeText(field.value); copied = true; }}
      catch (_) {{
        field.focus(); field.select();
        try {{ copied = document.execCommand('copy'); }} catch (_) {{ copied = false; }}
      }}
      result.textContent = copied ? 'Setup link copied.' :
        'Could not copy automatically. Select the setup link and copy it manually.';
      button.disabled = false;
    }});
    if (hosted) void poll();
    else document.getElementById('privacy').textContent +=
      ' This saved HTML file cannot show live progress. ' +
      'Return to your setup terminal and rerun the same setup command ' +
      'to check for saved records.';
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
