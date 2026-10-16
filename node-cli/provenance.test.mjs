import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';

// Tiny synthetic wheel exercises the exact empty archive_info emitted by uv 0.11.14.
// Public CLI/MCP behavior is separately exercised with the actual built product wheel.
function installedFixture() {
  const root = mkdtempSync(join(tmpdir(), 'launcher-provenance-'));
  const python = process.env.UV_PYTHON || 'python3';
  const wheel = join(root, 'apple_health_ai_bridge-1.1.2-py3-none-any.whl');
  const created = spawnSync(python, ['-c', `
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('health_bridge/__init__.py', '# synthetic fixture\\n')
    z.writestr('apple_health_ai_bridge-1.1.2.dist-info/METADATA', 'Name: apple-health-ai-bridge\\nVersion: 1.1.2\\n')
    z.writestr('apple_health_ai_bridge-1.1.2.dist-info/RECORD', '')
`, wheel], { encoding: 'utf8' });
  assert.equal(created.status, 0, created.stderr);
  const sha256 = createHash('sha256').update(readFileSync(wheel)).digest('hex');
  const install = join(root, '.local/share/apple-health-ai-bridge/backends', sha256);
  const base = join(install, 'tools/apple-health-ai-bridge');
  const site = join(base, 'lib/python3.11/site-packages');
  const retained = join(install, 'apple_health_ai_bridge-1.1.2-py3-none-any.whl');
  mkdirSync(site, { recursive: true });
  mkdirSync(join(base, 'bin'));
  copyFileSync(wheel, retained);
  const unpacked = spawnSync(python, ['-c', 'import sys,zipfile;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])', wheel, site]);
  assert.equal(unpacked.status, 0);
  const direct = join(site, 'apple_health_ai_bridge-1.1.2.dist-info/direct_url.json');
  writeFileSync(direct, JSON.stringify({ url: `${pathToFileURL(retained).href}#sha256=${sha256}`, archive_info: {} }));
  // Use the selected interpreter directly; no product imports in the verification helper.
  const linked = spawnSync(python, ['-c', 'import os,sys;os.symlink(sys.executable,sys.argv[1])', join(base, 'bin/python')]);
  assert.equal(linked.status, 0);
  writeFileSync(join(base, 'bin/health-bridge'), `#!${process.execPath}\nprocess.exit(23);\n`, { mode: 0o700 });
  writeFileSync(join(root, 'backend-pin.json'), JSON.stringify({ name: 'apple-health-ai-bridge', version: '1.1.2', sha256, url: pathToFileURL(wheel).href }));
  copyFileSync(new URL('health-bridge.mjs', import.meta.url), join(root, 'health-bridge.mjs'));
  return { root, site, retained, direct, run: () => spawnSync(process.execPath, [join(root, 'health-bridge.mjs'), '--help'], { env: { ...process.env, HOME: root }, encoding: 'utf8' }) };
}

test('uv hashless metadata accepts only the retained pinned wheel and exact installed bytes', () => {
  const fixture = installedFixture();
  assert.equal(fixture.run().status, 23);
  assert.equal(fixture.run().status, 23);
  writeFileSync(join(fixture.site, 'health_bridge/__init__.py'), '# altered fixture\n');
  const result = fixture.run();
  assert.equal(result.status, 1);
  assert.match(result.stderr, /provenance mismatch/);
});

test('hashless metadata cannot substitute an extra module, different URL or changed wheel', () => {
  for (const mutation of ['module', 'url', 'wheel']) {
    const fixture = installedFixture();
    if (mutation === 'module') writeFileSync(join(fixture.site, 'health_bridge/extra.py'), '# fixture\n');
    if (mutation === 'url') writeFileSync(fixture.direct, JSON.stringify({ url: 'file:///different.whl', archive_info: {} }));
    if (mutation === 'wheel') writeFileSync(fixture.retained, 'changed');
    const result = fixture.run();
    assert.equal(result.status, 1, mutation);
    assert.match(result.stderr, /provenance mismatch|checksum mismatch/);
  }
});
