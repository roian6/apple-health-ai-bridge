from __future__ import annotations

import os
import stat
from typing import TYPE_CHECKING, Annotated, ClassVar, Literal, Self

from pydantic import BaseModel, ConfigDict, StringConstraints, model_validator

from health_bridge.contract._hbjcs1 import (
    HBJCS1Error,
    hbjcs1_decode,
    hbjcs1_encode,
)
from health_bridge.private_files import write_private_text_file

if TYPE_CHECKING:
    from pathlib import Path

Hex16 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{16}$")]
Hex40 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{40}$")]
Hex64 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
QALaneName = Literal[
    "HealthBridgeCompanionMailboxQA",
    "HealthBridgeCompanionPublicDocumentsQA",
]


class ArchiveProvenanceError(ValueError):
    pass


class QAArchiveProvenanceV1(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )

    v: Literal[1]
    kind: Literal["health_bridge.mailbox_qa_archive_provenance.v1"]
    source_commit: Hex40
    production_seal_fingerprint: Hex16
    executable_sha256: Hex64
    codesign_identity_sha256: Hex64
    scheme: QALaneName
    target: QALaneName

    @model_validator(mode="after")
    def exact_lane_pair(self) -> Self:
        if self.scheme != self.target:
            raise ArchiveProvenanceError
        return self


def write_archive_provenance(
    path: Path,
    provenance: QAArchiveProvenanceV1,
) -> None:
    write_private_text_file(
        path,
        hbjcs1_encode(provenance.model_dump(mode="json")).decode("utf-8"),
    )


def load_archive_provenance(path: Path) -> QAArchiveProvenanceV1:
    try:
        entry = path.lstat()
        encoded = path.read_bytes()
    except OSError as exc:
        raise ArchiveProvenanceError from exc
    if (
        not stat.S_ISREG(entry.st_mode)
        or entry.st_nlink != 1
        or (os.name == "posix" and entry.st_mode & 0o077)
    ):
        raise ArchiveProvenanceError
    try:
        document = hbjcs1_decode(encoded)
    except HBJCS1Error as exc:
        raise ArchiveProvenanceError from exc
    if not isinstance(document, dict) or hbjcs1_encode(document) != encoded:
        raise ArchiveProvenanceError
    try:
        return QAArchiveProvenanceV1.model_validate(document)
    except ValueError as exc:
        raise ArchiveProvenanceError from exc


__all__ = [
    "ArchiveProvenanceError",
    "QAArchiveProvenanceV1",
    "load_archive_provenance",
    "write_archive_provenance",
]
