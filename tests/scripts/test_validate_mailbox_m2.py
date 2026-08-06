from __future__ import annotations

import subprocess
import sys
from pathlib import Path

VALIDATOR = Path("scripts/validate-mailbox-milestone.py")
HEAD = "6eb12a4fb29543e691c7e930f385dc4f9964598f"


def test_m2_validator_requires_strict_mode(tmp_path: Path) -> None:
    # Given: an M2 invocation that omits the strict gate.
    manifest = tmp_path / "m2.json"
    _ = manifest.write_text("{}", encoding="utf-8")

    # When: the validator is invoked without --strict.
    result = subprocess.run(
        [
            sys.executable,
            str(VALIDATOR),
            "--milestone",
            "M2",
            "--commit",
            HEAD,
            "--manifest",
            str(manifest),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    # Then: M2 fails closed before reading the manifest.
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        "FAIL M2 unsupported_invocation\n",
        "",
    )


def test_strict_m2_validator_rejects_missing_manifest(tmp_path: Path) -> None:
    # Given: no M2 milestone manifest exists at the approved path.
    missing_manifest = tmp_path / "m2.json"

    # When: the strict M2 validator is invoked for the pinned HEAD.
    result = subprocess.run(
        [
            sys.executable,
            str(VALIDATOR),
            "--milestone",
            "M2",
            "--strict",
            "--commit",
            HEAD,
            "--manifest",
            str(missing_manifest),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    # Then: the missing manifest fails closed as M2, never as M1.
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        "FAIL M2 invalid_manifest\n",
        "",
    )
