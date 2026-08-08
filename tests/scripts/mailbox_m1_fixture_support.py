from __future__ import annotations

import hashlib
import subprocess
from typing import TYPE_CHECKING, ClassVar

from pydantic import BaseModel, ConfigDict

from health_bridge.mailbox_m1_validator import (
    FROZEN_SCOPE_DIGESTS,
    RECEIPT_POLICIES,
    REQUIRED_BOUNDARIES,
    REQUIRED_SCOPE_PATHS,
)

if TYPE_CHECKING:
    from pathlib import Path


class PathFixture(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", frozen=True)

    path: str
    sha256: str


class ReceiptFixture(PathFixture):
    kind: str


class ManifestFixture(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", frozen=True)

    v: int
    milestone: str
    verdict: str
    head: str
    scope: tuple[PathFixture, ...]
    receipts: tuple[ReceiptFixture, ...]
    boundaries: dict[str, str]


def git_head(repository_root: Path) -> str:
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repository_root,
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return result.stdout.strip()


def build_manifest_fixture(repository_root: Path, head: str) -> ManifestFixture:
    scope = tuple(
        PathFixture(
            path=path,
            sha256=FROZEN_SCOPE_DIGESTS.get(path) or _digest(repository_root / path),
        )
        for path in sorted(REQUIRED_SCOPE_PATHS)
    )
    receipts = tuple(
        ReceiptFixture(
            kind=policy.kind,
            path=policy.path,
            sha256=_digest(repository_root / policy.path),
        )
        for policy in RECEIPT_POLICIES
    )
    return ManifestFixture(
        v=1,
        milestone="M1",
        verdict="PASS",
        head=head,
        scope=scope,
        receipts=receipts,
        boundaries=REQUIRED_BOUNDARIES,
    )


def write_manifest(path: Path, manifest: ManifestFixture) -> None:
    _ = path.write_text(manifest.model_dump_json(), encoding="utf-8")


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


__all__ = [
    "ManifestFixture",
    "PathFixture",
    "ReceiptFixture",
    "build_manifest_fixture",
    "git_head",
    "write_manifest",
]
