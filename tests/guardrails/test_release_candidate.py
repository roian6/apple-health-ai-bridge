from __future__ import annotations

import base64
import os
import subprocess
import sys
from dataclasses import dataclass, replace
from typing import TYPE_CHECKING

import pytest
from pydantic import JsonValue, TypeAdapter

from tests.guardrails.release_policy_fixtures import (
    REPOSITORY,
    TAG,
    ReleaseGraph,
    release_graph,
)
from tests.guardrails.release_version_fixtures import ROOT, git_output

if TYPE_CHECKING:
    from pathlib import Path


@dataclass(frozen=True, slots=True)
class SignedCandidate:
    graph: ReleaseGraph
    encoded: str
    environment: dict[str, str]


@pytest.fixture
def signed(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> SignedCandidate:
    graph = release_graph(tmp_path, monkeypatch)
    key = tmp_path / "synthetic-signing-key"
    generated = subprocess.run(
        [
            "ssh-keygen",
            "-q",
            "-t",
            "ed25519",
            "-N",
            "",
            "-C",
            "synthetic-test-only",
            "-f",
            str(key),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert generated.returncode == 0, generated.stderr
    _ = git_output(graph.repo, "tag", "-d", TAG)
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
        "-s",
        TAG,
        "-m",
        "Synthetic signing test; never publish",
    )
    oid = git_output(graph.repo, "rev-parse", TAG)
    raw = subprocess.run(
        ["git", "cat-file", "tag", oid], cwd=graph.repo, capture_output=True, check=True
    ).stdout
    payload = graph.read()
    payload["/users/roian6/ssh_signing_keys?per_page=100"] = [
        {"key": " ".join(key.with_suffix(".pub").read_text().split()[:2])}
    ]
    graph.write(payload)
    graph = replace(graph, tag_object=oid)
    encoded = base64.b64encode(raw).decode()
    environment = os.environ | {
        "GITHUB_REPOSITORY": REPOSITORY,
        "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_REF": "refs/heads/release",
        "GITHUB_SHA": graph.target,
        "GITHUB_WORKFLOW_SHA": graph.target,
        "GITHUB_WORKFLOW_REF": (
            f"{REPOSITORY}/.github/workflows/release.yml@refs/heads/release"
        ),
        "GITHUB_RUN_ID": "1234",
        "GITHUB_RUN_ATTEMPT": "2",
        "SIGNED_TAG_OBJECT": encoded,
    }
    return SignedCandidate(graph, encoded, environment)


def prepare(signed: SignedCandidate) -> subprocess.CompletedProcess[str]:
    graph = signed.graph
    return subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts/release_candidate.py"),
            "--repo",
            str(graph.repo),
            "--tag",
            TAG,
            "--commit",
            graph.target,
            "--tag-object",
            graph.tag_object,
            "--output",
            str(graph.transport.parent / "candidate.json"),
            "--source-output",
            str(graph.transport.parent / "source.json"),
        ],
        env=signed.environment,
        capture_output=True,
        text=True,
        check=False,
    )


def test_genuine_local_signed_tag_is_verified_without_public_ref(
    signed: SignedCandidate,
) -> None:
    refs = git_output(signed.graph.repo, "show-ref")
    result = prepare(signed)
    assert result.returncode == 0, result.stderr
    record = TypeAdapter(dict[str, JsonValue]).validate_json(
        (signed.graph.transport.parent / "candidate.json").read_bytes()
    )
    assert record["remote_tag_verification"] == "pending"
    assert record["run_id"] == 1234
    assert record["run_attempt"] == 2
    assert git_output(signed.graph.repo, "show-ref") == refs


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("GITHUB_SHA", "a" * 40),
        ("GITHUB_WORKFLOW_SHA", "b" * 40),
        ("GITHUB_REF", "refs/heads/main"),
        ("GITHUB_EVENT_NAME", "push"),
        (
            "GITHUB_WORKFLOW_REF",
            "other/repo/.github/workflows/release.yml@refs/heads/release",
        ),
        ("SIGNED_TAG_OBJECT", "not base64"),
    ],
)
def test_dispatch_and_transport_mismatches_fail_before_qualification(
    signed: SignedCandidate, field: str, value: str
) -> None:
    result = prepare(replace(signed, environment=signed.environment | {field: value}))
    assert result.returncode == 1
    assert not (signed.graph.transport.parent / "candidate.json").exists()


