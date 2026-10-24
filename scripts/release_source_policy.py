#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Final, Protocol, TypeAlias

if TYPE_CHECKING:
    from collections.abc import Callable

    from scripts.release_versions import ReleaseError, parse_receiver_release_tag
else:
    from release_versions import ReleaseError, parse_receiver_release_tag

REPOSITORY: Final = "roian6/apple-health-ai-bridge"
AUTHORITY_PATH: Final = ".github/release/receiver-maintenance.json"
SHA: Final = re.compile(r"[0-9a-f]{40}")
JsonValue: TypeAlias = (
    "str | int | float | bool | None | list[JsonValue] | dict[str, JsonValue]"
)
JsonObject: TypeAlias = dict[str, JsonValue]


class JsonLoader(Protocol):
    def __call__(
        self,
        raw: str,
        /,
        *,
        object_pairs_hook: Callable[[list[tuple[str, JsonValue]]], JsonObject],
    ) -> JsonValue: ...


class Arguments(argparse.Namespace):
    repo: Path = Path()
    tag: str = ""
    commit: str = ""
    tag_object: str = ""


@dataclass(frozen=True, slots=True)
class ReleaseSource:
    default_main_commit: str
    baseline_commit: str


@dataclass(frozen=True, slots=True)
class SourceRequest:
    repo: Path
    tag: str
    commit: str
    tag_object: str


@dataclass(frozen=True, slots=True)
class MaintenanceAuthorization:
    tag: str
    branch_ref: str
    base_tag: str
    base_commit: str
    target_commit: str


def _run(repo: Path, command: str, *args: str) -> str:
    executable = shutil.which(command)
    if executable is None:
        message = f"release source requires {command}"
        raise ReleaseError(message)
    completed = subprocess.run(  # noqa: S603
        [executable, *args], cwd=repo, capture_output=True, text=True, check=False
    )
    if completed.returncode:
        message = f"release source {command} lookup failed"
        raise ReleaseError(message)
    return completed.stdout.strip()


def _unique_object(pairs: list[tuple[str, JsonValue]]) -> JsonObject:
    result: JsonObject = {}
    for key, value in pairs:
        if key in result:
            message = "duplicate release source JSON field"
            raise ReleaseError(message)
        result[key] = value
    return result


def _object(value: JsonValue) -> JsonObject:
    if not isinstance(value, dict):
        message = "release source JSON must be an object"
        raise ReleaseError(message)
    return value


def _document(raw: str, loader: JsonLoader = json.loads) -> JsonObject:
    try:
        value = loader(raw, object_pairs_hook=_unique_object)
    except json.JSONDecodeError as exc:
        message = "invalid release source JSON"
        raise ReleaseError(message) from exc
    return _object(value)


def _string(payload: JsonObject, key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str):
        message = f"release source {key} must be a string"
        raise ReleaseError(message)
    return value


def _sha(value: str) -> str:
    if SHA.fullmatch(value) is None:
        message = "release source requires lowercase 40-character Git SHAs"
        raise ReleaseError(message)
    return value


def _api(repo: Path, route: str) -> JsonObject:
    return _document(_run(repo, "gh", "api", f"/repos/{REPOSITORY}{route}"))


def _git(repo: Path, *args: str) -> str:
    return _run(repo, "git", "--no-replace-objects", *args)


def _revision_document(repo: Path, commit: str, path: str) -> JsonObject:
    return _document(_git(repo, "show", f"{commit}:{path}"))


def _branch_head(branch: JsonObject) -> str:
    return _sha(_string(_object(branch.get("commit")), "sha"))


def _verified(payload: JsonObject) -> bool:
    verification = _object(payload.get("verification"))
    return (
        verification.get("verified") is True and verification.get("reason") == "valid"
    )


