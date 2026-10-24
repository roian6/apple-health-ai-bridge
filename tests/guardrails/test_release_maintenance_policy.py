from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
from dataclasses import dataclass, replace
from typing import TYPE_CHECKING, TypeAlias

import pytest
from pydantic import JsonValue, TypeAdapter

from tests.guardrails.release_version_fixtures import (
    ROOT,
    commit_release_tree,
    git_output,
    validate_transition,
)

if TYPE_CHECKING:
    from pathlib import Path

BASE = "a4fd59e2f222251ab9ff76cb0eb08524035fcb6d"
BASE_TAG = "receiver-v1.1.3"
TAG = "receiver-v1.1.4"
BRANCH = "fix/receiver-1.1.4"
POLICY = ".github/release/receiver-maintenance.json"
JsonObject: TypeAlias = dict[str, JsonValue]


def required_object(value: JsonValue) -> JsonObject:
    assert isinstance(value, dict)
    return value


@dataclass(frozen=True, slots=True)
class MaintenanceGraph:
    repo: Path
    target: str
    main: str
    transport: Path


def authorization(target: str) -> str:
    return json.dumps(
        {
            "schema_id": "health_bridge.receiver_maintenance.v1",
            "releases": [
                {
                    "tag": TAG,
                    "branch_ref": f"refs/heads/{BRANCH}",
                    "base_tag": BASE_TAG,
                    "base_commit": BASE,
                    "target_commit": target,
                }
            ],
        }
    )


