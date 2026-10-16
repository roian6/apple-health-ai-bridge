import hashlib
import io
import json
import subprocess
import sys
import tarfile
from pathlib import Path


def test_npm_gate_rejects_checksum_paths_outside_exact_asset_set(
    tmp_path: Path,
) -> None:
    version = "1.1.3"
    wheel = tmp_path / f"apple_health_ai_bridge-{version}-py3-none-any.whl"
    _ = wheel.write_bytes(b"synthetic registry fixture; not a release wheel")
    package = tmp_path / "apple-health-ai-bridge-0.1.0.tgz"
    pin = {
        "name": "apple-health-ai-bridge",
        "version": version,
        "sha256": hashlib.sha256(wheel.read_bytes()).hexdigest(),
        "url": f"https://github.com/roian6/apple-health-ai-bridge/releases/download/receiver-v{version}/{wheel.name}",
    }
    manifest = {
        "name": "apple-health-ai-bridge",
        "version": "0.1.0",
        "bin": {"health-bridge": "health-bridge.mjs"},
    }
    with tarfile.open(package, "w:gz") as archive:
        for name, content in {
            "package.json": json.dumps(manifest),
            "backend-pin.json": json.dumps(pin),
            "health-bridge.mjs": "fixture",
            "skills/health-bridge/SKILL.md": "fixture",
        }.items():
            data = content.encode()
            member = tarfile.TarInfo("package/" + name)
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
    digest = hashlib.sha256(package.read_bytes()).hexdigest()
    metadata = {
        "release_version": version,
        "git": {"tag": "receiver-v1.1.3", "commit": "a" * 40},
        "node_launcher": {
            "package": manifest["name"],
            "version": "0.1.0",
            "artifact": {
                "filename": package.name,
                "sha256": digest,
                "bytes": package.stat().st_size,
            },
        },
    }
    _ = (tmp_path / "release-metadata.json").write_text(json.dumps(metadata))
    files = [
        package.name,
        wheel.name,
        "release-metadata.json",
        "SHA256SUMS",
        f"apple_health_ai_bridge-{version}.tar.gz",
        f"HealthBridgeMailboxAckPublisher-{version}.zip",
        f"HealthBridgeMailboxAckPublisher-{version}.manifest.json",
    ]
    release = {
        "tag_name": "receiver-v1.1.3",
        "assets": [{"name": name} for name in files],
    }
    _ = (tmp_path / "release.json").write_text(json.dumps(release))
    _ = (tmp_path / "SHA256SUMS").write_text("0" * 64 + "  ../../outside-fixture\n")
    script = Path(__file__).parents[2] / "scripts/verify-npm-release.py"
    completed = subprocess.run(
        [sys.executable, str(script), str(tmp_path / "release.json"), "a" * 40, digest],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
    )
    assert completed.returncode != 0
    assert "checksum" in completed.stderr.lower()
