import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, writeFileSync, copyFileSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';

test('registry package is publishable with unambiguous single-bin inference', () => {
  const metadata = JSON.parse(readFileSync(new URL('package.json', import.meta.url)));
  assert.notEqual(metadata.private, true);
  assert.equal(metadata.license, 'Apache-2.0');
  assert.deepEqual(Object.values(metadata.bin), ['health-bridge.mjs']);
  assert.equal(metadata.name, 'apple-health-ai-bridge');
});

function fixture(digest) {
  const root = mkdtempSync(join(tmpdir(), 'launcher-test-'));
  const wheel = join(root, 'apple_health_ai_bridge-1.1.2-py3-none-any.whl');
  writeFileSync(wheel, 'synthetic artifact');
  const hash = createHash('sha256').update(readFileSync(wheel)).digest('hex');
  const pin = { name: 'apple-health-ai-bridge', version: '1.1.2', sha256: digest ?? hash, url: pathToFileURL(wheel).href };
  writeFileSync(join(root, 'backend-pin.json'), JSON.stringify(pin));
  copyFileSync(new URL('health-bridge.mjs', import.meta.url), join(root, 'health-bridge.mjs'));
  const bin = join(root, 'bin');
  mkdirSync(bin);
  writeFileSync(join(bin, 'uv'), `#!${process.execPath}
const fs = require('node:fs'), p = require('node:path');
if (process.argv[2] === '--version') { console.log('uv fixture'); process.exit(0); }
fs.appendFileSync(p.join(process.env.HOME, 'installs'), JSON.stringify(process.argv.slice(2))+'\\n');
fs.writeFileSync(p.join(process.env.HOME, 'installer-path.json'), JSON.stringify({bin:process.env.UV_TOOL_BIN_DIR, path:process.env.PATH.split(p.delimiter)}));
const base = p.join(process.env.UV_TOOL_DIR, 'apple-health-ai-bridge');
const info = p.join(base, 'lib/python3.11/site-packages/apple_health_ai_bridge-1.1.2.dist-info');
fs.mkdirSync(info, {recursive:true}); fs.mkdirSync(p.join(base, 'bin'), {recursive:true});
fs.writeFileSync(p.join(info, 'METADATA'), 'Name: apple-health-ai-bridge\\nVersion: 1.1.2\\n');
fs.writeFileSync(p.join(info, 'direct_url.json'), JSON.stringify({archive_info:{hashes:{sha256:'${hash}'}}}));
fs.writeFileSync(p.join(base, 'bin/health-bridge'), '#!${process.execPath}\\nconsole.log(JSON.stringify(process.argv.slice(2))); process.exit(23);', {mode:0o700});
`, { mode: 0o700 });
  return { root, env: { ...process.env, HOME: root, PATH: bin }, run: join(root, 'health-bridge.mjs') };
}

test('prepares a pinned backend and forwards literal argv and exit status, then reuses it', () => {
  const f = fixture();
  const args = ['query', 'space here', '$(touch nope); *', ''];
  const first = spawnSync(process.execPath, [f.run, ...args], { env: f.env, encoding: 'utf8' });
  assert.equal(first.status, 23, first.stderr);
  assert.deepEqual(JSON.parse(first.stdout), args);
  const install = JSON.parse(readFileSync(join(f.root, 'installs'), 'utf8').trim());
  assert.equal(install[0], 'tool');
  assert.equal(install[1], 'install');
  assert.match(install.at(-1), /#sha256=[a-f0-9]{64}$/);
  const childPath = JSON.parse(readFileSync(join(f.root, 'installer-path.json'), 'utf8'));
  assert.ok(childPath.path.includes(childPath.bin), 'Installer must not request a manual PATH change');
  const second = spawnSync(process.execPath, [f.run, ...args], { env: f.env, encoding: 'utf8' });
  assert.equal(second.status, 23, second.stderr);
  assert.equal(readFileSync(join(f.root, 'installs'), 'utf8').trim().split('\n').length, 1);
});

test('refuses an artifact with a different digest before backend preparation', () => {
  const f = fixture('0'.repeat(64));
  const result = spawnSync(process.execPath, [f.run, '--help'], { env: f.env, encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /checksum mismatch/);
  assert.throws(() => readFileSync(join(f.root, 'installs')));
});

test('creates private installation parents with a group-writable caller umask', () => {
  const f = fixture();
  const result = spawnSync(process.execPath, ['--input-type=module', '-e',
    `process.umask(0o002); await import(${JSON.stringify(pathToFileURL(f.run).href)});`,
  ], { env: f.env, encoding: 'utf8' });
  assert.equal(result.status, 23, result.stderr);
  for (const path of ['.local', '.local/share', '.local/share/apple-health-ai-bridge']) {
    assert.equal(statSync(join(f.root, path)).mode & 0o077, 0, path);
  }
});
