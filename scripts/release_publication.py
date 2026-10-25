#!/usr/bin/env python3
from __future__ import annotations

from release_authority import REPOSITORY, command
from release_candidate_model import CandidateRecord, artifact_record
from release_packet import verify_candidate_artifact_receipt, verify_source_receipt
from release_provenance import FINAL_PROVENANCE, verify_execution
from release_publication_inputs import PublicationRequest, prepare_proof, qualify_packet
from release_reconciliation import (
    ExpectedRelease,
    RecoveryPlan,
    publish,
    reconcile,
    snapshot,
    synchronize,
    verify_remote_bytes,
)
from release_source_policy import SourceRequest
from release_tools import release_title
from release_versions import ReleaseError, parse_receiver_release_tag


def fetch_staged_assets(
    request: PublicationRequest, record: CandidateRecord
) -> RecoveryPlan:
    identity = record.identity
    releases = snapshot(request.repo, identity.tag)
    if len(releases) != 1:
        msg = "HOLD: expected one staged release"
        raise ReleaseError(msg)
    release = releases[0]
    if request.release_id is not None and release.id != request.release_id:
        message = "HOLD: staged release ID differs from continuation input"
        raise ReleaseError(message)
    version = str(parse_receiver_release_tag(identity.tag).version)
    helper = f"HealthBridgeMailboxAckPublisher-{version}"
    allowed = {item.name for item in record.artifacts} | {
        f"{helper}.zip",
        f"{helper}.manifest.json",
        "SHA256SUMS",
        FINAL_PROVENANCE,
    }
    names = {item.name for item in release.assets}
    if (
        len(names) != len(release.assets)
        or not names <= allowed
        or release.target_commitish != identity.commit
    ):
        msg = "HOLD: staged release identity or asset set mismatch"
        raise ReleaseError(msg)
    for asset in release.assets:
        data = command(
            request.repo,
            "gh",
            "api",
            f"/repos/{REPOSITORY}/releases/assets/{asset.id}",
            "-H",
            "Accept: application/octet-stream",
        )
        path = request.dist / asset.name
        if path.exists() and (path.is_symlink() or path.read_bytes() != data):
            msg = "HOLD: staged bytes differ from candidate"
            raise ReleaseError(msg)
        if not path.exists():
            _ = path.write_bytes(data)
        local = artifact_record(path)
        if asset.digest != "sha256:" + local.sha256 or asset.size != local.size:
            msg = "HOLD: staged asset digest readback mismatch"
            raise ReleaseError(msg)
    if (
        artifact_record(request.dist / f"{helper}.zip").sha256 != request.helper_sha256
        or artifact_record(request.dist / f"{helper}.manifest.json").sha256
        != request.helper_manifest_sha256
    ):
        msg = "HOLD: staged helper differs from continuation inputs"
        raise ReleaseError(msg)
    return RecoveryPlan(
        release_id=release.id,
        action="verify-only" if not release.draft else "ready",
        missing=[],
    )


def continue_publication(request: PublicationRequest) -> RecoveryPlan:
    record = CandidateRecord.model_validate_json(request.candidate_record.read_bytes())
    identity = record.identity
    if request.phase == "fetch":
        verify_execution(identity.tag, identity.commit, "publish-release.yml")
        verify_candidate_artifact_receipt(
            request.repo, record, request.candidate_artifact
        )
        return fetch_staged_assets(request, record)
    releases = snapshot(request.repo, identity.tag)
    if len(releases) > 1:
        msg = "HOLD: duplicate release identities"
        raise ReleaseError(msg)
    if request.release_id is not None and (
        not releases or releases[0].id != request.release_id
    ):
        message = "HOLD: pinned release is missing or changed"
        raise ReleaseError(message)
    published = bool(releases and not releases[0].draft)
    packet = qualify_packet(request, record, published)
    expected_names = prepare_proof(request, packet, releases)
    expected = ExpectedRelease(
        release_id=request.release_id
        if request.release_id is not None
        else releases[0].id
        if releases
        else None,
        tag=identity.tag,
        commit=identity.commit,
        title=release_title(identity.tag),
        notes=(
            request.repo / ".github/release" / f"notes-{identity.tag}.md"
        ).read_text(),
        assets=[
            artifact_record(request.dist / name) for name in sorted(expected_names)
        ],
    )
    plan = reconcile(expected, releases)
    if releases:
        verify_remote_bytes(request.repo, releases[0], request.dist)
    if request.phase == "prepare-final" or plan.action == "verify-only":
        return plan
    if request.phase == "stage":
        verify_source_receipt(
            SourceRequest(
                request.repo, identity.tag, identity.commit, identity.tag_object
            ),
            record,
        )
        return synchronize(request.repo, expected, request.dist)
    ready = synchronize(request.repo, expected, request.dist)
    verify_candidate_artifact_receipt(request.repo, record, request.candidate_artifact)
    verify_source_receipt(
        SourceRequest(
            request.repo,
            identity.tag,
            identity.commit,
            identity.tag_object,
            published=ready.action == "verify-only",
        ),
        record,
    )
    return publish(request.repo, expected, request.dist)