@pytest.fixture
def maintenance_graph(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> MaintenanceGraph:
    repo = tmp_path / "repo"
    _ = git_output(tmp_path, "clone", "--shared", "--no-checkout", str(ROOT), str(repo))
    _ = git_output(repo, "checkout", "-b", BRANCH, BASE)
    for name in (
        "pyproject.toml",
        "component-versions.json",
        "macos/HealthBridgeMailboxAckPublisher/Info.plist",
    ):
        path = repo / name
        _ = path.write_text(path.read_text().replace("1.1.3", "1.1.4"))
    notes = repo / ".github/release" / f"notes-{TAG}.md"
    _ = notes.write_text(
        (repo / ".github/release" / f"notes-{BASE_TAG}.md")
        .read_text()
        .replace("1.1.3", "1.1.4")
    )
    target = commit_release_tree(repo, "synthetic receiver patch")
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
        "synthetic tag; signature metadata mocked",
    )
    _ = git_output(
        repo, "checkout", "-B", "main", git_output(ROOT, "rev-parse", "HEAD")
    )
    _ = (repo / POLICY).write_text(authorization(target))
    main = commit_release_tree(repo, "synthetic protected authorization")
    _ = git_output(repo, "checkout", "--detach", target)
    transport = tmp_path / "transport.json"
    tag_object = git_output(repo, "rev-parse", f"refs/tags/{TAG}")
    base_object = git_output(repo, "rev-parse", f"refs/tags/{BASE_TAG}")
    tagger_account = "23256775+roian6"
    committer_account = "noreply"
    metadata = {
        "": {"default_branch": "main"},
        "/branches/main": {"commit": {"sha": main}, "protected": True},
        f"/branches/{BRANCH}": {
            "name": BRANCH,
            "commit": {"sha": target},
            "protected": True,
        },
        f"/git/ref/tags/{TAG}": {"object": {"sha": tag_object, "type": "tag"}},
        f"/git/ref/tags/{BASE_TAG}": {"object": {"sha": base_object, "type": "tag"}},
        f"/git/tags/{base_object}": {"object": {"sha": BASE, "type": "commit"}},
        f"/git/tags/{tag_object}": {
            "tag": TAG,
            "object": {"sha": target, "type": "commit"},
            "verification": {"verified": True, "reason": "valid"},
            "tagger": {
                "name": "Chanhyo Jung",
                "email": f"{tagger_account}@users.noreply.github.com",
            },
        },
        f"/commits/{target}": {
            "author": {"login": "roian6"},
            "committer": {"login": "web-flow"},
            "commit": {
                "verification": {"verified": True, "reason": "valid"},
                "author": {"name": "Chanhyo Jung"},
                "committer": {
                    "name": "GitHub",
                    "email": f"{committer_account}@github.com",
                },
            },
        },
    }
    _ = transport.write_text(json.dumps(metadata))
    _ = git_output(repo, "remote", "set-url", "origin", str(repo))
    gh = tmp_path / "gh"
    _ = gh.write_text(
        f"""#!{sys.executable}
import json, os, pathlib, sys
route = sys.argv[2].removeprefix('/repos/roian6/apple-health-ai-bridge')
payload = json.loads(pathlib.Path(os.environ['SOURCE_TRANSPORT']).read_text())
if route not in payload: sys.exit(19)
print(json.dumps(payload[route]))
"""
    )
    gh.chmod(0o700)
    monkeypatch.setenv("PATH", f"{tmp_path}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("SOURCE_TRANSPORT", str(transport))
    monkeypatch.setenv("GITHUB_REPOSITORY", "roian6/apple-health-ai-bridge")
    return MaintenanceGraph(repo, target, main, transport)


def test_authorized_maintenance_preserves_real_default_main(
    maintenance_graph: MaintenanceGraph,
) -> None:
    # Given: real divergent Git objects, with authority only in protected main.
    graph = maintenance_graph
    assert graph.target != graph.main
    assert not (graph.repo / POLICY).exists()

    # When: the existing release CLI validates the actual maintenance target.
    completed = validate_transition(
        graph.repo,
        tag=TAG,
        tag_target=graph.target,
        default_main=graph.main,
        baseline=BASE,
    )

    # Then: maintenance authority permits the patch without relabeling main.
    assert completed.returncode == 0, completed.stderr


def run_source(
    graph: MaintenanceGraph, *, tag_object: str | None = None
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts/release_source_policy.py"),
            "--repo",
            str(graph.repo),
            "--tag",
            TAG,
            "--commit",
            graph.target,
            "--tag-object",
            tag_object
            if tag_object is not None
            else git_output(graph.repo, "rev-parse", f"refs/tags/{TAG}"),
        ],
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.mark.parametrize("command", ["gh", "git"])
def test_stalled_source_lookup_has_clean_bounded_failure(
    maintenance_graph: MaintenanceGraph, command: str
) -> None:
    graph = maintenance_graph
    tag_object = git_output(graph.repo, "rev-parse", f"refs/tags/{TAG}")
    executable = graph.transport.parent / command
    _ = executable.write_text(f"#!{sys.executable}\nimport time\ntime.sleep(0.5)\n")
    executable.chmod(0o700)
    runner = graph.transport.parent / "timeout_runner.py"
    _ = runner.write_text(
        f"""import sys
sys.path.insert(0, {str(ROOT / "scripts")!r})
import release_source_policy as policy
policy._LOOKUP_TIMEOUT_SECONDS = 0.05
raise SystemExit(policy.main())
"""
    )
    completed = subprocess.run(
        [
            sys.executable,
            "-I",
            "-S",
            str(runner),
            "--repo",
            str(graph.repo),
            "--tag",
            TAG,
            "--commit",
            graph.target,
            "--tag-object",
            tag_object,
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    assert completed.returncode == 1
    assert completed.stdout == ""
    assert completed.stderr == f"release source {command} lookup timed out\n"


def test_different_local_tag_object_is_rejected(
    maintenance_graph: MaintenanceGraph,
) -> None:
    graph = maintenance_graph
    requested_object = git_output(graph.repo, "rev-parse", f"refs/tags/{TAG}")
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
        "synthetic different local tag object",
    )
    assert git_output(graph.repo, "rev-parse", f"refs/tags/{TAG}") != requested_object
    completed = run_source(graph, tag_object=requested_object)
    assert completed.returncode == 1
    assert "signed tag identity or target mismatch" in completed.stderr


def read_transport(graph: MaintenanceGraph) -> JsonObject:
    return TypeAdapter(dict[str, JsonValue]).validate_json(graph.transport.read_text())


def publish_authority(graph: MaintenanceGraph, raw: str | None) -> MaintenanceGraph:
    _ = git_output(graph.repo, "checkout", "main")
    if raw is None:
        (graph.repo / POLICY).unlink()
    else:
        _ = (graph.repo / POLICY).write_text(raw)
    main = commit_release_tree(graph.repo, "synthetic authority revision")
    _ = git_output(graph.repo, "checkout", "--detach", graph.target)
    metadata = read_transport(graph)
    metadata["/branches/main"] = {"commit": {"sha": main}, "protected": True}
    _ = graph.transport.write_text(json.dumps(metadata))
    return replace(graph, main=main)


def test_source_cli_reports_real_main_and_first_parent(
    maintenance_graph: MaintenanceGraph,
) -> None:
    graph = maintenance_graph
    completed = run_source(graph)
    assert completed.returncode == 0, completed.stderr
    assert json.loads(completed.stdout) == {
        "default_main_commit": graph.main,
        "baseline_commit": BASE,
    }


@pytest.mark.parametrize(
    "raw",
    [
        None,
        "{}",
        "[]",
        "invalid JSON",
        '{"schema_id":"health_bridge.receiver_maintenance.v1","releases":[]}',
        '{"schema_id":"health_bridge.receiver_maintenance.v1","releases":[],"extra":true}',
        '{"schema_id":"health_bridge.receiver_maintenance.v1","releases":[],"releases":[]}',
    ],
)
def test_missing_or_malformed_main_authority_rejects_candidate_local_record(
    maintenance_graph: MaintenanceGraph,
    raw: str | None,
) -> None:
    graph = publish_authority(maintenance_graph, raw)
    _ = (graph.repo / POLICY).write_text(authorization(graph.target))
    completed = run_source(graph)
    assert completed.returncode == 1, completed.stdout


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("target_commit", "b" * 40),
        ("target_commit", "B" * 40),
        ("target_commit", "short"),
        ("target_commit", None),
        ("branch_ref", "refs/heads/main"),
        ("branch_ref", "refs/heads/fix/receiver-1.1.5"),
        ("base_commit", "b" * 40),
        ("base_tag", "receiver-v1.1.2"),
        ("tag", "receiver-v1.2.0"),
        ("extra", "unreviewed"),
    ],
)
def test_closed_record_rejects_different_or_malformed_binding(
    maintenance_graph: MaintenanceGraph,
    field: str,
    value: JsonValue,
) -> None:
    graph = maintenance_graph
    document = TypeAdapter(dict[str, JsonValue]).validate_json(
        authorization(graph.target)
    )
    records = document["releases"]
    assert isinstance(records, list)
    required_object(records[0])[field] = value
    graph = publish_authority(graph, json.dumps(document))
    completed = run_source(graph)
    assert completed.returncode == 1, completed.stdout


