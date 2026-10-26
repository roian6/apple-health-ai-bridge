import os
import re
import subprocess
from pathlib import Path
from typing import Protocol

import pytest
from coverage import Coverage
from pydantic import JsonValue, TypeAdapter
from ruamel.yaml import YAML

from health_bridge.mcp.types import JsonObject, required_list, required_object

PYTHON_WORKFLOW = Path(".github/workflows/python.yml")
IOS_WORKFLOW = Path(".github/workflows/ios.yml")
DEPENDABOT_CONFIG = Path(".github/dependabot.yml")
PINNED_ACTION = re.compile(r"^\s*uses:\s*[^#\s]+@(?P<sha>[0-9a-f]{40})(?:\s+#.*)?$")


class YamlLoader(Protocol):
    def load(self, stream: str) -> JsonValue: ...


def _workflow(path: Path, loader: YamlLoader) -> JsonObject:
    return TypeAdapter(dict[str, JsonValue]).validate_python(
        loader.load(path.read_text())
    )


def test_ci_workflows_use_minimal_permissions_and_immutable_actions() -> None:
    workflows = (PYTHON_WORKFLOW, IOS_WORKFLOW)
    for workflow in workflows:
        text = workflow.read_text()
        assert "permissions:\n  contents: read" in text
        assert "npm" not in text.lower()
        uses_lines = [line for line in text.splitlines() if "uses:" in line]
        assert uses_lines
        assert all(PINNED_ACTION.match(line) for line in uses_lines)


def test_python_ci_runs_all_release_facing_python_gates() -> None:
    text = PYTHON_WORKFLOW.read_text()
    build_command = " ".join(  # noqa: FLY002
        (
            "uv build --build-constraints .github/release/build-constraints.txt",
            "--require-hashes --out-dir dist",
        )
    )
    assert "runs-on: ubuntu-24.04" in text
    for command in (
        "uv sync --all-extras --dev --locked",
        "uv run python scripts/public-release-audit.py --strict",
        "uv run ruff format --check .",
        "uv run ruff check .",
        "uv run basedpyright",
        "uv run bandit -r src -q",
        "uv run pip-audit --local --skip-editable",
        "uv run pytest -q",
        "--cov --cov-config=pyproject.toml",
        "--cov-report=xml:coverage/coverage.xml",
        "--cov-report=json:coverage/coverage.json",
        "rm -rf dist",
        build_command,
        "uv run python scripts/package-smoke.py --dist-dir dist",
    ):
        assert command in text


def test_python_coverage_measures_all_source_and_child_process_branches() -> None:
    coverage = Coverage(config_file="pyproject.toml")

    assert coverage.get_option("run:branch") is True
    assert coverage.get_option("run:source") == ["src/health_bridge"]
    assert coverage.get_option("run:relative_files") is True
    assert coverage.get_option("run:concurrency") == ["thread", "multiprocessing"]
    assert coverage.get_option("run:patch") == ["subprocess"]
    assert not coverage.get_option("run:omit")
    assert not coverage.get_option("report:omit")


def test_ios_ci_runs_swift_tests_and_unsigned_simulator_build() -> None:
    text = IOS_WORKFLOW.read_text()
    assert "runs-on: macos-26" in text
    assert "swift test" in text
    assert "xcodebuild -project HealthBridgeCompanion.xcodeproj" in text
    assert "-sdk iphonesimulator" in text
    assert "-sdk iphoneos" in text
    assert "CODE_SIGNING_ALLOWED=NO" in text


def test_dependabot_keeps_security_updates_without_version_prs() -> None:
    text = DEPENDABOT_CONFIG.read_text()

    assert "version: 2" in text
    assert 'package-ecosystem: "pip"' in text
    assert 'package-ecosystem: "github-actions"' in text
    assert text.count('interval: "monthly"') == 2
    assert text.count("open-pull-requests-limit: 0") == 2
    assert "cooldown:" not in text
    assert "groups:" not in text


