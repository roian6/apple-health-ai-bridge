# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run: python scripts/verify-npm-release.py RELEASE_JSON COMMIT PACKAGE_SHA256."""

import hashlib
import json
import re
import sys
import tarfile
from pathlib import Path


def main() -> None:
    release = json.loads(Path(sys.argv[1]).read_text())
    metadata = json.loads(Path("release-metadata.json").read_text())
    node = metadata["node_launcher"]
    artifact = node["artifact"]
    version = metadata["release_version"]
    tag = f"receiver-v{version}"
    expected_files = {
        "release-metadata.json",
        "SHA256SUMS",
        artifact["filename"],
        f"apple_health_ai_bridge-{version}-py3-none-any.whl",
        f"apple_health_ai_bridge-{version}.tar.gz",
        f"HealthBridgeMailboxAckPublisher-{version}.zip",
        f"HealthBridgeMailboxAckPublisher-{version}.manifest.json",
    }
    checksums = Path("SHA256SUMS").read_text().splitlines()
    matched = [
        re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)", line)
        for line in checksums
    ]
    if any(item is None for item in matched):
        sys.exit("Invalid checksum file paths")
    names = [item.group(2) for item in matched if item is not None]
    if len(set(names)) != len(names) or set(names) != expected_files - {"SHA256SUMS"}:
        sys.exit("Checksum file set mismatch")
    if (
        release["tag_name"] != tag
        or metadata["git"]["tag"] != tag
        or metadata["git"]["commit"] != sys.argv[2]
        or {a["name"] for a in release["assets"]} != expected_files
    ):
        sys.exit("Release source or exact file set mismatch")
    package = Path(artifact["filename"])
    if (
        hashlib.sha256(package.read_bytes()).hexdigest() != artifact["sha256"]
        or artifact["sha256"] != sys.argv[3]
        or package.stat().st_size != artifact["bytes"]
    ):
        sys.exit("Packed npm artifact identity mismatch")
    expected_members = {
        "package/package.json",
        "package/backend-pin.json",
        "package/health-bridge.mjs",
        "package/skills/health-bridge/SKILL.md",
    }
    with tarfile.open(package) as archive:
        members = archive.getmembers()
        if (
            len(members) != len(expected_members)
            or {m.name for m in members} != expected_members
            or not all(m.isfile() for m in members)
        ):
            sys.exit("Packed npm payload mismatch")
        package_file = archive.extractfile("package/package.json")
        pin_file = archive.extractfile("package/backend-pin.json")
        if package_file is None or pin_file is None:
            sys.exit("Packed npm metadata missing")
        manifest, pin = json.load(package_file), json.load(pin_file)
    wheel = Path(f"apple_health_ai_bridge-{version}-py3-none-any.whl")
    expected_pin = {
        "name": "apple-health-ai-bridge",
        "version": version,
        "sha256": hashlib.sha256(wheel.read_bytes()).hexdigest(),
        "url": f"https://github.com/roian6/apple-health-ai-bridge/releases/download/{tag}/{wheel.name}",
    }
    if (
        pin != expected_pin
        or manifest.get("private") is True
        or manifest["name"] != node["package"]
        or manifest["version"] != node["version"]
        or manifest["bin"] != {"health-bridge": "health-bridge.mjs"}
    ):
        sys.exit("Publication metadata or wheel pin mismatch")
    _ = sys.stdout.write("Exact npm artifact and wheel binding verified\n")


if __name__ == "__main__":
    main()
