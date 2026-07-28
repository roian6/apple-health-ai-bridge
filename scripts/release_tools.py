#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final, Literal, assert_never

from release_versions import (
    ReleaseError,
    canonical_receiver_tag,
    parse_receiver_release_tag,
    parse_semantic_version,
)

HEX_SHA_PATTERN: Final = re.compile(r"^[0-9a-f]{40}$")
SHA256_PATTERN: Final = re.compile(r"^[0-9a-f]{64}$")
XCODE_ASSIGNMENT_TEMPLATE: Final = r"\b{key}\s*=\s*([^;]+);"
IOS_SOURCE_SETTINGS: Final = Path(
    "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj"
)
COMPONENT_VERSION_INDEX: Final = Path("component-versions.json")
GIT_EXECUTABLE: Final = shutil.which("git")


ReleaseScope = Literal["receiver", "coordinated"]


@dataclass(frozen=True, slots=True)
class ComponentSnapshot:
    release_scope: ReleaseScope
    receiver_version: str
    receiver_tag: str
    ios_version: str
    ios_build: int
    batch_version: str
    batch_schema_id: str


@dataclass(frozen=True, slots=True)
class ReleaseVersions:
    project_version: str
    requires_python: str
    ios_marketing_version: str
    ios_build: str
    components: ComponentSnapshot


@dataclass(frozen=True, slots=True)
class TransitionRequest:
    repo: Path
    tag_target_commit: str
    default_main_commit: str
    baseline_commit: str


@dataclass(frozen=True, slots=True)
class ManifestRequest:
    repo: Path
    dist: Path
    tag: str
    tag_object: str
    commit: str
    tree: str
    output: Path


@dataclass(frozen=True, slots=True)
class ChecksumRequest:
    repo: Path
    dist: Path
    tag: str
    tag_object: str
    commit: str
    tree: str
    output: Path


@dataclass(frozen=True, slots=True)
class PacketVerificationRequest:
    repo: Path
    dist: Path
    tag: str
    tag_object: str
    commit: str
    tree: str


@dataclass(frozen=True, slots=True)
class DraftVerificationRequest:
    repo: Path
    dist: Path
    release_json: Path
    notes_file: Path
    tag: str
    tag_object: str
    commit: str
    tree: str


def _project_metadata(repo: Path) -> tuple[str, str]:
    with (repo / "pyproject.toml").open("rb") as handle:
        document = tomllib.load(handle)
    project = document.get("project")
    if not isinstance(project, dict):
        message = "pyproject.toml is missing [project]"
        raise ReleaseError(message)
    version = project.get("version")
    if not isinstance(version, str) or not version:
        message = "pyproject.toml project.version must be a non-empty string"
        raise ReleaseError(message)
    requires_python = project.get("requires-python")
    if not isinstance(requires_python, str) or not requires_python:
        message = "pyproject.toml project.requires-python must be a non-empty string"
        raise ReleaseError(message)
    return version, requires_python


def _single_xcode_value(project: str, key: str) -> str:
    values = {
        match.strip()
        for match in re.findall(
            XCODE_ASSIGNMENT_TEMPLATE.format(key=re.escape(key)), project
        )
    }
    if len(values) != 1:
        message = f"Xcode {key} must have exactly one value across configurations"
        raise ReleaseError(message)
    return values.pop()


def read_versions(repo: Path) -> ReleaseVersions:
    project_path = repo / IOS_SOURCE_SETTINGS
    project = project_path.read_text(encoding="utf-8")
    project_version, requires_python = _project_metadata(repo)
    return ReleaseVersions(
        project_version=project_version,
        requires_python=requires_python,
        ios_marketing_version=_single_xcode_value(project, "MARKETING_VERSION"),
        ios_build=_single_xcode_value(project, "CURRENT_PROJECT_VERSION"),
        components=_read_component_snapshot(
            (repo / COMPONENT_VERSION_INDEX).read_text(encoding="utf-8"),
            surface="component version index",
        ),
    )


def _stable_version_tuple(value: str, *, surface: str) -> tuple[int, int, int]:
    return parse_semantic_version(value, surface=surface).as_tuple()


def _release_scope(versions: ReleaseVersions) -> str:
    return versions.components.release_scope


def _expected_receiver_tag(version: str) -> str:
    return canonical_receiver_tag(version)


