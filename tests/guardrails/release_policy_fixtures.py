from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass, replace
from typing import TYPE_CHECKING

from pydantic import JsonValue, TypeAdapter

from tests.guardrails.release_git_fixtures import synthetic_release_base
from tests.guardrails.release_version_fixtures import (
    ROOT,
    ReleaseTree,
    commit_release_tree,
    git_output,
    write_release_tree,
)

if TYPE_CHECKING:
    from pathlib import Path

    import pytest

TAG = "receiver-v1.1.4"
BASE_TAG = "receiver-v1.1.3"
POLICY = ".github/release/release-policy.json"
REPOSITORY = "roian6/apple-health-ai-bridge"
CHECKS = {
    "Python quality and package checks": "python.yml",
    "Swift tests and unsigned app builds": "ios.yml",
    "Analyze Python": "codeql.yml",
}


@dataclass(frozen=True, slots=True)
class ReleaseGraph:
    repo: Path
    base: str
    target: str
    main: str
    tag_object: str
    transport: Path
    tag: str = TAG

    def read(self) -> dict[str, JsonValue]:
        return TypeAdapter(dict[str, JsonValue]).validate_json(
            self.transport.read_text()
        )

    def write(self, payload: dict[str, JsonValue]) -> None:
        _ = self.transport.write_text(json.dumps(payload))


def obj(value: JsonValue) -> dict[str, JsonValue]:
    assert isinstance(value, dict)
    return value


def policy_document() -> dict[str, JsonValue]:
    policy = TypeAdapter(dict[str, JsonValue]).validate_json(
        (ROOT / POLICY).read_text()
    )
    policy["retired_tags"] = []
    return policy


def replace_target(graph: ReleaseGraph, parents: tuple[str, ...]) -> ReleaseGraph:
    _ = git_output(graph.repo, "add", ".")
    tree = git_output(graph.repo, "write-tree")
    parent_args = [argument for parent in parents for argument in ("-p", parent)]
    target = git_output(
        graph.repo,
        "-c",
        "user.name=Synthetic",
        "-c",
        "user.email=synthetic",
        "commit-tree",
        tree,
        *parent_args,
        "-m",
        "synthetic reviewed source",
    )
    _ = git_output(graph.repo, "checkout", "--detach", target)
    _ = git_output(graph.repo, "update-ref", "refs/heads/release", target)
    _ = git_output(
        graph.repo,
        "-c",
        "user.name=Synthetic",
        "-c",
        "user.email=synthetic",
        "tag",
        "-f",
        "-a",
        TAG,
        "-m",
        "synthetic remote signature",
    )
    tag_object = git_output(graph.repo, "rev-parse", TAG)
    payload = (
        graph.transport.read_text()
        .replace(graph.target, target)
        .replace(graph.tag_object, tag_object)
    )
    _ = graph.transport.write_text(payload)
    return replace(graph, target=target, tag_object=tag_object)


