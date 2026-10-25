from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import replace
from typing import TYPE_CHECKING

import pytest
from pydantic import JsonValue, TypeAdapter

from tests.guardrails.release_policy_fixtures import (
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
    ReleaseTree,
    commit_release_tree,
    git_output,
    write_release_tree,
)
from tests.guardrails.test_release_maintenance_policy import publish_policy, run_source

if TYPE_CHECKING:
    from pathlib import Path

PREFIX = f"/repos/{REPOSITORY}"


@pytest.mark.parametrize("retirement", ["exact", "missing", "wrong-object"])
def test_generic_patch_gaps_preserve_unpublished_tag_evidence(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, retirement: str
) -> None:
    graph = release_graph(tmp_path, monkeypatch)
    previous, original_payload = graph, graph.read()
    new_tag = "receiver-v1.1.6"
    write_release_tree(
        graph.repo, ReleaseTree("1.1.6", new_tag, "receiver", "1.1.1", "50", "1.0.0")
    )
    graph = replace_target(graph, (graph.target,))
    for tag in (new_tag, "receiver-v1.1.5"):
        _ = git_output(
            graph.repo,
            "-c",
            "user.name=Synthetic",
            "-c",
            "user.email=synthetic",
            "tag",
            "-a",
            tag,
            "-m",
            "synthetic candidate",
            graph.target if tag == new_tag else previous.target,
        )
    oid = git_output(graph.repo, "rev-parse", new_tag)
    skipped_oid = git_output(graph.repo, "rev-parse", "receiver-v1.1.5")
    payload = TypeAdapter(dict[str, JsonValue]).validate_json(
        graph.transport.read_text().replace(TAG, new_tag).replace(graph.tag_object, oid)
    )
    payload[PREFIX + f"/git/ref/tags/{TAG}"] = original_payload[
        PREFIX + f"/git/ref/tags/{TAG}"
    ]
    payload[PREFIX + f"/git/tags/{previous.tag_object}"] = original_payload[
        PREFIX + f"/git/tags/{previous.tag_object}"
    ]
    payload[PREFIX + "/git/ref/tags/receiver-v1.1.5"] = {
        "object": {"sha": skipped_oid, "type": "tag"}
    }
    payload[PREFIX + f"/git/tags/{skipped_oid}"] = obj(
        original_payload[PREFIX + f"/git/tags/{previous.tag_object}"]
    ) | {"tag": "receiver-v1.1.5", "sha": skipped_oid}
    releases = payload[PREFIX + "/releases?per_page=100&page=1"]
    assert isinstance(releases, list)
    releases.append(
        {
            "id": 5,
            "tag_name": "receiver-v1.1.5",
            "draft": True,
            "prerelease": False,
            "published_at": None,
        }
    )
    graph.write(payload)
    graph = replace(graph, tag=new_tag, tag_object=oid)
    policy = policy_document()
    records: list[JsonValue] = [
        {
            "tag": TAG,
            "tag_object": previous.tag_object,
            "commit": previous.target,
            "reason": "synthetic failed unpublished candidate",
        },
        {
            "tag": "receiver-v1.1.5",
            "tag_object": skipped_oid,
            "commit": previous.target,
            "reason": "synthetic failed unpublished candidate",
        },
    ]
    if retirement == "missing":
        _ = records.pop()
    elif retirement == "wrong-object":
        obj(records[0])["tag_object"] = "b" * 40
    policy["retired_tags"] = records
    graph = publish_policy(graph, json.dumps(policy))
    result = run_source(graph)
    assert (result.returncode == 0) is (retirement == "exact"), result.stderr
    if retirement == "exact":
        assert json.loads(result.stdout)["baseline_commit"] == previous.base
    else:
        assert "patch gap" in result.stderr