def _validate_release_notes(
    versions: ReleaseVersions,
    tag: str,
    notes: str,
) -> None:
    if tag == "v1.0.0":
        return
    if tag == "v1.0.1":
        historical_required = (
            "Receiver-only release",
            (
                "Compatible iOS companion: "
                f"`{versions.ios_marketing_version} ({versions.ios_build})`"
            ),
            "No TestFlight update is required",
        )
        if any(marker not in notes for marker in historical_required):
            message = "historical release notes are missing compatibility markers"
            raise ReleaseError(message)
        return
    exact_ios = (
        "Compatible iOS Companion: "
        f"`{versions.ios_marketing_version} ({versions.ios_build})`"
    )
    exact_batch = (
        "Compatible Batch Protocol: "
        f"`{versions.components.batch_schema_id} "
        f"({versions.components.batch_version})`"
    )
    if exact_ios not in notes:
        message = "release notes must state exact compatible iOS Companion"
        raise ReleaseError(message)
    if exact_batch not in notes:
        message = "release notes must state exact compatible Batch Protocol"
        raise ReleaseError(message)
    match versions.components.release_scope:
        case "receiver":
            required = ("Receiver-only release", "No TestFlight update is required")
            forbidden = ("Coordinated release",)
        case "coordinated":
            required = ("Coordinated release",)
            forbidden = ("Receiver-only release", "No TestFlight update is required")
        case unreachable:
            assert_never(unreachable)
    if any(marker not in notes for marker in required) or any(
        marker in notes for marker in forbidden
    ):
        message = "release notes do not match release_scope"
        raise ReleaseError(message)


def validate_tag(repo: Path, tag: str) -> ReleaseVersions:
    versions = read_versions(repo)
    expected = _expected_receiver_tag(versions.project_version)
    if tag != expected:
        message = f"receiver release tag must exactly match package version: {expected}"
        raise ReleaseError(message)
    if not versions.ios_build.isdecimal() or int(versions.ios_build) < 1:
        message = "iOS CURRENT_PROJECT_VERSION must be a positive integer"
        raise ReleaseError(message)
    _validate_component_version_index(repo, versions, release_tag=tag)
    notes_path = repo / ".github/release" / f"notes-{tag}.md"
    if not notes_path.is_file():
        message = f"versioned release notes are missing: {notes_path}"
        raise ReleaseError(message)
    notes = notes_path.read_text(encoding="utf-8")
    if f"@{tag}" not in notes:
        message = f"release notes must contain the exact install tag: @{tag}"
        raise ReleaseError(message)
    _validate_release_notes(versions, tag, notes)
    return versions


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _atomic_write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(content)
        handle.flush()
    temporary.replace(path)


def _release_artifacts(dist: Path, version: str) -> list[Path]:
    expected = {
        f"apple_health_ai_bridge-{version}-py3-none-any.whl",
        f"apple_health_ai_bridge-{version}.tar.gz",
    }
    candidates = {
        path.name: path
        for pattern in ("*.whl", "*.tar.gz")
        for path in dist.glob(pattern)
        if path.is_file() and not path.is_symlink()
    }
    if set(candidates) != expected:
        message = f"release artifacts must exactly match project version {version}"
        raise ReleaseError(message)
    return [candidates[name] for name in sorted(candidates)]


def _batch_contract(repo: Path) -> dict[str, str]:
    fixture = json.loads(
        (repo / "fixtures/health_bridge_batch_v1.synthetic.json").read_text(
            encoding="utf-8"
        )
    )
    schema_id = fixture.get("schema_id")
    schema_version = fixture.get("schema_version")
    if not isinstance(schema_id, str) or not isinstance(schema_version, str):
        message = "canonical batch fixture is missing schema metadata"
        raise ReleaseError(message)
    return {"schema_id": schema_id, "schema_version": schema_version}


def _required_component_string(
    mapping: dict[str, Any],
    key: str,
    surface: str,
) -> str:
    value = mapping.get(key)
    if not isinstance(value, str):
        message = f"{surface} component values must be strings"
        raise ReleaseError(message)
    return value