def install_transport(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    executable = tmp_path / "gh"
    _ = executable.write_text(
        "\n".join(
            [
                f"#!{sys.executable}",
                "import base64, json, os, pathlib, sys",
                "path = pathlib.Path(os.environ['SOURCE_TRANSPORT'])",
                "payload = json.loads(path.read_text())",
                "route = sys.argv[2]",
                "if route not in payload:",
                "    message = 'synthetic transport missing route: ' + route",
                "    print(message, file=sys.stderr)",
                "    sys.exit(19)",
                "value = payload[route]",
                "if isinstance(value, dict) and 'synthetic_binary' in value:",
                "    raw = base64.b64decode(value['synthetic_binary'])",
                "    sys.stdout.buffer.write(raw)",
                "else:",
                "    print(json.dumps(value))",
                "",
            ]
        )
    )
    executable.chmod(0o700)
    monkeypatch.setenv("PATH", f"{tmp_path}{os.pathsep}{os.environ['PATH']}")


def release_graph(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> ReleaseGraph:
    repo = tmp_path / "repo"
    base = synthetic_release_base(repo, "release")
    write_release_tree(
        repo, ReleaseTree("1.1.4", TAG, "receiver", "1.1.1", "50", "1.0.0")
    )
    target = commit_release_tree(repo, "synthetic reviewed patch")
    _ = git_output(
        repo,
        "-c",
        "user.name=Synthetic",
        "-c",
        "user.email=synthetic",
        "tag",
        "-a",
        TAG,
        "-m",
        "synthetic remote signature transport",
    )
    tag_object = git_output(repo, "rev-parse", TAG)
    base_object = git_output(repo, "rev-parse", BASE_TAG)
    _ = git_output(repo, "checkout", "-b", "main", base)
    _ = (repo / POLICY).write_text(json.dumps(policy_document()))
    main = commit_release_tree(repo, "synthetic trusted policy")
    _ = git_output(repo, "checkout", "--detach", target)
    prefix = f"/repos/{REPOSITORY}"
    payload: dict[str, JsonValue] = {
        "graphql": {
            "data": {
                "repository": {
                    "pullRequest": {
                        "reviewThreads": {
                            "nodes": [],
                            "pageInfo": {"hasNextPage": False, "endCursor": None},
                        }
                    }
                }
            }
        },
        prefix: {"default_branch": "main", "full_name": REPOSITORY},
        prefix + "/branches/main": {
            "name": "main",
            "protected": True,
            "commit": {"sha": main},
        },
        prefix + "/branches/release": {
            "name": "release",
            "protected": True,
            "commit": {"sha": target},
        },
        prefix + "/rulesets/7": {"enforcement": "active", "bypass_actors": []},
        prefix + "/rules/branches/release?per_page=100&page=1": [
            {"type": "deletion", "ruleset_id": 7},
            {"type": "non_fast_forward", "ruleset_id": 7},
            {
                "type": "pull_request",
                "ruleset_id": 7,
                "parameters": {
                    "required_approving_review_count": 1,
                    "dismiss_stale_reviews_on_push": True,
                    "require_last_push_approval": True,
                    "required_review_thread_resolution": True,
                },
            },
            {
                "type": "required_status_checks",
                "ruleset_id": 7,
                "parameters": {
                    "strict_required_status_checks_policy": True,
                    "required_status_checks": [
                        {"context": name, "integration_id": 15368} for name in CHECKS
                    ],
                },
            },
        ],
        prefix + f"/commits/{target}": {
            "sha": target,
            "author": {"login": "roian6"},
            "committer": {"login": "web-flow"},
            "commit": {
                "verification": {"verified": True, "reason": "valid"},
                "author": {"name": "Chanhyo Jung"},
                "committer": {"name": "GitHub", "email": "noreply" + "@github.com"},
            },
        },
        prefix + f"/commits/{target}/pulls?per_page=100&page=1": [
            {"number": 42, "merge_commit_sha": target, "base": {"ref": "release"}}
        ],
        prefix + "/pulls/42": {
            "merged": True,
            "state": "closed",
            "merge_commit_sha": target,
            "user": {"login": "synthetic-author"},
            "base": {"ref": "release", "repo": {"full_name": REPOSITORY}},
            "head": {
                "ref": "fix/synthetic",
                "sha": target,
                "repo": {"full_name": REPOSITORY},
            },
        },
        prefix + "/pulls/42/reviews?per_page=100&page=1": [
            {
                "state": "APPROVED",
                "author_association": "COLLABORATOR",
                "commit_id": target,
                "user": {"login": "synthetic-reviewer"},
            }
        ],
        prefix + "/releases?per_page=100&page=1": [
            {
                "id": 3,
                "tag_name": BASE_TAG,
                "draft": False,
                "prerelease": False,
                "published_at": "2026-01-01T00:00:00Z",
            }
        ],
    }
    for tag, oid, commit in ((TAG, tag_object, target), (BASE_TAG, base_object, base)):
        payload[prefix + f"/git/ref/tags/{tag}"] = {
            "object": {"type": "tag", "sha": oid}
        }
        payload[prefix + f"/git/tags/{oid}"] = {
            "sha": oid,
            "tag": tag,
            "object": {"type": "commit", "sha": commit},
            "verification": {"verified": True, "reason": "valid"},
            "tagger": {
                "name": "Chanhyo Jung",
                "email": "23256775+roian6" + "@users.noreply.github.com",
            },
        }
    for run_id, (name, workflow) in enumerate(CHECKS.items(), 10):
        payload[
            prefix
            + f"/actions/workflows/{workflow}/runs?head_sha={target}"
            + "&event=push&per_page=100&page=1"
        ] = {
            "workflow_runs": [
                {
                    "id": run_id,
                    "run_attempt": 1,
                    "head_sha": target,
                    "head_branch": "release",
                    "path": f".github/workflows/{workflow}",
                    "event": "push",
                    "status": "completed",
                    "conclusion": "success",
                    "repository": {"full_name": REPOSITORY},
                }
            ]
        }
        payload[
            prefix + f"/actions/runs/{run_id}/attempts/1/jobs?per_page=100&page=1"
        ] = {
            "jobs": [
                {
                    "id": run_id * 100,
                    "name": name,
                    "head_sha": target,
                    "status": "completed",
                    "conclusion": "success",
                }
            ]
        }
    transport = tmp_path / "transport.json"
    graph = ReleaseGraph(repo, base, target, main, tag_object, transport)
    graph.write(payload)
    install_transport(tmp_path, monkeypatch)
    monkeypatch.setenv("SOURCE_TRANSPORT", str(transport))
    return graph
