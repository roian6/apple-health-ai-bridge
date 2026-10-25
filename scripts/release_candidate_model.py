#!/usr/bin/env python3
from __future__ import annotations

import hashlib
from typing import TYPE_CHECKING, ClassVar, Literal, Self

from pydantic import BaseModel, ConfigDict, Field, model_validator
from release_authority import ArtifactRecord, Document, GitSha, SourceReceipt
from release_versions import ReleaseError

if TYPE_CHECKING:
    from pathlib import Path


class CandidateIdentity(BaseModel):
    model_config: ClassVar[ConfigDict] = Document.model_config
    tag: str
    tag_object: GitSha
    commit: GitSha
    tree: GitSha
    helper_tree: GitSha


class CandidateRecord(BaseModel):
    model_config: ClassVar[ConfigDict] = Document.model_config
    schema_id: Literal["health_bridge.candidate.v1"] = "health_bridge.candidate.v1"
    identity: CandidateIdentity
    source: SourceReceipt
    run_id: int = Field(gt=0)
    run_attempt: int = Field(gt=0)
    artifacts: list[ArtifactRecord]
    remote_tag_verification: Literal["pending"] = "pending"

    @model_validator(mode="after")
    def consistent_identity(self) -> Self:
        source = self.source
        identity = self.identity
        if (
            (
                source.source_commit,
                source.source_tree,
                source.source_tag,
                source.tag_object,
            )
            != (identity.commit, identity.tree, identity.tag, identity.tag_object)
            or source.baseline_commit != source.baseline.commit
            or len({artifact.name for artifact in self.artifacts})
            != len(self.artifacts)
        ):
            message = "candidate source receipt or artifact identity is inconsistent"
            raise ValueError(message)
        return self


def artifact_record(path: Path) -> ArtifactRecord:
    if path.is_symlink() or not path.is_file():
        message = "candidate artifact must be a regular file"
        raise ReleaseError(message)
    with path.open("rb") as handle:
        digest = hashlib.file_digest(handle, "sha256").hexdigest()
    return ArtifactRecord(name=path.name, size=path.stat().st_size, sha256=digest)
