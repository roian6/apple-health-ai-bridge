from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Literal, assert_never

import pytest
from pydantic import TypeAdapter
from typing_extensions import TypedDict

from tests.guardrails.release_version_fixtures import (
    ReleaseTree,
    commit_release_tree,
    git_output,
    write_release_tree,
)
from tests.guardrails.test_helper_release_contract import build_helper_packet

ROOT = Path(__file__).parents[2]
TOOL = ROOT / "scripts/release_tools.py"
BUILD = "receiver-build-provenance.intoto.jsonl"
FINAL = "receiver-final-provenance.intoto.jsonl"
REPOSITORY = "roian6/apple-health-ai-bridge"
TAG = "receiver-v1.1.3"


class SubjectRecord(TypedDict):
    name: str
    digest: dict[str, str]


class StatementRecord(TypedDict):
    _type: str
    predicateType: str
    subject: list[SubjectRecord]


class ResultRecord(TypedDict):
    statement: StatementRecord


class VerificationRecord(TypedDict):
    verificationResult: ResultRecord


class AssetRecord(TypedDict):
    name: str
    digest: str
    size: int
    state: str


class ReleaseRecord(TypedDict):
    tag_name: str
    name: str
    draft: bool
    prerelease: bool
    body: str
    assets: list[AssetRecord]


def run_tool(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(TOOL), *args],
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.fixture
def future_repo(receiver_release_repo: Path) -> Path:
    write_release_tree(
        receiver_release_repo,
        ReleaseTree("1.1.3", TAG, "receiver", "1.1.0", "39", "1.0.0"),
    )
    _ = commit_release_tree(receiver_release_repo, "synthetic prospective release")
    return receiver_release_repo


@pytest.fixture
def native_transport_mock(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Mock only gh transport; never claim these JSON records are signed proofs."""
    command = tmp_path / "gh"
    _ = command.write_text(
        f"""#!{sys.executable}
import json, os, pathlib, shutil, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ['PROVENANCE_MOCK'])
with (root / 'calls.jsonl').open('a') as out:
    out.write(json.dumps(args) + '\\n')
if args[0] == 'api':
    endpoint = args[1]
    if '/git/ref/' in endpoint: print('3' * 40)
    elif '/git/tags/' in endpoint: print('1' * 40)
    elif '/branches/' in endpoint: print('1' * 40)
    elif endpoint.endswith('?per_page=100'): print('17')
    elif endpoint.endswith('/releases/17'):
        print(pathlib.Path(os.environ['PROVENANCE_RELEASE_JSON']).read_text())
    else: print('main')
    sys.exit(0)
if args[:2] == ['release', 'download']:
    destination = pathlib.Path(args[args.index('--dir') + 1])
    for path in pathlib.Path(os.environ['PROVENANCE_DIST']).iterdir():
        shutil.copyfile(path, destination / path.name)
    sys.exit(0)
if args[:2] == ['release', 'edit']: sys.exit(0)
bundle = pathlib.Path(args[args.index('--bundle') + 1])
if (os.environ.get('PROVENANCE_REJECT') == bundle.name or
    bundle.read_text() != '{{"unit_transport_mock": true}}\\n'):
    sys.exit(1)