def _read_component_snapshot(raw: str, *, surface: str) -> ComponentSnapshot:
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        message = f"{surface} is invalid JSON"
        raise ReleaseError(message) from exc
    if not isinstance(payload, dict):
        message = f"{surface} must be an object"
        raise ReleaseError(message)
    if "release_scope" not in payload:
        message = "component version index release_scope must be explicit"
        raise ReleaseError(message)
    expected_keys = {
        "batch_protocol",
        "ios_companion",
        "receiver_cli",
        "release_scope",
        "schema_id",
    }
    batch = payload.get("batch_protocol")
    ios = payload.get("ios_companion")
    receiver = payload.get("receiver_cli")
    scope = payload.get("release_scope")
    if (
        set(payload) != expected_keys
        or payload.get("schema_id") != "health_bridge.component_versions.v1"
        or not isinstance(batch, dict)
        or set(batch) != {"schema_id", "version"}
        or not isinstance(ios, dict)
        or set(ios) != {"build", "marketing_version"}
        or not isinstance(receiver, dict)
        or set(receiver) != {"release_tag", "version"}
    ):
        message = f"{surface} schema is not exact"
        raise ReleaseError(message)
    match scope:
        case "receiver" | "coordinated":
            release_scope: ReleaseScope = scope
        case _:
            message = "component version index release_scope must be explicit"
            raise ReleaseError(message)
    batch_schema_id = _required_component_string(batch, "schema_id", surface)
    batch_version = _required_component_string(batch, "version", surface)
    ios_build = _required_component_string(ios, "build", surface)
    ios_version = _required_component_string(ios, "marketing_version", surface)
    receiver_tag = _required_component_string(receiver, "release_tag", surface)
    receiver_version = _required_component_string(receiver, "version", surface)
    _ = _stable_version_tuple(
        receiver_version,
        surface=f"{surface} Receiver/CLI version",
    )
    _ = _stable_version_tuple(
        ios_version,
        surface=f"{surface} iOS Companion version",
    )
    _ = _stable_version_tuple(
        batch_version,
        surface=f"{surface} Batch Protocol version",
    )
    if not ios_build.isdecimal() or int(ios_build) < 1:
        message = f"{surface} iOS build must be a positive integer"
        raise ReleaseError(message)
    expected_tag = _expected_receiver_tag(receiver_version)
    if receiver_tag != expected_tag:
        message = f"{surface} Receiver/CLI tag must be {expected_tag}"
        raise ReleaseError(message)
    return ComponentSnapshot(
        release_scope=release_scope,
        receiver_version=receiver_version,
        receiver_tag=receiver_tag,
        ios_version=ios_version,
        ios_build=int(ios_build),
        batch_version=batch_version,
        batch_schema_id=batch_schema_id,
    )


def _validate_component_version_index(
    repo: Path,
    versions: ReleaseVersions,
    *,
    release_tag: str,
) -> None:
    batch = _batch_contract(repo)
    expected = ComponentSnapshot(
        release_scope=versions.components.release_scope,
        receiver_version=versions.project_version,
        receiver_tag=release_tag,
        ios_version=versions.ios_marketing_version,
        ios_build=int(versions.ios_build),
        batch_version=batch["schema_version"],
        batch_schema_id=batch["schema_id"],
    )
    if versions.components != expected:
        message = "component version index does not match release source versions"
        raise ReleaseError(message)


def _git_output(repo: Path, *args: str) -> str:
    if GIT_EXECUTABLE is None:
        message = "Git executable is required for trusted transition validation"
        raise ReleaseError(message)
    completed = subprocess.run(  # noqa: S603
        [GIT_EXECUTABLE, *args],
        cwd=repo,
        capture_output=True,
        check=False,
        text=True,
    )
    if completed.returncode != 0:
        message = "trusted release commit could not be resolved"
        raise ReleaseError(message)
    return completed.stdout.strip()


def _transition_baseline(request: TransitionRequest) -> ComponentSnapshot:
    commits = (
        request.tag_target_commit,
        request.default_main_commit,
        request.baseline_commit,
    )
    if any(HEX_SHA_PATTERN.fullmatch(commit) is None for commit in commits):
        message = "trusted transition commits must be lowercase 40-character Git SHAs"
        raise ReleaseError(message)
    checked_out = _git_output(request.repo, "rev-parse", "HEAD")
    if checked_out != request.tag_target_commit:
        message = "tag target must equal the checked-out commit"
        raise ReleaseError(message)
    if request.tag_target_commit != request.default_main_commit:
        message = "tag target must equal the trusted default-main commit"
        raise ReleaseError(message)
    expected_baseline = _git_output(
        request.repo,
        "rev-parse",
        f"{request.tag_target_commit}^1",
    )
    if request.baseline_commit != expected_baseline:
        message = "baseline must equal the tag target's first parent"
        raise ReleaseError(message)
    return _read_component_snapshot(
        _git_output(
            request.repo,
            "show",
            f"{request.baseline_commit}:{COMPONENT_VERSION_INDEX.as_posix()}",
        ),
        surface="baseline component version index",
    )


