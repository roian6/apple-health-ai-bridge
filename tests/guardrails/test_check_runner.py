from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import TYPE_CHECKING, Final

import pytest

if TYPE_CHECKING:
    from collections.abc import Mapping

ROOT: Final = Path(__file__).resolve().parents[2]
RUNNER: Final = ROOT / "scripts/run-checks.sh"
RECORDER: Final = """#!/bin/bash
set -eu
program="${0##*/}"
printf '%s\\0' "$program" "$PWD" "$@" >> "$CHECK_CALLS"
printf '\\n' >> "$CHECK_CALLS"
printf '%s\\0' "$program" "$HOME" "${TMPDIR:-}" "$@" >> "$CHECK_ENVS"
printf '\\n' >> "$CHECK_ENVS"
if [[ "$program" == bash && "${1:-}" == scripts/ci-scope.sh ]]; then
  printf '%s\\n' "$FAKE_SCOPE"
  exit 0
fi
if [[ "$program" == uname ]]; then printf 'Darwin\\n'; fi
if [[ "$program" == uv && "${1:-}" == run && "${2:-}" == "${FAIL_ON:-}" ]]; then
  exit 23
fi
if [[ "$program" == xcodebuild && "${FAIL_ON:-}" == xcodebuild ]]; then exit 23; fi
"""


@pytest.fixture
def tools(tmp_path: Path) -> tuple[Mapping[str, str], Path]:
    directory = tmp_path / "bin"
    directory.mkdir()
    calls = tmp_path / "calls"
    for name in ("uv", "bash", "uname", "swift", "xcodebuild"):
        script = directory / name
        _ = script.write_text(RECORDER)
        script.chmod(0o755)
    return {
        **os.environ,
        "PATH": f"{directory}{os.pathsep}{os.environ['PATH']}",
        "CHECK_CALLS": str(calls),
        "CHECK_ENVS": str(tmp_path / "environments"),
        "CHECKS_OUTPUT_DIR": str(tmp_path / "output"),
    }, calls


def _calls(path: Path) -> list[list[str]]:
    return [line.rstrip("\0").split("\0") for line in path.read_text().splitlines()]


