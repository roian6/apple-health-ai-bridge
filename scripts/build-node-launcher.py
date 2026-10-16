#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run: python scripts/build-node-launcher.py WHEEL OUTPUT [--wheel-url URL]."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tomllib
import zipfile
from email.parser import BytesParser
from pathlib import Path
from typing import Final, TypedDict, cast
from urllib.parse import urlsplit

URL_ARG_COUNT: Final = 5


class Project(TypedDict):
    name: str
    version: str


def main() -> None:
    if len(sys.argv) not in (3, 5) or (
        len(sys.argv) == URL_ARG_COUNT and sys.argv[3] != "--wheel-url"
    ):
        sys.exit(__doc__)
    root = Path(__file__).resolve().parents[1]
    wheel = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    project = cast(
        "Project", tomllib.loads((root / "pyproject.toml").read_text())["project"]
    )
    version = project["version"]
    name = project["name"]
    expected = f"apple_health_ai_bridge-{version}-py3-none-any.whl"
    with zipfile.ZipFile(wheel) as archive:
        metadata_files = [
            n for n in archive.namelist() if n.endswith(".dist-info/METADATA")
        ]
        if len(metadata_files) != 1:
            sys.exit("Expected exactly one wheel distribution")
        metadata = BytesParser().parsebytes(archive.read(metadata_files[0]))
    if (
        wheel.name != expected
        or metadata["Name"] != name
        or metadata["Version"] != version
    ):
        sys.exit("Wheel metadata does not match pyproject")
    url = (
        sys.argv[4]
        if len(sys.argv) == URL_ARG_COUNT
        else f"https://github.com/roian6/apple-health-ai-bridge/releases/download/receiver-v{version}/{expected}"
    )
    parsed = urlsplit(url)
    if (
        parsed.fragment
        or parsed.username
        or parsed.password
        or parsed.scheme not in ("https", "http", "file")
    ):
        sys.exit("Expected an artifact URL without credentials or fragment")
    if parsed.scheme == "http" and parsed.hostname not in (
        "127.0.0.1",
        "localhost",
        "::1",
    ):
        sys.exit("HTTP is limited to loopback fixtures")
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    stage = output / "package"
    stage.mkdir(mode=0o700)
    for filename in ("package.json", "health-bridge.mjs"):
        _ = shutil.copyfile(root / "node-cli" / filename, stage / filename)
    (stage / "health-bridge.mjs").chmod(0o755)
    skill = stage / "skills/health-bridge/SKILL.md"
    skill.parent.mkdir(parents=True)
    _ = shutil.copyfile(root / "skills/health-bridge/SKILL.md", skill)
    with wheel.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    pin = {"name": name, "version": version, "url": url, "sha256": digest}
    _ = (stage / "backend-pin.json").write_text(json.dumps(pin, indent=2) + "\n")
    npm = shutil.which("npm")
    if npm is None:
        sys.exit("npm is required for packing")
    _ = subprocess.run(  # noqa: S603 - resolved npm executable, fixed argv, no shell.
        [npm, "pack", "--ignore-scripts", "--pack-destination", str(output)],
        cwd=stage,
        check=True,
    )


if __name__ == "__main__":
    main()
