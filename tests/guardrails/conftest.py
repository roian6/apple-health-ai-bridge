import hashlib
import io
import json
import plistlib
import shutil
import tarfile
from pathlib import Path

import pytest
from pydantic import TypeAdapter

from tests.guardrails.release_version_fixtures import (
    ReleaseTree,
    commit_release_tree,
    init_release_repo,
    write_release_tree,
)

ROOT = Path(__file__).parents[2]


@pytest.fixture
def receiver_release_repo(tmp_path: Path, request: pytest.FixtureRequest) -> Path:
    repo = init_release_repo(tmp_path)
    write_release_tree(
        repo,
        ReleaseTree(
            receiver_version="1.1.1",
            release_tag="receiver-v1.1.1",
            release_scope="receiver",
            ios_version="1.1.0",
            ios_build="39",
            batch_version="1.0.0",
        ),
    )
    helper = ROOT / "macos/HealthBridgeMailboxAckPublisher"
    _ = shutil.copytree(helper, repo / helper.relative_to(ROOT), dirs_exist_ok=True)
    helper_info = repo / helper.relative_to(ROOT) / "Info.plist"
    with helper_info.open("rb") as handle:
        info = TypeAdapter(dict[str, str | bool]).validate_python(plistlib.load(handle))
    info["CFBundleShortVersionString"] = "1.1.1"
    _ = helper_info.write_bytes(plistlib.dumps(info))
    if getattr(request, "param", "v3") == "v4":
        _ = shutil.copytree(ROOT / "node-cli", repo / "node-cli")
        _ = shutil.copytree(
            ROOT / "skills/health-bridge", repo / "skills/health-bridge"
        )
    _ = commit_release_tree(repo, "synthetic receiver release")
    return repo


def write_node_archive(repo: Path, dist: Path, mutation: str = "") -> Path | None:
    package_path = repo / "node-cli/package.json"
    if not package_path.exists():
        return None
    package = TypeAdapter(dict[str, object]).validate_json(package_path.read_text())
    wheel = dist / "apple_health_ai_bridge-1.1.1-py3-none-any.whl"
    release_url = "https://github.com/roian6/apple-health-ai-bridge/releases/download"
    pin = {
        "name": "apple-health-ai-bridge",
        "version": "1.1.1",
        "sha256": hashlib.sha256(wheel.read_bytes()).hexdigest(),
        "url": f"{release_url}/receiver-v1.1.1/{wheel.name}",
    }
    if mutation.startswith("pin-"):
        pin[mutation.removeprefix("pin-")] = "incorrect"
    if mutation == "package":
        package["version"] = "9.9.9"
    if mutation == "runtime":
        package["engines"] = {"node": ">=99"}
    files = {
        "package/package.json": json.dumps(package).encode(),
        "package/backend-pin.json": json.dumps(pin).encode(),
        "package/health-bridge.mjs": (repo / "node-cli/health-bridge.mjs").read_bytes(),
        "package/skills/health-bridge/SKILL.md": (
            repo / "skills/health-bridge/SKILL.md"
        ).read_bytes(),
    }
    if mutation in {"launcher-body", "skill-body"}:
        name = (
            "package/health-bridge.mjs"
            if mutation == "launcher-body"
            else "package/skills/health-bridge/SKILL.md"
        )
        files[name] += b"\nsynthetic tampering\n"
    if mutation == "extra-payload":
        files["package/extra"] = b"extra"
    archive = dist / "apple-health-ai-bridge-0.1.0.tgz"
    with tarfile.open(archive, "w:gz") as packed:
        for name, content in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(content)
            packed.addfile(member, io.BytesIO(content))
    return archive
