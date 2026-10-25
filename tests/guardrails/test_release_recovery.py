from __future__ import annotations

import base64
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest
from pydantic import JsonValue, TypeAdapter

ROOT = Path(__file__).parents[2]


@pytest.mark.parametrize("present", [0, 1, 2])
@pytest.mark.parametrize(
    "body", ["Synthetic release\n", " Synthetic release\n", "Synthetic release\n\n"]
)
def test_reconciliation_uploads_only_missing_bytes(
    tmp_path: Path, present: int, body: str
) -> None:
    assets = [
        {"name": name, "size": 3, "sha256": digest * 64}
        for name, digest in [("core.whl", "a"), ("helper.zip", "b")]
    ]
    expected = {
        "tag": "receiver-v9.0.1",
        "commit": "c" * 40,
        "title": "Synthetic",
        "notes": "Synthetic release\n",
        "assets": assets,
    }
    remote_assets = [
        {
            "id": index + 1,
            "name": asset["name"],
            "size": asset["size"],
            "digest": f"sha256:{asset['sha256']}",
            "state": "uploaded",
        }
        for index, asset in enumerate(assets[:present])
    ]
    snapshot = [
        {
            "id": 4,
            "tag_name": expected["tag"],
            "target_commitish": expected["commit"],
            "name": expected["title"],
            "body": body,
            "draft": True,
            "prerelease": False,
            "published_at": None,
            "assets": remote_assets,
        }
    ]
    expected_file = tmp_path / "expected.json"
    snapshot_file = tmp_path / "snapshot.json"
    _ = expected_file.write_text(json.dumps(expected))
    _ = snapshot_file.write_text(json.dumps(snapshot))
    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts/release_recovery.py"),
            "--phase",
            "plan",
            "--expected",
            str(expected_file),
            "--snapshot",
            str(snapshot_file),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if body != expected["notes"]:
        assert result.returncode == 1
        assert "HOLD:" in result.stderr
        assert snapshot_file.read_text() == json.dumps(snapshot)
        return
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {
        "release_id": 4,
        "action": "upload" if present < 2 else "ready",
        "missing": [asset["name"] for asset in assets[present:]],
    }


def recovery_transport(tmp_path: Path, failure: str) -> tuple[dict[str, str], Path]:
    executable = tmp_path / "gh"
    state = tmp_path / "remote.json"
    _ = state.write_text(
        json.dumps(
            {"releases": [], "writes": [], "failed": False, "readback_failed": False}
        )
    )
    _ = executable.write_text(f"""#!{sys.executable}
import base64, hashlib, json, os, pathlib, sys
path = pathlib.Path(os.environ['RECOVERY_STATE'])
state = json.loads(path.read_text())
args = sys.argv[1:]
failure = os.environ['RECOVERY_FAILURE']
def save(): path.write_text(json.dumps(state))
def lose(kind):
    if failure == kind and not state['failed']:
        state['failed'] = True
        save()
        sys.exit(23)
if args[:2] == ['api', '/repos/roian6/apple-health-ai-bridge/releases']:
    payload = json.load(sys.stdin)
    state['releases'].append(dict(payload, id=7, published_at=None, assets=[]))
    state['writes'].append('create')
    save()
    lose('create')
    print(json.dumps(state['releases'][0]))
elif args[0] == 'api' and '/releases?' in args[1]:
    if (failure == 'published-readback' and state['releases']
        and not state['releases'][0]['draft'] and not state['readback_failed']):
        state['readback_failed'] = True
        save()
        sys.exit(24)
    print(json.dumps(state['releases']))
elif args[0] == 'api' and '/releases/assets/' in args[1]:
    identity = int(args[1].rsplit('/', 1)[1])
    asset = next(item for item in state['releases'][0]['assets']
                 if item['id'] == identity)
    sys.stdout.buffer.write(base64.b64decode(asset['data']))
elif args[:2] == ['release', 'upload']:
    source = pathlib.Path(args[3])
    data = source.read_bytes()
    state['releases'][0]['assets'].append(dict(
        id=len(state['releases'][0]['assets'])+1, name=source.name, size=len(data),
        digest='sha256:'+hashlib.sha256(data).hexdigest(), state='uploaded',
        data=base64.b64encode(data).decode(),
    ))
    state['writes'].append('upload:' + source.name)
    save()
    lose(source.name)
elif args[:2] == ['release', 'edit']:
    state['releases'][0]['draft'] = False
    state['releases'][0]['published_at'] = '2026-01-01T00:00:00Z'
    state['writes'].append('publish')
    save()
    lose('publish')
else:
    sys.exit(25)
""")
    executable.chmod(0o700)
    return os.environ | {
        "PATH": f"{tmp_path}{os.pathsep}{os.environ['PATH']}",
        "RECOVERY_STATE": str(state),
        "RECOVERY_FAILURE": failure,
    }, state


