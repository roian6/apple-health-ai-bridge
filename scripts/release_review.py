#!/usr/bin/env python3
from __future__ import annotations

import json
from typing import TYPE_CHECKING, Final

from pydantic import JsonValue, TypeAdapter
from release_authority import (
    REPOSITORY,
    ReleasePolicy,
    array_value,
    command,
    git,
    integer,
    object_value,
    pages,
    repository_api,
    string,
    verified,
)
from release_versions import ReleaseError

if TYPE_CHECKING:
    from pathlib import Path

GITHUB_ACTIONS_APP: Final = 15368
MERGE_PARENTS: Final = 2


def protected_release(repo: Path, policy: ReleasePolicy) -> tuple[str, int]:
    branch = repository_api(repo, "/branches/release")
    if branch.get("name") != "release" or branch.get("protected") is not True:
        msg = "release branch must be protected"
        raise ReleaseError(msg)
    rules = pages(repo, "/rules/branches/release")
    kinds = {string(rule.get("type")) for rule in rules}
    if (
        not {"deletion", "non_fast_forward", "pull_request", "required_status_checks"}
        <= kinds
    ):
        msg = "release protection is incomplete"
        raise ReleaseError(msg)
    for rule in rules:
        ruleset_id = integer(rule.get("ruleset_id"))
        ruleset = repository_api(repo, f"/rulesets/{ruleset_id}")
        if ruleset.get("enforcement") != "active" or (
            "bypass_actors" in ruleset and ruleset["bypass_actors"] != []
        ):
            msg = "release ruleset must be active without bypass actors"
            raise ReleaseError(msg)
    reviews = [
        object_value(rule.get("parameters"))
        for rule in rules
        if rule.get("type") == "pull_request"
    ]
    if not any(
        integer(review.get("required_approving_review_count")) >= 1
        and review.get("dismiss_stale_reviews_on_push") is True
        and review.get("require_last_push_approval") is True
        and review.get("required_review_thread_resolution") is True
        for review in reviews
    ):
        msg = "release review protection is incomplete"
        raise ReleaseError(msg)
    checks = [
        object_value(rule.get("parameters"))
        for rule in rules
        if rule.get("type") == "required_status_checks"
    ]
    if not any(
        check.get("strict_required_status_checks_policy") is True
        and set(policy.required_checks)
        <= {
            string(object_value(item).get("context"))
            for item in array_value(check.get("required_status_checks"))
            if object_value(item).get("integration_id") == GITHUB_ACTIONS_APP
        }
        for check in checks
    ):
        msg = "release required checks are not strict GitHub Actions checks"
        raise ReleaseError(msg)
    return string(object_value(branch.get("commit")).get("sha")), max(
        integer(review.get("required_approving_review_count")) for review in reviews
    )


def reviewed_merge(repo: Path, commit: str, approvals: int) -> tuple[int, str]:
    metadata = repository_api(repo, f"/commits/{commit}")
    commit_data = object_value(metadata.get("commit"))
    verified(commit_data.get("verification"))
    committer = object_value(commit_data.get("committer"))
    if (
        metadata.get("sha") != commit
        or object_value(metadata.get("author")).get("login") != "roian6"
        or object_value(metadata.get("committer")).get("login") != "web-flow"
        or object_value(commit_data.get("author")).get("name") != "Chanhyo Jung"
        or committer.get("name") != "GitHub"
        or string(committer.get("email")).partition("@")
        != ("noreply", "@", "github.com")
    ):
        msg = "source must be a GitHub verified maintainer PR merge"
        raise ReleaseError(msg)
    matches = [
        pr
        for pr in pages(repo, f"/commits/{commit}/pulls")
        if pr.get("merge_commit_sha") == commit
        and object_value(pr.get("base")).get("ref") == "release"
    ]
    if len(matches) != 1:
        msg = "source must identify exactly one release PR merge"
        raise ReleaseError(msg)
    number = integer(matches[0].get("number"))
    pr = repository_api(repo, f"/pulls/{number}")
    head = object_value(pr.get("head"))
    base = object_value(pr.get("base"))
    if (
        pr.get("merged") is not True
        or pr.get("state") != "closed"
        or pr.get("merge_commit_sha") != commit
        or base.get("ref") != "release"
        or object_value(base.get("repo")).get("full_name") != REPOSITORY
        or object_value(head.get("repo")).get("full_name") != REPOSITORY
    ):
        msg = "PR merge receipt does not bind this repository/source"
        raise ReleaseError(msg)
    head_sha = string(head.get("sha"))
    parents = git(repo, "show", "-s", "--format=%P", commit).split()
    if len(parents) not in (1, MERGE_PARENTS) or (
        len(parents) == MERGE_PARENTS and parents[1] != head_sha
    ):
        msg = "source must be a squash or reviewed two-parent merge"
        raise ReleaseError(msg)
    if head.get("ref") == "main" and len(parents) != MERGE_PARENTS:
        msg = "main promotion must preserve reviewed merge ancestry"
        raise ReleaseError(msg)
    latest: dict[str, tuple[str, str, bool]] = {}
    for review in pages(repo, f"/pulls/{number}/reviews"):
        state = string(review.get("state"))
        if state in {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}:
            login = string(object_value(review.get("user")).get("login"))
            eligible = review.get("author_association") in {
                "OWNER",
                "MEMBER",
                "COLLABORATOR",
            } or (
                login == "coderabbitai[bot]"
                and object_value(review.get("user")).get("type") == "Bot"
            )
            latest[login] = (state, string(review.get("commit_id")), eligible)
    author = string(object_value(pr.get("user")).get("login"))
    if (
        any(state == "CHANGES_REQUESTED" for state, _, _ in latest.values())
        or sum(
            state == "APPROVED" and sha == head_sha and login != author and eligible
            for login, (state, sha, eligible) in latest.items()
        )
        < approvals
    ):
        msg = "PR requires current-head approval; skipped is not approval"
        raise ReleaseError(msg)
    resolved_threads(repo, number)
    return number, head_sha