print((root / (bundle.name + '.result')).read_text())
""",
        encoding="utf-8",
    )
    command.chmod(0o700)
    monkeypatch.setenv("PATH", f"{tmp_path}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("PROVENANCE_MOCK", str(tmp_path))
    return tmp_path


def mock_bundle(dist: Path, transport: Path, name: str, subjects: set[str]) -> None:
    _ = (dist / name).write_text('{"unit_transport_mock": true}\n')
    statement = {
        "_type": "https://in-toto.io/Statement/v1",
        "predicateType": "https://slsa.dev/provenance/v1",
        "subject": [
            {
                "name": item,
                "digest": {
                    "sha256": hashlib.sha256((dist / item).read_bytes()).hexdigest()
                },
            }
            for item in sorted(subjects)
        ],
    }
    _ = (transport / f"{name}.result").write_text(
        json.dumps([{"verificationResult": {"statement": statement}}])
    )


@pytest.fixture
def helper_packet(
    tmp_path: Path, future_repo: Path, native_transport_mock: Path
) -> tuple[str, ...]:
    args = build_helper_packet(tmp_path, future_repo, "1.1.3")
    dist = tmp_path / "dist"
    mock_bundle(
        dist,
        native_transport_mock,
        BUILD,
        {
            "apple_health_ai_bridge-1.1.3-py3-none-any.whl",
            "apple_health_ai_bridge-1.1.3.tar.gz",
            "release-metadata.json",
        },
    )
    return args


def remote_release(dist: Path, repo: Path, output: Path) -> None:
    _ = output.write_text(
        json.dumps(
            {
                "tag_name": TAG,
                "name": TAG,
                "draft": True,
                "prerelease": False,
                "body": (repo / f".github/release/notes-{TAG}.md").read_text(),
                "assets": [
                    {
                        "name": path.name,
                        "digest": "sha256:"
                        + hashlib.sha256(path.read_bytes()).hexdigest(),
                        "size": path.stat().st_size,
                        "state": "uploaded",
                    }
                    for path in dist.iterdir()
                ],
            }
        )
    )


def test_helper_stage_verifies_three_native_subjects(
    tmp_path: Path, helper_packet: tuple[str, ...]
) -> None:
    result = run_tool("verify-helper", *helper_packet)

    assert result.returncode == 0, result.stderr
    calls = [
        TypeAdapter(list[str]).validate_json(line)
        for line in (tmp_path / "calls.jsonl").read_text().splitlines()
    ]
    assert len(calls) == 3
    for call in calls:
        assert call[:2] == ["attestation", "verify"]
        assert call[call.index("--source-digest") + 1] == "1" * 40
        assert call[call.index("--signer-digest") + 1] == "1" * 40
        assert call[call.index("--source-ref") + 1] == f"refs/tags/{TAG}"
        assert call[call.index("--signer-workflow") + 1] == (
            f"{REPOSITORY}/.github/workflows/release.yml"
        )


def test_prospective_release_rejects_missing_build_proof(
    tmp_path: Path, helper_packet: tuple[str, ...]
) -> None:
    (tmp_path / "dist" / BUILD).unlink()

    result = run_tool("verify-helper", *helper_packet)

    assert result.returncode != 0


@pytest.mark.parametrize("mutation", ["extra", "missing", "symlink", "invalid"])
def test_helper_rejects_bad_packet(
    tmp_path: Path,
    helper_packet: tuple[str, ...],
    mutation: Literal["extra", "missing", "symlink", "invalid"],
) -> None:
    dist = tmp_path / "dist"
    match mutation:
        case "extra":
            _ = (dist / "unexpected").write_bytes(b"extra")
        case "missing":
            (dist / "apple_health_ai_bridge-1.1.3.tar.gz").unlink()
        case "symlink":
            (dist / BUILD).unlink()
            (dist / BUILD).symlink_to(tmp_path / "gh")
        case "invalid":
            _ = (dist / BUILD).write_text("{}")
        case _:
            assert_never(mutation)

    result = run_tool("verify-helper", *helper_packet)

    assert result.returncode != 0


@pytest.mark.parametrize("mutation", ["digest", "name", "duplicate", "empty"])
def test_verified_statement_must_have_exact_subjects(
    tmp_path: Path,
    helper_packet: tuple[str, ...],
    mutation: Literal["digest", "name", "duplicate", "empty"],
) -> None:
    result_file = tmp_path / f"{BUILD}.result"
    payload = TypeAdapter(list[VerificationRecord]).validate_json(
        result_file.read_text()
    )
    subjects = payload[0]["verificationResult"]["statement"]["subject"]
    match mutation:
        case "digest":
            subjects[0]["digest"]["sha256"] = "0" * 64
        case "name":
            subjects[0]["name"] = "wrong"
        case "duplicate":
            subjects.append(subjects[0])
        case "empty":
            payload = []
        case _:
            assert_never(mutation)
    _ = result_file.write_text(json.dumps(payload))

    result = run_tool("verify-helper", *helper_packet)

    assert result.returncode != 0


def test_final_checksums_cover_six_inputs_without_cycles(
    tmp_path: Path,
    helper_packet: tuple[str, ...],
    native_transport_mock: Path,
    future_repo: Path,
) -> None:
    dist = tmp_path / "dist"
    initial_names = {path.name for path in dist.iterdir()}
    checksum = dist / "SHA256SUMS"

    result = run_tool("final-checksums", *helper_packet, "--output", str(checksum))

    assert result.returncode == 0, result.stderr
    assert {
        line.split("  ")[1] for line in checksum.read_text().splitlines()
    } == initial_names
    assert len(initial_names) == 6
    mock_bundle(
        dist,
        native_transport_mock,
        FINAL,
        {
            "HealthBridgeMailboxAckPublisher-1.1.3.zip",
            "HealthBridgeMailboxAckPublisher-1.1.3.manifest.json",
            "SHA256SUMS",
        },
    )
    remote = tmp_path / "release.json"
    remote_release(dist, future_repo, remote)
    verified = run_tool(
        "verify-final-draft",
        *helper_packet,
        "--release-json",
        str(remote),
        "--notes-file",
        str(future_repo / f".github/release/notes-{TAG}.md"),
    )
    assert verified.returncode == 0, verified.stderr
    assert len(list(dist.iterdir())) == 8


@pytest.mark.parametrize("workflow", ["release.yml", "publish-release.yml"])
@pytest.mark.parametrize(
    "wrong",
    [None, "GITHUB_REF", "GITHUB_SHA", "GITHUB_WORKFLOW_REF", "GITHUB_WORKFLOW_SHA"],
)
def test_execution_identity_is_bound_to_tag_source(
    future_repo: Path, monkeypatch: pytest.MonkeyPatch, workflow: str, wrong: str | None
) -> None:
    commit = git_output(future_repo, "rev-parse", "HEAD")
    tree = git_output(future_repo, "rev-parse", "HEAD^{tree}")
    values = {
        "GITHUB_REPOSITORY": REPOSITORY,
        "GITHUB_REF": f"refs/tags/{TAG}",
        "GITHUB_SHA": commit,
        "GITHUB_WORKFLOW_REF": (
            f"{REPOSITORY}/.github/workflows/{workflow}@refs/tags/{TAG}"
        ),
        "GITHUB_WORKFLOW_SHA": commit,
    }
    if wrong:
        values[wrong] = "refs/heads/main" if wrong.endswith("REF") else "0" * 40
    for key, value in values.items():
        monkeypatch.setenv(key, value)

    result = run_tool(
        "verify-execution",
        "--repo",
        str(future_repo),
        "--tag",
        TAG,
        "--commit",
        commit,
        "--tree",
        tree,
        "--workflow",
        workflow,
    )

    assert (result.returncode == 0) is (wrong is None), result.stderr


@pytest.fixture
def final_packet(
    tmp_path: Path, helper_packet: tuple[str, ...], native_transport_mock: Path
) -> tuple[str, ...]:
    dist = tmp_path / "dist"
    result = run_tool(
        "final-checksums", *helper_packet, "--output", str(dist / "SHA256SUMS")
    )
    assert result.returncode == 0, result.stderr
    mock_bundle(
        dist,
        native_transport_mock,
        FINAL,
        {
            "HealthBridgeMailboxAckPublisher-1.1.3.zip",
            "HealthBridgeMailboxAckPublisher-1.1.3.manifest.json",
            "SHA256SUMS",
        },
    )
    return helper_packet


@pytest.mark.parametrize("bundle", [BUILD, FINAL])
def test_native_failure_rejects_final_packet(
    final_packet: tuple[str, ...], monkeypatch: pytest.MonkeyPatch, bundle: str
) -> None:
    monkeypatch.setenv("PROVENANCE_REJECT", bundle)

    result = run_tool("verify-final", *final_packet)

    assert result.returncode == 1
    assert "native provenance verification failed" in result.stderr


@pytest.mark.parametrize("mutation", ["self", "final-proof", "duplicate"])
def test_checksum_rejects_cycles_and_duplicates(
    tmp_path: Path, final_packet: tuple[str, ...], mutation: str
) -> None:
    checksum = tmp_path / "dist/SHA256SUMS"
    line = checksum.read_text().splitlines()[0]
    name = "SHA256SUMS" if mutation == "self" else FINAL
    extra = line if mutation == "duplicate" else f"{'0' * 64}  {name}"
    with checksum.open("a") as handle:
        _ = handle.write(extra + "\n")

    result = run_tool("verify-final", *final_packet)

    assert result.returncode == 1
    assert "checksum manifest" in result.stderr


@pytest.mark.parametrize(
    "mutation", ["missing", "extra", "duplicate", "name", "digest", "size"]
)
@pytest.mark.parametrize("stage", ["helper", "final"])
def test_remote_assets_must_match_downloaded_bytes(
    tmp_path: Path,
    future_repo: Path,
    final_packet: tuple[str, ...],
    mutation: Literal["missing", "extra", "duplicate", "name", "digest", "size"],
    stage: str,
) -> None:
    dist = tmp_path / "dist"
    if stage == "helper":
        (dist / FINAL).unlink()
        (dist / "SHA256SUMS").unlink()
    remote = tmp_path / "release.json"
    remote_release(dist, future_repo, remote)
    payload = TypeAdapter(ReleaseRecord).validate_json(remote.read_text())
    assets = payload["assets"]
    match mutation:
        case "missing":
            _ = assets.pop()
        case "extra":
            assets.append({**assets[0], "name": "unexpected"})
        case "duplicate":
            assets.append(assets[0])
        case "name":
            assets[0]["name"] = "wrong"
        case "digest":
            assets[0]["digest"] = f"sha256:{'0' * 64}"
        case "size":
            assets[0]["size"] += 1
        case _:
            assert_never(mutation)
    _ = remote.write_text(json.dumps(payload))

    result = run_tool(
        f"verify-{stage}-draft",
        *final_packet,
        "--release-json",
        str(remote),
        "--notes-file",
        str(future_repo / f".github/release/notes-{TAG}.md"),
    )

    assert result.returncode == 1
    assert "GitHub release" in result.stderr or "remote asset" in result.stderr


def workflow_run(name: str) -> str:
    text = (ROOT / ".github/workflows/publish-release.yml").read_text()
    step = text.split(f"      - name: {name}\n", 1)[1].split("\n      - name:", 1)[0]
    lines = step.split("        run: |\n", 1)[1].splitlines()
    return "\n".join(line.removeprefix("          ") for line in lines)


@pytest.mark.parametrize("bundle", [BUILD, FINAL])
def test_workflow_proof_failure_prevents_publish(
    tmp_path: Path,
    future_repo: Path,
    final_packet: tuple[str, ...],
    monkeypatch: pytest.MonkeyPatch,
    bundle: str,
) -> None:
    remote = tmp_path / "release.json"
    (future_repo / "dist").symlink_to(tmp_path / "dist", target_is_directory=True)
    remote_release(tmp_path / "dist", future_repo, remote)
    uv = tmp_path / "uv"
    _ = uv.write_text(
        f"""#!{sys.executable}
