#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tempfile
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final

HEX_SHA_PATTERN: Final = re.compile(r"^[0-9a-f]{40}$")
SHA256_PATTERN: Final = re.compile(r"^[0-9a-f]{64}$")
STABLE_VERSION_PATTERN: Final = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)
XCODE_ASSIGNMENT_TEMPLATE: Final = r"\b{key}\s*=\s*([^;]+);"
IOS_SOURCE_SETTINGS: Final = Path(
    "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj"
)


class ReleaseError(ValueError):
    """Expected release-input failure safe to print to CI logs."""


@dataclass(frozen=True, slots=True)
class ReleaseVersions:
    project_version: str
    requires_python: str
    ios_marketing_version: str
    ios_build: str


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
    )


def _stable_version_tuple(value: str, *, surface: str) -> tuple[int, int, int]:
    match = STABLE_VERSION_PATTERN.fullmatch(value)
    if match is None:
        message = f"{surface} must be a stable semantic version"
        raise ReleaseError(message)
    major, minor, patch = match.groups()
    return int(major), int(minor), int(patch)


def _release_scope(versions: ReleaseVersions) -> str:
    project = _stable_version_tuple(versions.project_version, surface="project version")
    ios = _stable_version_tuple(
        versions.ios_marketing_version,
        surface="iOS MARKETING_VERSION",
    )
    if project == ios:
        return "coordinated"
    if project < ios:
        message = "receiver version must be newer than the compatible iOS version"
        raise ReleaseError(message)
    return "receiver"


def validate_tag(repo: Path, tag: str) -> ReleaseVersions:
    versions = read_versions(repo)
    expected = f"v{versions.project_version}"
    if tag != expected:
        message = f"release tag must exactly match project version: {expected}"
        raise ReleaseError(message)
    if not versions.ios_build.isdecimal() or int(versions.ios_build) < 1:
        message = "iOS CURRENT_PROJECT_VERSION must be a positive integer"
        raise ReleaseError(message)
    notes_path = repo / ".github/release" / f"notes-{tag}.md"
    if not notes_path.is_file():
        message = f"versioned release notes are missing: {notes_path}"
        raise ReleaseError(message)
    notes = notes_path.read_text(encoding="utf-8")
    if f"@{tag}" not in notes:
        message = f"release notes must contain the exact install tag: @{tag}"
        raise ReleaseError(message)
    if _release_scope(versions) == "receiver":
        required = (
            "Receiver-only release",
            (
                "Compatible iOS companion: "
                f"`{versions.ios_marketing_version} ({versions.ios_build})`"
            ),
            "No TestFlight update is required",
        )
        missing = [marker for marker in required if marker not in notes]
        if missing:
            message = "receiver-only release notes are missing compatibility markers"
            raise ReleaseError(message)
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
    if (
        payload.get("tag_name") != request.tag
        or payload.get("name") != request.tag
        or payload.get("draft") is not expected_draft
        or payload.get("prerelease")
        is not request.tag.removeprefix("v").startswith("0.")
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

    validate = subparsers.add_parser("validate")
    validate.add_argument("--repo", type=Path, required=True)
    validate.add_argument("--tag", required=True)

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


def main() -> int:
    args = _parser().parse_args()
    try:
        if args.command == "validate":
            versions = validate_tag(args.repo, args.tag)
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
