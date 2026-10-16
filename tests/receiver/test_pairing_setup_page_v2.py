import json
import subprocess
from pathlib import Path

import pytest

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
    assert "Scan the QR code with iPhone Camera" in page
    assert "Health Bridge for AI (companion app)" in page
    assert "HealthBridge Companion" not in page
    assert "Allow Health Access" in page
    assert "Automatic Sync" in page
    assert "Review Permissions" not in page
    assert "health-bridge query synced-metrics" not in page
    assert "health-bridge setup" not in page
    assert "Your setup terminal shows the exact command" in page
    assert "then return here" in page
    assert "To connect with a code" in page
    assert "health.example.test" in page
    assert "ABCDE-FGHJK-MNPQR" in page
    assert bundle.expires_at in page
    assert bundle.invitation_secret not in page
    assert "Token prefix" not in page
    assert "bearer-token" not in page
    assert "single-use invitation" in page
    assert "Sharing it before use" in page
    assert "then delete the setup artifact" not in page
    assert "Delete this setup page after pairing" not in page


@pytest.mark.parametrize(
    "mode", ["pending", "expired", "received", "offline", "read_failure", "revoked"]
)
def test_connection_page_polling_and_clipboard(tmp_path: Path, mode: str) -> None:
    bundle = create_receiver_pairing_invitation_bundle(
        tmp_path / "receiver.sqlite",
        label="synthetic",
        receiver_url="https://health.example.test/v1/batches",
    )
    page = render_pairing_setup_page(bundle, pairing_deep_link(bundle))
    script = page.split("<script>", 1)[1].split("</script>", 1)[0]
    harness = r"""
const {strict: assert} = require('node:assert');
const vm = require('node:vm');
const {script, mode} = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
const events = {}, timers = new Map(), requests = [];
const elements = new Map();
for (const id of ['heading', 'progress', 'health', 'stored', 'pending', 'privacy',
                  'copy-link', 'pairing-url', 'copy-result']) {
  elements.set(id, {hidden: false, textContent: '', value: 'synthetic-link',
    focus() {}, select() {}, remove() { elements.delete(id); },
    addEventListener(name, callback) { this[name] = callback; }});
}
const main = {dataset: {state: mode === 'received' ? 'received' : 'pending',
  expires: mode === 'expired' ? '2000-01-01T00:00:00Z' : '2099-01-01T00:00:00Z'}};
const document = {hidden: false, querySelector: () => main,
  getElementById: id => elements.get(id), execCommand: () => false,
  addEventListener: (name, callback) => { events[name] = callback; }};
const location = {pathname: '/setup/' + 'a'.repeat(64)};
let next = {pairing_status: 'pending', data_receipt_status: 'not_received'};
let timerId = 0;
const context = {document, location, navigator: {}, AbortController, Date,
  setTimeout: (callback, ms) => {
    timers.set(++timerId, {callback, ms}); return timerId;
  },
  clearTimeout: id => timers.delete(id),
  fetch: async (url, options) => {
    requests.push({url, options});
    if (mode === 'offline') throw new Error('offline');
    const status = mode === 'revoked' ? 404 :
      mode === 'read_failure' && requests.length === 1 ? 503 : 200;
    return {status, ok: status === 200, json: async () => next};
  }};
vm.runInNewContext(script, context);
const settle = () => new Promise(resolve => setImmediate(resolve));
(async () => {
  await settle();
  if (['expired', 'received'].includes(mode)) {
    assert.equal(requests.length, 0); assert.equal(timers.size, 0); return;
  }
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, location.pathname);
  assert.equal(requests[0].options.headers.Accept, 'application/json');
  if (mode === 'revoked') {
    assert.equal(timers.size, 0);
    assert.equal(elements.get('pending').hidden, true); return;
  }
  assert.deepEqual([...timers.values()].map(t => t.ms), [5000]);
  if (['offline', 'read_failure'].includes(mode)) {
    assert.equal(elements.get('pending').hidden, true);
    assert.equal(elements.get('stored').hidden, true);
    if (mode === 'offline') return;
    [...timers.values()][0].callback(); await settle();
    assert.equal(requests.length, 2);
    assert.equal(elements.get('pending').hidden, false);

  }
  document.hidden = true; events.visibilitychange();
  assert.equal(timers.size, 0);
  assert.equal(requests.length, mode === 'read_failure' ? 2 : 1);
  const copy = elements.get('copy-link');
  await copy.click();
  assert.match(elements.get('copy-result').textContent, /manually/);
  context.navigator.clipboard = {writeText: async () => {}};
  await copy.click();
  assert.match(elements.get('copy-result').textContent, /copied/);
  next = {pairing_status: 'paired', data_receipt_status: 'not_received'};
  document.hidden = false; events.visibilitychange(); await settle();
  assert.equal(elements.has('pending'), false);
  assert.equal(elements.get('health').hidden, false);
  next = {pairing_status: 'paired', data_receipt_status: 'received'};
  [...timers.values()][0].callback(); await settle();
  assert.equal(elements.get('stored').hidden, false);
  assert.equal(elements.get('health').hidden, true);
  assert.equal(timers.size, 0);
})().catch(error => { console.error(error); process.exitCode = 1; });
"""
    result = subprocess.run(
        ["node", "-e", harness],
        input=json.dumps({"script": script, "mode": mode}),
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 0, result.stderr
