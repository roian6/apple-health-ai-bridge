from pathlib import Path
from typing import Protocol

from pydantic import JsonValue, TypeAdapter
from ruamel.yaml import YAML

from health_bridge.mcp.types import JsonObject, required_list, required_object


class YamlLoader(Protocol):
    def load(self, stream: str) -> JsonValue: ...


def _document(path: str, loader: YamlLoader) -> JsonObject:
    return TypeAdapter(dict[str, JsonValue]).validate_python(
        loader.load(Path(path).read_text())
    )


def test_issue_labeler_retains_supported_append_only_area_configuration() -> None:
    # Given: the configuration consumed by the pinned issue-labeling action.
    config = _document(".github/labeler.yml", YAML(typ="safe"))
    # When: its machine-consumed label and matcher fields are inspected.
    assert set(config) == {"version", "labels"}
    assert config["version"] == "v1"
    labels = [required_object(label) for label in required_list(config["labels"])]
    names = [label["label"] for label in labels]
    # Then: the fallback owns only area labels and uses the supported matcher shape.
    assert names
    assert all(isinstance(name, str) and name.startswith("area: ") for name in names)
    assert len(names) == len({str(name) for name in names})
    for label in labels:
        assert set(label) == {"label", "matcher"}
        matcher = required_object(label["matcher"])
        assert set(matcher) == {"title", "body", "files"}
        assert isinstance(matcher["title"], str)
        assert matcher["title"]
        assert isinstance(matcher["body"], str)
        assert matcher["body"]
        paths = required_list(matcher["files"])
        assert paths
        assert all(isinstance(path, str) and path for path in paths)


def test_issue_fallback_cannot_write_pull_requests_or_repository_contents() -> None:
    # Given: the live issue-only workflow, not an emulation of the external matcher.
    workflow = _document(".github/workflows/labels.yml", YAML(typ="safe"))
    # When: triggers and token capabilities are decoded.
    events = required_object(workflow["on"])
    job = required_object(required_object(workflow["jobs"])["label"])
    # Then: only issue labeling has write capability.
    assert set(events) == {"issues"}
    assert required_object(events["issues"])["types"] == [
        "opened",
        "edited",
        "reopened",
    ]
    assert workflow["permissions"] == {}
    assert job["permissions"] == {"contents": "read", "issues": "write"}
    steps = [required_object(step) for step in required_list(job["steps"])]
    assert len(steps) == 1
    action = steps[0]["uses"]
    assert isinstance(action, str)
    name, revision = action.split("@")
    assert name == "fuxingloh/multi-labeler"
    assert len(revision) == 40
    assert all(c in "0123456789abcdef" for c in revision)


def test_review_configuration_keeps_independent_approval_and_shared_label_names() -> (
    None
):
    # Given: the configuration actually consumed by CodeRabbit.
    config = _document(".coderabbit.yaml", YAML(typ="safe"))
    reviews = required_object(config["reviews"])
    issues = required_object(required_object(config["issue_enrichment"])["labeling"])
    # When: review authority and the two label-name sets are inspected.
    pr_labels = [
        required_object(item)["label"]
        for item in required_list(reviews["labeling_instructions"])
    ]
    issue_labels = [
        required_object(item)["label"]
        for item in required_list(issues["labeling_instructions"])
    ]
    # Then: authors cannot self-approve and both surfaces share the label taxonomy.
    assert reviews["request_changes_workflow"] is True
    assert reviews["allow_author_approval"] is False
    assert required_object(reviews["auto_review"])["enabled"] is True
    assert reviews["auto_apply_labels"] is True
    assert issues["auto_apply_labels"] is True
    assert pr_labels
    assert pr_labels == issue_labels
