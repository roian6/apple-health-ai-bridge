import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import ClassVar, Literal, cast

import pytest
from pydantic import BaseModel, ConfigDict

ROOT = Path(__file__).parents[2]
RELEASE_TOOL = ROOT / "scripts/release_tools.py"
RELEASE_WORKFLOW = ROOT / ".github/workflows/release.yml"
RELEASE_NOTES = ROOT / ".github/release/notes-v1.0.1.md"
RELEASE_CRITERIA = ROOT / ".github/release/criteria.md"
COMPONENT_VERSIONS = ROOT / "component-versions.json"
VERSIONING_DOC = ROOT / "docs/versioning.md"
XCODE_PROJECT = (
    ROOT / "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj"
)


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
    release_scope: Literal["receiver", "coordinated"]
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
    version: Literal["1.0.1"]


class ReleaseMetadataOutput(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", strict=True)

    schema_id: Literal["health_bridge.release.v2"]
    release_scope: Literal["receiver"]
    release_version: Literal["1.0.1"]
    git: dict[str, str]
    ios: dict[str, str]
    batch_contract: dict[str, str]
    python: PythonReleaseOutput


def _run_release_tool(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(RELEASE_TOOL), *args],
        cwd=ROOT,
        capture_output=True,
        check=False,
        text=True,
    )


def _packet_verify_args(
    *, dist: Path, tag_object: str, commit: str, tree: str
) -> tuple[str, ...]:
    return (
        "verify-packet",
        "--repo",
        str(ROOT),
        "--dist-dir",
        str(dist),
        "--tag",
        "v1.0.1",
        "--tag-object",
        tag_object,
        "--commit",
        commit,
        "--tree",
        tree,
    )


def _checksum_args(*, dist: Path, output: Path) -> tuple[str, ...]:
    return (
        "checksums",
        "--repo",
        str(ROOT),
        "--dist-dir",
        str(dist),
        "--tag",
        "v1.0.1",
        "--tag-object",
        "3" * 40,
        "--commit",
        "1" * 40,
        "--tree",
        "2" * 40,
        "--output",
        str(output),
    )


def _create_manifest_fixture(dist: Path) -> Path:
    dist.mkdir(parents=True, exist_ok=True)
    _ = (dist / "apple_health_ai_bridge-1.0.1-py3-none-any.whl").write_bytes(
        b"wheel fixture\n"
    )
    _ = (dist / "apple_health_ai_bridge-1.0.1.tar.gz").write_bytes(b"sdist fixture\n")
    metadata = dist / "release-metadata.json"
    completed = _run_release_tool(
        "manifest",
        "--repo",
        str(ROOT),
        "--dist-dir",
        str(dist),
        "--tag",
        "v1.0.1",
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


def test_release_validate_accepts_exact_v_prefixed_project_version() -> None:
    completed = _run_release_tool("validate", "--repo", str(ROOT), "--tag", "v1.0.1")

    assert completed.returncode == 0, completed.stderr
    output = ValidateOutput.model_validate_json(completed.stdout)
    assert output.model_dump() == {
        "ios_build": _current_ios_build(),
        "ios_marketing_version": "1.0.0",
        "project_version": "1.0.1",
        "release_scope": "receiver",
        "tag": "v1.0.1",
    }


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
        "ios_companion": {"build": "15", "marketing_version": "1.0.0"},
        "receiver_cli": {"release_tag": "v1.0.1", "version": "1.0.1"},
        "release_scope": "receiver",
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
        receiver_version="1.0.1",
        release_tag="v1.0.1",
        index_receiver_version="1.0.0",
    )

    completed = _run_release_tool(
        "validate",
        "--repo",
        str(repo),
        "--tag",
        "v1.0.1",
    )

    assert completed.returncode == 1
    assert "component version index" in completed.stderr


@pytest.mark.parametrize("tag", ["1.0.1", "v1.0.0", "v1.0.1-beta.1", "main"])
def test_release_validate_rejects_noncanonical_or_mismatched_tag(tag: str) -> None:
    completed = _run_release_tool("validate", "--repo", str(ROOT), "--tag", tag)

    assert completed.returncode == 1
    assert completed.stdout == ""
    assert (
        "receiver release tag must exactly match package version: v1.0.1"
        in completed.stderr
    )


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


