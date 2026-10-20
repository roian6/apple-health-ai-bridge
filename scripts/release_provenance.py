#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
from dataclasses import dataclass
from typing import TYPE_CHECKING, ClassVar, Final, Literal

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter, ValidationError

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


class NativeModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, strict=True)


class Subject(NativeModel):
    name: str
    digest: dict[str, str]


class Statement(NativeModel):
    statement_type: Literal["https://in-toto.io/Statement/v1"] = Field(alias="_type")
    predicate_type: Literal["https://slsa.dev/provenance/v1"] = Field(
        alias="predicateType"
    )
    subject: list[Subject]


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
                f"refs/tags/{request.tag}",
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
        try:
            verified = TypeAdapter(list[NativeVerification]).validate_json(
                result.stdout
            )
        except ValidationError as exc:
            message = "native provenance verification returned invalid statements"
            raise ProvenanceError(message) from exc
        if not verified:
            message = "native provenance verification returned no statements"
            raise ProvenanceError(message)
        for record in verified:
            subjects = record.verification_result.statement.subject
            if (
                len(subjects) != len(expected)
                or {subject.name: subject.digest for subject in subjects} != expected
            ):
                message = "verified provenance subject names or digests are not exact"
                raise ProvenanceError(message)


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
