from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Literal, assert_never

import pytest
from pydantic import JsonValue, TypeAdapter
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
DOCUMENTED_TAG = "receiver-v1.2.0"


def run_documented_proof(
    tmp_path: Path,
    *,
    failed_gh: int = 0,
    failed_checksum: bool = False,
    missing: Literal["tag", "commit"] | None = None,
    empty: bool = False,
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    """Exercise the actual docs in Bash; stubs test control flow, not signatures."""
    document = (ROOT / "docs/icloud-mailbox-service.md").read_text(encoding="utf-8")
    section = document.split("## Verify published release provenance\n", 1)[1]
    snippet = section.split("```bash\n", 1)[1].split("\n```", 1)[0]
    controls = tmp_path / "shell-controls"
    controls.mkdir()
    calls = tmp_path / "shell-calls.txt"
    stub = f"""#!{sys.executable}
import json
import os
import pathlib
import sys

command = pathlib.Path(sys.argv[0]).name
calls = pathlib.Path(os.environ['DOC_PROOF_CALLS'])
previous = calls.read_text().splitlines() if calls.exists() else []
with calls.open('a') as stream:
    stream.write(command + '\\n')
if command == 'gh':
    with calls.with_name('shell-attestation-argv.jsonl').open('a') as stream:
        stream.write(json.dumps(sys.argv[1:]) + '\\n')
with calls.with_suffix('.jsonl').open('a') as stream:
    stream.write(json.dumps([command, *sys.argv[1:]]) + '\\n')
if command == 'gh' and previous.count('gh') + 1 == int(os.environ['DOC_PROOF_FAIL_GH']):
    sys.exit(17)
if command == 'shasum' and os.environ['DOC_PROOF_FAIL_CHECKSUM'] == '1':
    sys.exit(23)
"""
    for name in ("gh", "shasum"):
        tool = controls / name
        _ = tool.write_text(stub, encoding="utf-8")
        tool.chmod(0o700)
    environment = os.environ.copy()
    environment.update(
        PATH=f"{controls}{os.pathsep}{os.environ['PATH']}",
        DOC_PROOF_CALLS=str(calls),
        DOC_PROOF_FAIL_GH=str(failed_gh),
        DOC_PROOF_FAIL_CHECKSUM="1" if failed_checksum else "0",
    )
    input_control = ":"
    if missing is not None:
        input_control = f"{missing}=''" if empty else f"unset {missing}"
    script = "\n".join(
        [
            "set +e +u",
            "set +o pipefail",
            f"tag={DOCUMENTED_TAG}",
            "commit=" + "1" * 40,
            input_control,
            'verification_flags_before="$-"',
            'verification_options_before="$(set +o)"',
            snippet,
            "verification_block_status=$?",
            'verification_options_after="$(set +o)"',
            str.join(
                "",
                (
                    'if [[ "$verification_flags_before" = "$-" && ',
                    '"$verification_options_before" = ',
                    '"$verification_options_after" ]]; then',
                ),
            ),
            "  verification_options_preserved=yes",
            "else",
            "  verification_options_preserved=no",
            "fi",
            str.join(
                "",
                (
                    "printf '\\nVERIFICATION_PARENT %s %s\\n' ",
                    '"$verification_block_status" "$verification_options_preserved"',
                ),
            ),
        ]
    )
    completed = subprocess.run(
        ["bash", "--noprofile", "--norc"],
        input=script,
        cwd=tmp_path,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    recorded_calls = calls.read_text().splitlines() if calls.exists() else []
    return completed, recorded_calls


@pytest.mark.parametrize("failed_gh", [0, 1])
def test_documented_proof_preserves_parent_shell(
    tmp_path: Path, failed_gh: int
) -> None:
    completed, _ = run_documented_proof(tmp_path, failed_gh=failed_gh)
    assert completed.returncode == 0, completed.stderr
    marker = next(
        line
        for line in completed.stdout.splitlines()
        if line.startswith("VERIFICATION_PARENT ")
    )
    assert marker.endswith(" yes"), marker


def test_documented_proof_selects_build_and_publication_source_refs(
    tmp_path: Path,
) -> None:
    completed, _ = run_documented_proof(tmp_path)
    assert completed.returncode == 0, completed.stderr
    assert "VERIFICATION_PARENT 0 yes" in completed.stdout
    calls = [
        TypeAdapter(list[str]).validate_json(line)
        for line in (tmp_path / "shell-attestation-argv.jsonl").read_text().splitlines()
    ]
    assert len(calls) == 6
    assert [call[call.index("--bundle") + 1] for call in calls] == [BUILD] * 3 + [
        FINAL
    ] * 3
    for index, call in enumerate(calls):
        expected_ref = (
            "refs/heads/release" if index < 3 else f"refs/tags/{DOCUMENTED_TAG}"
        )
        assert call[call.index("--source-ref") + 1] == expected_ref
        assert call[call.index("--source-digest") + 1] == "1" * 40
        assert call[call.index("--signer-digest") + 1] == "1" * 40


def test_documented_proof_reports_success(tmp_path: Path) -> None:
    completed, calls = run_documented_proof(tmp_path)
    assert completed.returncode == 0, completed.stderr
    assert "VERIFICATION_PARENT 0 yes" in completed.stdout
    assert "Release proof verified." in completed.stdout
    assert "Release proof FAILED." not in completed.stdout + completed.stderr
    assert calls == ["gh"] * 6 + ["shasum"]
    arguments = [
        TypeAdapter(list[str]).validate_json(line)
        for line in (tmp_path / "shell-calls.jsonl").read_text().splitlines()
    ]
    documented_version = DOCUMENTED_TAG.removeprefix("receiver-v")
    core = [
        f"apple_health_ai_bridge-{documented_version}-py3-none-any.whl",
        f"apple_health_ai_bridge-{documented_version}.tar.gz",
        "release-metadata.json",
    ]
    final = [
        f"HealthBridgeMailboxAckPublisher-{documented_version}.zip",
        f"HealthBridgeMailboxAckPublisher-{documented_version}.manifest.json",
        "SHA256SUMS",
    ]
    for actual, subject in zip(arguments[:6], core + final, strict=True):
        is_core = subject in core
        workflow = "release.yml" if is_core else "publish-release.yml"
        source_ref = "refs/heads/release" if is_core else f"refs/tags/{DOCUMENTED_TAG}"
        assert actual == [
            "gh",
            "attestation",
            "verify",
            subject,
            "--repo",
            REPOSITORY,
            "--bundle",
            BUILD if is_core else FINAL,
            "--signer-workflow",
            f"{REPOSITORY}/.github/workflows/{workflow}",
            "--source-ref",
            source_ref,
            "--source-digest",
            "1" * 40,
            "--signer-digest",
            "1" * 40,
            "--deny-self-hosted-runners",
            "--predicate-type",
            "https://slsa.dev/provenance/v1",
        ]
    assert arguments[6] == ["shasum", "-a", "256", "-c", "SHA256SUMS"]


@pytest.mark.parametrize("failed_gh", [1, 3, 4, 6])
def test_documented_proof_stops_after_rejected_subject(
    tmp_path: Path, failed_gh: int
) -> None:
    completed, calls = run_documented_proof(tmp_path, failed_gh=failed_gh)
    assert completed.returncode == 0, completed.stderr
    assert "VERIFICATION_PARENT 17 yes" in completed.stdout
    assert "Release proof FAILED." in completed.stderr
    assert "Release proof verified." not in completed.stdout
    assert calls == ["gh"] * failed_gh


def test_documented_proof_reports_checksum_failure(tmp_path: Path) -> None:
    completed, calls = run_documented_proof(tmp_path, failed_checksum=True)
    assert completed.returncode == 0, completed.stderr
    assert "VERIFICATION_PARENT 23 yes" in completed.stdout
    assert "Release proof FAILED." in completed.stderr
    assert "Release proof verified." not in completed.stdout
    assert calls == ["gh"] * 6 + ["shasum"]


@pytest.mark.parametrize("empty", [False, True], ids=["unset", "empty"])
@pytest.mark.parametrize("missing", ["tag", "commit"])
def test_documented_proof_reports_missing_input(
    tmp_path: Path, missing: Literal["tag", "commit"], empty: bool
) -> None:
    completed, calls = run_documented_proof(tmp_path, missing=missing, empty=empty)
    assert completed.returncode == 0, completed.stderr
    assert "VERIFICATION_PARENT 1 yes" in completed.stdout
    assert "Release proof FAILED." in completed.stderr
    assert "Release proof verified." not in completed.stdout
    assert calls == []


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
    elif '/releases/assets/' in endpoint:
        record_path = pathlib.Path(os.environ['PROVENANCE_RELEASE_JSON'])
        release = json.loads(record_path.read_text())
        asset = next(item for item in release['assets']
                     if item['id'] == int(endpoint.rsplit('/', 1)[1]))
        root_dist = pathlib.Path(os.environ['PROVENANCE_DIST'])
        sys.stdout.buffer.write((root_dist / asset['name']).read_bytes())
        sys.exit(0)
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


def remote_release(
    dist: Path,
    repo: Path,
    output: Path,
    *,
    tag: str = TAG,
    title: str | None = None,
) -> None:
    _ = output.write_text(
        json.dumps(
            {
                "tag_name": tag,
                "name": title if title is not None else tag,
                "draft": True,
                "prerelease": False,
                "body": (repo / f".github/release/notes-{tag}.md").read_text(),
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


@pytest.fixture
def published_artifact_packet(
    tmp_path: Path, receiver_release_repo: Path, native_transport_mock: Path
) -> tuple[str, ...]:
    """Build the current eight-asset shape with synthetic native transport."""
    tag = "receiver-v1.2.0"
    write_release_tree(
        receiver_release_repo,
        ReleaseTree("1.2.0", tag, "coordinated", "1.2.0", "51", "1.0.0"),
    )
    _ = commit_release_tree(receiver_release_repo, "synthetic published audit")
    args = build_helper_packet(tmp_path, receiver_release_repo, "1.2.0")
    dist = tmp_path / "dist"
    mock_bundle(
        dist,
        native_transport_mock,
        BUILD,
        {
            "apple_health_ai_bridge-1.2.0-py3-none-any.whl",
            "apple_health_ai_bridge-1.2.0.tar.gz",
            "release-metadata.json",
        },
    )
    result = run_tool("final-checksums", *args, "--output", str(dist / "SHA256SUMS"))
    assert result.returncode == 0, result.stderr
    mock_bundle(
        dist,
        native_transport_mock,
        FINAL,
        {
            "HealthBridgeMailboxAckPublisher-1.2.0.zip",
            "HealthBridgeMailboxAckPublisher-1.2.0.manifest.json",
            "SHA256SUMS",
        },
    )
    remote = tmp_path / "release.json"
    remote_release(
        dist, receiver_release_repo, remote, tag=tag, title="Receiver/CLI 1.2.0"
    )
    payload = TypeAdapter(ReleaseRecord).validate_json(remote.read_bytes())
    payload["draft"] = False
    _ = remote.write_text(json.dumps(payload))
    return (
        *args,
        "--release-json",
        str(remote),
        "--notes-file",
        str(receiver_release_repo / f".github/release/notes-{tag}.md"),
    )


@pytest.mark.parametrize("audit", [False, True], ids=["strict", "explicit"])
@pytest.mark.parametrize("drift", ["none", "title", "body", "whitespace", "table"])
def test_published_artifact_audit_accepts_only_explicit_prose_drift(
    tmp_path: Path,
    published_artifact_packet: tuple[str, ...],
    audit: bool,
    drift: Literal["none", "title", "body", "whitespace", "table"],
) -> None:
    # Given a current final packet and independently supplied source inputs.
    remote = tmp_path / "release.json"
    payload = TypeAdapter(ReleaseRecord).validate_json(remote.read_bytes())
    match drift:
        case "none":
            pass
        case "title":
            payload["name"] = "Updated published title"
        case "body":
            payload["body"] = "Updated published notes"
        case "whitespace":
            payload["body"] = " " + payload["body"] + "\n"
        case "table":
            payload["body"] += (
                "\n| Component | Version |\n| --- | --- |\n| CLI | 1.2.0 |\n"
            )
        case _:
            assert_never(drift)
    _ = remote.write_text(json.dumps(payload))
    dist = tmp_path / "dist"
    before = {path.name: path.read_bytes() for path in dist.iterdir()}
    assert len(before) == 8
    assert len((dist / "SHA256SUMS").read_text().splitlines()) == 6
    calls_file = tmp_path / "calls.jsonl"
    _ = calls_file.write_text("")

    # When the real CLI verifies the snapshot.
    result = run_tool(
        "verify-final-published",
        *published_artifact_packet,
        *(("--published-artifacts-only",) if audit else ()),
    )

    # Then only explicit audit accepts drift, without writes or proof signing.
    assert result.returncode == (0 if audit or drift == "none" else 1), result.stderr
    assert {path.name: path.read_bytes() for path in dist.iterdir()} == before
    assert TypeAdapter(ReleaseRecord).validate_json(remote.read_bytes()) == payload
    calls = [
        TypeAdapter(list[str]).validate_json(line)
        for line in calls_file.read_text().splitlines()
    ]
    assert all(call[:2] == ["attestation", "verify"] for call in calls)
    if result.returncode == 0:
        assert len(calls) == 6


@pytest.mark.parametrize(
    ("mutation", "error"),
    [
        ("tag", "release metadata"),
        ("draft", "release metadata"),
        ("prerelease", "release metadata"),
        ("missing", "file set"),
        ("extra", "file set"),
        ("duplicate", "invalid asset"),
        ("state", "not ready"),
        ("size", "remote asset digest"),
        ("digest", "remote asset digest"),
    ],
)
def test_published_artifact_audit_preserves_integrity_rejections(
    tmp_path: Path,
    published_artifact_packet: tuple[str, ...],
    mutation: Literal[
        "tag",
        "draft",
        "prerelease",
        "missing",
        "extra",
        "duplicate",
        "state",
        "size",
        "digest",
    ],
    error: str,
) -> None:
    # Given prose drift plus a distinct integrity violation.
    remote = tmp_path / "release.json"
    payload = TypeAdapter(ReleaseRecord).validate_json(remote.read_bytes())
    payload["name"] = "Updated title"
    payload["body"] = "Updated notes"
    match mutation:
        case "tag":
            payload["tag_name"] = TAG
        case "draft":
            payload["draft"] = True
        case "prerelease":
            payload["prerelease"] = True
        case "missing":
            _ = payload["assets"].pop()
        case "extra":
            payload["assets"].append({**payload["assets"][0], "name": "extra"})
        case "duplicate":
            payload["assets"].append(payload["assets"][0])
        case "state":
            payload["assets"][0]["state"] = "new"
        case "size":
            payload["assets"][0]["size"] += 1
        case "digest":
            payload["assets"][0]["digest"] = "sha256:" + "0" * 64
        case _:
            assert_never(mutation)
    _ = remote.write_text(json.dumps(payload))
    _ = (tmp_path / "calls.jsonl").write_text("")

    # When audit mode runs, it must reach the original integrity check.
    result = run_tool(
        "verify-final-published",
        *published_artifact_packet,
        "--published-artifacts-only",
    )

    # Then the corruption, not a parser/prose failure, rejects the packet.
    assert result.returncode == 1, result.stderr
    assert error in result.stderr
    calls = [
        TypeAdapter(list[str]).validate_json(line)
        for line in (tmp_path / "calls.jsonl").read_text().splitlines()
    ]
    assert all(call[:2] == ["attestation", "verify"] for call in calls)


@pytest.mark.parametrize("mutation", ["commit", "tag_object", "tree", "scope", "ios"])
def test_published_artifact_audit_keeps_exact_metadata(
    tmp_path: Path,
    published_artifact_packet: tuple[str, ...],
    mutation: Literal["commit", "tag_object", "tree", "scope", "ios"],
) -> None:
    # Given inconsistent metadata in a current published packet.
    metadata = tmp_path / "dist/release-metadata.json"
    record = TypeAdapter(dict[str, JsonValue]).validate_json(metadata.read_bytes())
    match mutation:
        case "commit" | "tag_object" | "tree":
            identity = record["git"]
            assert isinstance(identity, dict)
            identity[mutation] = "0" * 40
        case "scope":
            record["release_scope"] = "receiver"
        case "ios":
            ios = record["ios"]
            assert isinstance(ios, dict)
            ios["build"] = "99"
        case _:
            assert_never(mutation)
    _ = metadata.write_text(json.dumps(record))

    # When the actual CLI audits the packet, then metadata remains exact.
    result = run_tool(
        "verify-final-published",
        *published_artifact_packet,
        "--published-artifacts-only",
    )

    assert result.returncode == 1, result.stderr
    assert "release metadata version, scope, source, or compatibility" in result.stderr


@pytest.mark.parametrize(
    ("mutation", "error"),
    [
        ("helper", "signed mailbox helper digest"),
        ("manifest", "helper manifest digest"),
        ("core-proof", "native provenance"),
        ("final-proof", "native provenance"),
        ("missing-core", "file set"),
        ("missing-final", "file set"),
        ("checksum", "checksum manifest"),
        ("source-notes", "compatible Batch Protocol"),
    ],
)
def test_published_artifact_audit_keeps_packet_and_frozen_source(
    tmp_path: Path,
    published_artifact_packet: tuple[str, ...],
    monkeypatch: pytest.MonkeyPatch,
    mutation: Literal[
        "helper",
        "manifest",
        "core-proof",
        "final-proof",
        "missing-core",
        "missing-final",
        "checksum",
        "source-notes",
    ],
    error: str,
) -> None:
    # Given corruption in the packet or its independently supplied inputs.
    args = list(published_artifact_packet)
    match mutation:
        case "helper" | "manifest":
            flag = (
                "--helper-sha256"
                if mutation == "helper"
                else "--helper-manifest-sha256"
            )
            args[args.index(flag) + 1] = "0" * 64
        case "core-proof" | "final-proof":
            monkeypatch.setenv(
                "PROVENANCE_REJECT", BUILD if mutation == "core-proof" else FINAL
            )
        case "missing-core" | "missing-final":
            (
                tmp_path / "dist" / (BUILD if mutation == "missing-core" else FINAL)
            ).unlink()
        case "checksum":
            with (tmp_path / "dist/SHA256SUMS").open("a") as stream:
                _ = stream.write("0" * 64 + "  SHA256SUMS\n")
        case "source-notes":
            notes = Path(args[args.index("--notes-file") + 1])
            _ = notes.write_text(
                "\n".join(
                    line
                    for line in notes.read_text().splitlines()
                    if not line.startswith("Compatible Batch Protocol:")
                )
            )
        case _:
            assert_never(mutation)
    _ = (tmp_path / "calls.jsonl").write_text("")

    # When audit mode runs, it must reach the original integrity check.
    result = run_tool("verify-final-published", *args, "--published-artifacts-only")

    # Then the corruption, not a parser/prose failure, rejects the packet.
    assert result.returncode == 1, result.stderr
    assert error in result.stderr
    calls = [
        TypeAdapter(list[str]).validate_json(line)
        for line in (tmp_path / "calls.jsonl").read_text().splitlines()
    ]
    assert all(call[:2] == ["attestation", "verify"] for call in calls)


@pytest.mark.parametrize(
    "command",
    [
        "verify-draft",
        "verify-core-draft",
        "verify-helper-draft",
        "verify-final-draft",
        "verify-final",
        "verify-helper",
        "verify-packet",
        "verify-core",
        "final-checksums",
        "checksums",
        "manifest",
        "validate",
        "verify-execution",
        "tag-info",
    ],
)
def test_published_artifact_flag_rejected_by_unsupported_cli(
    tmp_path: Path, published_artifact_packet: tuple[str, ...], command: str
) -> None:
    # Given an unsupported command, when the actual CLI receives the flag.
    result = run_tool(command, "--published-artifacts-only", "--help")

    # Then argparse help must not advertise the unsupported option.
    assert result.returncode == 0, result.stderr
    assert "--published-artifacts-only" not in result.stdout
    args = list(published_artifact_packet)
    if command not in {"verify-helper-draft", "verify-final-draft"}:
        del args[args.index("--release-json") :]
    if command in {
        "verify-draft",
        "verify-core-draft",
        "verify-packet",
        "verify-core",
        "checksums",
        "manifest",
        "validate",
        "verify-execution",
        "tag-info",
    }:
        position = args.index("--helper-sha256")
        del args[position : position + 4]
    if command in {"validate", "verify-execution", "tag-info"}:
        position = args.index("--dist-dir")
        del args[position : position + 2]
    if command in {"validate", "tag-info"}:
        del args[args.index("--tag-object") :]
    if command == "tag-info":
        del args[:2]
    if command in {"verify-draft", "verify-core-draft"}:
        args.extend(published_artifact_packet[-4:])
    if command in {"checksums", "manifest", "final-checksums"}:
        args.extend(("--output", str(tmp_path / "output")))
    if command == "verify-execution":
        position = args.index("--tag-object")
        del args[position : position + 2]
        args.extend(("--workflow", "release.yml"))
    rejected = run_tool(command, *args, "--published-artifacts-only")
    assert rejected.returncode == 2
    assert "unrecognized arguments: --published-artifacts-only" in rejected.stderr


@pytest.mark.parametrize("command", ["verify-published", "verify-final-published"])
def test_published_artifact_cli_help_advertises_explicit_mode(command: str) -> None:
    result = run_tool(command, "--help")

    assert result.returncode == 0, result.stderr
    assert "--published-artifacts-only" in result.stdout


@pytest.mark.parametrize("verifier", ["legacy", "final", "helper"])
def test_published_artifact_direct_draft_bypass_rejected(
    tmp_path: Path, published_artifact_packet: tuple[str, ...], verifier: str
) -> None:
    # Given valid inputs, bypassing argparse must not weaken draft verification.
    args = published_artifact_packet
    runner = tmp_path / "direct.py"
    _ = runner.write_text(f"""import sys
from pathlib import Path
sys.path.insert(0, {str(ROOT / "scripts")!r})
from release_tools import (
    DraftVerificationRequest, FinalReleaseVerificationRequest,
    verify_release_state, verify_final_release_state,
)
args = {args!r}
def value(flag): return args[args.index(flag) + 1]
request = DraftVerificationRequest(
    Path(value("--repo")), Path(value("--dist-dir")), Path(value("--release-json")),
    Path(value("--notes-file")), value("--tag"), value("--tag-object"),
    value("--commit"), value("--tree"),
)
if {verifier!r} == "legacy":
    verify_release_state(request, expected_draft=True, published_artifacts_only=True)
else:
    verify_final_release_state(
        FinalReleaseVerificationRequest(
            request, value("--helper-sha256"), value("--helper-manifest-sha256"),
        ), expected_draft={verifier != "helper"!r},
        final={verifier != "helper"!r}, published_artifacts_only=True,
    )
""")

    # When a direct caller requests the published-only purpose for drafts.
    result = subprocess.run(
        [sys.executable, str(runner)], capture_output=True, text=True, check=False
    )

    # Then reject explicitly rather than silently falling back or bypassing.
    assert result.returncode == 1
    assert (
        "published artifact audit requires a final release packet"
        if verifier == "helper"
        else "published artifact audit requires a published release"
    ) in result.stderr


@pytest.mark.parametrize("audit", [False, True], ids=["strict", "explicit"])
@pytest.mark.parametrize("corrupt", [False, True], ids=["intact", "bad-digest"])
def test_published_artifact_legacy_verifier_keeps_remote_checks(
    tmp_path: Path, receiver_release_repo: Path, audit: bool, corrupt: bool
) -> None:
    # Given the legacy four-asset shape with edited hosted prose.
    args = build_helper_packet(tmp_path, receiver_release_repo)
    args = args[: args.index("--helper-sha256")]
    dist = tmp_path / "dist"
    for path in dist.glob("HealthBridgeMailboxAckPublisher-*"):
        path.unlink()
    _ = (dist / "SHA256SUMS").write_text("legacy checksum fixture\n")
    remote = tmp_path / "release.json"
    remote_release(dist, receiver_release_repo, remote, tag="receiver-v1.1.1")
    payload = TypeAdapter(ReleaseRecord).validate_json(remote.read_bytes())
    payload["draft"] = False
    payload["name"] = "Edited title"
    payload["body"] = "Edited notes"
    if corrupt:
        payload["assets"][0]["digest"] = "sha256:" + "0" * 64
    _ = remote.write_text(json.dumps(payload))

    # When the published legacy command receives an explicit audit purpose.
    result = run_tool(
        "verify-published",
        *args,
        "--release-json",
        str(remote),
        "--notes-file",
        str(receiver_release_repo / ".github/release/notes-receiver-v1.1.1.md"),
        *(("--published-artifacts-only",) if audit else ()),
    )

    # Then title/body drift is optional, but digest checks remain mandatory.
    assert result.returncode == (0 if audit and not corrupt else 1), result.stderr
    if audit and corrupt:
        assert "remote asset digest mismatch" in result.stderr


@pytest.mark.parametrize(
    "flag",
    [
        "--repo",
        "--tag",
        "--tag-object",
        "--commit",
        "--tree",
        "--helper-sha256",
        "--helper-manifest-sha256",
        "--notes-file",
    ],
)
def test_published_artifact_audit_requires_frozen_source_inputs(
    published_artifact_packet: tuple[str, ...], flag: str
) -> None:
    # Given one omitted input, when the actual audit CLI parses the request.
    args = list(published_artifact_packet)
    position = args.index(flag)
    del args[position : position + 2]
    result = run_tool("verify-final-published", *args, "--published-artifacts-only")

    # Then artifact audit does not invent defaults from downloaded metadata.
    assert result.returncode == 2
    assert flag in result.stderr


@pytest.mark.parametrize(
    "title_case",
    [
        ("1.1.3", "receiver-v1.1.3", "Receiver/CLI 1.1.3"),
        ("1.1.4", "Receiver/CLI 1.1.4", "receiver-v1.1.4"),
    ],
)
@pytest.mark.parametrize(
    "scenario",
    [
        (command, mutation)
        for command in (
            "verify-core-draft",
            "verify-helper-draft",
            "verify-final-draft",
            "verify-final-published",
        )
        for mutation in ("none", "other-title", "arbitrary-title", "body")
    ],
)
def test_release_stages_require_exact_title_and_source_body(
    tmp_path: Path,
    receiver_release_repo: Path,
    native_transport_mock: Path,
    title_case: tuple[str, str, str],
    scenario: tuple[str, Literal["none", "other-title", "arbitrary-title", "body"]],
) -> None:
    version, title, other_title = title_case
    command, mutation = scenario
    tag = f"receiver-v{version}"
    write_release_tree(
        receiver_release_repo,
        ReleaseTree(version, tag, "receiver", "1.1.0", "39", "1.0.0"),
    )
    _ = commit_release_tree(receiver_release_repo, "synthetic release title boundary")
    args = build_helper_packet(tmp_path, receiver_release_repo, version)
    dist = tmp_path / "dist"
    mock_bundle(
        dist,
        native_transport_mock,
        BUILD,
        {
            f"apple_health_ai_bridge-{version}-py3-none-any.whl",
            f"apple_health_ai_bridge-{version}.tar.gz",
            "release-metadata.json",
        },
    )
    if command == "verify-core-draft":
        for path in dist.glob("HealthBridgeMailboxAckPublisher-*"):
            path.unlink()
        args = args[: args.index("--helper-sha256")]
    elif command in {"verify-final-draft", "verify-final-published"}:
        checksum = run_tool(
            "final-checksums", *args, "--output", str(dist / "SHA256SUMS")
        )
        assert checksum.returncode == 0, checksum.stderr
        mock_bundle(
            dist,
            native_transport_mock,
            FINAL,
            {
                f"HealthBridgeMailboxAckPublisher-{version}.zip",
                f"HealthBridgeMailboxAckPublisher-{version}.manifest.json",
                "SHA256SUMS",
            },
        )
    remote = tmp_path / "release.json"
    remote_release(dist, receiver_release_repo, remote, tag=tag, title=title)
    payload = TypeAdapter(ReleaseRecord).validate_json(remote.read_text())
    payload["draft"] = command != "verify-final-published"
    match mutation:
        case "none":
            pass
        case "other-title":
            payload["name"] = other_title
        case "arbitrary-title":
            payload["name"] = "Untrusted release title"
        case "body":
            payload["body"] += "\n"
        case _:
            assert_never(mutation)
    _ = remote.write_text(json.dumps(payload))

    result = run_tool(
        command,
        *args,
        "--release-json",
        str(remote),
        "--notes-file",
        str(receiver_release_repo / f".github/release/notes-{tag}.md"),
    )

    assert (result.returncode == 0) is (mutation == "none"), result.stderr
    if mutation == "body":
        assert "release body does not match exact notes" in result.stderr
    elif mutation != "none":
        assert "release metadata is not exact" in result.stderr


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


def publication_runner(tmp_path: Path) -> Path:
    runner = tmp_path / "synthetic-publication.py"
    _ = runner.write_text(f"""import sys
from pathlib import Path
import os
from pydantic import TypeAdapter
sys.path.insert(0, {str(ROOT / "scripts")!r})
import release_publication as publication
import release_publication_inputs as qualification
from release_authority import Baseline, SourceReceipt
from release_reconciliation import RemoteRelease
from release_candidate_model import CandidateIdentity, CandidateRecord, artifact_record
repo, dist = Path(sys.argv[1]), Path(sys.argv[2])
identity = CandidateIdentity(
    tag={TAG!r}, tag_object="3"*40, commit="1"*40, tree="2"*40, helper_tree="4"*40,
)
baseline = Baseline(
    tag="receiver-v1.1.2", tag_object="5"*40, commit="6"*40, release_id=2,
)
source = SourceReceipt(
    default_main_commit="7"*40, baseline_commit=baseline.commit,
    source_commit=identity.commit, source_tree=identity.tree,
    source_tag=identity.tag, tag_object=identity.tag_object,
    baseline=baseline, pull_request=1, reviewed_head="8"*40, check_runs=dict(check=1),
)
artifacts = [
    artifact_record(path) for path in dist.iterdir()
    if path.name.endswith((".whl", ".tar.gz"))
    or path.name in ("release-metadata.json", {BUILD!r})
]
record = CandidateRecord(
    identity=identity, source=source, run_id=1, run_attempt=1, artifacts=artifacts,
)
record_path = dist.parent / "candidate.json"
record_path.write_text(record.model_dump_json())
qualification.verify_candidate = lambda *args, **kwargs: None
qualification.verify_candidate_artifact_receipt = lambda *args: None
qualification.verify_execution = lambda *args: None
snapshot = os.environ.get("SYNTHETIC_PUBLICATION_SNAPSHOT")
releases = (
    [RemoteRelease.model_validate_json(Path(snapshot).read_bytes())]
    if snapshot else []
)
publication.snapshot = lambda *args: releases
request = publication.PublicationRequest(
    repo, dist, record_path, 1, sys.argv[3], sys.argv[4],
    sys.argv[5] if len(sys.argv) > 5 else "publish",
)
print(publication.continue_publication(request).model_dump_json())
""")
    return runner


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
    monkeypatch.setenv("PROVENANCE_REJECT", bundle)
    runner = publication_runner(tmp_path)
    result = subprocess.run(
        [
            sys.executable,
            str(runner),
            str(future_repo),
            str(tmp_path / "dist"),
            final_packet[final_packet.index("--helper-sha256") + 1],
            final_packet[final_packet.index("--helper-manifest-sha256") + 1],
        ],
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
    assert all(call[:2] != ["release", "upload"] for call in calls)


@pytest.mark.parametrize("published", [False, True])
def test_valid_existing_final_proof_is_reused_without_signing_or_mutation(
    tmp_path: Path,
    future_repo: Path,
    final_packet: tuple[str, ...],
    monkeypatch: pytest.MonkeyPatch,
    published: bool,
) -> None:
    dist = tmp_path / "dist"
    remote_dist = tmp_path / "remote-bytes"
    remote_dist.mkdir()
    for path in dist.iterdir():
        _ = (remote_dist / path.name).write_bytes(path.read_bytes())
    original_proof = (dist / FINAL).read_bytes()
    remote = tmp_path / "release.json"
    remote_release(dist, future_repo, remote)
    payload = TypeAdapter(dict[str, JsonValue]).validate_json(remote.read_bytes())
    payload.update(
        {
            "id": 17,
            "target_commitish": "1" * 40,
            "draft": not published,
            "published_at": "2026-01-01T00:00:00Z" if published else None,
        }
    )
    assets = payload["assets"]
    assert isinstance(assets, list)
    for identity, asset in enumerate(assets, 1):
        assert isinstance(asset, dict)
        asset["id"] = identity
    _ = remote.write_text(json.dumps(payload))
    (dist / FINAL).unlink()
    monkeypatch.setenv("SYNTHETIC_PUBLICATION_SNAPSHOT", str(remote))
    monkeypatch.setenv("PROVENANCE_RELEASE_JSON", str(remote))
    monkeypatch.setenv("PROVENANCE_DIST", str(remote_dist))
    _ = (tmp_path / "calls.jsonl").write_text("")
    runner = publication_runner(tmp_path)
    result = subprocess.run(
        [
            sys.executable,
            str(runner),
            str(future_repo),
            str(dist),
            final_packet[final_packet.index("--helper-sha256") + 1],
            final_packet[final_packet.index("--helper-manifest-sha256") + 1],
            "publish" if published else "prepare-final",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["action"] == (
        "verify-only" if published else "ready"
    )
    assert (dist / FINAL).read_bytes() == original_proof
    calls = [
        TypeAdapter(list[str]).validate_json(line)
        for line in (tmp_path / "calls.jsonl").read_text().splitlines()
    ]
    assert all(call[0] in {"api", "attestation"} for call in calls)
    assert all(call[1] == "verify" for call in calls if call[0] == "attestation")


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


@pytest.mark.parametrize(
    ("schema", "expected_ref"),
    [
        ("health_bridge.release.v3", f"refs/tags/{TAG}"),
        ("health_bridge.release.v4", "refs/heads/release"),
    ],
)
def test_metadata_version_selects_strict_core_provenance_role(
    tmp_path: Path,
    helper_packet: tuple[str, ...],
    native_transport_mock: Path,
    schema: str,
    expected_ref: str,
) -> None:
    metadata = tmp_path / "dist/release-metadata.json"
    payload = TypeAdapter(dict[str, JsonValue]).validate_json(metadata.read_bytes())
    payload["schema_id"] = schema
    _ = metadata.write_text(json.dumps(payload))
    names = {
        "apple_health_ai_bridge-1.1.3-py3-none-any.whl",
        "apple_health_ai_bridge-1.1.3.tar.gz",
        "release-metadata.json",
    }
    mock_bundle(tmp_path / "dist", native_transport_mock, BUILD, names)
    calls_file = tmp_path / "calls.jsonl"
    _ = calls_file.write_text("")
    result = run_tool("verify-helper", *helper_packet)
    assert result.returncode == 0, result.stderr
    calls = [
        TypeAdapter(list[str]).validate_json(line)
        for line in calls_file.read_text().splitlines()
    ]
    assert len(calls) == 3
    for call in calls:
        assert call[call.index("--source-ref") + 1] == expected_ref
        assert call[call.index("--source-digest") + 1] == "1" * 40
        assert call[call.index("--signer-digest") + 1] == "1" * 40
        assert (
            call[call.index("--signer-workflow") + 1]
            == f"{REPOSITORY}/.github/workflows/release.yml"
        )


@pytest.mark.parametrize("attempt", [1, 2])
def test_candidate_native_proof_binds_original_execution_attempt(
    tmp_path: Path,
    helper_packet: tuple[str, ...],
    attempt: int,
) -> None:
    _ = helper_packet
    result_file = tmp_path / f"{BUILD}.result"
    records = TypeAdapter(list[dict[str, JsonValue]]).validate_json(
        result_file.read_bytes()
    )
    verification = records[0]["verificationResult"]
    assert isinstance(verification, dict)
    statement = verification["statement"]
    assert isinstance(statement, dict)
    statement["predicate"] = {
        "runDetails": {
            "metadata": {
                "invocationId": f"https://github.com/{REPOSITORY}/actions/runs/123/attempts/{attempt}"
            }
        }
    }
    _ = result_file.write_text(json.dumps(records))
    runner = tmp_path / "invocation.py"
    _ = runner.write_text(f"""import sys
from pathlib import Path
sys.path.insert(0, {str(ROOT / "scripts")!r})
from release_provenance import ProvenanceRequest, verify_provenance
names = frozenset([
    "apple_health_ai_bridge-1.1.3-py3-none-any.whl",
    "apple_health_ai_bridge-1.1.3.tar.gz", "release-metadata.json",
])
request = ProvenanceRequest(
    Path(sys.argv[1]), {TAG!r}, "1"*40, "release.yml", {BUILD!r}, names,
    candidate=True,
    invocation="https://github.com/{REPOSITORY}/actions/runs/123/attempts/2",
)
verify_provenance(request)
""")
    result = subprocess.run(
        [sys.executable, str(runner), str(tmp_path / "dist")],
        capture_output=True,
        text=True,
        check=False,
    )
    assert (result.returncode == 0) is (attempt == 2), result.stderr
