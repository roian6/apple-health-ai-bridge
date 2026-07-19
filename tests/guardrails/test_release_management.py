import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import ClassVar, Literal

import pytest
from pydantic import BaseModel, ConfigDict

ROOT = Path(__file__).parents[2]
RELEASE_TOOL = ROOT / "scripts/release_tools.py"
RELEASE_WORKFLOW = ROOT / ".github/workflows/release.yml"
RELEASE_NOTES = ROOT / ".github/release/notes-v1.0.0.md"
RELEASE_CRITERIA = ROOT / ".github/release/criteria.md"
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
    version: Literal["1.0.0"]


class ReleaseMetadataOutput(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", strict=True)

    schema_id: Literal["health_bridge.release.v1"]
    release_version: Literal["1.0.0"]
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
        "v1.0.0",
        "--tag-object",
        tag_object,
        "--commit",
        commit,
        "--tree",
        tree,
    )


def test_release_validate_accepts_exact_v_prefixed_project_version() -> None:
    completed = _run_release_tool("validate", "--repo", str(ROOT), "--tag", "v1.0.0")

    assert completed.returncode == 0, completed.stderr
    output = ValidateOutput.model_validate_json(completed.stdout)
    assert output.model_dump() == {
        "ios_build": _current_ios_build(),
        "ios_marketing_version": "1.0.0",
        "project_version": "1.0.0",
        "tag": "v1.0.0",
    }


@pytest.mark.parametrize("tag", ["1.0.0", "v1.0.1", "v1.0.0-beta.1", "main"])
def test_release_validate_rejects_noncanonical_or_mismatched_tag(tag: str) -> None:
    completed = _run_release_tool("validate", "--repo", str(ROOT), "--tag", tag)

    assert completed.returncode == 1
    assert completed.stdout == ""
    assert "release tag must exactly match project version: v1.0.0" in completed.stderr


