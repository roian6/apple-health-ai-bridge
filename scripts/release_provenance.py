#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
from dataclasses import dataclass
from typing import TYPE_CHECKING, ClassVar, Final, Literal

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter, ValidationError
from release_authority import GitSha

if TYPE_CHECKING:
    from pathlib import Path

BUILD_PROVENANCE: Final = "receiver-build-provenance.intoto.jsonl"
FINAL_PROVENANCE: Final = "receiver-final-provenance.intoto.jsonl"
REPOSITORY: Final = "roian6/apple-health-ai-bridge"
Workflow = Literal["release.yml", "publish-release.yml"]


class ProvenanceError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class ProvenanceRequest:
    dist: Path
    tag: str
    commit: str
    workflow: Workflow
    bundle: str
    subjects: frozenset[str]
    candidate: bool = False
    invocation: str | None = None


class NativeModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)


class Subject(NativeModel):
    name: str
    digest: dict[str, str]


class RunMetadata(NativeModel):
    invocation_id: str = Field(alias="invocationId")


class RunDetails(NativeModel):
    metadata: RunMetadata


class Predicate(NativeModel):
    run_details: RunDetails = Field(alias="runDetails")


class Statement(NativeModel):
    statement_type: Literal["https://in-toto.io/Statement/v1"] = Field(alias="_type")
    predicate_type: Literal["https://slsa.dev/provenance/v1"] = Field(
        alias="predicateType"
    )
    subject: list[Subject]
    predicate: Predicate | None = None


class VerificationResult(NativeModel):
    statement: Statement


class NativeVerification(NativeModel):
    verification_result: VerificationResult = Field(alias="verificationResult")


def verify_provenance(request: ProvenanceRequest) -> None:
    """Apply subject policy only to output authenticated by native gh verification."""
    executable = shutil.which("gh")
    bundle = request.dist / request.bundle
    if executable is None or bundle.is_symlink() or not bundle.is_file():
        message = "native gh and a regular provenance bundle are required"
        raise ProvenanceError(message)
    expected: dict[str, dict[str, str]] = {}
    for name in sorted(request.subjects):
        path = request.dist / name
        if path.is_symlink() or not path.is_file():
            message = f"provenance subject is not a regular file: {name}"
            raise ProvenanceError(message)
        with path.open("rb") as handle:
            expected[name] = {
                "sha256": hashlib.file_digest(handle, "sha256").hexdigest()
            }
    workflow = f"{REPOSITORY}/.github/workflows/{request.workflow}"
    if request.candidate and request.workflow != "release.yml":
        msg = "only candidate build provenance may use the release branch"
        raise ProvenanceError(msg)
    source_ref = (
        "refs/heads/release" if request.candidate else f"refs/tags/{request.tag}"
    )
    for name in sorted(request.subjects):
        result = subprocess.run(  # noqa: S603
            [
                executable,
                "attestation",
                "verify",
                str(request.dist / name),
                "--repo",
                REPOSITORY,
                "--bundle",
                str(bundle),
                "--signer-workflow",
                workflow,
                "--source-ref",
                source_ref,
                "--source-digest",
                request.commit,
                "--signer-digest",
                request.commit,
                "--deny-self-hosted-runners",
                "--predicate-type",
                "https://slsa.dev/provenance/v1",
                "--format",
                "json",
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=120,
        )
        if result.returncode != 0:
            message = f"native provenance verification failed: {name}\n{result.stderr}"
            raise ProvenanceError(message)
        verify_statements(result.stdout, expected, request.invocation)


def verify_statements(
    raw: str, expected: dict[str, dict[str, str]], invocation: str | None
) -> None:
    try:
        verified = TypeAdapter(list[NativeVerification]).validate_json(raw)
    except ValidationError as exc:
        message = "native provenance verification returned invalid statements"
        raise ProvenanceError(message) from exc
    if not verified:
        message = "native provenance verification returned no statements"
        raise ProvenanceError(message)
    for record in verified:
        if invocation is not None:
            predicate = record.verification_result.statement.predicate
            if (
                predicate is None
                or predicate.run_details.metadata.invocation_id != invocation
            ):
                msg = "verified provenance execution snapshot mismatch"
                raise ProvenanceError(msg)
        subjects = record.verification_result.statement.subject
        if (
            len(subjects) != len(expected)
            or {subject.name: subject.digest for subject in subjects} != expected
        ):
            message = "verified provenance subject names or digests are not exact"
            raise ProvenanceError(message)


def verify_dispatch(commit: str) -> None:
    expected = {
        "GITHUB_REPOSITORY": REPOSITORY,
        "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_REF": "refs/heads/release",
        "GITHUB_SHA": commit,
        "GITHUB_WORKFLOW_SHA": commit,
        "GITHUB_WORKFLOW_REF": (
            f"{REPOSITORY}/.github/workflows/release.yml@refs/heads/release"
        ),
    }
    _ = TypeAdapter(GitSha).validate_python(commit)
    for key, value in expected.items():
        if os.environ.get(key) != value:
            msg = f"candidate dispatch source mismatch: {key}"
            raise ProvenanceError(msg)


def verify_execution(tag: str, commit: str, workflow: Workflow) -> None:
    expected = {
        "GITHUB_REPOSITORY": REPOSITORY,
        "GITHUB_REF": f"refs/tags/{tag}",
        "GITHUB_SHA": commit,
        "GITHUB_WORKFLOW_REF": (
            f"{REPOSITORY}/.github/workflows/{workflow}@refs/tags/{tag}"
        ),
        "GITHUB_WORKFLOW_SHA": commit,
    }
    for key, value in expected.items():
        if os.environ.get(key) != value:
            message = f"workflow execution identity mismatch: {key}"
            raise ProvenanceError(message)
