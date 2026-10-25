#!/usr/bin/env python3
from __future__ import annotations

import shutil
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Literal

from release_authority import REPOSITORY, command
from release_candidate_model import CandidateRecord, artifact_record
from release_packet import verify_candidate, verify_candidate_artifact_receipt
from release_provenance import FINAL_PROVENANCE, verify_execution
from release_tools import (
    HelperVerificationRequest,
    create_final_checksums,
    verify_final_packet,
    verify_helper_packet,
)
from release_versions import ReleaseError, parse_receiver_release_tag

if TYPE_CHECKING:
    from release_reconciliation import RemoteRelease


@dataclass(frozen=True, slots=True)
class PublicationRequest:
    repo: Path
    dist: Path
    candidate_record: Path
    candidate_artifact: int
    helper_sha256: str
    helper_manifest_sha256: str
    phase: Literal["fetch", "stage", "prepare-final", "publish"]
    release_id: int | None = None


@dataclass(frozen=True, slots=True)
class QualifiedPacket:
    record: CandidateRecord
    names: set[str]
    checksums: bytes


def qualify_packet(
    request: PublicationRequest, record: CandidateRecord, published: bool
) -> QualifiedPacket:
    identity = record.identity
    verify_candidate_artifact_receipt(request.repo, record, request.candidate_artifact)
    with tempfile.TemporaryDirectory(prefix="release-core-") as temporary:
        core = Path(temporary)
        for asset in record.artifacts:
            path = request.dist / asset.name
            if artifact_record(path) != asset:
                msg = "HOLD: frozen candidate artifact differs"
                raise ReleaseError(msg)
            _ = shutil.copyfile(path, core / asset.name)
        verify_candidate(request.repo, record, core, published=published)
    version = str(parse_receiver_release_tag(identity.tag).version)
    helper = f"HealthBridgeMailboxAckPublisher-{version}"
    base_names = {item.name for item in record.artifacts} | {
        f"{helper}.zip",
        f"{helper}.manifest.json",
    }
    if any(
        path.is_symlink() or not path.is_file() for path in request.dist.iterdir()
    ) or not {path.name for path in request.dist.iterdir()} <= base_names | {
        "SHA256SUMS",
        FINAL_PROVENANCE,
    }:
        msg = "HOLD: unexpected local publication assets"
        raise ReleaseError(msg)
    with tempfile.TemporaryDirectory(prefix="release-helper-") as temporary:
        helper_dist = Path(temporary)
        for name in base_names:
            _ = shutil.copyfile(request.dist / name, helper_dist / name)
        verification = HelperVerificationRequest(
            request.repo,
            helper_dist,
            identity.tag,
            identity.tag_object,
            identity.commit,
            identity.tree,
            request.helper_sha256,
            request.helper_manifest_sha256,
            helper_dist / "SHA256SUMS",
        )
        verify_helper_packet(verification)
        create_final_checksums(verification)
        checksums = (helper_dist / "SHA256SUMS").read_bytes()
    if request.phase == "stage":
        _ = command(
            request.repo,
            sys.executable,
            str(request.repo / "scripts/verify_helper_distribution.py"),
            "--archive",
            str(request.dist / f"{helper}.zip"),
            "--manifest",
            str(request.dist / f"{helper}.manifest.json"),
        )
    else:
        verify_execution(identity.tag, identity.commit, "publish-release.yml")
    return QualifiedPacket(record, base_names, checksums)


def prepare_proof(
    request: PublicationRequest, packet: QualifiedPacket, releases: list[RemoteRelease]
) -> set[str]:
    identity = packet.record.identity
    checksums, base_names = packet.checksums, packet.names
    published = bool(releases and not releases[0].draft)
    checksum = request.dist / "SHA256SUMS"
    if checksum.exists() and checksum.read_bytes() != checksums:
        msg = "HOLD: existing checksum differs from frozen subjects"
        raise ReleaseError(msg)
    remote_names = {asset.name for release in releases for asset in release.assets}
    needs_final = (
        request.phase != "stage"
        or checksum.exists()
        or (request.dist / FINAL_PROVENANCE).exists()
        or bool(remote_names & {"SHA256SUMS", FINAL_PROVENANCE})
    )
    if needs_final and not checksum.exists():
        _ = checksum.write_bytes(checksums)
    proof = request.dist / FINAL_PROVENANCE
    expected_names = base_names | ({"SHA256SUMS"} if needs_final else set[str]())
    if remote_names - (expected_names | {FINAL_PROVENANCE}):
        msg = "HOLD: unknown remote file before mutation"
        raise ReleaseError(msg)
    if FINAL_PROVENANCE in remote_names:
        asset = next(
            asset for asset in releases[0].assets if asset.name == FINAL_PROVENANCE
        )
        data = command(
            request.repo,
            "gh",
            "api",
            f"/repos/{REPOSITORY}/releases/assets/{asset.id}",
            "-H",
            "Accept: application/octet-stream",
        )
        if proof.exists() and proof.read_bytes() != data:
            msg = "HOLD: existing final provenance must be reused exactly"
            raise ReleaseError(msg)
        if not proof.exists():
            _ = proof.write_bytes(data)
    final_request = HelperVerificationRequest(
        request.repo,
        request.dist,
        identity.tag,
        identity.tag_object,
        identity.commit,
        identity.tree,
        request.helper_sha256,
        request.helper_manifest_sha256,
    )
    if proof.exists():
        _ = verify_final_packet(final_request)
        expected_names.add(FINAL_PROVENANCE)
    elif published or request.phase == "publish":
        msg = "HOLD: final native provenance is missing"
        raise ReleaseError(msg)
    return expected_names
