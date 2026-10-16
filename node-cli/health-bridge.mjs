#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const uvAssets = {
  'linux-arm64': ['aarch64-unknown-linux-gnu', 'c4958f729e216f1610632574ed927b8cf0af1bd02cb88cb30d948571727aee43'],
  'linux-x64': ['x86_64-unknown-linux-gnu', 'f3b623eb0e6141a7053d571d59a0bdc341e0f238ea8f5f0b4815ddbec9a2a296'],
  'darwin-arm64': ['aarch64-apple-darwin', '4333af5c0730d94323a7819bbdf87ce92dd07fc857d67fff0059e0fca31b5c02'],
  'darwin-x64': ['x86_64-apple-darwin', '9836c1440b0bd6aa5f81793648a339bd01d593b7b8f575de3b855dae4ab64654'],
};

async function verifiedBytes(url, hash) {
  let bytes;
  if (new URL(url).protocol === 'file:') bytes = readFileSync(new URL(url));
  else {
    const response = await fetch(url);
    if (!response.ok) throw new Error('Artifact download failed');
    bytes = Buffer.from(await response.arrayBuffer());
  }
  if (createHash('sha256').update(bytes).digest('hex') !== hash) throw new Error('Artifact checksum mismatch');
  return bytes;
}

function run(command, args, env) {
  const result = spawnSync(command, args, { env, stdio: 'inherit', shell: false });
  if (result.error) throw new Error('Unable to execute prepared tool');
  if (result.signal) process.kill(process.pid, result.signal);
  return result.status ?? 1;
}

async function prepareUv(root) {
  if (spawnSync('uv', ['--version'], { stdio: 'ignore', shell: false }).status === 0) return 'uv';
  const [target, hash] = uvAssets[`${process.platform}-${process.arch}`];
  const directory = join(root, 'uv', '0.11.14');
  const archive = join(directory, 'uv.tar.gz');
  const binary = join(directory, `uv-${target}`, 'uv');
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const bytes = existsSync(archive)
    ? await verifiedBytes(new URL(`file://${archive}`).href, hash)
    : await verifiedBytes(`https://github.com/astral-sh/uv/releases/download/0.11.14/uv-${target}.tar.gz`, hash);
  writeFileSync(archive, bytes, { mode: 0o600 });
  if (run('/usr/bin/tar', ['-xzf', archive, '-C', directory, `uv-${target}/uv`], process.env) !== 0) throw new Error('uv extraction failed');
  return binary;
}

async function verifyBackend(base, pin, wheel) {
  const libraries = readdirSync(join(base, 'lib')).filter(name => /^python3\./.test(name));
  const metadataName = `apple_health_ai_bridge-${pin.version}.dist-info`;
  const info = libraries.map(name => join(base, 'lib', name, 'site-packages', metadataName)).find(existsSync);
  if (!info) throw new Error('Installed backend version mismatch');
  const metadata = readFileSync(join(info, 'METADATA'), 'utf8');
  const direct = JSON.parse(readFileSync(join(info, 'direct_url.json'), 'utf8'));
  const recordedHash = direct.archive_info?.hashes?.sha256;
  const pinnedSource = direct.url === `${pin.url}#sha256=${pin.sha256}`;
  if (!metadata.split('\n').includes(`Version: ${pin.version}`)) throw new Error('Installed backend version mismatch');
  if (recordedHash || pinnedSource) {
    if (recordedHash && recordedHash !== pin.sha256) throw new Error('Installed backend provenance mismatch');
    return;
  }
  // uv can omit archive hashes. Verify installed bytes against the retained pinned wheel.
  const wheelURL = pathToFileURL(wheel);
  if (![wheelURL.href, `${wheelURL.href}#sha256=${pin.sha256}`].includes(direct.url)) throw new Error('Installed backend provenance mismatch');
  await verifiedBytes(wheelURL.href, pin.sha256);
  const checked = spawnSync(join(base, 'bin', 'python'), ['-I', '-c', `
import pathlib, sys, zipfile
wheel, site = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
with zipfile.ZipFile(wheel) as archive:
    names = {n for n in archive.namelist() if not n.endswith('/')}
    for name in names:
        if name.endswith('.dist-info/RECORD'):
            continue
        target = site / name
        assert target.is_file() and not target.is_symlink()
        assert target.read_bytes() == archive.read(name)
    actual = {p.relative_to(site).as_posix() for p in (site / 'health_bridge').rglob('*.py')}
    assert actual == {n for n in names if n.startswith('health_bridge/') and n.endswith('.py')}
`, wheel, join(info, '..')], { stdio: 'ignore', shell: false });
  if (checked.error || checked.status !== 0) throw new Error('Installed backend provenance mismatch');
}

try {
  process.umask(0o077);
  if (!uvAssets[`${process.platform}-${process.arch}`]) throw new Error('Unsupported platform; Linux/macOS x64/arm64 required');
  const pin = JSON.parse(readFileSync(new URL('backend-pin.json', import.meta.url), 'utf8'));
  if (pin.name !== 'apple-health-ai-bridge' || !/^\d+\.\d+\.\d+$/.test(pin.version) || !/^[a-f0-9]{64}$/.test(pin.sha256)) throw new Error('Invalid packaged backend pin');
  const root = join(homedir(), '.local', 'share', 'apple-health-ai-bridge');
  const install = join(root, 'backends', pin.sha256);
  const toolDir = join(install, 'tools');
  const base = join(toolDir, pin.name);
  const backend = join(base, 'bin', 'health-bridge');
  const wheel = join(install, `apple_health_ai_bridge-${pin.version}-py3-none-any.whl`);
  if (!existsSync(backend)) {
    const bytes = await verifiedBytes(pin.url, pin.sha256);
    mkdirSync(install, { recursive: true, mode: 0o700 });
    writeFileSync(wheel, bytes, { mode: 0o600 });
    const uv = await prepareUv(root);
    const env = { ...process.env, PATH: [join(install, 'bin'), process.env.PATH].filter(Boolean).join(':'), UV_TOOL_DIR: toolDir, UV_TOOL_BIN_DIR: join(install, 'bin'), UV_PYTHON_INSTALL_DIR: join(root, 'python') };
    const status = run(uv, ['tool', 'install', '--no-config', '--python', '3.11', '--managed-python', `${pin.name} @ ${pathToFileURL(wheel).href}#sha256=${pin.sha256}`], env);
    if (status !== 0) process.exit(status);
  }
  await verifyBackend(base, pin, wheel);
  process.exitCode = run(backend, process.argv.slice(2), process.env);
} catch (error) {
  // Never include forwarded arguments, URLs, or backend setup material in errors.
  const safe = ['Artifact download failed', 'Artifact checksum mismatch', 'Unable to execute prepared tool', 'uv extraction failed', 'Installed backend version mismatch', 'Installed backend provenance mismatch', 'Invalid packaged backend pin', 'Unsupported platform; Linux/macOS x64/arm64 required'];
  console.error(safe.includes(error.message) ? error.message : 'Launcher preparation failed');
  process.exitCode = 1;
}
