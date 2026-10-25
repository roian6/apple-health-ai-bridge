from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import replace
from typing import TYPE_CHECKING

import pytest
from pydantic import JsonValue, TypeAdapter

from tests.guardrails.release_git_fixtures import synthetic_release_base
from tests.guardrails.release_policy_fixtures import (
    POLICY,
    REPOSITORY,
    TAG,
    ReleaseGraph,
    obj,
    policy_document,
    release_graph,
    replace_target,
)
from tests.guardrails.release_version_fixtures import (
    ROOT,
    commit_release_tree,
    git_output,
)

if TYPE_CHECKING:
    from pathlib import Path

PREFIX = f"/repos/{REPOSITORY}"


@pytest.fixture
def graph(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> ReleaseGraph:
    return release_graph(tmp_path, monkeypatch)


def run_source(
    graph: ReleaseGraph, *, local_tag: bool = False
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts/release_source_policy.py"),
            "--repo",
            str(graph.repo),
            "--tag",
            graph.tag,
            "--commit",
            graph.target,
            "--tag-object",
            graph.tag_object,
            *(["--local-tag"] if local_tag else []),
        ],
        capture_output=True,
        text=True,
        check=False,
    )


def publish_policy(graph: ReleaseGraph, raw: str) -> ReleaseGraph:
    _ = git_output(graph.repo, "checkout", "main")
    _ = (graph.repo / POLICY).write_text(raw)
    main = commit_release_tree(graph.repo, "synthetic policy revision")
    _ = git_output(graph.repo, "checkout", "--detach", graph.target)
    payload = graph.read()
    payload[PREFIX + "/branches/main"] = {
        "name": "main",
        "protected": True,
        "commit": {"sha": main},
    }
    graph.write(payload)
    return replace(graph, main=main)


@pytest.mark.parametrize("detached", [False, True])
def test_fixture_ignores_arbitrary_caller_refs(tmp_path: Path, detached: bool) -> None:
    source = tmp_path / "caller"
    _ = synthetic_release_base(source, "release")
    _ = git_output(source, "tag", TAG)
    if detached:
        _ = git_output(source, "checkout", "--detach")
    refs = git_output(source, "show-ref")
    head = git_output(source, "rev-parse", "HEAD")
    branch = git_output(source, "branch", "--show-current")
    isolated = tmp_path / "isolated"
    _ = synthetic_release_base(isolated, "release")
    assert git_output(isolated, "tag", "--list", TAG) == ""
    assert git_output(source, "show-ref") == refs
    assert git_output(source, "rev-parse", "HEAD") == head
    assert git_output(source, "branch", "--show-current") == branch


def test_exact_reviewed_source_resolves_published_baseline(graph: ReleaseGraph) -> None:
    result = run_source(graph)
    assert result.returncode == 0, result.stderr
    receipt = TypeAdapter(dict[str, JsonValue]).validate_json(result.stdout)
    assert receipt["source_commit"] == graph.target
    assert receipt["baseline_commit"] == graph.base
    assert obj(receipt["baseline"])["release_id"] == 3
    assert receipt["pull_request"] == 42
    assert receipt["check_runs"] == {
        "Python quality and package checks": 1000,
        "Swift tests and unsigned app builds": 1100,
        "Analyze Python": 1200,
    }


def test_main_and_release_advancement_preserve_candidate(graph: ReleaseGraph) -> None:
    _ = git_output(graph.repo, "checkout", "release")
    _ = (graph.repo / "later.txt").write_text("synthetic later source")
    later = commit_release_tree(graph.repo, "later reviewed source")
    _ = git_output(graph.repo, "checkout", "--detach", graph.target)
    payload = graph.read()
    obj(payload[PREFIX + "/branches/release"])["commit"] = {"sha": later}
    graph.write(payload)
    policy = policy_document()
    policy["revoked_commits"] = ["a" * 40]
    graph = publish_policy(graph, json.dumps(policy))
    result = run_source(graph)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["source_commit"] == graph.target


@pytest.mark.parametrize("raw", ["{}", "[]", "invalid JSON", '{"schema_id":"wrong"}'])
def test_candidate_cannot_supply_missing_main_policy(
    graph: ReleaseGraph, raw: str
) -> None:
    graph = publish_policy(graph, raw)
    _ = (graph.repo / POLICY).write_text(json.dumps(policy_document()))
    graph = replace_target(graph, (graph.target,))
    result = run_source(graph)
    assert result.returncode == 1
    assert "checkout must be clean" not in result.stderr


