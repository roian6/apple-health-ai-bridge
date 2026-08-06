from __future__ import annotations

import base64
import os
import secrets
import stat
import time
from typing import TYPE_CHECKING, Annotated, ClassVar, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from health_bridge.contract._hbjcs1 import hbjcs1_encode
from health_bridge.private_files import write_private_text_file

if TYPE_CHECKING:
    from pathlib import Path

RunReference = Annotated[
    str,
    StringConstraints(pattern=r"^[a-z0-9][a-z0-9-]{2,63}$"),
]
Hex32 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{32}$")]


class ProgressModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )


class ChallengeRecordV1(ProgressModel):
    v: Literal[1]
    kind: Literal["health_bridge.mailbox_qa_challenge.v1"]
    run_reference: RunReference
    run_id: Hex32
    challenge: Annotated[
        str,
        StringConstraints(pattern=r"^[A-Za-z0-9_-]{43}$"),
    ]
    created_at_ms: Annotated[int, Field(ge=0)]


def create_challenge(root: Path, run_reference: str) -> ChallengeRecordV1:
    _require_private_directory(root)
    record = ChallengeRecordV1(
        v=1,
        kind="health_bridge.mailbox_qa_challenge.v1",
        run_reference=run_reference,
        run_id=secrets.token_hex(16),
        challenge=base64.urlsafe_b64encode(secrets.token_bytes(32))
        .rstrip(b"=")
        .decode("ascii"),
        created_at_ms=time.time_ns() // 1_000_000,
    )
    write_private_text_file(
        root / "challenge.hbjcs1",
        hbjcs1_encode(record.model_dump(mode="json")).decode("utf-8"),
    )
    return record


def _require_private_directory(path: Path) -> None:
    entry = path.lstat()
    if (
        not stat.S_ISDIR(entry.st_mode)
        or path.is_symlink()
        or (os.name == "posix" and entry.st_mode & 0o077)
    ):
        raise ValueError


__all__ = [
    "ChallengeRecordV1",
    "create_challenge",
]
