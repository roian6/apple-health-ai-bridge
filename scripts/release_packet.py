#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import io
import stat
import zipfile
from dataclasses import dataclass
from pathlib import Path

from pydantic import JsonValue, TypeAdapter
from release_authority import (
    REPOSITORY,
    command,
    git,
    integer,
    object_value,
    pages,
    repository_api,
    string,
)
from release_candidate_model import CandidateRecord, artifact_record
from release_local_tag import import_local_tag
from release_source_policy import SourceRequest, resolve_release_source
from release_tools import PacketVerificationRequest, verify_core_packet
from release_versions import ReleaseError


@dataclass(frozen=True, slots=True)
class CandidateDownload:
    repo: Path
    run_id: int
    attempt: int
    artifact_id: int
    output: Path
    local: bool = False


def download_candidate(request: CandidateDownload) -> CandidateRecord:
    repo = request.repo
    run = repository_api(
        repo, f"/actions/runs/{request.run_id}/attempts/{request.attempt}"
    )
    if (
        run.get("id") != request.run_id
        or run.get("run_attempt") != request.attempt
        or run.get("head_branch") != "release"
        or run.get("event") != "workflow_dispatch"
        or run.get("path") != ".github/workflows/release.yml"
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
        or object_value(run.get("repository")).get("full_name") != REPOSITORY
    ):
        msg = "candidate run snapshot is not a successful release dispatch"
        raise ReleaseError(msg)
    artifacts = pages(repo, f"/actions/runs/{request.run_id}/artifacts", "artifacts")
    name = f"candidate-{request.run_id}-{request.attempt}"
    selected = [item for item in artifacts if item.get("name") == name]
    if (
        len(selected) != 1
        or selected[0].get("id") != request.artifact_id
        or selected[0].get("expired") is not False
    ):
        msg = "candidate artifact identity is missing, duplicate or expired"
        raise ReleaseError(msg)
    artifact = selected[0]
    if object_value(artifact.get("workflow_run")).get("head_sha") != run.get(
        "head_sha"
    ):
        msg = "artifact does not bind original execution source"
        raise ReleaseError(msg)
    archive = command(
        repo,
        "gh",
        "api",
        f"/repos/{REPOSITORY}/actions/artifacts/{request.artifact_id}/zip",
    )
    if artifact.get("digest") != "sha256:" + hashlib.sha256(archive).hexdigest():
        msg = "downloaded Actions artifact digest mismatch"
        raise ReleaseError(msg)
    record = extract_candidate(request, archive, string(run.get("head_sha")))
    released = [
        item
        for item in pages(repo, "/releases")
        if item.get("tag_name") == record.identity.tag
    ]
    if len(released) > 1:
        msg = "duplicate candidate release identities"
        raise ReleaseError(msg)
    verify_candidate(
        repo,
        record,
        request.output,
        published=bool(released and released[0].get("draft") is False),
        local=request.local,
    )
    return record


def extract_candidate(
    request: CandidateDownload, archive: bytes, source_commit: str
) -> CandidateRecord:
    with zipfile.ZipFile(io.BytesIO(archive)) as packet:
        members = packet.infolist()
        if (
            len({item.filename for item in members}) != len(members)
            or any(
                item.is_dir()
                or Path(item.filename).name != item.filename
                or item.file_size > 512 * 1024 * 1024
                or stat.S_ISLNK(item.external_attr >> 16)
                for item in members
            )
            or sum(item.file_size for item in members) > 1024 * 1024 * 1024
        ):
            msg = "candidate archive has unsafe or oversized members"
            raise ReleaseError(msg)
        record = CandidateRecord.model_validate_json(packet.read("candidate.json"))
        expected = {item.name: item for item in record.artifacts}
        if len(expected) != len(record.artifacts) or set(expected) | {
            "candidate.json"
        } != {item.filename for item in members}:
            msg = "candidate archive subject set is not exact"
            raise ReleaseError(msg)
        if (
            record.run_id != request.run_id
            or record.run_attempt != request.attempt
            or record.identity.commit != source_commit
        ):
            msg = "candidate record differs from original execution snapshot"
            raise ReleaseError(msg)
        request.output.mkdir(parents=True, exist_ok=False)
        for member in members:
            if member.filename != "candidate.json":
                path = request.output / member.filename
                _ = path.write_bytes(packet.read(member))
                if artifact_record(path) != expected[member.filename]:
                    msg = "candidate artifact bytes differ from frozen record"
                    raise ReleaseError(msg)
    return record


