from pathlib import Path
from typing import Final, Protocol

import pytest
from pydantic import JsonValue, TypeAdapter
from ruamel.yaml import YAML

from health_bridge.mcp.types import JsonObject, required_list, required_object

WORKFLOW: Final = Path(".github/workflows/scorecard.yml")


class YamlLoader(Protocol):
    def load(self, stream: str) -> JsonValue: ...


def _load_workflow(loader: YamlLoader) -> JsonObject:
    return TypeAdapter(dict[str, JsonValue]).validate_python(
        loader.load(WORKFLOW.read_text(encoding="utf-8"))
    )


@pytest.fixture
def workflow() -> JsonObject:
    return _load_workflow(YAML(typ="safe"))


def test_scorecard_runs_only_on_main_push_with_bounded_resources(
    workflow: JsonObject,
) -> None:
    # Given / When: the parsed workflow, including all event and execution keys.
    jobs = required_object(workflow["jobs"])
    job = required_object(jobs["scorecard"])
    concurrency = required_object(workflow["concurrency"])
    # Then: no alternate triggers or execution contexts can publish results.
    assert set(workflow) == {"name", "on", "permissions", "concurrency", "jobs"}
    assert workflow["on"] == {"push": {"branches": ["main"]}}
    assert set(jobs) == {"scorecard"}
    assert set(job) == {"name", "runs-on", "timeout-minutes", "permissions", "steps"}
    assert job["runs-on"] == "ubuntu-latest"
    assert job["timeout-minutes"] == 15
    assert concurrency == {
        "group": "${{ github.workflow }}-${{ github.ref }}",
        "cancel-in-progress": True,
    }


def test_scorecard_uses_minimum_job_permissions(workflow: JsonObject) -> None:
    # Given / When
    job = required_object(required_object(workflow["jobs"])["scorecard"])
    # Then: no workflow writes, PATs, or code-scanning permissions.
    assert workflow["permissions"] == {}
    assert job["permissions"] == {"contents": "read", "id-token": "write"}


def test_scorecard_uses_only_pinned_actions_and_supported_publication_inputs(
    workflow: JsonObject,
) -> None:
    # Given / When
    job = required_object(required_object(workflow["jobs"])["scorecard"])
    steps = [required_object(step) for step in required_list(job["steps"])]
    # Then: the official action publishes JSON with its default token.
    assert len(steps) == 3
    checkout, scorecard, upload = steps
    assert set(checkout) <= {"name", "uses", "with"}
    assert set(scorecard) <= {"name", "uses", "with"}
    assert set(upload) <= {"name", "uses", "with", "if"}
    assert checkout["uses"] == (
        "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
    )
    assert checkout["with"] == {"persist-credentials": False}
    assert scorecard["uses"] == (
        "ossf/scorecard-action@fa7117db83c52d787ae5a89f350999701505d78e"
    )
    assert scorecard["with"] == {
        "results_file": "results.json",
        "results_format": "json",
        "publish_results": True,
    }
    assert upload["uses"] == (
        "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9"
    )
    assert upload["if"] == "always()"
    assert upload["with"] == {
        "name": "scorecard-results",
        "path": "results.json",
        "retention-days": 5,
    }