@pytest.mark.parametrize(
    "field", ["revoked_commits", "revoked_tag_objects", "retired_tags"]
)
def test_explicit_revocation_is_fresh(graph: ReleaseGraph, field: str) -> None:
    assert run_source(graph).returncode == 0
    policy = policy_document()
    policy[field] = (
        [graph.target]
        if field == "revoked_commits"
        else [graph.tag_object]
        if field == "revoked_tag_objects"
        else [
            {
                "tag": TAG,
                "tag_object": graph.tag_object,
                "commit": graph.target,
                "reason": "synthetic retired candidate",
            }
        ]
    )
    graph = publish_policy(graph, json.dumps(policy))
    result = run_source(graph)
    assert result.returncode == 1
    assert "revoked or retired" in result.stderr


@pytest.mark.parametrize(
    ("route", "keys", "value"),
    [
        ("/branches/main", ("protected",), False),
        ("/branches/main", ("name",), "release"),
        ("/branches/release", ("protected",), False),
        ("/branches/release", ("name",), "other"),
        ("/branches/release", ("commit", "sha"), "b" * 40),
        ("", ("default_branch",), "other"),
        ("/rulesets/7", ("enforcement",), "evaluate"),
        ("/rulesets/7", ("bypass_actors",), [{"actor_id": 1}]),
        ("/git/ref/tags/" + TAG, ("object", "type"), "commit"),
        ("/git/ref/tags/" + TAG, ("object", "sha"), "b" * 40),
        ("/git/tags/{tag_object}", ("object", "sha"), "b" * 40),
        ("/git/tags/{tag_object}", ("verification", "verified"), False),
        ("/git/tags/{tag_object}", ("tag",), "receiver-v9.9.9"),
        ("/commits/{target}", ("commit", "verification", "verified"), False),
        ("/commits/{target}", ("committer", "login"), "other"),
        ("/commits/{target}", ("sha",), "b" * 40),
        ("/commits/{target}", ("author", "login"), "other"),
        ("/git/tags/{tag_object}", ("tagger", "email"), "other"),
        ("/pulls/42", ("merged",), False),
        ("/pulls/42", ("merge_commit_sha",), "b" * 40),
        ("/pulls/42", ("base", "ref"), "main"),
        ("/pulls/42", ("head", "repo", "full_name"), "other/repository"),
    ],
)
def test_wrong_source_or_governance_holds_before_qualification(
    graph: ReleaseGraph,
    route: str,
    keys: tuple[str, ...],
    value: JsonValue,
) -> None:
    payload = graph.read()
    node = obj(
        payload[PREFIX + route.format(target=graph.target, tag_object=graph.tag_object)]
    )
    for key in keys[:-1]:
        node = obj(node[key])
    node[keys[-1]] = value
    graph.write(payload)
    result = run_source(graph)
    assert result.returncode == 1, result.stdout


@pytest.mark.parametrize(
    "state", ["COMMENTED", "DISMISSED", "CHANGES_REQUESTED", "SKIPPED"]
)
def test_review_skip_is_never_approval(graph: ReleaseGraph, state: str) -> None:
    payload = graph.read()
    payload[PREFIX + "/pulls/42/reviews?per_page=100&page=1"] = [
        {"state": state, "commit_id": graph.target, "user": {"login": "reviewer"}}
    ]
    graph.write(payload)
    assert run_source(graph).returncode == 1


@pytest.mark.parametrize(
    ("reviewer", "sha"), [("synthetic-author", "target"), ("reviewer", "base")]
)
def test_review_must_approve_latest_head_by_other_author(
    graph: ReleaseGraph, reviewer: str, sha: str
) -> None:
    payload = graph.read()
    payload[PREFIX + "/pulls/42/reviews?per_page=100&page=1"] = [
        {
            "state": "APPROVED",
            "commit_id": getattr(graph, sha),
            "author_association": "COLLABORATOR",
            "user": {"login": reviewer},
        }
    ]
    graph.write(payload)
    assert run_source(graph).returncode == 1


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("conclusion", "failure"),
        ("conclusion", "skipped"),
        ("status", "in_progress"),
        ("head_sha", "b" * 40),
        ("head_branch", "main"),
        ("path", ".github/workflows/other.yml"),
        ("event", "pull_request"),
    ],
)
def test_checks_bind_successful_release_push_execution(
    graph: ReleaseGraph, field: str, value: str
) -> None:
    payload = graph.read()
    route = (
        PREFIX
        + f"/actions/workflows/python.yml/runs?head_sha={graph.target}"
        + "&event=push&per_page=100&page=1"
    )
    runs = obj(payload[route])["workflow_runs"]
    assert isinstance(runs, list)
    obj(runs[0])[field] = value
    graph.write(payload)
    assert run_source(graph).returncode == 1


@pytest.mark.parametrize(
    "state", ["draft", "prerelease", "missing-publication", "duplicate"]
)
def test_baseline_requires_unique_published_stable_release(
    graph: ReleaseGraph, state: str
) -> None:
    payload = graph.read()
    releases = payload[PREFIX + "/releases?per_page=100&page=1"]
    assert isinstance(releases, list)
    release = obj(releases[0])
    if state == "duplicate":
        releases.append(release)
    elif state == "missing-publication":
        release["published_at"] = None
    else:
        release[state] = True
    graph.write(payload)
    assert run_source(graph).returncode == 1