@pytest.mark.parametrize("profile", ["maintenance", "python", "native", "full"])
def test_actual_runner_selects_component_tests_and_preserves_coverage(
    tools: tuple[Mapping[str, str], Path], profile: str
) -> None:
    # Given: real runner control flow with only its external test executable recorded.
    environment, calls = tools
    # When: it selects a concrete profile.
    result = subprocess.run(
        ["/bin/bash", str(RUNNER), "tests", profile],
        env=environment,
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    # Then: commands cover the selected consumers without falsely reporting full tests.
    assert result.returncode == 0, result.stdout + result.stderr
    command = _calls(calls)[0]
    assert command[:4] == ["uv", str(ROOT), "run", "pytest"]
    args = command[4:]
    assert ("--cov" in args) is (profile in {"full", "python"})
    assert f"--junitxml={environment['CHECKS_OUTPUT_DIR']}/pytest-{profile}.xml" in args
    if profile == "full":
        assert "tests" in args
    elif profile == "python":
        assert "tests/queries/test_date_boundaries.py" in args
        assert "tests/receiver/test_mailbox_keys_reopened.py" in args
        assert "tests/guardrails/test_release_provenance.py" not in args
        assert "tests/guardrails/test_release_maintenance_policy.py" not in args
    else:
        assert "tests/guardrails/test_repository_automation.py" in args
        assert "tests/guardrails/test_ios_app_privacy.py" in args
        assert "tests/guardrails/test_public_release_audit.py" in args
        assert "tests/mcp/test_reference_examples.py" in args
        assert "tests" not in args
        assert "tests/receiver/test_mailbox_keys_reopened.py" not in args
        assert ("tests/contract" in args) is (profile == "native")
    if profile != "full":
        assert (
            "tests/guardrails/test_release_management.py::"
            "test_install_commands_are_pinned_to_their_receiver_release"
        ) in args


@pytest.mark.parametrize("failure", ["pytest", "ruff"])
def test_selected_python_failure_stops_before_package_success(
    tools: tuple[Mapping[str, str], Path], failure: str
) -> None:
    # Given: a selected test or static-check command fails at its process boundary.
    environment, calls = tools
    # When: the complete Python runner executes the maintenance profile.
    result = subprocess.run(
        ["/bin/bash", str(RUNNER), "python", "maintenance"],
        env={**environment, "FAIL_ON": failure},
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    # Then: its real exit code propagates and later success cannot mask it.
    assert result.returncode == 23
    assert not any(call[2:3] == ["build"] for call in _calls(calls))


def test_native_runner_preserves_both_targets_and_unsigned_sdks(
    tools: tuple[Mapping[str, str], Path],
) -> None:
    # Given: platform tools are recorded without requiring Xcode on Python CI.
    environment, calls = tools
    # When: the actual native runner schedules its commands.
    result = subprocess.run(
        ["/bin/bash", str(RUNNER), "native", "native"],
        env=environment,
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    # Then: lint, package tests and all four unsigned app configurations remain.
    assert result.returncode == 0, result.stdout + result.stderr
    recorded = _calls(calls)
    assert any(
        call[0] == "bash" and call[2:] == ["scripts/swift-analysis.sh"]
        for call in recorded
    )
    assert any(call[0] == "swift" and call[2] == "test" for call in recorded)
    builds = [call for call in recorded if call[0] == "xcodebuild"]
    assert {
        (call[call.index("-target") + 1], call[call.index("-sdk") + 1])
        for call in builds
    } == {
        (target, sdk)
        for target in (
            "HealthBridgeCompanion",
            "HealthBridgeCompanionPublicDocumentsQA",
        )
        for sdk in ("iphonesimulator", "iphoneos")
    }
    assert len(builds) == 4
    assert all("CODE_SIGNING_ALLOWED=NO" in call for call in builds)
    assert all("CODE_SIGNING_REQUIRED=NO" in call for call in builds)
    assert all(call[1] == str(ROOT / "ios/HealthBridgeCompanion") for call in builds)


def test_native_build_failure_cannot_become_success(
    tools: tuple[Mapping[str, str], Path],
) -> None:
    # Given: the first selected app configuration fails.
    environment, calls = tools
    # When: the CI-facing native-build command runs.
    result = subprocess.run(
        ["/bin/bash", str(RUNNER), "native-builds", "full"],
        env={**environment, "FAIL_ON": "xcodebuild"},
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    # Then: it stops with the compiler's nonzero status, not a later successful build.
    assert result.returncode == 23
    assert len([call for call in _calls(calls) if call[0] == "xcodebuild"]) == 1


@pytest.mark.parametrize("fail_on", ["", "pytest"])
def test_local_checks_isolate_python_without_replacing_native_home(
    tools: tuple[Mapping[str, str], Path], tmp_path: Path, fail_on: str
) -> None:
    # Given: local checks need file isolation and the caller's native login context.
    environment, _ = tools
    original_home = tmp_path / "original-home"
    scratch = tmp_path / "scratch"
    original_home.mkdir()
    scratch.mkdir()
    # When: actual local orchestration runs a full selection with recorded executables.
    result = subprocess.run(
        ["/bin/bash", str(RUNNER), "local", "HEAD"],
        env={
            **environment,
            "HOME": str(original_home),
            "TMPDIR": str(scratch),
            "FAKE_SCOPE": "full",
            "FAIL_ON": fail_on,
        },
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    # Then: Python is private, native keeps its login context, and scratch is removed.
    assert result.returncode == (23 if fail_on else 0), result.stdout + result.stderr
    records = _calls(Path(environment["CHECK_ENVS"]))
    python = [
        row for row in records if row[0] == "uv" and row[3:4] in (["run"], ["build"])
    ]
    native = [row for row in records if row[0] in {"swift", "xcodebuild"}]
    assert python
    assert all(row[1] != str(original_home) for row in python)
    if fail_on:
        assert not native
    else:
        assert native
        assert all(row[1] == str(original_home) for row in native)
    assert all(not Path(row[2]).exists() for row in (*python, *native))
