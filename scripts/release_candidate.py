#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Literal, assert_never

from pydantic import ValidationError
from release_authority import canonical_json, git
from release_candidate_model import CandidateIdentity, CandidateRecord, artifact_record
from release_local_tag import import_local_tag
from release_packet import CandidateDownload, download_candidate, verify_candidate_core
from release_provenance import ProvenanceError, verify_dispatch
from release_source_policy import SourceRequest, resolve_release_source
from release_tools import (
    TransitionRequest,
    validate_component_transition,
    validate_tag,
)
from release_versions import ReleaseError


class Arguments(argparse.Namespace):
    phase: Literal["prepare", "seal", "download"] = "prepare"
    repo: Path = Path()
    tag: str = ""
    commit: str = ""
    tag_object: str = ""
    tag_base64_env: str = "SIGNED_TAG_OBJECT"
    output: Path = Path()
    source_output: Path | None = None
    record: Path | None = None
    dist_dir: Path | None = None
    run_id: int = 0
    attempt: int = 0
    artifact_id: int = 0
    local: bool = False


def required_path(value: Path | None) -> Path:
    if value is None:
        message = "required candidate file or directory argument is missing"
        raise ReleaseError(message)
    return value


def prepare(args: Arguments) -> CandidateRecord:
    verify_dispatch(args.commit)
    identity = CandidateIdentity(
        tag=args.tag,
        tag_object=args.tag_object,
        commit=args.commit,
        tree=git(args.repo, "rev-parse", "HEAD^{tree}"),
        helper_tree=git(
            args.repo, "rev-parse", "HEAD:macos/HealthBridgeMailboxAckPublisher"
        ),
    )
    import_local_tag(args.repo, identity, os.environ.get(args.tag_base64_env, ""))
    source = resolve_release_source(
        SourceRequest(args.repo, args.tag, args.commit, args.tag_object, local=True)
    )
    source_output = required_path(args.source_output)
    _ = source_output.write_text(canonical_json(source), encoding="utf-8")
    versions = validate_tag(args.repo, args.tag)
    validate_component_transition(
        TransitionRequest(
            args.repo,
            args.commit,
            source.default_main_commit,
            source.baseline_commit,
            source_output,
        ),
        versions,
    )
    return CandidateRecord(
        identity=identity,
        source=source,
        run_id=int(os.environ["GITHUB_RUN_ID"]),
        run_attempt=int(os.environ["GITHUB_RUN_ATTEMPT"]),
        artifacts=[],
    )


def seal(args: Arguments) -> CandidateRecord:
    record = CandidateRecord.model_validate_json(
        required_path(args.record).read_bytes()
    )
    identity = record.identity
    dist = required_path(args.dist_dir)
    verify_dispatch(identity.commit)
    if record.run_id != int(os.environ["GITHUB_RUN_ID"]) or record.run_attempt != int(
        os.environ["GITHUB_RUN_ATTEMPT"]
    ):
        message = "candidate record belongs to another execution snapshot"
        raise ReleaseError(message)
    verify_candidate_core(args.repo, record, dist)
    return record.model_copy(
        update={"artifacts": [artifact_record(path) for path in sorted(dist.iterdir())]}
    )


def execute(args: Arguments) -> CandidateRecord:
    match args.phase:
        case "prepare":
            return prepare(args)
        case "seal":
            return seal(args)
        case "download":
            if min(args.run_id, args.attempt, args.artifact_id) < 1:
                message = (
                    "download requires exact positive run, attempt and artifact IDs"
                )
                raise ReleaseError(message)
            return download_candidate(
                CandidateDownload(
                    args.repo,
                    args.run_id,
                    args.attempt,
                    args.artifact_id,
                    required_path(args.dist_dir),
                    args.local,
                )
            )
    assert_never(args.phase)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Bind a genuine local signed release candidate"
    )
    _ = parser.add_argument("--repo", type=Path, default=Path())
    _ = parser.add_argument(
        "--phase", choices=("prepare", "seal", "download"), default="prepare"
    )
    _ = parser.add_argument("--tag", default="")
    _ = parser.add_argument("--commit", default="")
    _ = parser.add_argument("--tag-object", default="")
    _ = parser.add_argument("--tag-base64-env", default="SIGNED_TAG_OBJECT")
    _ = parser.add_argument("--output", type=Path, required=True)
    _ = parser.add_argument("--source-output", type=Path)
    _ = parser.add_argument("--record", type=Path)
    _ = parser.add_argument("--dist-dir", type=Path)
    _ = parser.add_argument("--run-id", type=int, default=0)
    _ = parser.add_argument("--attempt", type=int, default=0)
    _ = parser.add_argument("--artifact-id", type=int, default=0)
    _ = parser.add_argument("--local", action="store_true")
    args = parser.parse_args(namespace=Arguments())
    try:
        record = execute(args)
        _ = args.output.write_text(canonical_json(record), encoding="utf-8")
    except (
        ReleaseError,
        ProvenanceError,
        ValidationError,
        OSError,
        ValueError,
        KeyError,
    ) as exc:
        _ = sys.stderr.write(f"{exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