def _verify_tag(request: SourceRequest) -> None:
    ref = _object(_api(request.repo, f"/git/ref/tags/{request.tag}").get("object"))
    if ref.get("type") != "tag" or ref.get("sha") != request.tag_object:
        message = "release source annotated tag object changed"
        raise ReleaseError(message)
    tag = _api(request.repo, f"/git/tags/{request.tag_object}")
    target = _object(tag.get("object"))
    tagger = _object(tag.get("tagger"))
    if (
        tag.get("tag") != request.tag
        or target.get("type") != "commit"
        or target.get("sha") != request.commit
        or not _verified(tag)
        or tagger.get("name") != "Chanhyo Jung"
        or _string(tagger, "email").partition("@")
        != ("23256775+roian6", "@", "users.noreply.github.com")
        or _git(request.repo, "rev-parse", f"refs/tags/{request.tag}^{{tag}}")
        != request.tag_object
        or _git(request.repo, "rev-parse", f"{request.tag_object}^{{commit}}")
        != request.commit
    ):
        message = "release source signed tag identity or target mismatch"
        raise ReleaseError(message)
    metadata = _api(request.repo, f"/commits/{request.commit}")
    commit = _object(metadata.get("commit"))
    if (
        not _verified(commit)
        or _object(metadata.get("author")).get("login") != "roian6"
        or _object(metadata.get("committer")).get("login") != "web-flow"
        or _object(commit.get("author")).get("name") != "Chanhyo Jung"
        or _object(commit.get("committer")).get("name") != "GitHub"
        or _string(_object(commit.get("committer")), "email").partition("@")
        != ("noreply", "@", "github.com")
    ):
        message = "release source requires verified maintainer squash commit"
        raise ReleaseError(message)


def _authorizations(repo: Path, main: str) -> list[MaintenanceAuthorization]:
    document = _revision_document(repo, main, AUTHORITY_PATH)
    releases = document.get("releases")
    if (
        set(document) != {"schema_id", "releases"}
        or document.get("schema_id") != "health_bridge.receiver_maintenance.v1"
        or not isinstance(releases, list)
    ):
        message = "maintenance authorization schema is not exact"
        raise ReleaseError(message)
    records: list[MaintenanceAuthorization] = []
    tags: set[str] = set()
    branches: set[str] = set()
    targets: set[str] = set()
    for value in releases:
        record = _object(value)
        if set(record) != {
            "tag",
            "branch_ref",
            "base_tag",
            "base_commit",
            "target_commit",
        }:
            message = "maintenance authorization fields are not exact"
            raise ReleaseError(message)
        entry = MaintenanceAuthorization(
            _string(record, "tag"),
            _string(record, "branch_ref"),
            _string(record, "base_tag"),
            _sha(_string(record, "base_commit")),
            _sha(_string(record, "target_commit")),
        )
        version = parse_receiver_release_tag(entry.tag).version
        base = parse_receiver_release_tag(entry.base_tag).version
        if (
            version.as_tuple() != (base.major, base.minor, base.patch + 1)
            or entry.branch_ref != f"refs/heads/fix/receiver-{version}"
            or entry.tag in tags
            or entry.branch_ref in branches
            or entry.target_commit in targets
            or entry.base_commit == entry.target_commit
        ):
            message = "maintenance authorization must pin a unique next-patch branch"
            raise ReleaseError(message)
        tags.add(entry.tag)
        branches.add(entry.branch_ref)
        targets.add(entry.target_commit)
        records.append(entry)
    return records