def _component_change_flags(
    candidate: ComponentSnapshot,
    baseline: ComponentSnapshot,
) -> tuple[bool, bool]:
    candidate_receiver = _stable_version_tuple(
        candidate.receiver_version,
        surface="candidate Receiver/CLI version",
    )
    baseline_receiver = _stable_version_tuple(
        baseline.receiver_version,
        surface="baseline Receiver/CLI version",
    )
    if candidate_receiver <= baseline_receiver:
        message = "Receiver/CLI version must advance from the baseline"
        raise ReleaseError(message)
    candidate_ios = _stable_version_tuple(
        candidate.ios_version,
        surface="candidate iOS Companion version",
    )
    baseline_ios = _stable_version_tuple(
        baseline.ios_version,
        surface="baseline iOS Companion version",
    )
    candidate_batch = _stable_version_tuple(
        candidate.batch_version,
        surface="candidate Batch Protocol version",
    )
    baseline_batch = _stable_version_tuple(
        baseline.batch_version,
        surface="baseline Batch Protocol version",
    )
    if (
        candidate_ios < baseline_ios
        or candidate.ios_build < baseline.ios_build
        or candidate_batch < baseline_batch
    ):
        message = "component versions must not regress from the baseline"
        raise ReleaseError(message)
    ios_changed = (
        candidate.ios_version,
        candidate.ios_build,
    ) != (
        baseline.ios_version,
        baseline.ios_build,
    )
    batch_changed = (
        candidate.batch_version,
        candidate.batch_schema_id,
    ) != (
        baseline.batch_version,
        baseline.batch_schema_id,
    )
    if (
        candidate.batch_schema_id != baseline.batch_schema_id
        and candidate_batch == baseline_batch
    ):
        message = "Batch Protocol schema changes must advance its version"
        raise ReleaseError(message)
    if ios_changed and candidate.ios_build <= baseline.ios_build:
        message = "iOS component updates must advance the build number"
        raise ReleaseError(message)
    return ios_changed, batch_changed


def _validate_scope_transition(
    candidate: ComponentSnapshot,
    ios_changed: bool,
    batch_changed: bool,
) -> None:
    match candidate.release_scope:
        case "receiver":
            if ios_changed or batch_changed:
                message = "receiver scope must preserve baseline iOS and Batch Protocol"
                raise ReleaseError(message)
        case "coordinated":
            if not ios_changed and not batch_changed:
                message = "coordinated scope must advance iOS or Batch Protocol"
                raise ReleaseError(message)
        case unreachable:
            assert_never(unreachable)


def validate_component_transition(
    request: TransitionRequest,
    versions: ReleaseVersions,
) -> None:
    baseline = _transition_baseline(request)
    ios_changed, batch_changed = _component_change_flags(
        versions.components,
        baseline,
    )
    _validate_scope_transition(versions.components, ios_changed, batch_changed)


def create_manifest(request: ManifestRequest) -> None:
    versions = validate_tag(request.repo, request.tag)
    if any(
        HEX_SHA_PATTERN.fullmatch(value) is None
        for value in (request.tag_object, request.commit, request.tree)
    ):
        message = "tag object, commit, and tree must be lowercase 40-character Git SHAs"
        raise ReleaseError(message)
    if request.output.parent.resolve() != request.dist.resolve():
        message = "release metadata output must be inside dist directory"
        raise ReleaseError(message)
    artifacts = _release_artifacts(request.dist, versions.project_version)
    payload: dict[str, Any] = {
        "batch_contract": _batch_contract(request.repo),
        "git": {
            "commit": request.commit,
            "tag": request.tag,
            "tag_object": request.tag_object,
            "tree": request.tree,
        },
        "ios": {
            "build": versions.ios_build,
            "marketing_version": versions.ios_marketing_version,
            "source_settings": IOS_SOURCE_SETTINGS.as_posix(),
            "source_settings_sha256": _sha256(request.repo / IOS_SOURCE_SETTINGS),
        },
        "python": {
            "artifacts": [
                {
                    "bytes": artifact.stat().st_size,
                    "filename": artifact.name,
                    "sha256": _sha256(artifact),
                }
                for artifact in artifacts
            ],
            "package": "apple-health-ai-bridge",
            "requires_python": versions.requires_python,
            "version": versions.project_version,
        },
        "release_scope": _release_scope(versions),
        "release_version": versions.project_version,
        "schema_id": "health_bridge.release.v2",
    }
    encoded = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()
    _atomic_write(request.output, encoded)


