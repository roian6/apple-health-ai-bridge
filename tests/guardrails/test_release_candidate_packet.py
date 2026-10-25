from __future__ import annotations

import base64
import hashlib
import json
import subprocess
import sys
import zipfile
from typing import TYPE_CHECKING

from pydantic import JsonValue, TypeAdapter

from tests.guardrails.release_policy_fixtures import REPOSITORY, TAG
from tests.guardrails.release_version_fixtures import ROOT, git_output
from tests.guardrails.test_release_candidate import SignedCandidate, prepare, signed

if TYPE_CHECKING:
    from pathlib import Path

__all__ = ["signed"]


def test_original_candidate_packet_round_trip_before_public_tag(
    tmp_path: Path,
    signed: SignedCandidate,
) -> None:
    graph = signed.graph
    prepared = prepare(signed)
    assert prepared.returncode == 0, prepared.stderr
    core = tmp_path / "core"
    core.mkdir()
    for name in (
        "apple_health_ai_bridge-1.1.4-py3-none-any.whl",
        "apple_health_ai_bridge-1.1.4.tar.gz",
    ):
        _ = (core / name).write_bytes(b"synthetic package transport only")
    manifest = subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts/release_tools.py"),
            "manifest",
            "--candidate",
            "--repo",
            str(graph.repo),
            "--dist-dir",
            str(core),
            "--tag",
            TAG,
            "--tag-object",
            graph.tag_object,
            "--commit",
            graph.target,
            "--tree",
            git_output(graph.repo, "rev-parse", "HEAD^{tree}"),
            "--output",
            str(core / "release-metadata.json"),
        ],
        env=signed.environment,
        capture_output=True,
        text=True,
        check=False,
    )
    assert manifest.returncode == 0, manifest.stderr
    payload = graph.read()
    subjects: list[JsonValue] = [
        {
            "name": path.name,
            "digest": {"sha256": hashlib.sha256(path.read_bytes()).hexdigest()},
        }
        for path in sorted(core.iterdir())
    ]
    payload["verify"] = [
        {
            "verificationResult": {
                "statement": {
                    "_type": "https://in-toto.io/Statement/v1",
                    "predicateType": "https://slsa.dev/provenance/v1",
                    "subject": subjects,
                    "predicate": {
                        "runDetails": {
                            "metadata": {
                                "invocationId": f"https://github.com/{REPOSITORY}/actions/runs/1234/attempts/2"
                            }
                        }
                    },
                }
            }
        }
    ]
    graph.write(payload)
    _ = (core / "receiver-build-provenance.intoto.jsonl").write_text(
        "synthetic native transport fixture\n"
    )
    sealed = tmp_path / "sealed.json"
    seal = subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts/release_candidate.py"),
            "--phase",
            "seal",
            "--repo",
            str(graph.repo),
            "--record",
            str(tmp_path / "candidate.json"),
            "--dist-dir",
            str(core),
            "--output",
            str(sealed),
        ],
        env=signed.environment,
        capture_output=True,
        text=True,
        check=False,
    )
    assert seal.returncode == 0, seal.stderr
    archive = tmp_path / "candidate.zip"
    with zipfile.ZipFile(archive, "w") as bundle:
        for path in core.iterdir():
            bundle.write(path, path.name)
        bundle.write(sealed, "candidate.json")
    prefix = f"/repos/{REPOSITORY}"
    payload[prefix + "/actions/runs/1234/attempts/2"] = {
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
    payload[prefix + "/actions/runs/1234/artifacts?per_page=100&page=1"] = {
        "artifacts": [
            {
                "id": 456,
                "name": "candidate-1234-2",
                "expired": False,
                "workflow_run": {"head_sha": graph.target},
                "digest": "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest(),
            }
        ],
    }
    payload[prefix + "/actions/artifacts/456/zip"] = {
        "synthetic_binary": base64.b64encode(archive.read_bytes()).decode(),
    }
    graph.write(payload)
    output = tmp_path / "downloaded.json"
    downloaded = tmp_path / "downloaded"
    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts/release_candidate.py"),
            "--phase",
            "download",
            "--local",
            "--repo",
            str(graph.repo),
            "--run-id",
            "1234",
            "--attempt",
            "2",
            "--artifact-id",
            "456",
            "--dist-dir",
            str(downloaded),
            "--output",
            str(output),
        ],
        env=signed.environment,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert output.read_bytes() == sealed.read_bytes()
    assert {path.name: path.read_bytes() for path in downloaded.iterdir()} == {
        path.name: path.read_bytes() for path in core.iterdir()
    }
    checker = tmp_path / "receipt.py"
    _ = checker.write_text(f"""import sys
from pathlib import Path
sys.path.insert(0, {str(ROOT / "scripts")!r})
from release_candidate_model import CandidateRecord
from release_packet import verify_candidate_artifact_receipt
record = CandidateRecord.model_validate_json(Path(sys.argv[2]).read_bytes())
verify_candidate_artifact_receipt(Path(sys.argv[1]), record, 456)
""")
    verified = subprocess.run(
        [sys.executable, str(checker), str(graph.repo), str(output)],
        env=signed.environment,
        capture_output=True,
        text=True,
        check=False,
    )
    assert verified.returncode == 0, verified.stderr
    changed = TypeAdapter(dict[str, JsonValue]).validate_json(output.read_bytes())
    source = changed["source"]
    assert isinstance(source, dict)
    source["default_main_commit"] = "a" * 40
    _ = output.write_text(json.dumps(changed))
    rejected = subprocess.run(
        [sys.executable, str(checker), str(graph.repo), str(output)],
        env=signed.environment,
        capture_output=True,
        text=True,
        check=False,
    )
    assert rejected.returncode == 1
    assert "differs from immutable execution artifact" in rejected.stderr