def test_duplicate_records_are_rejected(maintenance_graph: MaintenanceGraph) -> None:
    graph = maintenance_graph
    document = TypeAdapter(dict[str, JsonValue]).validate_json(
        authorization(graph.target)
    )
    records = document["releases"]
    assert isinstance(records, list)
    records.append(records[0])
    graph = publish_authority(graph, json.dumps(document))
    completed = run_source(graph)
    assert completed.returncode == 1
    assert "unique next-patch branch" in completed.stderr


@pytest.mark.parametrize(
    ("keys", "value"),
    [
        (("/branches/main", "protected"), False),
        ((f"/branches/{BRANCH}", "protected"), False),
        ((f"/branches/{BRANCH}", "commit", "sha"), BASE),
        (("", "default_branch"), "other"),
        (("/git/tags/{base_object}", "object", "sha"), "b" * 40),
        ((f"/git/ref/tags/{TAG}", "object", "sha"), "b" * 40),
        ((f"/git/ref/tags/{TAG}", "object", "type"), "commit"),
        (("/git/tags/{tag_object}", "object", "sha"), BASE),
        (("/git/tags/{tag_object}", "verification", "verified"), False),
        (("/git/tags/{tag_object}", "tag"), "receiver-v1.1.5"),
        (("/git/tags/{tag_object}", "tagger", "email"), "untrusted"),
        (("/commits/{target}", "commit", "verification", "verified"), False),
        (("/commits/{target}", "author", "login"), "untrusted"),
        (("/commits/{target}", "committer", "login"), "untrusted"),
    ],
)
def test_live_source_boundaries_fail_closed(
    maintenance_graph: MaintenanceGraph,
    keys: tuple[str, ...],
    value: JsonValue,
) -> None:
    graph = maintenance_graph
    metadata = read_transport(graph)
    tag_object = git_output(graph.repo, "rev-parse", f"refs/tags/{TAG}")
    base_object = git_output(graph.repo, "rev-parse", f"refs/tags/{BASE_TAG}")
    selected = metadata
    for key in keys[:-1]:
        selected = required_object(
            selected[
                key.format(
                    tag_object=tag_object,
                    base_object=base_object,
                    target=graph.target,
                )
            ]
        )
    selected[keys[-1]] = value
    _ = graph.transport.write_text(json.dumps(metadata))
    completed = run_source(graph)
    assert completed.returncode == 1, completed.stdout