def _metadata_artifact_records(payload: object) -> dict[str, tuple[str, int]]:
    try:
        artifacts = payload["python"]["artifacts"]  # type: ignore[index]
    except (KeyError, TypeError) as exc:
        message = "release metadata has invalid Python artifact entries"
        raise ReleaseError(message) from exc
    if not isinstance(artifacts, list) or not artifacts:
        message = "release metadata has invalid Python artifact entries"
        raise ReleaseError(message)
    expected: dict[str, tuple[str, int]] = {}
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            message = "release metadata has invalid Python artifact entries"
            raise ReleaseError(message)
        name = artifact.get("filename")
        digest = artifact.get("sha256")
        size = artifact.get("bytes")
        if (
            set(artifact) != {"bytes", "filename", "sha256"}
            or not isinstance(name, str)
            or Path(name).name != name
            or not isinstance(digest, str)
            or SHA256_PATTERN.fullmatch(digest) is None
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size < 0
            or name in expected
        ):
            message = "release metadata contains an invalid artifact record"
            raise ReleaseError(message)
        expected[name] = (digest, size)
    return expected


def _expected_ios_metadata(repo: Path, versions: ReleaseVersions) -> dict[str, str]:
    return {
        "build": versions.ios_build,
        "marketing_version": versions.ios_marketing_version,
        "source_settings": IOS_SOURCE_SETTINGS.as_posix(),
        "source_settings_sha256": _sha256(repo / IOS_SOURCE_SETTINGS),
    }


def _expected_python_artifact_names(versions: ReleaseVersions) -> set[str]:
    return {
        f"apple_health_ai_bridge-{versions.project_version}-py3-none-any.whl",
        f"apple_health_ai_bridge-{versions.project_version}.tar.gz",
    }


def _expected_git_identity(
    *,
    tag: str,
    tag_object: str,
    commit: str,
    tree: str,
) -> dict[str, str]:
    if any(
        HEX_SHA_PATTERN.fullmatch(value) is None for value in (tag_object, commit, tree)
    ):
        message = "release Git identity must use lowercase 40-character SHAs"
        raise ReleaseError(message)
    return {
        "commit": commit,
        "tag": tag,
        "tag_object": tag_object,
        "tree": tree,
    }


def _validate_release_metadata(
    repo: Path,
    payload: object,
    versions: ReleaseVersions,
    *,
    expected_git: dict[str, str],
) -> dict[str, tuple[str, int]]:
    expected_top_level = {
        "batch_contract",
        "git",
        "ios",
        "python",
        "release_scope",
        "release_version",
        "schema_id",
    }
    if not isinstance(payload, dict) or set(payload) != expected_top_level:
        message = "release metadata top-level schema is not exact"
        raise ReleaseError(message)
    if (
        payload.get("schema_id") != "health_bridge.release.v2"
        or payload.get("release_scope") != _release_scope(versions)
        or payload.get("release_version") != versions.project_version
        or payload.get("batch_contract") != _batch_contract(repo)
        or payload.get("ios") != _expected_ios_metadata(repo, versions)
        or payload.get("git") != expected_git
    ):
        message = "release metadata version, scope, source, or compatibility is invalid"
        raise ReleaseError(message)
    python = payload.get("python")
    if (
        not isinstance(python, dict)
        or set(python) != {"artifacts", "package", "requires_python", "version"}
        or python.get("package") != "apple-health-ai-bridge"
        or python.get("version") != versions.project_version
        or python.get("requires_python") != versions.requires_python
    ):
        message = "release metadata Python package or runtime contract is invalid"
        raise ReleaseError(message)
    records = _metadata_artifact_records(payload)
    if set(records) != _expected_python_artifact_names(versions):
        message = "release metadata artifact file set is not exact"
        raise ReleaseError(message)
    return records


def _exact_regular_file_names(
    directory: Path, *, excluded_names: set[str] | None = None
) -> set[str]:
    excluded = excluded_names or set()
    names: set[str] = set()
    for path in directory.iterdir():
        if path.name in excluded:
            continue
        if path.is_symlink() or not path.is_file():
            message = "release packet file set contains a non-regular entry"
            raise ReleaseError(message)
        names.add(path.name)
    return names


