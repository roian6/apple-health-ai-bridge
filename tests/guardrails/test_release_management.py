import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import ClassVar, Final, Literal, cast

import pytest
from pydantic import BaseModel, ConfigDict, JsonValue, TypeAdapter

from health_bridge import __version__
from tests.guardrails.test_release_recovery import recovery_transport

ROOT = Path(__file__).parents[2]
# Reviewed published baseline: receiver-v1.1.5 at 6940fe41, not the source candidate.
PUBLISHED_RECEIVER_VERSION: Final = "1.1.5"
RELEASE_TOOL = ROOT / "scripts/release_tools.py"
RELEASE_WORKFLOW = ROOT / ".github/workflows/release.yml"
RELEASE_NOTES = ROOT / ".github/release/notes-receiver-v1.1.1.md"
HISTORICAL_V101_RELEASE_NOTES = ROOT / ".github/release/notes-v1.0.1.md"
RELEASE_CRITERIA = ROOT / ".github/release/criteria.md"
COMPONENT_VERSIONS = ROOT / "component-versions.json"
VERSIONING_DOC = ROOT / "docs/versioning.md"
XCODE_PROJECT = (
    ROOT / "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj"
)


def test_candidate_notes_selection_uses_planned_tag_on_release_branch(
    tmp_path: Path,
) -> None:
    notes = b"# Synthetic Receiver release\n\nExact candidate notes.\n"
    notes_directory = tmp_path / ".github/release"
    notes_directory.mkdir(parents=True)
    _ = (notes_directory / "notes-receiver-v9.0.1.md").write_bytes(notes)
    (tmp_path / "dist").mkdir()
    commands = [
        line.strip()
        for line in RELEASE_WORKFLOW.read_text(encoding="utf-8").splitlines()
        if line.strip().startswith("cp ")
        and line.strip().endswith("dist/release-notes.md")
    ]
    assert len(commands) == 1
    result = subprocess.run(
        ["bash", "-euc", commands[0]],
        cwd=tmp_path,
        env={
            **os.environ,
            "GITHUB_REF_NAME": "release",
            "RELEASE_TAG": "receiver-v9.0.1",
        },
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert (tmp_path / "dist/release-notes.md").read_bytes() == notes


def _current_ios_build() -> str:
    values: set[str] = set()
    for line in XCODE_PROJECT.read_text(encoding="utf-8").splitlines():
        if "CURRENT_PROJECT_VERSION =" in line:
            _, _, value = line.partition("=")
            values.add(value.removesuffix(";").strip())
    assert len(values) == 1
    return values.pop()


class ValidateOutput(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", strict=True)

    ios_build: str
    ios_marketing_version: str
    project_version: str
    release_scope: Literal["receiver", "ios", "coordinated"]
    tag: str


class ArtifactOutput(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", strict=True)

    bytes: int
    filename: str
    sha256: str


class PythonReleaseOutput(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", strict=True)

    artifacts: list[ArtifactOutput]
    package: Literal["apple-health-ai-bridge"]
    requires_python: Literal[">=3.11"]
    version: Literal["1.1.1"]


class ReleaseMetadataOutput(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", strict=True)

    schema_id: Literal["health_bridge.release.v3"]
    release_scope: Literal["receiver"]
    release_version: Literal["1.1.1"]
    git: dict[str, str]
    ios: dict[str, str]
    batch_contract: dict[str, str]
    python: PythonReleaseOutput
    macos_mailbox_ack_helper: dict[str, object]


def _run_release_tool(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(RELEASE_TOOL), *args],
        cwd=ROOT,
        capture_output=True,
        check=False,
        text=True,
    )


def _packet_verify_args(
    *, repo: Path, dist: Path, tag_object: str, commit: str, tree: str
) -> tuple[str, ...]:
    return (
        "verify-packet",
        "--repo",
        str(repo),
        "--dist-dir",
        str(dist),
        "--tag",
        "receiver-v1.1.1",
        "--tag-object",
        tag_object,
        "--commit",
        commit,
        "--tree",
        tree,
    )


def _checksum_args(*, repo: Path, dist: Path, output: Path) -> tuple[str, ...]:
    return (
        "checksums",
        "--repo",
        str(repo),
        "--dist-dir",
        str(dist),
        "--tag",
        "receiver-v1.1.1",
        "--tag-object",
        "3" * 40,
        "--commit",
        "1" * 40,
        "--tree",
        "2" * 40,
        "--output",
        str(output),
    )


def _create_manifest_fixture(repo: Path, dist: Path) -> Path:
    dist.mkdir(parents=True, exist_ok=True)
    _ = (dist / "apple_health_ai_bridge-1.1.1-py3-none-any.whl").write_bytes(
        b"wheel fixture\n"
    )
    _ = (dist / "apple_health_ai_bridge-1.1.1.tar.gz").write_bytes(b"sdist fixture\n")
    metadata = dist / "release-metadata.json"
    completed = _run_release_tool(
        "manifest",
        "--repo",
        str(repo),
        "--dist-dir",
        str(dist),
        "--tag",
        "receiver-v1.1.1",
        "--tag-object",
        "3" * 40,
        "--commit",
        "1" * 40,
        "--tree",
        "2" * 40,
        "--output",
        str(metadata),
    )
    assert completed.returncode == 0, completed.stderr
    return metadata


def _write_version_fixture(
    repo: Path,
    *,
    receiver_version: str,
    release_tag: str,
    index_receiver_version: str | None = None,
    ios_marketing_version: str = "1.0.0",
) -> None:
    xcode_project = repo / XCODE_PROJECT.relative_to(ROOT)
    xcode_project.parent.mkdir(parents=True)
    _ = xcode_project.write_text(
        (
            f"MARKETING_VERSION = {ios_marketing_version};\n"
            "CURRENT_PROJECT_VERSION = 15;\n"
        ),
        encoding="utf-8",
    )
    _ = (repo / "pyproject.toml").write_text(
        (f'[project]\nversion = "{receiver_version}"\nrequires-python = ">=3.11"\n'),
        encoding="utf-8",
    )
    fixture = repo / "fixtures/health_bridge_batch_v1.synthetic.json"
    fixture.parent.mkdir(parents=True)
    _ = fixture.write_text(
        json.dumps(
            {
                "schema_id": "health_bridge.batch.v1",
                "schema_version": "1.0.0",
            }
        ),
        encoding="utf-8",
    )
    notes = repo / ".github/release" / f"notes-{release_tag}.md"
    notes.parent.mkdir(parents=True)
    if release_tag.startswith("receiver-v"):
        note_lines = (
            f"# {release_tag}",
            f"@{release_tag}",
            "Receiver-only release",
            f"Compatible iOS Companion: `{ios_marketing_version} (15)`",
            "Compatible Batch Protocol: `health_bridge.batch.v1 (1.0.0)`",
            "No TestFlight update is required",
        )
    else:
        note_lines = (
            f"# {release_tag}",
            f"@{release_tag}",
            "Receiver-only release",
            f"Compatible iOS companion: `{ios_marketing_version} (15)`",
            "No TestFlight update is required",
        )
    _ = notes.write_text("\n".join(note_lines) + "\n", encoding="utf-8")
    _ = (repo / COMPONENT_VERSIONS.relative_to(ROOT)).write_text(
        json.dumps(
            {
                "batch_protocol": {
                    "schema_id": "health_bridge.batch.v1",
                    "version": "1.0.0",
                },
                "ios_companion": {
                    "build": "15",
                    "marketing_version": ios_marketing_version,
                },
                "receiver_cli": {
                    "release_tag": release_tag,
                    "version": index_receiver_version or receiver_version,
                },
                "release_scope": "receiver",
                "schema_id": "health_bridge.component_versions.v1",
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


def _mutate_release_metadata(payload: dict[str, object], mutation: str) -> None:
    if mutation == "wrong-schema":
        payload["schema_id"] = "health_bridge.release.untrusted"
    elif mutation == "missing-schema":
        _ = payload.pop("schema_id")
    elif mutation == "wrong-scope":
        payload["release_scope"] = "coordinated"
    elif mutation == "missing-scope":
        _ = payload.pop("release_scope")
    elif mutation in {"wrong-git-commit", "missing-git-commit", "extra-git-field"}:
        git_value = payload.get("git")
        assert isinstance(git_value, dict)
        git = cast("dict[str, object]", git_value)
        if mutation == "wrong-git-commit":
            git["commit"] = "4" * 40
        elif mutation == "missing-git-commit":
            _ = git.pop("commit")
        else:
            git["unexpected"] = "5" * 40
    else:
        payload["unexpected"] = True


def test_release_validate_accepts_exact_component_scoped_project_version() -> None:
    completed = _run_release_tool(
        "validate",
        "--repo",
        str(ROOT),
        "--tag",
        f"receiver-v{__version__}",
    )

    assert completed.returncode == 0, completed.stderr
    output = ValidateOutput.model_validate_json(completed.stdout)
    assert output.model_dump() == {
        "ios_build": _current_ios_build(),
        "ios_marketing_version": "1.2.0",
        "project_version": __version__,
        "release_scope": "coordinated",
        "tag": f"receiver-v{__version__}",
    }


@pytest.mark.parametrize(
    ("tag", "version", "title", "prerelease"),
    [
        ("v1.0.0", "1.0.0", "v1.0.0", False),
        ("v1.0.1", "1.0.1", "v1.0.1", False),
        ("receiver-v0.9.0", "0.9.0", "receiver-v0.9.0", True),
        ("receiver-v1.1.2", "1.1.2", "receiver-v1.1.2", False),
        ("receiver-v1.1.3", "1.1.3", "receiver-v1.1.3", False),
        ("receiver-v1.1.4", "1.1.4", "Receiver/CLI 1.1.4", False),
        ("receiver-v1.2.0", "1.2.0", "Receiver/CLI 1.2.0", False),
        ("receiver-v2.0.0", "2.0.0", "Receiver/CLI 2.0.0", False),
    ],
)
def test_tag_info_derives_exact_release_title(
    tag: str, version: str, title: str, prerelease: bool
) -> None:
    completed = _run_release_tool("tag-info", "--tag", tag)

    assert completed.returncode == 0, completed.stderr
    assert json.loads(completed.stdout) == {
        "tag": tag,
        "version": version,
        "title": title,
        "prerelease": prerelease,
    }


@pytest.mark.parametrize(
    ("tag", "title"),
    [
        ("receiver-v1.1.3", "receiver-v1.1.3"),
        ("receiver-v1.1.4", "Receiver/CLI 1.1.4"),
    ],
)
def test_release_workflow_passes_derived_title_to_create(
    tmp_path: Path, tag: str, title: str
) -> None:
    environment, state = recovery_transport(tmp_path, "none")
    runner = tmp_path / "title.py"
    _ = runner.write_text(f"""import sys
from pathlib import Path
sys.path.insert(0, {str(ROOT / "scripts")!r})
from release_tools import release_title
from release_reconciliation import ExpectedRelease, synchronize
expected = ExpectedRelease(
    tag=sys.argv[1], commit="1"*40, title=release_title(sys.argv[1]),
    notes="synthetic notes", assets=[],
)
synchronize(Path(sys.argv[2]), expected, Path(sys.argv[2]))
""")
    result = subprocess.run(
        [sys.executable, str(runner), tag, str(tmp_path)],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    payload = TypeAdapter(dict[str, JsonValue]).validate_json(state.read_bytes())
    releases = payload["releases"]
    assert isinstance(releases, list)
    release = releases[0]
    assert isinstance(release, dict)
    assert release["tag_name"] == tag
    assert release["name"] == title
    assert release["draft"] is True


def test_component_version_index_matches_current_release_surfaces() -> None:
    payload = cast(
        "dict[str, object]",
        json.loads(COMPONENT_VERSIONS.read_text(encoding="utf-8")),
    )

    assert payload == {
        "batch_protocol": {
            "schema_id": "health_bridge.batch.v1",
            "version": "1.0.0",
        },
        "ios_companion": {"build": "51", "marketing_version": "1.2.0"},
        "receiver_cli": {
            "release_tag": f"receiver-v{__version__}",
            "version": __version__,
        },
        "release_scope": "coordinated",
        "schema_id": "health_bridge.component_versions.v1",
    }


def test_next_receiver_release_requires_component_scoped_tag(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _write_version_fixture(
        repo,
        receiver_version="1.0.2",
        release_tag="receiver-v1.0.2",
    )

    accepted = _run_release_tool(
        "validate",
        "--repo",
        str(repo),
        "--tag",
        "receiver-v1.0.2",
    )
    legacy = _run_release_tool(
        "validate",
        "--repo",
        str(repo),
        "--tag",
        "v1.0.2",
    )

    assert accepted.returncode == 0, accepted.stderr
    assert legacy.returncode == 1
    assert "receiver-v1.0.2" in legacy.stderr


def test_release_validate_rejects_component_version_index_drift(
    tmp_path: Path,
) -> None:
    repo = tmp_path / "repo"
    _write_version_fixture(
        repo,
        receiver_version="1.1.1",
        release_tag="receiver-v1.1.1",
        index_receiver_version="1.0.0",
    )

    completed = _run_release_tool(
        "validate",
        "--repo",
        str(repo),
        "--tag",
        "receiver-v1.1.1",
    )

    assert completed.returncode == 1
    assert "component version index" in completed.stderr


@pytest.mark.parametrize("tag", ["1.1.0", "v1.0.0", "receiver-v1.1.1", "main"])
def test_release_validate_rejects_noncanonical_or_mismatched_tag(tag: str) -> None:
    completed = _run_release_tool("validate", "--repo", str(ROOT), "--tag", tag)

    assert completed.returncode == 1
    assert completed.stdout == ""
    assert f"receiver-v{__version__}" in completed.stderr


def test_receiver_and_ios_semver_order_does_not_define_compatibility(
    tmp_path: Path,
) -> None:
    repo = tmp_path / "repo"
    _write_version_fixture(
        repo,
        receiver_version="1.0.2",
        release_tag="receiver-v1.0.2",
        ios_marketing_version="1.1.0",
    )

    completed = _run_release_tool(
        "validate",
        "--repo",
        str(repo),
        "--tag",
        "receiver-v1.0.2",
    )

    assert completed.returncode == 0, completed.stderr
    output = ValidateOutput.model_validate_json(completed.stdout)
    assert output.release_scope == "receiver"
    assert output.project_version == "1.0.2"
    assert output.ios_marketing_version == "1.1.0"


def test_release_metadata_and_checksums_are_deterministic(
    tmp_path: Path,
    receiver_release_repo: Path,
) -> None:
    dist = tmp_path / "dist"
    dist.mkdir()
    wheel = dist / "apple_health_ai_bridge-1.1.1-py3-none-any.whl"
    sdist = dist / "apple_health_ai_bridge-1.1.1.tar.gz"
    _ = wheel.write_bytes(b"wheel fixture\n")
    _ = sdist.write_bytes(b"sdist fixture\n")
    metadata = dist / "release-metadata.json"
    checksums = dist / "SHA256SUMS"
    commit = "1" * 40
    tree = "2" * 40
    tag_object = "3" * 40

    manifest_args = (
        "manifest",
        "--repo",
        str(receiver_release_repo),
        "--dist-dir",
        str(dist),
        "--tag",
        "receiver-v1.1.1",
        "--tag-object",
        tag_object,
        "--commit",
        commit,
        "--tree",
        tree,
        "--output",
        str(metadata),
    )
    first = _run_release_tool(*manifest_args)
    assert first.returncode == 0, first.stderr
    first_bytes = metadata.read_bytes()

    second = _run_release_tool(*manifest_args)
    assert second.returncode == 0, second.stderr
    assert metadata.read_bytes() == first_bytes

    payload = ReleaseMetadataOutput.model_validate_json(first_bytes)
    assert payload.git == {
        "commit": commit,
        "tag": "receiver-v1.1.1",
        "tag_object": tag_object,
        "tree": tree,
    }
    assert payload.ios == {
        "build": "39",
        "marketing_version": "1.1.0",
        "source_settings": (
            "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj"
        ),
        "source_settings_sha256": hashlib.sha256(
            (receiver_release_repo / XCODE_PROJECT.relative_to(ROOT)).read_bytes()
        ).hexdigest(),
    }
    assert payload.batch_contract == {
        "schema_id": "health_bridge.batch.v1",
        "schema_version": "1.0.0",
    }
    assert [item.filename for item in payload.python.artifacts] == [
        wheel.name,
        sdist.name,
    ]
    assert (
        payload.python.artifacts[0].sha256
        == hashlib.sha256(wheel.read_bytes()).hexdigest()
    )

    _ = (dist / "release-notes.md").write_bytes(
        (
            receiver_release_repo / ".github/release/notes-receiver-v1.1.1.md"
        ).read_bytes()
    )
    checksum_result = _run_release_tool(
        *_checksum_args(repo=receiver_release_repo, dist=dist, output=checksums)
    )
    assert checksum_result.returncode == 0, checksum_result.stderr
    lines = checksums.read_text(encoding="utf-8").splitlines()
    assert [line.split("  ", 1)[1] for line in lines] == [
        "apple_health_ai_bridge-1.1.1-py3-none-any.whl",
        "apple_health_ai_bridge-1.1.1.tar.gz",
        "release-metadata.json",
    ]

    verify_result = _run_release_tool(
        *_packet_verify_args(
            repo=receiver_release_repo,
            dist=dist,
            tag_object=tag_object,
            commit=commit,
            tree=tree,
        )
    )
    assert verify_result.returncode == 0, verify_result.stderr

    _ = wheel.write_bytes(b"tampered after download")
    tampered = _run_release_tool(
        *_packet_verify_args(
            repo=receiver_release_repo,
            dist=dist,
            tag_object=tag_object,
            commit=commit,
            tree=tree,
        )
    )
    assert tampered.returncode == 1
    assert "checksum" in tampered.stderr.lower()

    _ = wheel.write_bytes(b"wheel fixture\n")
    metadata_payload = payload.model_dump(mode="json")
    metadata_payload["schema_id"] = "health_bridge.release.untrusted"
    _ = metadata.write_text(
        json.dumps(metadata_payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    refreshed = _run_release_tool(
        *_checksum_args(repo=receiver_release_repo, dist=dist, output=checksums)
    )
    assert refreshed.returncode == 1
    assert "metadata" in refreshed.stderr.lower()

    artifact_payload = payload.model_dump(mode="json")
    artifact_payload["python"]["artifacts"][0]["unexpected"] = True
    _ = metadata.write_text(
        json.dumps(artifact_payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    extra_key = _run_release_tool(
        *_checksum_args(repo=receiver_release_repo, dist=dist, output=checksums)
    )
    assert extra_key.returncode == 1
    assert "invalid artifact record" in extra_key.stderr


@pytest.mark.parametrize(
    "mutation",
    [
        "wrong-schema",
        "missing-schema",
        "wrong-scope",
        "missing-scope",
        "wrong-git-commit",
        "missing-git-commit",
        "extra-git-field",
        "extra-top-level",
    ],
)
def test_checksums_reject_nonexact_release_metadata(
    tmp_path: Path,
    receiver_release_repo: Path,
    mutation: str,
) -> None:
    dist = tmp_path / "dist"
    metadata = _create_manifest_fixture(receiver_release_repo, dist)
    _ = (dist / "release-notes.md").write_bytes(RELEASE_NOTES.read_bytes())
    payload = ReleaseMetadataOutput.model_validate_json(
        metadata.read_bytes()
    ).model_dump(mode="json")
    _mutate_release_metadata(payload, mutation)
    _ = metadata.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    completed = _run_release_tool(
        *_checksum_args(
            repo=receiver_release_repo,
            dist=dist,
            output=dist / "SHA256SUMS",
        )
    )

    assert completed.returncode == 1
    assert "metadata" in completed.stderr.lower()


def test_release_manifest_rejects_wrong_or_extra_python_artifacts(
    tmp_path: Path,
    receiver_release_repo: Path,
) -> None:
    dist = tmp_path / "dist"
    dist.mkdir()
    _ = (dist / "apple_health_ai_bridge-1.1.1-py3-none-any.whl").write_bytes(b"wheel")
    _ = (dist / "apple_health_ai_bridge-9.9.9.tar.gz").write_bytes(b"wrong")

    completed = _run_release_tool(
        "manifest",
        "--repo",
        str(receiver_release_repo),
        "--dist-dir",
        str(dist),
        "--tag",
        "receiver-v1.1.1",
        "--tag-object",
        "3" * 40,
        "--commit",
        "1" * 40,
        "--tree",
        "2" * 40,
        "--output",
        str(dist / "release-metadata.json"),
    )

    assert completed.returncode == 1
    assert (
        "release artifacts must exactly match project version 1.1.1" in completed.stderr
    )
    assert not (dist / "release-metadata.json").exists()


def test_checksums_reject_artifact_changed_after_manifest(
    tmp_path: Path,
    receiver_release_repo: Path,
) -> None:
    dist = tmp_path / "dist"
    dist.mkdir()
    wheel = dist / "apple_health_ai_bridge-1.1.1-py3-none-any.whl"
    sdist = dist / "apple_health_ai_bridge-1.1.1.tar.gz"
    _ = wheel.write_bytes(b"original wheel")
    _ = sdist.write_bytes(b"original sdist")
    metadata = dist / "release-metadata.json"
    checksums = dist / "SHA256SUMS"

    manifest = _run_release_tool(
        "manifest",
        "--repo",
        str(receiver_release_repo),
        "--dist-dir",
        str(dist),
        "--tag",
        "receiver-v1.1.1",
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
    _ = (dist / "release-notes.md").write_bytes(RELEASE_NOTES.read_bytes())
    _ = wheel.write_bytes(b"mutated wheel")

    completed = _run_release_tool(
        *_checksum_args(repo=receiver_release_repo, dist=dist, output=checksums)
    )

    assert completed.returncode == 1
    assert "artifact no longer matches release metadata" in completed.stderr
    assert not checksums.exists()


def test_release_packet_rejects_directories_nested_files_and_symlinks(
    tmp_path: Path,
    receiver_release_repo: Path,
) -> None:
    dist = tmp_path / "dist"
    dist.mkdir()
    wheel = dist / "apple_health_ai_bridge-1.1.1-py3-none-any.whl"
    sdist = dist / "apple_health_ai_bridge-1.1.1.tar.gz"
    _ = wheel.write_bytes(b"wheel")
    _ = sdist.write_bytes(b"sdist")
    metadata = dist / "release-metadata.json"
    checksums = dist / "SHA256SUMS"
    commit = "1" * 40
    tree = "2" * 40
    tag_object = "3" * 40
    manifest = _run_release_tool(
        "manifest",
        "--repo",
        str(receiver_release_repo),
        "--dist-dir",
        str(dist),
        "--tag",
        "receiver-v1.1.1",
        "--tag-object",
        tag_object,
        "--commit",
        commit,
        "--tree",
        tree,
        "--output",
        str(metadata),
    )
    assert manifest.returncode == 0, manifest.stderr
    _ = (dist / "release-notes.md").write_bytes(RELEASE_NOTES.read_bytes())

    nested = dist / "nested"
    nested.mkdir()
    _ = (nested / "undeclared.bin").write_bytes(b"extra")
    nested_result = _run_release_tool(
        *_checksum_args(repo=receiver_release_repo, dist=dist, output=checksums)
    )
    assert nested_result.returncode == 1
    assert "file set" in nested_result.stderr.lower()
    (nested / "undeclared.bin").unlink()
    nested.rmdir()

    created = _run_release_tool(
        *_checksum_args(repo=receiver_release_repo, dist=dist, output=checksums)
    )
    assert created.returncode == 0, created.stderr
    (dist / "undeclared-link").symlink_to(wheel.name)
    symlink_result = _run_release_tool(
        *_packet_verify_args(
            repo=receiver_release_repo,
            dist=dist,
            tag_object=tag_object,
            commit=commit,
            tree=tree,
        )
    )
    assert symlink_result.returncode == 1
    assert "file set" in symlink_result.stderr.lower()


def test_draft_release_verifier_checks_metadata_body_and_remote_digests(
    tmp_path: Path,
    receiver_release_repo: Path,
) -> None:
    dist = tmp_path / "dist"
    _ = _create_manifest_fixture(receiver_release_repo, dist)
    names = (
        "apple_health_ai_bridge-1.1.1-py3-none-any.whl",
        "apple_health_ai_bridge-1.1.1.tar.gz",
        "SHA256SUMS",
        "release-metadata.json",
    )
    _ = (dist / "SHA256SUMS").write_bytes(b"checksum fixture\n")
    digests = {
        name: hashlib.sha256((dist / name).read_bytes()).hexdigest() for name in names
    }
    release_json = tmp_path / "release.json"
    assets: list[dict[str, str | int]] = [
        {
            "digest": f"sha256:{digests[name]}",
            "name": name,
            "size": (dist / name).stat().st_size,
            "state": "uploaded",
        }
        for name in names
    ]
    payload: dict[str, object] = {
        "assets": assets,
        "body": RELEASE_NOTES.read_text(encoding="utf-8"),
        "draft": True,
        "name": "receiver-v1.1.1",
        "prerelease": False,
        "tag_name": "receiver-v1.1.1",
    }
    _ = release_json.write_text(json.dumps(payload), encoding="utf-8")
    args = (
        "verify-draft",
        "--repo",
        str(receiver_release_repo),
        "--dist-dir",
        str(dist),
        "--release-json",
        str(release_json),
        "--notes-file",
        str(RELEASE_NOTES),
        "--tag",
        "receiver-v1.1.1",
        "--tag-object",
        "3" * 40,
        "--commit",
        "1" * 40,
        "--tree",
        "2" * 40,
    )

    valid = _run_release_tool(*args)
    assert valid.returncode == 0, valid.stderr

    assets[0]["digest"] = f"sha256:{'0' * 64}"
    _ = release_json.write_text(json.dumps(payload), encoding="utf-8")
    bad_digest = _run_release_tool(*args)
    assert bad_digest.returncode == 1
    assert "remote asset digest mismatch" in bad_digest.stderr

    assets[0]["digest"] = (
        f"sha256:{hashlib.sha256((dist / names[0]).read_bytes()).hexdigest()}"
    )
    payload["body"] = "different notes"
    _ = release_json.write_text(json.dumps(payload), encoding="utf-8")
    bad_body = _run_release_tool(*args)
    assert bad_body.returncode == 1
    assert "release body does not match exact notes" in bad_body.stderr

    payload["body"] = RELEASE_NOTES.read_text(encoding="utf-8")
    payload["draft"] = False
    _ = release_json.write_text(json.dumps(payload), encoding="utf-8")
    published = _run_release_tool("verify-published", *args[1:])
    assert published.returncode == 0, published.stderr

    payload["draft"] = True
    _ = release_json.write_text(json.dumps(payload), encoding="utf-8")
    wrong_published_state = _run_release_tool("verify-published", *args[1:])
    assert wrong_published_state.returncode == 1
    assert "published release metadata is not exact" in wrong_published_state.stderr


@pytest.mark.parametrize(
    ("command", "draft"),
    [("verify-draft", True), ("verify-published", False)],
)
@pytest.mark.parametrize(
    "mutation",
    [
        "wrong-schema",
        "missing-schema",
        "wrong-scope",
        "missing-scope",
        "wrong-git-commit",
        "missing-git-commit",
        "extra-git-field",
        "extra-top-level",
    ],
)
def test_draft_and_published_verifiers_reject_nonexact_release_metadata(
    tmp_path: Path,
    receiver_release_repo: Path,
    command: str,
    draft: bool,
    mutation: str,
) -> None:
    dist = tmp_path / "dist"
    metadata = _create_manifest_fixture(receiver_release_repo, dist)
    _ = (dist / "SHA256SUMS").write_bytes(b"checksum fixture\n")
    metadata_payload = ReleaseMetadataOutput.model_validate_json(
        metadata.read_bytes()
    ).model_dump(mode="json")
    _mutate_release_metadata(metadata_payload, mutation)
    _ = metadata.write_text(
        json.dumps(metadata_payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    names = (
        "apple_health_ai_bridge-1.1.1-py3-none-any.whl",
        "apple_health_ai_bridge-1.1.1.tar.gz",
        "SHA256SUMS",
        "release-metadata.json",
    )
    digests = {
        name: hashlib.sha256((dist / name).read_bytes()).hexdigest() for name in names
    }
    assets = [
        {
            "digest": f"sha256:{digests[name]}",
            "name": name,
            "size": (dist / name).stat().st_size,
            "state": "uploaded",
        }
        for name in names
    ]
    release_json = tmp_path / "release.json"
    _ = release_json.write_text(
        json.dumps(
            {
                "assets": assets,
                "body": RELEASE_NOTES.read_text(encoding="utf-8"),
                "draft": draft,
                "name": "receiver-v1.1.1",
                "prerelease": False,
                "tag_name": "receiver-v1.1.1",
            }
        ),
        encoding="utf-8",
    )

    completed = _run_release_tool(
        command,
        "--repo",
        str(receiver_release_repo),
        "--dist-dir",
        str(dist),
        "--release-json",
        str(release_json),
        "--notes-file",
        str(RELEASE_NOTES),
        "--tag",
        "receiver-v1.1.1",
        "--tag-object",
        "3" * 40,
        "--commit",
        "1" * 40,
        "--tree",
        "2" * 40,
    )

    assert completed.returncode == 1
    assert "metadata" in completed.stderr.lower()


def test_release_workflow_separates_candidate_and_publication_permissions() -> None:
    workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
    publish = (ROOT / ".github/workflows/publish-release.yml").read_text()
    assert "workflow_dispatch:" in workflow
    assert "source_commit:" in workflow
    assert "signed_tag_object:" in workflow
    assert "contents: write" not in workflow
    assert "environment: github-release" not in workflow
    assert "gh release" not in workflow
    assert "needs: [verify, python, ios]" in workflow
    assert "id-token: write" in workflow
    assert "attestations: write" in workflow
    assert "ref: ${{ github.sha }}" in workflow
    assert 'test "$GITHUB_SHA" = "$REQUESTED_SOURCE"' in workflow
    assert 'test "$GITHUB_WORKFLOW_SHA" = "$REQUESTED_SOURCE"' in workflow
    assert 'test "$GITHUB_REF" = refs/heads/release' in workflow
    assert "release.yml@refs/heads/release" in workflow
    assert "release_candidate.py --repo ." in workflow
    assert "release_candidate.py --phase seal" in workflow
    assert "name: candidate-${{ github.run_id }}-${{ github.run_attempt }}" in workflow
    assert "release_tools.py manifest --candidate" in workflow
    assert '--source-receipt "$RUNNER_TEMP/source.json"' in workflow
    assert "release_tools.py verify-packet" in workflow
    assert "uv run pytest -q" in workflow
    assert "uv run basedpyright" in workflow
    assert "package-smoke.py --dist-dir dist" in workflow
    assert "swift test" in workflow
    assert "CODE_SIGNING_ALLOWED=NO" in workflow
    assert "subject-path: |" in workflow
    assert "subject-path: dist/*" not in workflow
    assert "receiver-build-provenance.intoto.jsonl" in workflow
    assert "environment: github-release" in publish
    assert 'test "$GITHUB_REF" = "refs/tags/$RELEASE_TAG"' in publish
    assert "publish-release.yml@refs/tags/" in publish
    assert "needs: verify_helper_on_macos" in publish
    assert "group: release-publication-${{ github.repository }}" in publish
    assert "cancel-in-progress: false" in publish
    assert "release_candidate.py --phase download" in publish
    assert "release_recovery.py --phase prepare-final" in publish
    assert "release_recovery.py --phase publish" in publish
    assert "if: steps.final.outputs.attest == 'true'" in publish
    assert "verify_helper_distribution.py" in publish
    assert "--clobber" not in workflow + publish
    assert "--generate-notes" not in workflow + publish
    assert "pypi" not in workflow.lower()


def test_v101_receiver_release_notes_are_versioned_and_actionable() -> None:
    notes = HISTORICAL_V101_RELEASE_NOTES.read_text(encoding="utf-8")

    assert notes.startswith("# Apple Health AI Bridge v1.0.1")
    assert "Receiver-only release" in notes
    assert "Compatible iOS companion: `1.0.0 (15)`" in notes
    assert "No TestFlight update is required" in notes
    assert "@v1.0.1" in notes
    assert "SHA256SUMS" in notes
    assert "release-metadata.json" in notes
    assert "same-host stdio" in notes
    assert "TODO" not in notes


def test_release_criteria_requires_live_app_store_build_readback() -> None:
    criteria = RELEASE_CRITERIA.read_text(encoding="utf-8")

    assert "highest existing build number in App Store Connect" in criteria
    assert "TestFlight Internal Only" in criteria
    assert "github-release" in criteria
    assert "Required reviewers" in criteria
    assert "deployment tag rule" in criteria
    assert "receiver-v*" in criteria
    assert "component-versions.json" in criteria
    assert "active tag ruleset" in criteria
    assert "Restrict deletions" in criteria
    assert "Restrict updates" in criteria
    assert "Restrict creations" in criteria
    assert "Enable release immutability" in criteria
    operations = (ROOT / "docs/release-operations.md").read_text()
    assert 'git verify-tag "$tag"' in operations
    assert "git verify-commit HEAD" not in criteria
    assert "build 3" not in criteria
    assert "receiver-only patch" in criteria
    assert "must not upload a new TestFlight build" in criteria
    assert "release_scope" in criteria


def test_public_docs_name_each_version_surface_and_transition() -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    versioning = VERSIONING_DOC.read_text(encoding="utf-8")

    assert "(docs/versioning.md)" in readme
    for label in ("Receiver/CLI", "iOS Companion", "Batch Protocol"):
        assert label in versioning
    assert "receiver-v1.0.2" in versioning
    assert "ios-v1.1.1-build.50" in versioning
    assert "Existing `v1.0.0` and `v1.0.1` tags remain immutable" in versioning
    assert (
        "Do not bump an unchanged component merely to make the numbers match"
        in versioning
    )
    assert "component-versions.json" in versioning
    versioning_subject = (
        "Future release notes must state the exact compatible iOS Companion"
    )
    versioning_detail = "version/build and Batch Protocol schema identifier/version"
    expected_versioning_statement = f"{versioning_subject} {versioning_detail}"
    assert expected_versioning_statement in versioning
    assert "Historical release notes remain as published" in versioning


def test_release_and_self_build_docs_reference_current_guidance() -> None:
    self_build = (ROOT / "docs/self-build.md").read_text(encoding="utf-8")
    app_review = (ROOT / ".github/release/app-review-notes-template.md").read_text(
        encoding="utf-8"
    )
    testflight = (ROOT / ".github/release/testflight-checklist.md").read_text(
        encoding="utf-8"
    )

    assert "setup.md#pair-the-iphone" in self_build
    assert "pairing.md" not in self_build
    assert "docs/supported-health-data.md" in app_review
    assert "docs/supported-health-data.md" in testflight
    assert ".github/release/app-review-notes-template.md" in testflight
    assert "docs/healthkit-read-types.md" not in app_review + testflight
    assert "docs/maintainers/app-review-notes-template.example.md" not in testflight


def test_brand_readme_local_links_resolve_inside_repository() -> None:
    readme = ROOT / "assets/brand/README.md"
    destinations: list[str] = re.findall(
        r"\]\(([^)]+)\)", readme.read_text(encoding="utf-8")
    )

    assert len(destinations) == 13
    for destination in destinations:
        target = (readme.parent / destination.split("#", 1)[0]).resolve()
        assert target.is_relative_to(ROOT.resolve())
        assert target.exists(), destination


def test_install_commands_are_pinned_to_their_receiver_release() -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    setup = (ROOT / "docs/setup.md").read_text(encoding="utf-8")

    pin_pattern = (
        r'git\+https://github\.com/roian6/apple-health-ai-bridge\.git@([^\s"]+)'
    )
    assert f"/releases/tag/receiver-v{PUBLISHED_RECEIVER_VERSION})" in readme
    assert f"/blob/receiver-v{PUBLISHED_RECEIVER_VERSION}/docs/setup.md)" in readme
    assert (
        f"/blob/receiver-v{PUBLISHED_RECEIVER_VERSION}/docs/icloud-mailbox-service.md)"
        in readme
    )
    assert re.findall(pin_pattern, readme) == []
    pins = re.findall(pin_pattern, setup)
    assert pins, "No versioned install pin found in docs/setup.md"
    assert set(pins) == {f"receiver-v{__version__}"}, (
        f"Found stale install pins in docs/setup.md: {pins}"
    )
    unpinned = "git+https://github.com/roian6/apple-health-ai-bridge.git\n"
    assert unpinned not in readme
    assert unpinned not in setup


def test_roadmap_links_to_readme_default_receiver_release() -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    roadmap = (ROOT / "docs/roadmap.md").read_text(encoding="utf-8")
    current_receiver = re.search(r"/releases/tag/receiver-v([^\s)]+)", readme)

    assert current_receiver is not None
    assert current_receiver.group(1) == PUBLISHED_RECEIVER_VERSION
    roadmap_releases = set(re.findall(r"/releases/tag/receiver-v([^\s)]+)", roadmap))
    assert current_receiver.group(1) in roadmap_releases


def test_versioned_setup_links_to_matching_mailbox_release_assets() -> None:
    setup = (ROOT / "docs/setup.md").read_text(encoding="utf-8")
    self_build = (ROOT / "docs/self-build.md").read_text(encoding="utf-8")
    mailbox = (ROOT / "docs/icloud-mailbox-service.md").read_text(encoding="utf-8")

    assert re.search(r"\]\(setup\.md(?:#[^)]+)?\)", self_build)
    assert f"/blob/receiver-v{__version__}/docs/icloud-mailbox-service.md)" in setup
    release_notes_path = ROOT / f".github/release/notes-receiver-v{__version__}.md"
    assert release_notes_path.is_file()
    release_notes = release_notes_path.read_text(encoding="utf-8")
    expected_assets = set(re.findall(r"^- `([^`]+)`[.;]?", release_notes, re.MULTILINE))
    download_section = mailbox.split("download them:\n", 1)[1].split(
        "Do not extract the helper", 1
    )[0]
    downloaded_assets = set(
        re.findall(r"^- `([^`]+)`[.;]?", download_section, re.MULTILINE)
    )
    assert expected_assets == {
        f"apple_health_ai_bridge-{__version__}-py3-none-any.whl",
        f"apple_health_ai_bridge-{__version__}.tar.gz",
        "release-metadata.json",
        "receiver-build-provenance.intoto.jsonl",
        f"HealthBridgeMailboxAckPublisher-{__version__}.zip",
        f"HealthBridgeMailboxAckPublisher-{__version__}.manifest.json",
        "SHA256SUMS",
        "receiver-final-provenance.intoto.jsonl",
    }
    assert downloaded_assets == expected_assets
    assert set(
        re.findall(r"apple_health_ai_bridge-[\w.]+-py3-none-any\.whl", mailbox)
    ) == {f"apple_health_ai_bridge-{__version__}-py3-none-any.whl"}
    assert set(
        re.findall(
            r"HealthBridgeMailboxAckPublisher-[\d.]+(?:zip|manifest\.json)", mailbox
        )
    ) == {
        f"HealthBridgeMailboxAckPublisher-{__version__}.zip",
        f"HealthBridgeMailboxAckPublisher-{__version__}.manifest.json",
    }


@pytest.mark.parametrize("guide", ["setup.md", "icloud-mailbox-service.md"])
def test_versioned_guide_links_published_release_before_commands(guide: str) -> None:
    document = (ROOT / "docs" / guide).read_text(encoding="utf-8")
    repository = "https://github.com/roian6/apple-health-ai-bridge"
    release_link = f"({repository}/releases/tag/receiver-v{__version__})"
    assert document.index(release_link) < document.index("```bash\n")
    if guide == "icloud-mailbox-service.md":
        assert document.index(release_link) < document.index(
            f"HealthBridgeMailboxAckPublisher-{__version__}.zip"
        )
