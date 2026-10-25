#!/usr/bin/env python3
from __future__ import annotations

import re
from datetime import datetime
from typing import TYPE_CHECKING, ClassVar, Final

from pydantic import BaseModel, ConfigDict, Field, JsonValue, TypeAdapter
from release_authority import (
    REPOSITORY,
    Baseline,
    ReleasePolicy,
    git,
    integer,
    object_value,
    pages,
    public_tag,
    string,
)
from release_versions import ReleaseError, parse_receiver_release_tag

if TYPE_CHECKING:
    from pathlib import Path

IOS_TAG: Final = re.compile(r"ios-v([0-9]+)\.([0-9]+)\.([0-9]+)-build\.([1-9][0-9]*)")


class ReleaseSummary(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)
    id: int = Field(gt=0)
    tag_name: str
    draft: bool
    prerelease: bool
    published_at: str | None


def publication_time(value: JsonValue) -> datetime:
    if not isinstance(value, str):
        message = "published Receiver release requires a publication timestamp"
        raise ReleaseError(message)
    try:
        timestamp = datetime.fromisoformat(value)
    except ValueError as exc:
        message = "invalid Receiver publication timestamp"
        raise ReleaseError(message) from exc
    if timestamp.tzinfo is None:
        message = "publication timestamp requires a timezone"
        raise ReleaseError(message)
    return timestamp


def published_receiver(
    repo: Path,
    *,
    before: tuple[int, int, int] | None = None,
    compatible_tag: str | None = None,
) -> Baseline:
    releases: list[tuple[datetime, tuple[int, int, int], str, int]] = []
    for document in pages(repo, "/releases"):
        release = ReleaseSummary.model_validate(document)
        name = release.tag_name
        if not name.startswith(("receiver-v", "v1.0.")):
            continue
        if release.draft or release.prerelease:
            continue
        if compatible_tag is not None and name != compatible_tag:
            continue
        parsed = parse_receiver_release_tag(name)
        if parsed.is_prerelease:
            continue
        version = parsed.version.as_tuple()
        if before is not None and version >= before:
            continue
        published_time = publication_time(release.published_at)
        releases.append((published_time, version, name, release.id))
    if (
        not releases
        or len({name for _, _, name, _ in releases}) != len(releases)
        or len({identity for _, _, _, identity in releases}) != len(releases)
    ):
        msg = "missing or duplicate published Receiver release identity"
        raise ReleaseError(msg)
    _, version, base_tag, release_id = max(releases)
    if version != max(value[1] for value in releases):
        message = "published stable Receiver versions are not monotonic"
        raise ReleaseError(message)
    oid, commit = public_tag(repo, base_tag)
    components = object_value(
        TypeAdapter[JsonValue](JsonValue).validate_json(
            git(repo, "show", f"{commit}:component-versions.json")
        )
    )
    if components.get("receiver_cli") != {
        "version": str(parse_receiver_release_tag(base_tag).version),
        "release_tag": base_tag,
    }:
        message = "published Receiver tag does not match its source component baseline"
        raise ReleaseError(message)
    return Baseline(tag=base_tag, tag_object=oid, commit=commit, release_id=release_id)


def receiver_baseline(
    repo: Path, tag: str, policy: ReleasePolicy, *, published: bool = False
) -> Baseline:
    candidate = parse_receiver_release_tag(tag).version.as_tuple()
    baseline = published_receiver(
        repo,
        before=candidate if published else None,
    )
    version = parse_receiver_release_tag(baseline.tag).version.as_tuple()
    if version >= candidate:
        msg = "candidate must advance the last published Receiver release"
        raise ReleaseError(msg)
    if candidate[:2] == version[:2]:
        retired = {entry.tag: entry for entry in policy.retired_tags}
        for patch in range(version[2] + 1, candidate[2]):
            skipped = f"receiver-v{version[0]}.{version[1]}.{patch}"
            entry = retired.get(skipped)
            if entry is None or public_tag(repo, skipped) != (
                entry.tag_object,
                entry.commit,
            ):
                msg = "patch gap requires an exact retired unpublished tag record"
                raise ReleaseError(msg)
    return baseline


def ios_compatibility(repo: Path, commit: str) -> Baseline:
    components = object_value(
        TypeAdapter[JsonValue](JsonValue).validate_json(
            git(repo, "show", f"{commit}:component-versions.json")
        )
    )
    receiver = object_value(components.get("receiver_cli"))
    return published_receiver(repo, compatible_tag=string(receiver.get("release_tag")))


def checkpoint_passed(repo: Path, tag: str, commit: str) -> bool:
    workflows = {
        "python.yml": "Python quality and package checks",
        "ios.yml": "Swift tests and unsigned app builds",
    }
    for workflow, context in workflows.items():
        runs = pages(
            repo,
            f"/actions/workflows/{workflow}/runs?head_sha={commit}&event=push",
            "workflow_runs",
        )
        runs = [
            run
            for run in runs
            if run.get("head_branch") == tag
            and run.get("head_sha") == commit
            and run.get("path") == f".github/workflows/{workflow}"
        ]
        if not runs:
            return False
        run = max(runs, key=lambda value: integer(value.get("id")))
        if (
            run.get("status") != "completed"
            or run.get("conclusion") != "success"
            or object_value(run.get("repository")).get("full_name") != REPOSITORY
        ):
            return False
        run_id, attempt = integer(run.get("id")), integer(run.get("run_attempt"))
        jobs = pages(repo, f"/actions/runs/{run_id}/attempts/{attempt}/jobs", "jobs")
        matching = [job for job in jobs if job.get("name") == context]
        if (
            len(matching) != 1
            or matching[0].get("head_sha") != commit
            or matching[0].get("status") != "completed"
            or matching[0].get("conclusion") != "success"
        ):
            return False
    return True


def ios_baseline(repo: Path, tag: str, retired: frozenset[str]) -> Baseline:
    candidate = IOS_TAG.fullmatch(tag)
    if candidate is None:
        msg = "invalid iOS checkpoint tag"
        raise ReleaseError(msg)
    current = tuple(int(part) for part in candidate.groups())
    checkpoints: list[tuple[tuple[int, ...], str]] = []
    for ref in pages(repo, "/git/matching-refs/tags/ios-v"):
        name = ref.get("ref")
        if not isinstance(name, str):
            msg = "invalid iOS checkpoint ref"
            raise ReleaseError(msg)
        name = name.removeprefix("refs/tags/")
        match = IOS_TAG.fullmatch(name)
        if match is not None and name != tag and name not in retired:
            checkpoints.append((tuple(int(part) for part in match.groups()), name))
    for version, previous in sorted(checkpoints, reverse=True):
        oid, commit = public_tag(repo, previous)
        if not checkpoint_passed(repo, previous, commit):
            continue
        if version >= current:
            message = "iOS checkpoint must advance its independent baseline"
            raise ReleaseError(message)
        return Baseline(tag=previous, tag_object=oid, commit=commit, release_id=None)
    message = "no previous verified iOS checkpoint"
    raise ReleaseError(message)


def baseline_ancestry(repo: Path, source: str, baseline: Baseline) -> None:
    _ = git(repo, "merge-base", "--is-ancestor", baseline.commit, source)
