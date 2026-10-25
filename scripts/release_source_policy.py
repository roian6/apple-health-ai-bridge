#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import sys
from dataclasses import dataclass
from pathlib import Path

from pydantic import TypeAdapter, ValidationError
from release_authority import (
    GitSha,
    SourceReceipt,
    canonical_json,
    command,
    git,
    public_tag,
    trusted_policy,
)
from release_baseline import (
    IOS_TAG,
    baseline_ancestry,
    ios_baseline,
    ios_compatibility,
    receiver_baseline,
)
from release_candidate_model import CandidateIdentity
from release_local_tag import import_local_tag
from release_review import exact_checks, protected_release, reviewed_merge
from release_versions import ReleaseError, parse_receiver_release_tag


@dataclass(frozen=True, slots=True)
class SourceRequest:
    repo: Path
    tag: str
    commit: str
    tag_object: str
    local: bool = False
    published: bool = False


class Arguments(argparse.Namespace):
    repo: Path = Path()
    tag: str = ""
    commit: str = ""
    tag_object: str = ""
    local_tag: bool = False


def resolve_release_source(request: SourceRequest) -> SourceReceipt:
    repo = request.repo
    if request.tag.startswith("ios-v"):
        if IOS_TAG.fullmatch(request.tag) is None:
            message = "invalid iOS checkpoint tag"
            raise ReleaseError(message)
    else:
        _ = parse_receiver_release_tag(request.tag)
    _ = TypeAdapter(GitSha).validate_python(request.commit)
    _ = TypeAdapter(GitSha).validate_python(request.tag_object)
    if git(repo, "rev-parse", "HEAD") != request.commit:
        msg = "release source target must equal checkout"
        raise ReleaseError(msg)
    if git(repo, "status", "--porcelain", "--untracked-files=all"):
        message = "candidate source checkout must be clean"
        raise ReleaseError(message)
    main, policy = trusted_policy(repo)
    if (
        request.commit in policy.revoked_commits
        or request.tag_object in policy.revoked_tag_objects
        or any(entry.tag == request.tag for entry in policy.retired_tags)
    ):
        msg = "candidate is explicitly revoked or retired"
        raise ReleaseError(msg)
    if git(repo, "rev-parse", f"{request.tag_object}^{{commit}}") != request.commit:
        msg = "candidate tag target mismatch"
        raise ReleaseError(msg)
    if request.local:
        identity = CandidateIdentity(
            tag=request.tag,
            tag_object=request.tag_object,
            commit=request.commit,
            tree=git(repo, "rev-parse", "HEAD^{tree}"),
            helper_tree=git(
                repo, "rev-parse", "HEAD:macos/HealthBridgeMailboxAckPublisher"
            ),
        )
        raw = command(repo, "git", "cat-file", "tag", request.tag_object)
        import_local_tag(repo, identity, base64.b64encode(raw).decode())
    if not request.local and public_tag(repo, request.tag) != (
        request.tag_object,
        request.commit,
    ):
        msg = "public signed tag object or source mismatch"
        raise ReleaseError(msg)
    tip, approvals = protected_release(repo, policy)
    _ = git(repo, "fetch", "--no-tags", "origin", tip)
    _ = git(repo, "merge-base", "--is-ancestor", request.commit, tip)
    number, head = reviewed_merge(repo, request.commit, approvals)
    checks = exact_checks(repo, request.commit, policy)
    baseline = (
        ios_baseline(
            repo, request.tag, frozenset(entry.tag for entry in policy.retired_tags)
        )
        if request.tag.startswith("ios-v")
        else receiver_baseline(repo, request.tag, policy, published=request.published)
    )
    if not request.tag.startswith("ios-v"):
        baseline_ancestry(repo, request.commit, baseline)
    return SourceReceipt(
        default_main_commit=main,
        baseline_commit=baseline.commit,
        source_commit=request.commit,
        source_tree=git(repo, "rev-parse", "HEAD^{tree}"),
        source_tag=request.tag,
        tag_object=request.tag_object,
        remote_tag_verification="pending" if request.local else "verified",
        compatibility_baseline=ios_compatibility(repo, request.commit)
        if request.tag.startswith("ios-v")
        else None,
        baseline=baseline,
        pull_request=number,
        reviewed_head=head,
        check_runs=checks,
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Resolve reviewed frozen release source"
    )
    _ = parser.add_argument("--repo", type=Path, required=True)
    _ = parser.add_argument("--tag", required=True)
    _ = parser.add_argument("--commit", required=True)
    _ = parser.add_argument("--tag-object", required=True)
    _ = parser.add_argument("--local-tag", action="store_true")
    args = parser.parse_args(namespace=Arguments())
    try:
        source = resolve_release_source(
            SourceRequest(
                args.repo, args.tag, args.commit, args.tag_object, local=args.local_tag
            )
        )
    except (ReleaseError, ValidationError, OSError) as exc:
        _ = sys.stderr.write(f"{exc}\n")
        return 1
    _ = sys.stdout.write(canonical_json(source))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