import subprocess, sys
sys.exit(subprocess.call([sys.executable, {str(TOOL)!r}, *sys.argv[4:]]))
"""
    )
    uv.chmod(0o700)
    values = {
        "PROVENANCE_REJECT": bundle,
        "PROVENANCE_RELEASE_JSON": str(remote),
        "PROVENANCE_DIST": str(tmp_path / "dist"),
        "RUNNER_TEMP": str(tmp_path),
        "GITHUB_REPOSITORY": REPOSITORY,
        "DRAFT_RELEASE_ID": "17",
        "RELEASE_TAG": TAG,
        "PINNED_TAG_OBJECT_SHA": "3" * 40,
        "PINNED_TARGET_COMMIT_SHA": "1" * 40,
        "PINNED_TREE_SHA": "2" * 40,
        "EXPECTED_HELPER_SHA256": final_packet[
            final_packet.index("--helper-sha256") + 1
        ],
        "EXPECTED_HELPER_MANIFEST_SHA256": final_packet[-1],
    }
    for key, value in values.items():
        monkeypatch.setenv(key, value)
    (tmp_path / "calls.jsonl").unlink()

    result = subprocess.run(
        ["bash", "-c", workflow_run("Reverify exact draft and publish once")],
        cwd=future_repo,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode != 0
    assert "native provenance verification failed" in result.stderr
    calls = [
        TypeAdapter(list[str]).validate_json(line)
        for line in (tmp_path / "calls.jsonl").read_text().splitlines()
    ]
    assert all(call[:2] != ["release", "edit"] for call in calls)


@pytest.mark.parametrize("version", ["1.1.1", "1.1.2"])
def test_legacy_helper_contract_requires_no_new_proof(
    tmp_path: Path, receiver_release_repo: Path, version: str
) -> None:
    write_release_tree(
        receiver_release_repo,
        ReleaseTree(
            version, f"receiver-v{version}", "receiver", "1.1.0", "39", "1.0.0"
        ),
    )
    _ = commit_release_tree(receiver_release_repo, "synthetic historical release")
    args = build_helper_packet(tmp_path, receiver_release_repo, version)

    result = run_tool("verify-helper", *args)

    assert result.returncode == 0, result.stderr
    assert len(list((tmp_path / "dist").iterdir())) == 5


@pytest.mark.parametrize(
    "mutation", ["none", "missing", "extra", "duplicate", "digest", "size", "symlink"]
)
def test_core_draft_requires_exact_four_assets(
    tmp_path: Path,
    future_repo: Path,
    helper_packet: tuple[str, ...],
    mutation: Literal[
        "none", "missing", "extra", "duplicate", "digest", "size", "symlink"
    ],
) -> None:
    dist = tmp_path / "dist"
    for path in dist.glob("HealthBridgeMailboxAckPublisher-*"):
        path.unlink()
    remote = tmp_path / "release.json"
    remote_release(dist, future_repo, remote)
    payload = TypeAdapter(ReleaseRecord).validate_json(remote.read_text())
    match mutation:
        case "none":
            assert len(payload["assets"]) == 4
        case "missing":
            (dist / BUILD).unlink()
        case "extra":
            _ = (dist / "unexpected").write_text("synthetic")
        case "duplicate":
            payload["assets"].append(payload["assets"][0])
        case "digest":
            payload["assets"][0]["digest"] = f"sha256:{'0' * 64}"
        case "size":
            payload["assets"][0]["size"] += 1
        case "symlink":
            (dist / BUILD).unlink()
            (dist / BUILD).symlink_to(tmp_path / "gh")
        case _:
            assert_never(mutation)
    _ = remote.write_text(json.dumps(payload))
    args = helper_packet[: helper_packet.index("--helper-sha256")]

    result = run_tool(
        "verify-core-draft",
        *args,
        "--release-json",
        str(remote),
        "--notes-file",
        str(future_repo / f".github/release/notes-{TAG}.md"),
    )

    assert (result.returncode == 0) is (mutation == "none"), result.stderr


@pytest.mark.parametrize("mutation", ["missing", "symlink", "invalid", "extra"])
def test_final_bundle_is_required_and_independently_verified(
    tmp_path: Path,
    final_packet: tuple[str, ...],
    mutation: Literal["missing", "symlink", "invalid", "extra"],
) -> None:
    dist = tmp_path / "dist"
    match mutation:
        case "missing":
            (dist / FINAL).unlink()
        case "symlink":
            (dist / FINAL).unlink()
            (dist / FINAL).symlink_to(dist / BUILD)
        case "invalid":
            _ = (dist / FINAL).write_text("{}")
        case "extra":
            _ = (dist / "unexpected").write_text("synthetic")
        case _:
            assert_never(mutation)

    result = run_tool("verify-final", *final_packet)

    assert result.returncode == 1


def test_checksum_output_cannot_overwrite_an_input(
    tmp_path: Path, helper_packet: tuple[str, ...]
) -> None:
    bundle = tmp_path / "dist" / BUILD
    before = bundle.read_bytes()

    result = run_tool("final-checksums", *helper_packet, "--output", str(bundle))

    assert result.returncode == 1
    assert bundle.read_bytes() == before