def verify_candidate(
    repo: Path,
    record: CandidateRecord,
    dist: Path,
    *,
    published: bool = False,
    local: bool = False,
) -> None:
    identity = record.identity
    if local:
        encoded = base64.b64encode(
            command(repo, "git", "cat-file", "tag", identity.tag_object)
        ).decode()
        import_local_tag(repo, identity, encoded)
    if (
        git(repo, "rev-parse", "HEAD") != identity.commit
        or git(repo, "rev-parse", "HEAD^{tree}") != identity.tree
        or git(repo, "rev-parse", "HEAD:macos/HealthBridgeMailboxAckPublisher")
        != identity.helper_tree
    ):
        msg = "candidate checkout source identity mismatch"
        raise ReleaseError(msg)
    verify_source_receipt(
        SourceRequest(
            repo,
            identity.tag,
            identity.commit,
            identity.tag_object,
            published=published,
            local=local,
        ),
        record,
    )
    verify_candidate_core(repo, record, dist)


def verify_source_receipt(request: SourceRequest, record: CandidateRecord) -> None:
    source = resolve_release_source(request)
    if (
        source.baseline != record.source.baseline
        or source.pull_request != record.source.pull_request
        or source.reviewed_head != record.source.reviewed_head
        or source.compatibility_baseline != record.source.compatibility_baseline
    ):
        msg = "candidate baseline or reviewed source evidence is stale"
        raise ReleaseError(msg)


def verify_candidate_core(repo: Path, record: CandidateRecord, dist: Path) -> None:
    metadata = object_value(
        TypeAdapter[JsonValue](JsonValue).validate_json(
            (dist / "release-metadata.json").read_bytes()
        )
    )
    if metadata.get("schema_id") != "health_bridge.release.v4":
        message = (
            "new candidates require v4 branch provenance without historical fallback"
        )
        raise ReleaseError(message)
    identity = record.identity
    _ = verify_core_packet(
        PacketVerificationRequest(
            repo,
            dist,
            identity.tag,
            identity.tag_object,
            identity.commit,
            identity.tree,
            invocation=f"https://github.com/{REPOSITORY}/actions/runs/{record.run_id}/attempts/{record.run_attempt}",
        )
    )


def verify_candidate_artifact_receipt(
    repo: Path, record: CandidateRecord, artifact_id: int
) -> None:
    run = repository_api(
        repo, f"/actions/runs/{record.run_id}/attempts/{record.run_attempt}"
    )
    if (
        run.get("id") != record.run_id
        or run.get("run_attempt") != record.run_attempt
        or run.get("head_sha") != record.identity.commit
        or run.get("head_branch") != "release"
        or run.get("event") != "workflow_dispatch"
        or run.get("path") != ".github/workflows/release.yml"
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
        or object_value(run.get("repository")).get("full_name") != REPOSITORY
    ):
        msg = "original candidate execution snapshot is not passing"
        raise ReleaseError(msg)
    artifacts = pages(repo, f"/actions/runs/{record.run_id}/artifacts", "artifacts")
    matches = [
        item
        for item in artifacts
        if item.get("name") == f"candidate-{record.run_id}-{record.run_attempt}"
    ]
    if (
        len(matches) != 1
        or matches[0].get("expired") is not False
        or integer(matches[0].get("id")) != artifact_id
        or object_value(matches[0].get("workflow_run")).get("head_sha")
        != record.identity.commit
    ):
        msg = "candidate artifact receipt expired or changed"
        raise ReleaseError(msg)
    archive = command(
        repo, "gh", "api", f"/repos/{REPOSITORY}/actions/artifacts/{artifact_id}/zip"
    )
    if matches[0].get("digest") != "sha256:" + hashlib.sha256(archive).hexdigest():
        message = "immutable candidate archive digest changed"
        raise ReleaseError(message)
    with zipfile.ZipFile(io.BytesIO(archive)) as packet:
        records = [
            member
            for member in packet.infolist()
            if member.filename == "candidate.json"
        ]
        if len(records) != 1 or records[0].file_size > 1024 * 1024:
            message = "immutable candidate record is missing, duplicate or oversized"
            raise ReleaseError(message)
        original = CandidateRecord.model_validate_json(packet.read(records[0]))
    if original != record:
        message = "local candidate record differs from immutable execution artifact"
        raise ReleaseError(message)