def resolved_threads(repo: Path, number: int) -> None:
    query = """query($number:Int!,$cursor:String){
      repository(owner:"roian6",name:"apple-health-ai-bridge"){
        pullRequest(number:$number){reviewThreads(first:100,after:$cursor){
          nodes{isResolved} pageInfo{hasNextPage endCursor}
        }}
      }
    }"""
    cursor: str | None = None
    for _ in range(100):
        payload = json.dumps(
            {"query": query, "variables": {"number": number, "cursor": cursor}}
        ).encode()
        response = object_value(
            TypeAdapter[JsonValue](JsonValue).validate_json(
                command(repo, "gh", "api", "graphql", "--input", "-", data=payload)
            )
        )
        if "errors" in response:
            message = "PR thread proof lookup failed"
            raise ReleaseError(message)
        repository = object_value(object_value(response.get("data")).get("repository"))
        threads = object_value(
            object_value(repository.get("pullRequest")).get("reviewThreads")
        )
        if any(
            object_value(node).get("isResolved") is not True
            for node in array_value(threads.get("nodes"))
        ):
            message = "PR has unresolved review threads"
            raise ReleaseError(message)
        page = object_value(threads.get("pageInfo"))
        if page.get("hasNextPage") is False:
            return
        cursor = string(page.get("endCursor"))
    message = "PR thread proof exceeds bounded pagination"
    raise ReleaseError(message)


def exact_checks(repo: Path, commit: str, policy: ReleasePolicy) -> dict[str, int]:
    result: dict[str, int] = {}
    for name, workflow in policy.required_checks.items():
        runs = pages(
            repo,
            f"/actions/workflows/{workflow}/runs?head_sha={commit}&event=push",
            "workflow_runs",
        )
        runs = [run for run in runs if run.get("head_branch") == "release"]
        if not runs:
            msg = f"missing exact-source push checks: {name}"
            raise ReleaseError(msg)
        run = max(runs, key=lambda item: integer(item.get("id")))
        if (
            run.get("head_sha") != commit
            or run.get("head_branch") != "release"
            or run.get("path") != f".github/workflows/{workflow}"
            or run.get("event") != "push"
            or run.get("status") != "completed"
            or run.get("conclusion") != "success"
            or object_value(run.get("repository")).get("full_name") != REPOSITORY
        ):
            msg = f"nonpassing or wrong-source workflow: {name}"
            raise ReleaseError(msg)
        run_id = integer(run.get("id"))
        attempt = integer(run.get("run_attempt"))
        jobs = pages(repo, f"/actions/runs/{run_id}/attempts/{attempt}/jobs", "jobs")
        matches = [job for job in jobs if job.get("name") == name]
        if (
            len(matches) != 1
            or matches[0].get("head_sha") != commit
            or matches[0].get("conclusion") != "success"
            or matches[0].get("status") != "completed"
        ):
            msg = f"required check must pass on exact source: {name}"
            raise ReleaseError(msg)
        result[name] = integer(matches[0].get("id"))
    return result