def create_checksums(request: ChecksumRequest) -> None:
    versions = validate_tag(request.repo, request.tag)
    expected_git = _expected_git_identity(
        tag=request.tag,
        tag_object=request.tag_object,
        commit=request.commit,
        tree=request.tree,
    )
    if request.output.parent.resolve() != request.dist.resolve():
        message = "checksum output must be inside dist directory"
        raise ReleaseError(message)
    metadata = request.dist / "release-metadata.json"
    payload = json.loads(metadata.read_text(encoding="utf-8"))
    expected_artifacts = _validate_release_metadata(
        request.repo,
        payload,
        versions,
        expected_git=expected_git,
    )
    artifact_names = set(expected_artifacts)
    release_notes = request.dist / "release-notes.md"
    if not release_notes.is_file() or release_notes.is_symlink():
        message = "release-notes.md must exist before creating checksums"
        raise ReleaseError(message)
    expected_names = artifact_names | {metadata.name, release_notes.name}
    present_names = _exact_regular_file_names(
        request.dist,
        excluded_names={request.output.name},
    )
    if present_names != expected_names:
        message = "release checksum inputs must exactly match release metadata"
        raise ReleaseError(message)
    for name, (expected_digest, expected_size) in expected_artifacts.items():
        artifact = request.dist / name
        if (
            artifact.stat().st_size != expected_size
            or _sha256(artifact) != expected_digest
        ):
            message = f"artifact no longer matches release metadata: {name}"
            raise ReleaseError(message)
    public_asset_names = artifact_names | {metadata.name}
    files = [request.dist / name for name in sorted(public_asset_names)]
    lines = "".join(f"{_sha256(path)}  {path.name}\n" for path in files)
    _atomic_write(request.output, lines.encode("utf-8"))


def _verify_packet_checksums(dist: Path, expected_names: set[str]) -> None:
    checksum_lines = (dist / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
    checksums: dict[str, str] = {}
    for line in checksum_lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/\\]+)", line)
        if match is None or match.group(2) in checksums:
            message = "release checksum manifest is invalid"
            raise ReleaseError(message)
        checksums[match.group(2)] = match.group(1)
    public_checksum_names = expected_names - {"SHA256SUMS", "release-notes.md"}
    if set(checksums) != public_checksum_names:
        message = "release checksum manifest file set is not exact"
        raise ReleaseError(message)
    for name, digest in checksums.items():
        if _sha256(dist / name) != digest:
            message = f"release packet checksum mismatch: {name}"
            raise ReleaseError(message)


def _verify_packet_metadata(
    request: PacketVerificationRequest,
    versions: ReleaseVersions,
    expected_names: set[str],
) -> None:
    payload = json.loads(
        (request.dist / "release-metadata.json").read_text(encoding="utf-8")
    )
    expected_git = _expected_git_identity(
        tag=request.tag,
        tag_object=request.tag_object,
        commit=request.commit,
        tree=request.tree,
    )
    records = _validate_release_metadata(
        request.repo,
        payload,
        versions,
        expected_git=expected_git,
    )
    expected_artifacts = expected_names - {
        "release-metadata.json",
        "release-notes.md",
        "SHA256SUMS",
    }
    if set(records) != expected_artifacts:
        message = "release metadata artifact file set is not exact"
        raise ReleaseError(message)
    for name, (digest, size) in records.items():
        path = request.dist / name
        if path.stat().st_size != size or _sha256(path) != digest:
            message = f"release metadata artifact mismatch: {name}"
            raise ReleaseError(message)


def verify_packet(request: PacketVerificationRequest) -> None:
    versions = validate_tag(request.repo, request.tag)
    if any(
        HEX_SHA_PATTERN.fullmatch(value) is None
        for value in (request.tag_object, request.commit, request.tree)
    ):
        message = "tag object, commit, and tree must be lowercase 40-character Git SHAs"
        raise ReleaseError(message)
    expected_names = {
        f"apple_health_ai_bridge-{versions.project_version}-py3-none-any.whl",
        f"apple_health_ai_bridge-{versions.project_version}.tar.gz",
        "release-metadata.json",
        "release-notes.md",
        "SHA256SUMS",
    }
    present_names = _exact_regular_file_names(request.dist)
    if present_names != expected_names:
        message = "downloaded release packet file set is not exact"
        raise ReleaseError(message)
    _verify_packet_checksums(request.dist, expected_names)
    expected_notes = request.repo / ".github/release" / f"notes-{request.tag}.md"
    if (request.dist / "release-notes.md").read_bytes() != expected_notes.read_bytes():
        message = "release notes do not match the exact source tag"
        raise ReleaseError(message)
    _verify_packet_metadata(request, versions, expected_names)


