#!/usr/bin/env python3
from __future__ import annotations

import json
from typing import TYPE_CHECKING, ClassVar, Literal

from pydantic import BaseModel, ConfigDict, Field
from release_authority import (
    REPOSITORY,
    ArtifactRecord,
    Document,
    GitSha,
    command,
    pages,
)
from release_versions import ReleaseError

if TYPE_CHECKING:
    from pathlib import Path


class ExpectedRelease(BaseModel):
    model_config: ClassVar[ConfigDict] = Document.model_config
    tag: str
    commit: GitSha
    title: str
    notes: str
    assets: list[ArtifactRecord]
    release_id: int | None = Field(default=None, gt=0)


class RemoteAsset(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)
    id: int = Field(gt=0)
    name: str
    size: int = Field(ge=0)
    digest: str
    state: Literal["uploaded"]


class RemoteRelease(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)
    id: int = Field(gt=0)
    tag_name: str
    target_commitish: str
    name: str
    body: str
    draft: bool
    prerelease: bool
    published_at: str | None
    assets: list[RemoteAsset]


class RecoveryPlan(Document):
    release_id: int | None
    action: Literal["create", "upload", "ready", "verify-only"]
    missing: list[str]


def selected_release(
    expected: ExpectedRelease, releases: list[RemoteRelease]
) -> RemoteRelease | None:
    matching = [release for release in releases if release.tag_name == expected.tag]
    if len(matching) > 1:
        msg = "HOLD: duplicate release identities"
        raise ReleaseError(msg)
    if not matching:
        if expected.release_id is not None:
            message = "HOLD: pinned release is missing; never recreate it"
            raise ReleaseError(message)
        return None
    release = matching[0]
    if expected.release_id is not None and release.id != expected.release_id:
        message = "HOLD: pinned release identity changed"
        raise ReleaseError(message)
    return release


def reconcile(expected: ExpectedRelease, releases: list[RemoteRelease]) -> RecoveryPlan:
    records = {asset.name: asset for asset in expected.assets}
    if len(records) != len(expected.assets):
        message = "HOLD: duplicate expected asset names"
        raise ReleaseError(message)
    release = selected_release(expected, releases)
    if release is None:
        return RecoveryPlan(release_id=None, action="create", missing=sorted(records))
    if (
        release.target_commitish != expected.commit
        or release.name != expected.title
        or release.body != expected.notes
        or release.prerelease
        or release.draft != (release.published_at is None)
    ):
        msg = "HOLD: release source, metadata or publication state mismatch"
        raise ReleaseError(msg)
    remote = {asset.name: asset for asset in release.assets}
    if len(remote) != len(release.assets) or not set(remote) <= set(records):
        msg = "HOLD: unknown or duplicate remote assets"
        raise ReleaseError(msg)
    for name, asset in remote.items():
        wanted = records[name]
        if asset.size != wanted.size or asset.digest != "sha256:" + wanted.sha256:
            msg = f"HOLD: same-name wrong bytes: {name}"
            raise ReleaseError(msg)
    missing = sorted(set(records) - set(remote))
    if not release.draft:
        if missing:
            msg = "HOLD: incomplete published release"
            raise ReleaseError(msg)
        return RecoveryPlan(release_id=release.id, action="verify-only", missing=[])
    return RecoveryPlan(
        release_id=release.id, action="upload" if missing else "ready", missing=missing
    )


def snapshot(repo: Path, tag: str) -> list[RemoteRelease]:
    return [
        RemoteRelease.model_validate(value)
        for value in pages(repo, "/releases")
        if value.get("tag_name") == tag
    ]


def verify_remote_bytes(repo: Path, release: RemoteRelease, dist: Path) -> None:
    for asset in release.assets:
        local = dist / asset.name
        data = command(
            repo,
            "gh",
            "api",
            f"/repos/{REPOSITORY}/releases/assets/{asset.id}",
            "-H",
            "Accept: application/octet-stream",
        )
        if data != local.read_bytes():
            msg = f"HOLD: downloaded remote bytes differ: {asset.name}"
            raise ReleaseError(msg)


def create_draft(repo: Path, expected: ExpectedRelease) -> RecoveryPlan:
    payload = json.dumps(
        {
            "tag_name": expected.tag,
            "target_commitish": expected.commit,
            "name": expected.title,
            "body": expected.notes,
            "draft": True,
            "prerelease": False,
        }
    ).encode()
    try:
        _ = command(
            repo,
            "gh",
            "api",
            f"/repos/{REPOSITORY}/releases",
            "--method",
            "POST",
            "--input",
            "-",
            data=payload,
        )
    except ReleaseError:
        recovered = reconcile(expected, snapshot(repo, expected.tag))
        if recovered.action == "create":
            raise
    plan = reconcile(expected, snapshot(repo, expected.tag))
    if plan.action == "create":
        msg = "HOLD: draft creation has no matching readback"
        raise ReleaseError(msg)
    return plan


def synchronize(repo: Path, expected: ExpectedRelease, dist: Path) -> RecoveryPlan:
    releases = snapshot(repo, expected.tag)
    plan = reconcile(expected, releases)
    if plan.release_id is not None:
        verify_remote_bytes(
            repo, next(item for item in releases if item.id == plan.release_id), dist
        )
    if plan.action == "create":
        plan = create_draft(repo, expected)
    expected = expected.model_copy(update={"release_id": plan.release_id})
    for name in plan.missing:
        releases = snapshot(repo, expected.tag)
        current = reconcile(expected, releases)
        if current.release_id != plan.release_id:
            message = "HOLD: release identity changed before upload"
            raise ReleaseError(message)
        verify_remote_bytes(
            repo, next(item for item in releases if item.id == current.release_id), dist
        )
        if name not in current.missing:
            continue
        try:
            _ = command(
                repo,
                "gh",
                "release",
                "upload",
                expected.tag,
                str(dist / name),
                "--repo",
                REPOSITORY,
            )
        except ReleaseError:
            recovered = reconcile(expected, snapshot(repo, expected.tag))
            if name in recovered.missing:
                raise
        releases = snapshot(repo, expected.tag)
        current = reconcile(expected, releases)
        if current.release_id != plan.release_id or name in current.missing:
            msg = "HOLD: uploaded asset identity missing from readback"
            raise ReleaseError(msg)
        verify_remote_bytes(
            repo, next(item for item in releases if item.id == current.release_id), dist
        )
    return reconcile(expected, snapshot(repo, expected.tag))


def publish(repo: Path, expected: ExpectedRelease, dist: Path) -> RecoveryPlan:
    releases = snapshot(repo, expected.tag)
    plan = reconcile(expected, releases)
    if plan.action not in {"ready", "verify-only"}:
        msg = "HOLD: final release is incomplete"
        raise ReleaseError(msg)
    verify_remote_bytes(
        repo, next(item for item in releases if item.id == plan.release_id), dist
    )
    if plan.action == "ready":
        try:
            _ = command(
                repo,
                "gh",
                "release",
                "edit",
                expected.tag,
                "--repo",
                REPOSITORY,
                "--draft=false",
            )
        except ReleaseError:
            recovered = reconcile(expected, snapshot(repo, expected.tag))
            if recovered.action != "verify-only":
                raise
    releases = snapshot(repo, expected.tag)
    result = reconcile(expected, releases)
    if result.action != "verify-only" or result.release_id != plan.release_id:
        msg = "HOLD: publication readback did not preserve release identity"
        raise ReleaseError(msg)
    verify_remote_bytes(
        repo, next(item for item in releases if item.id == result.release_id), dist
    )
    return result