def test_normal_main_needs_no_maintenance_record(
    maintenance_graph: MaintenanceGraph,
) -> None:
    graph = maintenance_graph
    metadata = read_transport(graph)
    metadata["/branches/main"] = {"commit": {"sha": graph.target}, "protected": True}
    _ = graph.transport.write_text(json.dumps(metadata))
    completed = run_source(graph)
    assert completed.returncode == 0, completed.stderr
    assert json.loads(completed.stdout)["default_main_commit"] == graph.target


def test_branch_response_must_name_authorized_ref(
    maintenance_graph: MaintenanceGraph,
) -> None:
    graph = maintenance_graph
    metadata = read_transport(graph)
    required_object(metadata[f"/branches/{BRANCH}"])["name"] = "different-branch"
    _ = graph.transport.write_text(json.dumps(metadata))
    completed = run_source(graph)
    assert completed.returncode == 1, completed.stdout


def test_revocation_is_fresh_on_every_call(maintenance_graph: MaintenanceGraph) -> None:
    graph = maintenance_graph
    assert run_source(graph).returncode == 0
    graph = publish_authority(
        graph, '{"schema_id":"health_bridge.receiver_maintenance.v1","releases":[]}'
    )
    completed = run_source(graph)
    assert completed.returncode == 1
    assert "exact maintenance authorization" in completed.stderr


def replace_candidate(
    graph: MaintenanceGraph, parents: tuple[str, ...]
) -> MaintenanceGraph:
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
        "synthetic alternate candidate",
    )
    _ = git_output(graph.repo, "reset", "--hard", target)
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
        "synthetic replacement tag",
    )
    metadata = read_transport(graph)
    old_object = required_object(
        required_object(metadata[f"/git/ref/tags/{TAG}"])["object"]
    )["sha"]
    assert isinstance(old_object, str)
    new_object = git_output(graph.repo, "rev-parse", f"refs/tags/{TAG}")
    tag = required_object(metadata.pop(f"/git/tags/{old_object}"))
    tag["object"] = {"sha": target, "type": "commit"}
    metadata[f"/git/tags/{new_object}"] = tag
    metadata[f"/git/ref/tags/{TAG}"] = {"object": {"sha": new_object, "type": "tag"}}
    metadata[f"/commits/{target}"] = metadata.pop(f"/commits/{graph.target}")
    metadata[f"/branches/{BRANCH}"] = {
        "name": BRANCH,
        "commit": {"sha": target},
        "protected": True,
    }
    _ = graph.transport.write_text(json.dumps(metadata))
    return publish_authority(replace(graph, target=target), authorization(target))


@pytest.mark.parametrize("boundary", ["ios-source", "ios-build", "batch", "scope"])
def test_authority_cannot_relax_receiver_only_constraints(
    maintenance_graph: MaintenanceGraph,
    boundary: str,
) -> None:
    graph = maintenance_graph
    index = graph.repo / "component-versions.json"
    document = TypeAdapter(dict[str, JsonValue]).validate_json(index.read_text())
    if boundary == "ios-source":
        _ = (graph.repo / "ios/unauthorized.swift").write_text("// synthetic change\n")
    elif boundary == "ios-build":
        required_object(document["ios_companion"])["build"] = "999"
    elif boundary == "batch":
        required_object(document["batch_protocol"])["version"] = "1.1.0"
    else:
        document["release_scope"] = "coordinated"
    _ = index.write_text(json.dumps(document))
    graph = replace_candidate(graph, (BASE,))
    completed = run_source(graph)
    assert completed.returncode == 1
    assert "preserve base iOS source/build and Batch Protocol" in completed.stderr