def _verify_release_identity(
    payload: dict[str, Any],
    request: DraftVerificationRequest,
    *,
    expected_draft: bool,
) -> None:
    state_name = "draft" if expected_draft else "published"
    parsed_tag = parse_receiver_release_tag(request.tag)
    if (
        payload.get("tag_name") != request.tag
        or payload.get("name") != request.tag
        or payload.get("draft") is not expected_draft
        or payload.get("prerelease") is not parsed_tag.is_prerelease
    ):
        message = f"GitHub {state_name} release metadata is not exact"
        raise ReleaseError(message)
    expected_notes = request.notes_file.read_text(encoding="utf-8")
    if payload.get("body") != expected_notes:
        message = "release body does not match exact notes"
        raise ReleaseError(message)


def _release_asset_records(payload: dict[str, Any]) -> dict[str, tuple[str, int, str]]:
    assets = payload.get("assets")
    if not isinstance(assets, list):
        message = "GitHub release assets must be a list"
        raise ReleaseError(message)
    remote_assets: dict[str, tuple[str, int, str]] = {}
    for asset in assets:
        if not isinstance(asset, dict):
            message = "GitHub release contains an invalid asset"
            raise ReleaseError(message)
        name = asset.get("name")
        digest = asset.get("digest")
        size = asset.get("size")
        state = asset.get("state")
        if (
            not isinstance(name, str)
            or name in remote_assets
            or not isinstance(digest, str)
            or not isinstance(size, int)
            or not isinstance(state, str)
        ):
            message = "GitHub release contains an invalid asset"
            raise ReleaseError(message)
        remote_assets[name] = (digest, size, state)
    return remote_assets