def test_unregistered_signature_is_rejected(
    signed: SignedCandidate, tmp_path: Path
) -> None:
    other = tmp_path / "other-synthetic-key"
    _ = subprocess.run(
        ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(other)],
        capture_output=True,
        check=True,
    )
    payload = signed.graph.read()
    payload["/users/roian6/ssh_signing_keys?per_page=100"] = [
        {"key": " ".join(other.with_suffix(".pub").read_text().split()[:2])}
    ]
    signed.graph.write(payload)
    result = prepare(signed)
    assert result.returncode == 1
    assert not (signed.graph.transport.parent / "candidate.json").exists()


def test_same_source_with_different_tag_bytes_is_rejected(
    signed: SignedCandidate,
) -> None:
    raw = base64.b64decode(signed.encoded).replace(
        b"Synthetic signing test", b"Changed signing test"
    )
    result = prepare(
        replace(
            signed,
            environment=signed.environment
            | {"SIGNED_TAG_OBJECT": base64.b64encode(raw).decode()},
        )
    )
    assert result.returncode == 1
    assert "hash mismatch" in result.stderr


def test_missing_local_ref_is_imported_without_changing_other_refs(
    signed: SignedCandidate,
) -> None:
    _ = git_output(signed.graph.repo, "tag", "-d", TAG)
    before = git_output(signed.graph.repo, "show-ref").splitlines()
    result = prepare(signed)
    assert result.returncode == 0, result.stderr
    after = git_output(signed.graph.repo, "show-ref").splitlines()
    assert set(after) - set(before) == {f"{signed.graph.tag_object} refs/tags/{TAG}"}
    assert set(before) <= set(after)


@pytest.mark.parametrize(
    "mutation",
    [
        "attempt",
        "workflow",
        "branch",
        "source",
        "nonpassing",
        "expired",
        "artifact-id",
        "duplicate",
        "artifact-digest",
    ],
)
def test_download_rejects_stale_or_wrong_execution_evidence(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, mutation: str
) -> None:
    graph = release_graph(tmp_path, monkeypatch)
    payload = graph.read()
    run: dict[str, JsonValue] = {
        "id": 1234,
        "run_attempt": 2,
        "head_sha": graph.target,
        "head_branch": "release",
        "event": "workflow_dispatch",
        "path": ".github/workflows/release.yml",
        "status": "completed",
        "conclusion": "success",
        "repository": {"full_name": REPOSITORY},
    }
    artifact: dict[str, JsonValue] = {
        "id": 456,
        "name": "candidate-1234-2",
        "expired": False,
        "workflow_run": {"head_sha": graph.target},
        "digest": "sha256:" + "a" * 64,
    }
    artifacts: list[JsonValue] = [artifact]
    if mutation == "attempt":
        run["run_attempt"] = 3
    elif mutation == "workflow":
        run["path"] = ".github/workflows/other.yml"
    elif mutation == "branch":
        run["head_branch"] = "main"
    elif mutation == "source":
        run["head_sha"] = "b" * 40
    elif mutation == "nonpassing":
        run["conclusion"] = "failure"
    elif mutation == "expired":
        artifact["expired"] = True
    elif mutation == "artifact-id":
        artifact["id"] = 457
    elif mutation == "duplicate":
        artifacts.append(artifact)
    prefix = f"/repos/{REPOSITORY}"
    payload[prefix + "/actions/runs/1234/attempts/2"] = run
    payload[prefix + "/actions/runs/1234/artifacts?per_page=100&page=1"] = {
        "artifacts": artifacts
    }
    payload[prefix + "/actions/artifacts/456/zip"] = {
        "synthetic_binary": base64.b64encode(b"wrong synthetic archive").decode()
    }
    graph.write(payload)
    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts/release_candidate.py"),
            "--phase",
            "download",
            "--repo",
            str(graph.repo),
            "--run-id",
            "1234",
            "--attempt",
            "2",
            "--artifact-id",
            "456",
            "--dist-dir",
            str(tmp_path / "download"),
            "--output",
            str(tmp_path / "record.json"),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert "synthetic transport missing route" not in result.stderr
    assert not (tmp_path / "record.json").exists()
    assert not (tmp_path / "download").exists()
