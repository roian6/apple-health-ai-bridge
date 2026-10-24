from pathlib import Path
from typing import Final, Protocol

import pytest
from pydantic import JsonValue, TypeAdapter
from ruamel.yaml import YAML

from health_bridge.mcp.types import JsonObject, required_list, required_object

WORKFLOW: Final = Path(".github/workflows/codeql.yml")
CODEQL_SHA: Final = "24c54180a607b1449ed407dd24f251e4e9147c8d"


class YamlLoader(Protocol):
    def load(self, stream: str) -> JsonValue: ...


def _load_workflow(loader: YamlLoader) -> JsonObject:
    return TypeAdapter(dict[str, JsonValue]).validate_python(
        loader.load(WORKFLOW.read_text(encoding="utf-8"))
    )


@pytest.fixture
def workflow() -> JsonObject:
    return _load_workflow(YAML(typ="safe"))


def test_codeql_runs_on_main_push_and_pull_requests_with_bounded_resources(
    workflow: JsonObject,
) -> None:
    # Given / When: all parsed event and execution keys in the workflow.
    jobs = required_object(workflow["jobs"])
    job = required_object(jobs["analyze"])
    # Then: only native push/PR events reach a bounded Ubuntu analysis job.
    assert set(workflow) == {"name", "on", "permissions", "concurrency", "jobs"}
    assert workflow["on"] == {
        "push": {"branches": ["main", "fix/receiver-1.1.4"]},
        "pull_request": {},
    }
    assert set(jobs) == {"analyze"}
    assert set(job) == {"name", "runs-on", "timeout-minutes", "permissions", "steps"}
    assert job["runs-on"] == "ubuntu-latest"
    assert job["timeout-minutes"] == 15
    assert workflow["concurrency"] == {
        "group": "${{ github.workflow }}-${{ github.ref }}",
        "cancel-in-progress": True,
    }


def test_codeql_limits_write_permissions_to_analysis_results(
    workflow: JsonObject,
) -> None:
    # Given / When
    job = required_object(required_object(workflow["jobs"])["analyze"])
    # Then: the default token has only the required job scopes.
    assert workflow["permissions"] == {"contents": "read"}
    assert job["permissions"] == {
        "contents": "read",
        "security-events": "write",
        "actions": "read",
    }


def test_codeql_uses_pinned_python_analysis_without_project_execution(
    workflow: JsonObject,
) -> None:
    # Given / When
    job = required_object(required_object(workflow["jobs"])["analyze"])
    steps = [required_object(step) for step in required_list(job["steps"])]
    # Then: extraction, query execution, and result upload use official defaults.
    assert len(steps) == 3
    checkout, initialize, analyze = steps
    for step in steps:
        assert set(step) <= {"name", "uses", "with"}
    assert checkout["uses"] == (
        "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
    )
    assert checkout["with"] == {"persist-credentials": False}
    assert initialize["uses"] == f"github/codeql-action/init@{CODEQL_SHA}"
    assert initialize["with"] == {"languages": "python", "build-mode": "none"}
    assert analyze["uses"] == f"github/codeql-action/analyze@{CODEQL_SHA}"
    assert analyze["with"] == {"category": "/language:python"}