def test_release_metadata_and_checksums_are_deterministic(tmp_path: Path) -> None:
    dist = tmp_path / "dist"
    dist.mkdir()
    wheel = dist / "apple_health_ai_bridge-1.0.1-py3-none-any.whl"
    sdist = dist / "apple_health_ai_bridge-1.0.1.tar.gz"
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
        str(ROOT),
        "--dist-dir",
        str(dist),
        "--tag",
        "v1.0.1",
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
        "tag": "v1.0.1",
        "tag_object": tag_object,
        "tree": tree,
    }
    assert payload.ios == {
        "build": _current_ios_build(),
        "marketing_version": "1.0.0",
        "source_settings": (
            "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj"
        ),
        "source_settings_sha256": hashlib.sha256(
            XCODE_PROJECT.read_bytes()
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

    _ = (dist / "release-notes.md").write_bytes(RELEASE_NOTES.read_bytes())
    checksum_result = _run_release_tool(*_checksum_args(dist=dist, output=checksums))
    assert checksum_result.returncode == 0, checksum_result.stderr
    lines = checksums.read_text(encoding="utf-8").splitlines()
    assert [line.split("  ", 1)[1] for line in lines] == [
        "apple_health_ai_bridge-1.0.1-py3-none-any.whl",
        "apple_health_ai_bridge-1.0.1.tar.gz",
        "release-metadata.json",
    ]

    verify_result = _run_release_tool(
        *_packet_verify_args(dist=dist, tag_object=tag_object, commit=commit, tree=tree)
    )
    assert verify_result.returncode == 0, verify_result.stderr

    _ = wheel.write_bytes(b"tampered after download")
    tampered = _run_release_tool(
        *_packet_verify_args(dist=dist, tag_object=tag_object, commit=commit, tree=tree)
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
    refreshed = _run_release_tool(*_checksum_args(dist=dist, output=checksums))
    assert refreshed.returncode == 1
    assert "metadata" in refreshed.stderr.lower()

    artifact_payload = payload.model_dump(mode="json")
    artifact_payload["python"]["artifacts"][0]["unexpected"] = True
    _ = metadata.write_text(
        json.dumps(artifact_payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    extra_key = _run_release_tool(*_checksum_args(dist=dist, output=checksums))
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
    mutation: str,
) -> None:
    dist = tmp_path / "dist"
    metadata = _create_manifest_fixture(dist)
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
        *_checksum_args(dist=dist, output=dist / "SHA256SUMS")
    )

    assert completed.returncode == 1
    assert "metadata" in completed.stderr.lower()


def test_release_manifest_rejects_wrong_or_extra_python_artifacts(
    tmp_path: Path,
) -> None:
    dist = tmp_path / "dist"
    dist.mkdir()
    _ = (dist / "apple_health_ai_bridge-1.0.1-py3-none-any.whl").write_bytes(b"wheel")
    _ = (dist / "apple_health_ai_bridge-9.9.9.tar.gz").write_bytes(b"wrong")

    completed = _run_release_tool(
        "manifest",
        "--repo",
        str(ROOT),
        "--dist-dir",
        str(dist),
        "--tag",
        "v1.0.1",
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
        "release artifacts must exactly match project version 1.0.1" in completed.stderr
    )
    assert not (dist / "release-metadata.json").exists()


def test_checksums_reject_artifact_changed_after_manifest(tmp_path: Path) -> None:
    dist = tmp_path / "dist"
    dist.mkdir()
    wheel = dist / "apple_health_ai_bridge-1.0.1-py3-none-any.whl"
    sdist = dist / "apple_health_ai_bridge-1.0.1.tar.gz"
    _ = wheel.write_bytes(b"original wheel")
    _ = sdist.write_bytes(b"original sdist")
    metadata = dist / "release-metadata.json"
    checksums = dist / "SHA256SUMS"

    manifest = _run_release_tool(
        "manifest",
        "--repo",
        str(ROOT),
        "--dist-dir",
        str(dist),
        "--tag",
        "v1.0.1",
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

    completed = _run_release_tool(*_checksum_args(dist=dist, output=checksums))

    assert completed.returncode == 1
    assert "artifact no longer matches release metadata" in completed.stderr
    assert not checksums.exists()


def test_release_packet_rejects_directories_nested_files_and_symlinks(
    tmp_path: Path,
) -> None:
    dist = tmp_path / "dist"
    dist.mkdir()
    wheel = dist / "apple_health_ai_bridge-1.0.1-py3-none-any.whl"
    sdist = dist / "apple_health_ai_bridge-1.0.1.tar.gz"
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
        str(ROOT),
        "--dist-dir",
        str(dist),
        "--tag",
        "v1.0.1",
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
    nested_result = _run_release_tool(*_checksum_args(dist=dist, output=checksums))
    assert nested_result.returncode == 1
    assert "file set" in nested_result.stderr.lower()
    (nested / "undeclared.bin").unlink()
    nested.rmdir()

    created = _run_release_tool(*_checksum_args(dist=dist, output=checksums))
    assert created.returncode == 0, created.stderr
    (dist / "undeclared-link").symlink_to(wheel.name)
    symlink_result = _run_release_tool(
        *_packet_verify_args(dist=dist, tag_object=tag_object, commit=commit, tree=tree)
    )
    assert symlink_result.returncode == 1
    assert "file set" in symlink_result.stderr.lower()


def test_draft_release_verifier_checks_metadata_body_and_remote_digests(
    tmp_path: Path,
) -> None:
    dist = tmp_path / "dist"
    _ = _create_manifest_fixture(dist)
    names = (
        "apple_health_ai_bridge-1.0.1-py3-none-any.whl",
        "apple_health_ai_bridge-1.0.1.tar.gz",
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
        "name": "v1.0.1",
        "prerelease": False,
        "tag_name": "v1.0.1",
    }
    _ = release_json.write_text(json.dumps(payload), encoding="utf-8")
    args = (
        "verify-draft",
        "--repo",
        str(ROOT),
        "--dist-dir",
        str(dist),
        "--release-json",
        str(release_json),
        "--notes-file",
        str(RELEASE_NOTES),
        "--tag",
        "v1.0.1",
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
    command: str,
    draft: bool,
    mutation: str,
) -> None:
    dist = tmp_path / "dist"
    metadata = _create_manifest_fixture(dist)
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
        "apple_health_ai_bridge-1.0.1-py3-none-any.whl",
        "apple_health_ai_bridge-1.0.1.tar.gz",
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
                "name": "v1.0.1",
                "prerelease": False,
                "tag_name": "v1.0.1",
            }
        ),
        encoding="utf-8",
    )

    completed = _run_release_tool(
        command,
        "--repo",
        str(ROOT),
        "--dist-dir",
        str(dist),
        "--release-json",
        str(release_json),
        "--notes-file",
        str(RELEASE_NOTES),
        "--tag",
        "v1.0.1",
        "--tag-object",
        "3" * 40,
        "--commit",
        "1" * 40,
        "--tree",
        "2" * 40,
    )

    assert completed.returncode == 1
    assert "metadata" in completed.stderr.lower()


def test_release_workflow_requires_verified_tag_and_attested_assets() -> None:  # noqa: PLR0915
    workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")

    assert 'tags: ["receiver-v*"]' in workflow
    assert "  verify:\n" in workflow
    assert "tag_object_sha:" in workflow
    assert "target_commit_sha:" in workflow
    assert workflow.count("needs: verify") == 2
    assert "needs: [verify, python, ios]" in workflow
    assert "environment: github-release" in workflow
    assert "ref: ${{ needs.verify.outputs.target_commit_sha }}" in workflow
    assert (
        "PINNED_TAG_OBJECT_SHA: ${{ needs.verify.outputs.tag_object_sha }}" in workflow
    )
    assert (
        "PINNED_TARGET_COMMIT_SHA: ${{ needs.verify.outputs.target_commit_sha }}"
        in workflow
    )
    assert '"${{ needs.verify.outputs.tag_object_sha }}"' not in workflow
    assert '"${{ needs.verify.outputs.target_commit_sha }}"' not in workflow
    assert "permissions:\n  contents: read" in workflow
    assert workflow.count("contents: write") == 1
    assert "id-token: write" in workflow
    assert "attestations: write" in workflow
    assert "release_tools.py validate" in workflow
    assert "release_tools.py manifest" in workflow
    assert "release_tools.py checksums" in workflow
    checksum_command = workflow.split("release_tools.py checksums", 1)[1].split(
        "(cd dist",
        1,
    )[0]
    assert "--repo ." in checksum_command
    assert '--tag "$GITHUB_REF_NAME"' in checksum_command
    assert '--tag-object "$tag_object_sha"' in checksum_command
    assert '--commit "$commit_sha"' in checksum_command
    assert '--tree "$tree_sha"' in checksum_command
    assert workflow.count('--tag-object "$PINNED_TAG_OBJECT_SHA"') == 4
    assert workflow.count('--commit "$PINNED_TARGET_COMMIT_SHA"') == 3
    assert workflow.count('--tree "$(git rev-parse') == 3
    assert "rm -f dist/.gitignore" in workflow
    assert "check-jsonschema --builtin-schema vendor.github-workflows" in workflow
    assert "enable-cache: false" in workflow
    assert "enable-cache: true" not in workflow
    assert "refs/tags/${GITHUB_REF_NAME}^{tag}" in workflow
    assert "${{ github.event.after }}" in workflow
    assert 'test "$target_sha" = "$event_target_commit_sha"' not in workflow
    assert 'test "$tag_ref_sha" = "$event_tag_object_sha"' in workflow
    assert 'test "$signed_tag_name" = "$GITHUB_REF_NAME"' in workflow
    assert 'test "$target_sha" = "$(git rev-parse HEAD)"' in workflow
    assert 'commit_sha="$(git rev-parse HEAD)"' in workflow
    assert '--commit "$commit_sha"' in workflow
    assert '--tag-object "$tag_object_sha"' in workflow
    assert "verification.verified == true" in workflow
    assert '.author.login == "roian6"' in workflow
    assert '.commit.author.name == "Chanhyo Jung"' in workflow
    assert '.committer.login == "web-flow"' in workflow
    assert '.commit.committer.name == "GitHub"' in workflow
    assert '.commit.committer.email == ("noreply" + "@" + "github.com")' in workflow
    assert ".commit.author.email | endswith" not in workflow
    assert 'endswith("@users.noreply.github.com")' in workflow
    assert (
        "actions/attest-build-provenance@0f67c3f4856b2e3261c31976d6725780e5e4c373"
        in workflow
    )
    assert "gh release create" in workflow
    assert "--draft" in workflow
    assert "DRAFT_RELEASE_ID" in workflow
    assert "for _ in {1..10}" in workflow
    assert "releases/${draft_release_id}" in workflow
    assert "releases/${DRAFT_RELEASE_ID}" in workflow
    assert "gh release edit" in workflow
    assert "--draft=false" in workflow
    assert 'test "$asset_names" = "$expected_assets"' in workflow
    assert workflow.count("git/ref/tags/${GITHUB_REF_NAME}") >= 3
    assert workflow.index("Create and verify draft release") < workflow.index(
        "Attest release artifacts"
    )
    assert workflow.index("Attest release artifacts") < workflow.index(
        "Reverify and publish release"
    )
    assert "verify-draft" in workflow
    assert "verify-published" in workflow
    assert "release-after-publish.json" in workflow
    release_tool = RELEASE_TOOL.read_text(encoding="utf-8")
    assert "remote asset digest mismatch" in release_tool
    assert "release body does not match exact notes" in release_tool
    assert "(cd dist && sha256sum --check --strict SHA256SUMS)" in workflow
    assert "--verify-tag" in workflow
    assert workflow.count("release_tools.py tag-info") == 1
    assert 'prerelease="$(jq -r \'.prerelease\' <<< "$tag_info")"' in workflow
    assert 'version="$(jq -r \'.version\' <<< "$tag_info")"' in workflow
    assert 'if [[ "$prerelease" = "true" ]]' in workflow
    assert 'version="${GITHUB_REF_NAME#receiver-v}"' not in workflow
    assert "release_flags+=(--prerelease)" in workflow
    assert "--notes-file dist/release-notes.md" in workflow
    assert "--generate-notes" not in workflow
    assert "dist/*.whl" in workflow
    assert "dist/*.tar.gz" in workflow
    assert "dist/SHA256SUMS" in workflow
    assert "dist/release-metadata.json" in workflow
    assert "(cd dist && sha256sum --check --strict SHA256SUMS)" in workflow
    assert "pypi" not in workflow.lower()


def test_v101_receiver_release_notes_are_versioned_and_actionable() -> None:
    notes = RELEASE_NOTES.read_text(encoding="utf-8")

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
    assert 'git verify-tag "$tag"' in criteria
    assert "git verify-commit HEAD" not in criteria
    assert '.author.login == "roian6"' in criteria
    assert '.committer.login == "web-flow"' in criteria
    assert "/commits/$commit_sha" in criteria
    assert "lightweight tag" in criteria
    assert "build 3" not in criteria
    assert "receiver-only patch" in criteria
    assert "must not upload a new TestFlight build" in criteria
    assert "release_scope" in criteria


def test_public_docs_name_each_version_surface_and_transition() -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    versioning = VERSIONING_DOC.read_text(encoding="utf-8")

    for label in ("Receiver/CLI", "iOS Companion", "Batch Protocol"):
        assert label in readme
        assert label in versioning
    assert "receiver-v1.0.2" in versioning
    assert "ios-v1.1.0-build.16" in versioning
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


def test_public_install_commands_are_pinned_to_published_v101() -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    setup = (ROOT / "docs/setup.md").read_text(encoding="utf-8")

    pinned = "git+https://github.com/roian6/apple-health-ai-bridge.git@v1.0.1"
    assert pinned in readme
    assert pinned in setup
    for content, name in ((readme, "README.md"), (setup, "docs/setup.md")):
        pins = re.findall(
            r'git\+https://github\.com/roian6/apple-health-ai-bridge\.git@([^\s"]+)',
            content,
        )
        assert pins, f"No versioned install pin found in {name}"
        assert set(pins) == {"v1.0.1"}, f"Found stale install pins in {name}: {pins}"
    unpinned = "git+https://github.com/roian6/apple-health-ai-bridge.git\n"
    assert unpinned not in readme
    assert unpinned not in setup