def test_release_metadata_and_checksums_are_deterministic(tmp_path: Path) -> None:
    dist = tmp_path / "dist"
    dist.mkdir()
    wheel = dist / "apple_health_ai_bridge-1.0.0-py3-none-any.whl"
    sdist = dist / "apple_health_ai_bridge-1.0.0.tar.gz"
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
        "v1.0.0",
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
        "tag": "v1.0.0",
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
    checksum_result = _run_release_tool(
        "checksums",
        "--dist-dir",
        str(dist),
        "--output",
        str(checksums),
    )
    assert checksum_result.returncode == 0, checksum_result.stderr
    lines = checksums.read_text(encoding="utf-8").splitlines()
    assert [line.split("  ", 1)[1] for line in lines] == [
        "apple_health_ai_bridge-1.0.0-py3-none-any.whl",
        "apple_health_ai_bridge-1.0.0.tar.gz",
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
    refreshed = _run_release_tool(
        "checksums", "--dist-dir", str(dist), "--output", str(checksums)
    )
    assert refreshed.returncode == 0, refreshed.stderr
    semantic_tamper = _run_release_tool(
        *_packet_verify_args(dist=dist, tag_object=tag_object, commit=commit, tree=tree)
    )
    assert semantic_tamper.returncode == 1
    assert "metadata" in semantic_tamper.stderr.lower()

    artifact_payload = payload.model_dump(mode="json")
    artifact_payload["python"]["artifacts"][0]["unexpected"] = True
    _ = metadata.write_text(
        json.dumps(artifact_payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    extra_key = _run_release_tool(
        "checksums", "--dist-dir", str(dist), "--output", str(checksums)
    )
    assert extra_key.returncode == 1
    assert "invalid artifact record" in extra_key.stderr


def test_release_manifest_rejects_wrong_or_extra_python_artifacts(
    tmp_path: Path,
) -> None:
    dist = tmp_path / "dist"
    dist.mkdir()
    _ = (dist / "apple_health_ai_bridge-1.0.0-py3-none-any.whl").write_bytes(b"wheel")
    _ = (dist / "apple_health_ai_bridge-9.9.9.tar.gz").write_bytes(b"wrong")

    completed = _run_release_tool(
        "manifest",
        "--repo",
        str(ROOT),
        "--dist-dir",
        str(dist),
        "--tag",
        "v1.0.0",
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
        "release artifacts must exactly match project version 1.0.0" in completed.stderr
    )
    assert not (dist / "release-metadata.json").exists()


def test_checksums_reject_artifact_changed_after_manifest(tmp_path: Path) -> None:
    dist = tmp_path / "dist"
    dist.mkdir()
    wheel = dist / "apple_health_ai_bridge-1.0.0-py3-none-any.whl"
    sdist = dist / "apple_health_ai_bridge-1.0.0.tar.gz"
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
        "v1.0.0",
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
        "checksums",
        "--dist-dir",
        str(dist),
        "--output",
        str(checksums),
    )

    assert completed.returncode == 1
    assert "artifact no longer matches release metadata" in completed.stderr
    assert not checksums.exists()


def test_release_packet_rejects_directories_nested_files_and_symlinks(
    tmp_path: Path,
) -> None:
    dist = tmp_path / "dist"
    dist.mkdir()
    wheel = dist / "apple_health_ai_bridge-1.0.0-py3-none-any.whl"
    sdist = dist / "apple_health_ai_bridge-1.0.0.tar.gz"
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
        "v1.0.0",
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
        "checksums", "--dist-dir", str(dist), "--output", str(checksums)
    )
    assert nested_result.returncode == 1
    assert "file set" in nested_result.stderr.lower()
    (nested / "undeclared.bin").unlink()
    nested.rmdir()

    created = _run_release_tool(
        "checksums", "--dist-dir", str(dist), "--output", str(checksums)
    )
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
    dist.mkdir()
    names = (
        "apple_health_ai_bridge-1.0.0-py3-none-any.whl",
        "apple_health_ai_bridge-1.0.0.tar.gz",
        "SHA256SUMS",
        "release-metadata.json",
    )
    for name in names:
        _ = (dist / name).write_bytes(f"fixture:{name}\n".encode())
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
        "name": "v1.0.0",
        "prerelease": False,
        "tag_name": "v1.0.0",
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
        "v1.0.0",
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


def test_release_workflow_requires_verified_tag_and_attested_assets() -> None:  # noqa: PLR0915
    workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")

    assert 'tags: ["v*"]' in workflow
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
    assert 'endswith("@users.noreply.github.com")' in workflow
    assert (
        "actions/attest-build-provenance@00014ed6ed5efc5b1ab7f7f34a39eb55d41aa4f8"
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
    assert 'if [[ "${version%%.*}" = "0" ]]' in workflow
    assert "release_flags+=(--prerelease)" in workflow
    assert "--notes-file dist/release-notes.md" in workflow
    assert "--generate-notes" not in workflow
    assert "dist/*.whl" in workflow
    assert "dist/*.tar.gz" in workflow
    assert "dist/SHA256SUMS" in workflow
    assert "dist/release-metadata.json" in workflow
    assert "(cd dist && sha256sum --check --strict SHA256SUMS)" in workflow
    assert "pypi" not in workflow.lower()


def test_v100_release_notes_are_versioned_and_actionable() -> None:
    notes = RELEASE_NOTES.read_text(encoding="utf-8")

    assert notes.startswith("# Apple Health AI Bridge v1.0.0")
    assert "@v1.0.0" in notes
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
    assert "v*" in criteria
    assert "active tag ruleset" in criteria
    assert "Restrict deletions" in criteria
    assert "Restrict updates" in criteria
    assert "Restrict creations" in criteria
    assert "Enable release immutability" in criteria
    assert 'git verify-tag "$tag"' in criteria
    assert "git verify-commit HEAD" in criteria
    assert "/commits/$commit_sha" in criteria
    assert "lightweight tag" in criteria
    assert "build 3" not in criteria


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


def test_public_install_commands_are_pinned_to_v100() -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    setup = (ROOT / "docs/setup.md").read_text(encoding="utf-8")

    pinned = "git+https://github.com/roian6/apple-health-ai-bridge.git@v1.0.0"
    assert pinned in readme
    assert pinned in setup
    unpinned = "git+https://github.com/roian6/apple-health-ai-bridge.git\n"
    assert unpinned not in readme
    assert unpinned not in setup
