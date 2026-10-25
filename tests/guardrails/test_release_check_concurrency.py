"""Workflow configuration guards, not a live GitHub scheduler experiment."""

from pathlib import Path
from typing import Final, Protocol

import pytest
from pydantic import JsonValue, TypeAdapter
from ruamel.yaml import YAML

from health_bridge.mcp.types import JsonObject, required_object

RELEASE_SELECTOR: Final = (
    "${{ github.ref == 'refs/heads/release' && github.sha || github.ref }}"
)
CANCEL_SELECTOR: Final = "${{ github.ref != 'refs/heads/release' }}"
WORKFLOWS: Final = (
    ("python.yml", "python-"),
    ("ios.yml", "ios-"),
    ("codeql.yml", ""),
)


class YamlLoader(Protocol):
    def load(self, stream: str) -> JsonValue: ...


def _concurrency(filename: str, loader: YamlLoader) -> JsonObject:
    workflow = TypeAdapter(dict[str, JsonValue]).validate_python(
        loader.load(Path(".github/workflows", filename).read_text(encoding="utf-8"))
    )
    return required_object(workflow["concurrency"])


@pytest.mark.parametrize(("filename", "prefix"), WORKFLOWS)
def test_release_check_groups_are_pinned_to_sha_not_a_shared_pending_queue(
    filename: str, prefix: str
) -> None:
    # GitHub replaces a pending run even when cancel-in-progress is false.
    # Distinct release SHAs therefore need distinct groups; other refs keep
    # their existing per-ref key so obsolete main/PR checks can be cancelled.
    assert _concurrency(filename, YAML(typ="safe"))["group"] == (
        f"{prefix}${{{{ github.workflow }}}}-{RELEASE_SELECTOR}"
    )


@pytest.mark.parametrize("filename", [name for name, _ in WORKFLOWS])
def test_only_release_pushes_disable_in_progress_cancellation(filename: str) -> None:
    assert (
        _concurrency(filename, YAML(typ="safe"))["cancel-in-progress"]
        == CANCEL_SELECTOR
    )
