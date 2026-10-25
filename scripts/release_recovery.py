#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Literal

from pydantic import TypeAdapter, ValidationError
from release_authority import canonical_json
from release_provenance import ProvenanceError
from release_publication import continue_publication
from release_publication_inputs import PublicationRequest
from release_reconciliation import (
    ExpectedRelease,
    RecoveryPlan,
    RemoteRelease,
    reconcile,
)
from release_versions import ReleaseError


class Arguments(argparse.Namespace):
    phase: Literal["plan", "fetch", "stage", "prepare-final", "publish"] = "plan"
    repo: Path = Path()
    dist_dir: Path | None = None
    candidate_record: Path | None = None
    candidate_artifact: int = 0
    helper_sha256: str = ""
    helper_manifest_sha256: str = ""
    expected: Path | None = None
    snapshot: Path | None = None
    release_id: int | None = None


def execute(args: Arguments) -> RecoveryPlan:
    if args.phase == "plan":
        if args.expected is None or args.snapshot is None:
            message = "plan requires expected packet and remote snapshot files"
            raise ReleaseError(message)
        expected = ExpectedRelease.model_validate_json(args.expected.read_bytes())
        releases = TypeAdapter(list[RemoteRelease]).validate_json(
            args.snapshot.read_bytes()
        )
        return reconcile(expected, releases)
    if (
        args.dist_dir is None
        or args.candidate_record is None
        or args.candidate_artifact < 1
        or not args.helper_sha256
        or not args.helper_manifest_sha256
    ):
        message = "publication requires candidate, artifact, packet and helper digests"
        raise ReleaseError(message)
    if args.phase != "stage" and (args.release_id is None or args.release_id < 1):
        message = "continuation requires the release ID returned by staging"
        raise ReleaseError(message)
    return continue_publication(
        PublicationRequest(
            args.repo,
            args.dist_dir,
            args.candidate_record,
            args.candidate_artifact,
            args.helper_sha256,
            args.helper_manifest_sha256,
            args.phase,
            args.release_id,
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Reconcile exact release bytes; conflicts HOLD before mutation"
    )
    _ = parser.add_argument(
        "--phase",
        choices=("plan", "fetch", "stage", "prepare-final", "publish"),
        required=True,
    )
    _ = parser.add_argument("--expected", type=Path)
    _ = parser.add_argument("--snapshot", type=Path)
    _ = parser.add_argument("--release-id", type=int)
    _ = parser.add_argument("--repo", type=Path, default=Path())
    _ = parser.add_argument("--dist-dir", type=Path)
    _ = parser.add_argument("--candidate-record", type=Path)
    _ = parser.add_argument("--candidate-artifact", type=int, default=0)
    _ = parser.add_argument("--helper-sha256", default="")
    _ = parser.add_argument("--helper-manifest-sha256", default="")
    args = parser.parse_args(namespace=Arguments())
    try:
        result = execute(args)
    except (ReleaseError, ProvenanceError, ValidationError, OSError) as exc:
        _ = sys.stderr.write(f"{exc}\n")
        return 1
    _ = sys.stdout.write(canonical_json(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