@pytest.mark.parametrize(
    "gate_case",
    [
        (
            PYTHON_WORKFLOW,
            "checks",
            "python-checks",
            "Python quality and package checks",
        ),
        (
            IOS_WORKFLOW,
            "build-and-test",
            "native-checks",
            "Swift tests and unsigned app builds",
        ),
    ],
)
@pytest.mark.parametrize(
    "result_case",
    [
        ("success", "full", "success"),
        ("success", "full", "failure"),
        ("success", "full", "cancelled"),
        ("success", "full", "skipped"),
        ("success", "metadata", "success"),
        ("success", "metadata", "failure"),
        ("success", "metadata", "cancelled"),
        ("success", "metadata", "skipped"),
        ("failure", "metadata", "skipped"),
        ("cancelled", "full", "success"),
        ("skipped", "metadata", "success"),
        ("success", "", "success"),
    ],
)
def test_required_gate_executes_actual_dependency_result_contract(
    gate_case: tuple[Path, str, str, str],
    result_case: tuple[str, str, str],
) -> None:
    # Given: the parsed required job and concrete scheduler dependency results.
    path, gate_id, worker_id, context = gate_case
    scope_result, mode, worker_result = result_case
    jobs = required_object(_workflow(path, YAML(typ="safe"))["jobs"])
    gate = required_object(jobs[gate_id])
    assert gate["name"] == context
    assert gate["if"] == "always()"
    assert gate["needs"] == ["scope", worker_id]
    step = required_object(required_list(gate["steps"])[-1])
    assert step["env"] == {
        "SCOPE_RESULT": "${{ needs.scope.result }}",
        "MODE": "${{ needs.scope.outputs.mode }}",
        "WORKER_RESULT": f"${{{{ needs.{worker_id}.result }}}}",
    }
    command = step["run"]
    assert isinstance(command, str)
    # When: the real workflow command consumes those results.
    result = subprocess.run(
        ["/bin/bash", "-euc", command],
        env={
            **os.environ,
            "SCOPE_RESULT": scope_result,
            "MODE": mode,
            "WORKER_RESULT": worker_result,
        },
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    # Then: only the selected successful work, or justified native skip, passes.
    expected_worker = (
        "skipped" if path == IOS_WORKFLOW and mode == "metadata" else "success"
    )
    expected = (
        scope_result == "success"
        and mode in {"metadata", "full"}
        and worker_result == expected_worker
    )
    assert (result.returncode == 0) is expected, result.stdout + result.stderr


def test_metadata_selection_never_removes_workflow_triggers_or_full_coverage() -> None:
    # Given: both workflows still receive every PR and all original full events.
    python = _workflow(PYTHON_WORKFLOW, YAML(typ="safe"))
    native = _workflow(IOS_WORKFLOW, YAML(typ="safe"))
    for workflow in (python, native):
        events = required_object(workflow["on"])
        assert events["pull_request"] is None
        assert events["workflow_dispatch"] is None
        push = required_object(events["push"])
        assert push["branches"] == ["main", "release"]
        assert push["tags"] == ["ios-v*"]
    # When: inspect which runnable workers and test steps consume the classifier.
    native_jobs = required_object(native["jobs"])
    worker = required_object(native_jobs["native-checks"])
    assert worker["needs"] == "scope"
    assert worker["if"] == "needs.scope.outputs.mode == 'full'"
    python_jobs = required_object(python["jobs"])
    checks = required_object(python_jobs["python-checks"])
    assert checks["needs"] == "scope"
    steps = [required_object(step) for step in required_list(checks["steps"])]
    full = next(step for step in steps if step.get("name") == "Test")
    metadata = next(
        step for step in steps if step.get("name") == "Test metadata contracts"
    )
    # Then: full and metadata runs are distinct, with no coverage claim for a subset.
    assert full["if"] == "needs.scope.outputs.mode == 'full'"
    assert metadata["if"] == "needs.scope.outputs.mode == 'metadata'"
    full_command = full["run"]
    metadata_command = metadata["run"]
    assert isinstance(full_command, str)
    assert isinstance(metadata_command, str)
    assert "--cov --cov-config=pyproject.toml" in full_command
    assert "--junitxml=coverage/pytest.xml" in full_command
    assert "--cov" not in metadata_command
    assert "--junitxml=coverage/pytest-metadata.xml" in metadata_command
