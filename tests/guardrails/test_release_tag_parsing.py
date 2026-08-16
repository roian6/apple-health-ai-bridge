import hashlib
import json
import subprocess
import sys
from pathlib import Path

import pytest

from tests.guardrails.release_version_fixtures import (
    ReleaseTree,
    commit_release_tree,
    init_release_repo,
    write_release_tree,
)

ROOT = Path(__file__).parents[2]
RELEASE_TOOL = ROOT / "scripts/release_tools.py"


def _run_release_tool(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(RELEASE_TOOL), *args],
        cwd=ROOT,
        capture_output=True,
        check=False,
        text=True,
    )


@pytest.mark.parametrize(
    ("tag", "version", "prerelease"),
    [
        ("v1.0.0", "1.0.0", False),
        ("v1.0.1", "1.0.1", False),
        ("receiver-v1.0.2", "1.0.2", False),
        ("receiver-v0.3.4", "0.3.4", True),
    ],
)
def test_tag_info_uses_canonical_receiver_tag_parser(
    tag: str,
    version: str,
    prerelease: bool,
) -> None:
    # Given: a supported historical or component-scoped Receiver/CLI tag.

    # When: the workflow-facing parser reports its canonical identity.
    completed = _run_release_tool("tag-info", "--tag", tag)

    # Then: version and prerelease state come from one parsed representation.
    assert completed.returncode == 0, completed.stderr
    assert json.loads(completed.stdout) == {
        "prerelease": prerelease,
        "tag": tag,
        "version": version,
    }


@pytest.mark.parametrize(
    "tag",
    [
        "v0.1.0",
        "receiver-v1.0.1",
        "receiver-v1.0",
        "receiver-v1.0.2-beta.1",
        "main",
    ],
)
def test_tag_info_rejects_noncanonical_receiver_tags(tag: str) -> None:
    # Given: a malformed or noncanonical Receiver/CLI tag.

    # When: the canonical parser evaluates it.
    completed = _run_release_tool("tag-info", "--tag", tag)

    # Then: parsing fails through the release-input boundary.
    assert completed.returncode == 1
    assert "Receiver/CLI release tag is not canonical" in completed.stderr


def _release_state_fixture(
    tmp_path: Path,
    *,
    prerelease: bool,
) -> tuple[Path, Path, Path]:
    repo = init_release_repo(tmp_path)
    write_release_tree(
        repo,
        ReleaseTree(
            receiver_version="0.1.0",
            release_tag="receiver-v0.1.0",
            release_scope="receiver",
            ios_version="1.0.0",
            ios_build="15",
            batch_version="1.0.0",
        ),
    )
    _ = commit_release_tree(repo, "synthetic receiver v0 release")
    dist = tmp_path / "dist"
    dist.mkdir()
    wheel = dist / "apple_health_ai_bridge-0.1.0-py3-none-any.whl"
    source = dist / "apple_health_ai_bridge-0.1.0.tar.gz"
    _ = wheel.write_bytes(b"synthetic wheel\n")
    _ = source.write_bytes(b"synthetic source\n")
    metadata = dist / "release-metadata.json"
    manifest = _run_release_tool(
        "manifest",
        "--repo",
        str(repo),
        "--dist-dir",
        str(dist),
        "--tag",
        "receiver-v0.1.0",
        "--tag-object",
        "3" * 40,
        "--commit",
        "1" * 40,
        "--tree",
        "2" * 40,
        "--output",
        str(metadata),
    )
    assert manifest.returncode == 0, manifest.stderr
    notes = dist / "release-notes.md"
    _ = notes.write_bytes(
        (repo / ".github/release/notes-receiver-v0.1.0.md").read_bytes()
    )
    checksums = dist / "SHA256SUMS"
    _ = checksums.write_text("synthetic checksums\n", encoding="utf-8")
    assets = [
        {
            "digest": f"sha256:{hashlib.sha256(path.read_bytes()).hexdigest()}",
            "name": path.name,
            "size": path.stat().st_size,
            "state": "uploaded",
        }
        for path in (checksums, wheel, source, metadata)
    ]
    release_json = tmp_path / "release.json"
    _ = release_json.write_text(
        json.dumps(
            {
                "assets": assets,
                "body": notes.read_text(encoding="utf-8"),
                "draft": True,
                "name": "receiver-v0.1.0",
                "prerelease": prerelease,
                "tag_name": "receiver-v0.1.0",
            }
        ),
        encoding="utf-8",
    )
    return repo, dist, release_json


@pytest.mark.parametrize(
    ("prerelease", "expected_returncode"),
    [(True, 0), (False, 1)],
)
def test_receiver_v_zero_draft_verification_uses_parsed_major(
    tmp_path: Path,
    prerelease: bool,
    expected_returncode: int,
) -> None:
    # Given: exact draft metadata for a receiver-v0.x release.
    repo, dist, release_json = _release_state_fixture(
        tmp_path,
        prerelease=prerelease,
    )

    # When: the release-state verifier checks prerelease identity.
    completed = _run_release_tool(
        "verify-draft",
        "--repo",
        str(repo),
        "--dist-dir",
        str(dist),
        "--release-json",
        str(release_json),
        "--notes-file",
        str(dist / "release-notes.md"),
        "--tag",
        "receiver-v0.1.0",
        "--tag-object",
        "3" * 40,
        "--commit",
        "1" * 40,
        "--tree",
        "2" * 40,
    )

    # Then: true is required for every canonical receiver-v0.x tag.
    assert completed.returncode == expected_returncode
    if expected_returncode == 0:
        assert completed.stderr == ""
    else:
        assert "GitHub draft release metadata is not exact" in completed.stderr