def ios_checkpoint_graph(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> tuple[ReleaseGraph, str]:
    graph = release_graph(tmp_path, monkeypatch)
    published_receiver = graph.target
    old_ios = "ios-v1.1.1-build.50"
    tag = "ios-v1.1.1-build.51"
    _ = git_output(
        graph.repo,
        "-c",
        "user.name=Synthetic",
        "-c",
        "user.email=synthetic",
        "tag",
        "-a",
        old_ios,
        graph.base,
        "-m",
        "synthetic verified iOS checkpoint",
    )
    old_oid = git_output(graph.repo, "rev-parse", old_ios)
    write_release_tree(
        graph.repo, ReleaseTree("1.1.4", TAG, "ios", "1.1.1", "51", "1.0.0")
    )
    graph = replace_target(graph, (graph.target,))
    _ = (graph.repo / "checkpoint-followup.txt").write_text("synthetic CI followup")
    graph = replace_target(graph, (graph.target,))
    _ = git_output(
        graph.repo,
        "-c",
        "user.name=Synthetic",
        "-c",
        "user.email=synthetic",
        "tag",
        "-a",
        tag,
        "-m",
        "synthetic current iOS checkpoint",
    )
    oid = git_output(graph.repo, "rev-parse", tag)
    payload = graph.read()
    template = obj(payload[PREFIX + f"/git/tags/{graph.tag_object}"])
    for name, object_sha, commit in (
        (old_ios, old_oid, graph.base),
        (tag, oid, graph.target),
    ):
        payload[PREFIX + f"/git/ref/tags/{name}"] = {
            "object": {"sha": object_sha, "type": "tag"}
        }
        tag_record = template.copy()
        tag_record["tag"] = name
        tag_record["sha"] = object_sha
        tag_record["object"] = {"sha": commit, "type": "commit"}
        payload[PREFIX + f"/git/tags/{object_sha}"] = tag_record
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
        published_receiver,
        "-m",
        "synthetic published Receiver",
    )
    receiver_oid = git_output(graph.repo, "rev-parse", TAG)
    payload[PREFIX + f"/git/ref/tags/{TAG}"] = {
        "object": {"sha": receiver_oid, "type": "tag"}
    }
    receiver_record = template.copy()
    receiver_record["tag"] = TAG
    receiver_record["sha"] = receiver_oid
    receiver_record["object"] = {"sha": published_receiver, "type": "commit"}
    payload[PREFIX + f"/git/tags/{receiver_oid}"] = receiver_record
    payload[PREFIX + "/releases?per_page=100&page=1"] = [
        {
            "id": 4,
            "tag_name": TAG,
            "draft": False,
            "prerelease": False,
            "published_at": "2026-02-01T00:00:00Z",
        }
    ]
    payload[PREFIX + "/git/matching-refs/tags/ios-v?per_page=100&page=1"] = [
        {"ref": f"refs/tags/{old_ios}"},
        {"ref": f"refs/tags/{tag}"},
    ]
    for run_id, (workflow, context) in enumerate(
        {
            "python.yml": "Python quality and package checks",
            "ios.yml": "Swift tests and unsigned app builds",
        }.items(),
        900,
    ):
        route = (
            PREFIX
            + f"/actions/workflows/{workflow}/runs?head_sha={graph.base}"
            + "&event=push&per_page=100&page=1"
        )
        payload[route] = {
            "workflow_runs": [
                {
                    "id": run_id,
                    "run_attempt": 1,
                    "head_sha": graph.base,
                    "head_branch": old_ios,
                    "path": f".github/workflows/{workflow}",
                    "status": "completed",
                    "conclusion": "success",
                    "repository": {"full_name": REPOSITORY},
                }
            ]
        }
        payload[
            PREFIX + f"/actions/runs/{run_id}/attempts/1/jobs?per_page=100&page=1"
        ] = {
            "jobs": [
                {
                    "name": context,
                    "head_sha": graph.base,
                    "status": "completed",
                    "conclusion": "success",
                }
            ]
        }
    graph.write(payload)
    graph = replace(graph, tag=tag, tag_object=oid)
    return graph, published_receiver


@pytest.mark.parametrize("local_tag", [False, True])
def test_ios_checkpoint_uses_independent_verified_baseline_after_branch_advance(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    local_tag: bool,
) -> None:
    graph, published_receiver = ios_checkpoint_graph(tmp_path, monkeypatch)
    if local_tag:
        key = tmp_path / "synthetic-ios-key"
        _ = subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
            capture_output=True,
            check=True,
        )
        _ = git_output(
            graph.repo,
            "-c",
            "user.name=Chanhyo Jung",
            "-c",
            "user.email=23256775+roian6" + "@users.noreply.github.com",
            "-c",
            "gpg.format=ssh",
            "-c",
            f"user.signingkey={key}",
            "tag",
            "-f",
            "-s",
            graph.tag,
            "-m",
            "synthetic local iOS checkpoint",
        )
        graph = replace(
            graph, tag_object=git_output(graph.repo, "rev-parse", graph.tag)
        )
        payload = graph.read()
        payload["/users/roian6/ssh_signing_keys?per_page=100"] = [
            {"key": " ".join(key.with_suffix(".pub").read_text().split()[:2])}
        ]
        del payload[PREFIX + f"/git/ref/tags/{graph.tag}"]
        graph.write(payload)
    _ = git_output(graph.repo, "checkout", "release")
    _ = (graph.repo / "later.txt").write_text("synthetic later development")
    later = commit_release_tree(graph.repo, "later release branch source")
    _ = git_output(graph.repo, "checkout", "--detach", graph.target)
    payload = graph.read()
    obj(payload[PREFIX + "/branches/release"])["commit"] = {"sha": later}
    graph.write(payload)
    policy = policy_document()
    policy["revoked_commits"] = ["a" * 40]
    graph = publish_policy(graph, json.dumps(policy))
    result = run_source(graph, local_tag=local_tag)
    assert result.returncode == 0, result.stderr
    receipt = TypeAdapter(dict[str, JsonValue]).validate_json(result.stdout)
    assert receipt["baseline_commit"] == graph.base
    assert receipt["remote_tag_verification"] == (
        "pending" if local_tag else "verified"
    )
    assert obj(receipt["compatibility_baseline"])["commit"] == published_receiver
    receipt_file = tmp_path / "ios-source.json"
    _ = receipt_file.write_text(result.stdout)
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
            str(receipt_file),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert validation.returncode == 0, validation.stderr