def test_unpublished_candidate_tag_and_draft_are_not_baseline(
    graph: ReleaseGraph,
) -> None:
    payload = graph.read()
    releases = payload[PREFIX + "/releases?per_page=100&page=1"]
    assert isinstance(releases, list)
    releases.append(
        {
            "id": 4,
            "tag_name": TAG,
            "draft": True,
            "prerelease": False,
            "published_at": None,
        }
    )
    graph.write(payload)
    result = run_source(graph)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["baseline_commit"] == graph.base


@pytest.mark.parametrize(
    "shape", ["followup", "reviewed-merge", "unrelated", "unreviewed-merge"]
)
def test_frozen_source_uses_published_baseline_across_reviewed_graphs(
    graph: ReleaseGraph, shape: str
) -> None:
    previous = graph.target
    parents = (
        ()
        if shape == "unrelated"
        else (previous, graph.main)
        if "merge" in shape
        else (previous,)
    )
    graph = replace_target(graph, parents)
    if shape == "reviewed-merge":
        payload = graph.read()
        obj(obj(payload[PREFIX + "/pulls/42"])["head"]).update(
            {"ref": "main", "sha": graph.main}
        )
        payload[PREFIX + "/pulls/42/reviews?per_page=100&page=1"] = [
            {
                "state": "APPROVED",
                "author_association": "COLLABORATOR",
                "commit_id": graph.main,
                "user": {"login": "reviewer"},
            }
        ]
        graph.write(payload)
    result = run_source(graph)
    accepted = shape in {"followup", "reviewed-merge"}
    assert (result.returncode == 0) is accepted, result.stderr
    if accepted:
        receipt = graph.transport.parent / "receipt.json"
        _ = receipt.write_text(result.stdout)
        validation = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/release_tools.py"),
                "validate",
                "--repo",
                str(graph.repo),
                "--tag",
                graph.tag,
                "--tag-target-commit",
                graph.target,
                "--default-main-commit",
                graph.main,
                "--baseline-commit",
                graph.base,
                "--source-receipt",
                str(receipt),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        assert validation.returncode == 0, validation.stderr
        assert git_output(graph.repo, "rev-parse", "HEAD^1") == previous
        assert json.loads(result.stdout)["baseline_commit"] == graph.base


def test_unresolved_threads_block_even_with_approval(graph: ReleaseGraph) -> None:
    payload = graph.read()
    repository = obj(obj(payload["graphql"])["data"])
    threads = obj(obj(obj(repository["repository"])["pullRequest"])["reviewThreads"])
    threads["nodes"] = [{"isResolved": False}]
    graph.write(payload)
    result = run_source(graph)
    assert result.returncode == 1
    assert "unresolved review threads" in result.stderr


def test_read_only_ruleset_response_does_not_invent_bypass_readback(
    graph: ReleaseGraph,
) -> None:
    payload = graph.read()
    del obj(payload[PREFIX + "/rulesets/7"])["bypass_actors"]
    graph.write(payload)
    result = run_source(graph)
    assert result.returncode == 0, result.stderr


def test_duplicate_policy_keys_fail_closed(graph: ReleaseGraph) -> None:
    raw = json.dumps(policy_document()).replace(
        '"revoked_commits": []', '"revoked_commits": [], "revoked_commits": []'
    )
    graph = publish_policy(graph, raw)
    result = run_source(graph)
    assert result.returncode == 1
    assert "duplicate trusted policy field" in result.stderr


@pytest.mark.parametrize("mutation", ["ios-source", "ios-version", "batch"])
def test_receiver_only_transition_preserves_component_baseline(
    graph: ReleaseGraph, mutation: str
) -> None:
    index = graph.repo / "component-versions.json"
    payload = TypeAdapter(dict[str, JsonValue]).validate_json(index.read_bytes())
    if mutation == "ios-source":
        _ = (graph.repo / "ios/changed.swift").write_text(
            "// synthetic changed source\n"
        )
    elif mutation == "ios-version":
        obj(payload["ios_companion"])["build"] = "51"
    else:
        obj(payload["batch_protocol"])["version"] = "1.1.0"
    _ = index.write_text(json.dumps(payload))
    graph = replace_target(graph, (graph.target,))
    result = run_source(graph)
    assert result.returncode == 0, result.stderr
    receipt = graph.transport.parent / "receipt.json"
    _ = receipt.write_text(result.stdout)
    validation = subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts/release_tools.py"),
            "validate",
            "--repo",
            str(graph.repo),
            "--tag",
            graph.tag,
            "--tag-target-commit",
            graph.target,
            "--default-main-commit",
            graph.main,
            "--baseline-commit",
            graph.base,
            "--source-receipt",
            str(receipt),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert validation.returncode == 1