def _validate_maintenance(
    request: SourceRequest, source: ReleaseSource, entry: MaintenanceAuthorization
) -> None:
    repo = request.repo
    branch_name = entry.branch_ref.removeprefix("refs/heads/")
    branch = _api(repo, f"/branches/{branch_name}")
    if (
        branch.get("name") != branch_name
        or branch.get("protected") is not True
        or _branch_head(branch) != request.commit
    ):
        message = "protected maintenance branch HEAD must equal authorized target"
        raise ReleaseError(message)
    base_ref = _object(_api(repo, f"/git/ref/tags/{entry.base_tag}").get("object"))
    base_object = _sha(_string(base_ref, "sha"))
    base_target = _object(_api(repo, f"/git/tags/{base_object}").get("object"))
    if (
        base_ref.get("type") != "tag"
        or base_target.get("type") != "commit"
        or base_target.get("sha") != entry.base_commit
        or _git(repo, "rev-parse", f"refs/tags/{entry.base_tag}^{{tag}}") != base_object
        or _git(repo, "rev-parse", f"refs/tags/{entry.base_tag}^{{commit}}")
        != entry.base_commit
    ):
        message = "maintenance immutable base tag/commit mismatch"
        raise ReleaseError(message)
    ancestors = _git(
        repo, "rev-list", "--first-parent", source.baseline_commit
    ).splitlines()
    if entry.base_commit not in ancestors or _git(
        repo, "rev-list", "--merges", f"{entry.base_commit}..{request.commit}"
    ):
        message = "maintenance target must descend linearly from its immutable base"
        raise ReleaseError(message)
    index = "component-versions.json"
    base = _revision_document(repo, entry.base_commit, index)
    parent = _revision_document(repo, source.baseline_commit, index)
    candidate = _revision_document(repo, request.commit, index)
    if (
        candidate.get("release_scope") != "receiver"
        or _object(base.get("receiver_cli"))
        != {
            "release_tag": entry.base_tag,
            "version": str(parse_receiver_release_tag(entry.base_tag).version),
        }
        or parent.get("receiver_cli") != base.get("receiver_cli")
        or _object(candidate.get("receiver_cli"))
        != {
            "release_tag": entry.tag,
            "version": str(parse_receiver_release_tag(entry.tag).version),
        }
        or any(
            candidate.get(key) != base.get(key) or parent.get(key) != base.get(key)
            for key in ("ios_companion", "batch_protocol")
        )
        or _git(repo, "rev-parse", f"{entry.base_commit}:ios")
        != _git(repo, "rev-parse", f"{request.commit}:ios")
    ):
        message = (
            "maintenance patch must preserve base iOS source/build and Batch Protocol"
        )
        raise ReleaseError(message)


def resolve_release_source(request: SourceRequest) -> ReleaseSource:
    _ = parse_receiver_release_tag(request.tag)
    _ = _sha(request.commit)
    _ = _sha(request.tag_object)
    if _git(request.repo, "rev-parse", "HEAD") != request.commit:
        message = "release source target must equal checkout"
        raise ReleaseError(message)
    _verify_tag(request)
    if _api(request.repo, "").get("default_branch") != "main":
        message = "release source authority must be default main"
        raise ReleaseError(message)
    branch = _api(request.repo, "/branches/main")
    main = _branch_head(branch)
    source = ReleaseSource(
        main, _sha(_git(request.repo, "rev-parse", f"{request.commit}^1"))
    )
    if request.commit == main:
        return source
    if branch.get("protected") is not True:
        message = "maintenance authority requires protected default main"
        raise ReleaseError(message)
    _ = _git(request.repo, "fetch", "--no-tags", "origin", main)
    for entry in _authorizations(request.repo, main):
        if entry.tag == request.tag and entry.target_commit == request.commit:
            _validate_maintenance(request, source, entry)
            return source
    message = (
        "tag target must equal the trusted default-main commit "
        "or exact maintenance authorization"
    )
    raise ReleaseError(message)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Resolve fresh protected release source"
    )
    _ = parser.add_argument("--repo", type=Path, required=True)
    _ = parser.add_argument("--tag", required=True)
    _ = parser.add_argument("--commit", required=True)
    _ = parser.add_argument("--tag-object", required=True)
    args = parser.parse_args(namespace=Arguments())
    try:
        source = resolve_release_source(
            SourceRequest(args.repo, args.tag, args.commit, args.tag_object)
        )
    except ReleaseError as exc:
        _ = sys.stderr.write(f"{exc}\n")
        return 1
    _ = sys.stdout.write(json.dumps(asdict(source), sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