@pytest.mark.parametrize("ancestry", ["unrelated", "merge", "reused-version"])
def test_authority_cannot_relax_first_parent_transition(
    maintenance_graph: MaintenanceGraph,
    ancestry: str,
) -> None:
    graph = maintenance_graph
    parents = () if ancestry == "unrelated" else (BASE, graph.main)
    if ancestry == "reused-version":
        parents = (graph.target,)
    graph = replace_candidate(graph, parents)
    completed = run_source(graph)
    assert completed.returncode == 1


def test_transition_rejects_false_first_parent(
    maintenance_graph: MaintenanceGraph,
) -> None:
    graph = maintenance_graph
    completed = validate_transition(
        graph.repo,
        tag=TAG,
        tag_target=graph.target,
        default_main=graph.main,
        baseline=graph.main,
    )
    assert completed.returncode == 1
    assert "baseline must equal the tag target's first parent" in completed.stderr


def test_transition_rejects_stale_default_main_input(
    maintenance_graph: MaintenanceGraph,
) -> None:
    graph = maintenance_graph
    completed = validate_transition(
        graph.repo,
        tag=TAG,
        tag_target=graph.target,
        default_main=BASE,
        baseline=BASE,
    )
    assert completed.returncode == 1
    assert (
        "default-main commit must equal fresh protected authority" in completed.stderr
    )


SOURCE_STAGES = [
    ("release.yml", "Verify and pin tag object and target commit"),
    ("release.yml", "Verify downloaded release packet"),
    ("release.yml", "Create and verify helper-pending draft release"),
    ("publish-release.yml", "Download exact bound draft helper assets"),
    ("publish-release.yml", "Download exact remote helper-pending asset set"),
    ("publish-release.yml", "Reverify exact draft and publish once"),
]


@pytest.mark.parametrize(("workflow", "step"), SOURCE_STAGES)
@pytest.mark.parametrize("authorized", [True, False])
def test_each_workflow_source_gate_executes_the_authoritative_decision(
    maintenance_graph: MaintenanceGraph,
    workflow: str,
    step: str,
    authorized: bool,
) -> None:
    graph = maintenance_graph
    if not authorized:
        graph = publish_authority(
            graph, '{"schema_id":"health_bridge.receiver_maintenance.v1","releases":[]}'
        )
    text = (ROOT / ".github/workflows" / workflow).read_text()
    body = text.split(f"      - name: {step}\n", 1)[1].split("\n      - name:", 1)[0]
    lines = body.splitlines()
    start = next(
        i
        for i, line in enumerate(lines)
        if "python3 scripts/release_source_policy.py" in line
    )
    command = lines[start].strip().removeprefix('source="$(')
    end = start
    while command.endswith("\\"):
        end += 1
        command = command[:-1] + lines[end].strip()
    command = command.removesuffix(')"')
    resolver = shlex.quote(str(ROOT / "scripts/release_source_policy.py"))
    command = command.replace(
        "python3 scripts/release_source_policy.py",
        f"{shlex.quote(sys.executable)} {resolver}",
    )
    tag_object = git_output(graph.repo, "rev-parse", f"refs/tags/{TAG}")
    environment = os.environ | {
        "GITHUB_REF_NAME": TAG,
        "RELEASE_TAG": TAG,
        "target_sha": graph.target,
        "commit_sha": graph.target,
        "PINNED_TARGET_COMMIT_SHA": graph.target,
        "tag_object_sha": tag_object,
        "PINNED_TAG_OBJECT_SHA": tag_object,
    }
    completed = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", command],
        cwd=graph.repo,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    assert completed.returncode == (0 if authorized else 1), completed.stderr