@pytest.mark.parametrize(
    "failure",
    [
        "none",
        "create",
        "core.whl",
        "helper.zip",
        "SHA256SUMS",
        "receiver-final-provenance.intoto.jsonl",
        "publish",
        "published-readback",
    ],
)
def test_response_loss_and_partial_upload_resume_without_replacement(
    tmp_path: Path, failure: str
) -> None:
    environment, state = recovery_transport(tmp_path, failure)
    dist = tmp_path / "dist"
    dist.mkdir()
    assets: list[dict[str, JsonValue]] = []
    for name in (
        "core.whl",
        "helper.zip",
        "SHA256SUMS",
        "receiver-final-provenance.intoto.jsonl",
    ):
        data = f"synthetic {name}".encode()
        _ = (dist / name).write_bytes(data)
        assets.append(
            {
                "name": name,
                "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            }
        )
    expected = tmp_path / "expected.json"
    _ = expected.write_text(
        json.dumps(
            {
                "tag": "receiver-v9.0.1",
                "commit": "c" * 40,
                "title": "Synthetic",
                "notes": "Synthetic",
                "assets": assets,
            }
        )
    )
    runner = tmp_path / "run.py"
    _ = runner.write_text(f"""import sys
from pathlib import Path
sys.path.insert(0, {str(ROOT / "scripts")!r})
from release_reconciliation import ExpectedRelease, synchronize, publish
expected = ExpectedRelease.model_validate_json(Path(sys.argv[1]).read_bytes())
repo, dist = Path(sys.argv[2]), Path(sys.argv[3])
print(synchronize(repo, expected, dist).model_dump_json())
print(publish(repo, expected, dist).model_dump_json())
""")
    args = [sys.executable, str(runner), str(expected), str(tmp_path), str(dist)]
    first = subprocess.run(
        args, env=environment, capture_output=True, text=True, check=False
    )
    assert (first.returncode != 0) is (failure == "published-readback"), first.stderr
    second = subprocess.run(
        args, env=environment, capture_output=True, text=True, check=False
    )
    assert second.returncode == 0, second.stderr
    assert '"action":"verify-only"' in second.stdout
    final = TypeAdapter(dict[str, JsonValue]).validate_json(state.read_bytes())
    assert final["writes"] == [
        "create",
        "upload:SHA256SUMS",
        "upload:core.whl",
        "upload:helper.zip",
        "upload:receiver-final-provenance.intoto.jsonl",
        "publish",
    ]


@pytest.mark.parametrize(
    "mutation",
    [
        "unknown",
        "duplicate-release",
        "duplicate-asset",
        "digest",
        "download-bytes",
        "source",
        "published-missing",
        "pinned-missing",
        "pinned-changed",
        "body-leading",
        "body-trailing",
    ],
)
def test_conflicting_remote_state_holds_without_any_write(
    tmp_path: Path, mutation: str
) -> None:
    environment, state_path = recovery_transport(tmp_path, "none")
    dist = tmp_path / "dist"
    dist.mkdir()
    data = b"synthetic core"
    _ = (dist / "core.whl").write_bytes(data)
    _ = (dist / "helper.zip").write_bytes(b"synthetic helper")
    expected_assets = [
        {
            "name": path.name,
            "size": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }
        for path in sorted(dist.iterdir())
    ]
    asset: dict[str, JsonValue] = {
        "id": 1,
        "name": "core.whl",
        "size": len(data),
        "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
        "state": "uploaded",
        "data": base64.b64encode(data).decode(),
    }
    assets: list[JsonValue] = [asset]
    release: dict[str, JsonValue] = {
        "id": 7,
        "tag_name": "receiver-v9.0.1",
        "target_commitish": "c" * 40,
        "name": "Synthetic",
        "body": "Synthetic",
        "draft": True,
        "prerelease": False,
        "published_at": None,
        "assets": assets,
    }
    releases: list[JsonValue] = [release]
    if mutation == "unknown":
        asset["name"] = "unknown.txt"
    elif mutation == "duplicate-release":
        releases.append(release)
    elif mutation == "duplicate-asset":
        assets.append(asset)
    elif mutation == "digest":
        asset["digest"] = "sha256:" + "b" * 64
    elif mutation == "download-bytes":
        asset["data"] = base64.b64encode(b"different bytes").decode()
    elif mutation == "source":
        release["target_commitish"] = "d" * 40
    elif mutation == "pinned-missing":
        releases.clear()
    elif mutation == "pinned-changed":
        release["id"] = 8
    elif mutation in {"body-leading", "body-trailing"}:
        release["body"] = {
            "body-leading": " Synthetic",
            "body-trailing": "Synthetic\n",
        }[mutation]
    else:
        release["draft"] = False
        release["published_at"] = "2026-01-01T00:00:00Z"
    _ = state_path.write_text(
        json.dumps(
            {
                "releases": releases,
                "writes": [],
                "failed": False,
                "readback_failed": False,
            }
        )
    )
    expected_path = tmp_path / "expected.json"
    _ = expected_path.write_text(
        json.dumps(
            {
                "tag": "receiver-v9.0.1",
                "commit": "c" * 40,
                "title": "Synthetic",
                "notes": "Synthetic",
                "assets": expected_assets,
                "release_id": 7,
            }
        )
    )
    runner = tmp_path / "hold.py"
    _ = runner.write_text(f"""import sys
from pathlib import Path
sys.path.insert(0, {str(ROOT / "scripts")!r})
from release_reconciliation import ExpectedRelease, synchronize
expected = ExpectedRelease.model_validate_json(Path(sys.argv[1]).read_bytes())
synchronize(Path(sys.argv[2]), expected, Path(sys.argv[3]))
""")
    result = subprocess.run(
        [sys.executable, str(runner), str(expected_path), str(tmp_path), str(dist)],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert "HOLD:" in result.stderr
    state = TypeAdapter(dict[str, JsonValue]).validate_json(state_path.read_bytes())
    assert state["writes"] == []