def verify_release_state(
    request: DraftVerificationRequest, *, expected_draft: bool
) -> None:
    versions = validate_tag(request.repo, request.tag)
    payload = json.loads(request.release_json.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        message = "GitHub release response must be an object"
        raise ReleaseError(message)
    _verify_release_identity(payload, request, expected_draft=expected_draft)
    metadata_payload = json.loads(
        (request.dist / "release-metadata.json").read_text(encoding="utf-8")
    )
    expected_git = _expected_git_identity(
        tag=request.tag,
        tag_object=request.tag_object,
        commit=request.commit,
        tree=request.tree,
    )
    artifact_records = _validate_release_metadata(
        request.repo,
        metadata_payload,
        versions,
        expected_git=expected_git,
    )
    for name, (digest, size) in artifact_records.items():
        local = request.dist / name
        if (
            local.is_symlink()
            or not local.is_file()
            or local.stat().st_size != size
            or _sha256(local) != digest
        ):
            message = f"release metadata artifact mismatch: {name}"
            raise ReleaseError(message)
    remote_assets = _release_asset_records(payload)
    expected_names = _expected_python_artifact_names(versions) | {
        "SHA256SUMS",
        "release-metadata.json",
    }
    if set(remote_assets) != expected_names:
        message = "GitHub release asset file set is not exact"
        raise ReleaseError(message)
    for name, (digest, size, state) in remote_assets.items():
        local = request.dist / name
        if local.is_symlink() or not local.is_file() or state != "uploaded":
            message = f"GitHub release asset is not ready: {name}"
            raise ReleaseError(message)
        if digest != f"sha256:{_sha256(local)}" or size != local.stat().st_size:
            message = f"remote asset digest mismatch: {name}"
            raise ReleaseError(message)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Build exact-tag release metadata.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    tag_info = subparsers.add_parser("tag-info")
    tag_info.add_argument("--tag", required=True)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--repo", type=Path, required=True)
    validate.add_argument("--tag", required=True)
    validate.add_argument("--tag-target-commit")
    validate.add_argument("--default-main-commit")
    validate.add_argument("--baseline-commit")

    manifest = subparsers.add_parser("manifest")
    manifest.add_argument("--repo", type=Path, required=True)
    manifest.add_argument("--dist-dir", type=Path, required=True)
    manifest.add_argument("--tag", required=True)
    manifest.add_argument("--tag-object", required=True)
    manifest.add_argument("--commit", required=True)
    manifest.add_argument("--tree", required=True)
    manifest.add_argument("--output", type=Path, required=True)

    checksums = subparsers.add_parser("checksums")
    checksums.add_argument("--repo", type=Path, required=True)
    checksums.add_argument("--dist-dir", type=Path, required=True)
    checksums.add_argument("--tag", required=True)
    checksums.add_argument("--tag-object", required=True)
    checksums.add_argument("--commit", required=True)
    checksums.add_argument("--tree", required=True)
    checksums.add_argument("--output", type=Path, required=True)

    verify_packet_parser = subparsers.add_parser("verify-packet")
    verify_packet_parser.add_argument("--repo", type=Path, required=True)
    verify_packet_parser.add_argument("--dist-dir", type=Path, required=True)
    verify_packet_parser.add_argument("--tag", required=True)
    verify_packet_parser.add_argument("--tag-object", required=True)
    verify_packet_parser.add_argument("--commit", required=True)
    verify_packet_parser.add_argument("--tree", required=True)
    for command in ("verify-draft", "verify-published"):
        verify_release_parser = subparsers.add_parser(command)
        verify_release_parser.add_argument("--repo", type=Path, required=True)
        verify_release_parser.add_argument("--dist-dir", type=Path, required=True)
        verify_release_parser.add_argument("--release-json", type=Path, required=True)
        verify_release_parser.add_argument("--notes-file", type=Path, required=True)
        verify_release_parser.add_argument("--tag", required=True)
        verify_release_parser.add_argument("--tag-object", required=True)
        verify_release_parser.add_argument("--commit", required=True)
        verify_release_parser.add_argument("--tree", required=True)
    return parser


def _transition_request(
    repo: Path,
    commits: tuple[str | None, str | None, str | None],
) -> TransitionRequest | None:
    match commits:
        case (None, None, None):
            return None
        case (str(tag_target), str(default_main), str(baseline)):
            return TransitionRequest(
                repo=repo,
                tag_target_commit=tag_target,
                default_main_commit=default_main,
                baseline_commit=baseline,
            )
        case _:
            message = "all trusted transition commits are required together"
            raise ReleaseError(message)


def main() -> int:
    args = _parser().parse_args()
    try:
        if args.command == "tag-info":
            parsed_tag = parse_receiver_release_tag(args.tag)
            sys.stdout.write(
                json.dumps(
                    {
                        "prerelease": parsed_tag.is_prerelease,
                        "tag": parsed_tag.tag,
                        "version": str(parsed_tag.version),
                    },
                    sort_keys=True,
                )
                + "\n"
            )
        elif args.command == "validate":
            versions = validate_tag(args.repo, args.tag)
            transition_commits = (
                args.tag_target_commit,
                args.default_main_commit,
                args.baseline_commit,
            )
            transition = _transition_request(args.repo, transition_commits)
            if transition is not None:
                validate_component_transition(transition, versions)
            sys.stdout.write(
                json.dumps(
                    {
                        "ios_build": versions.ios_build,
                        "ios_marketing_version": versions.ios_marketing_version,
                        "project_version": versions.project_version,
                        "release_scope": _release_scope(versions),
                        "tag": args.tag,
                    },
                    sort_keys=True,
                )
                + "\n"
            )
        elif args.command == "manifest":
            create_manifest(
                ManifestRequest(
                    repo=args.repo,
                    dist=args.dist_dir,
                    tag=args.tag,
                    tag_object=args.tag_object,
                    commit=args.commit,
                    tree=args.tree,
                    output=args.output,
                )
            )
        elif args.command == "checksums":
            create_checksums(
                ChecksumRequest(
                    repo=args.repo,
                    dist=args.dist_dir,
                    tag=args.tag,
                    tag_object=args.tag_object,
                    commit=args.commit,
                    tree=args.tree,
                    output=args.output,
                )
            )
        elif args.command == "verify-packet":
            verify_packet(
                PacketVerificationRequest(
                    repo=args.repo,
                    dist=args.dist_dir,
                    tag=args.tag,
                    tag_object=args.tag_object,
                    commit=args.commit,
                    tree=args.tree,
                )
            )
        elif args.command in {"verify-draft", "verify-published"}:
            verify_release_state(
                DraftVerificationRequest(
                    repo=args.repo,
                    dist=args.dist_dir,
                    release_json=args.release_json,
                    notes_file=args.notes_file,
                    tag=args.tag,
                    tag_object=args.tag_object,
                    commit=args.commit,
                    tree=args.tree,
                ),
                expected_draft=args.command == "verify-draft",
            )
    except (
        OSError,
        ReleaseError,
        json.JSONDecodeError,
        tomllib.TOMLDecodeError,
    ) as exc:
        sys.stderr.write(f"{exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
