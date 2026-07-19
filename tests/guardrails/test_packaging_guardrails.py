import re
import runpy
import tomllib
from pathlib import Path
from typing import TYPE_CHECKING, cast

import pytest

if TYPE_CHECKING:
    from collections.abc import Callable


def test_sdist_excludes_local_private_and_tool_state() -> None:
    pyproject = cast(
        "dict[str, object]", tomllib.loads(Path("pyproject.toml").read_text())
    )
    tool = cast("dict[str, object]", pyproject["tool"])
    hatch = cast("dict[str, object]", tool["hatch"])
    build = cast("dict[str, object]", hatch["build"])
    targets = cast("dict[str, object]", build["targets"])
    sdist = cast("dict[str, object]", targets["sdist"])
    excluded = set(cast("list[str]", sdist["exclude"]))

    assert {
        "/.codegraph",
        "/.hermes",
        "/.tmp",
        "/.public-release-denylist.local",
    }.issubset(excluded)


def test_release_criteria_requires_built_artifact_smoke() -> None:
    criteria = Path(".github/release/criteria.md").read_text()
    build_command = " ".join(  # noqa: FLY002
        (
            "uv build --build-constraints build-constraints.txt",
            "--require-hashes --out-dir dist",
        )
    )

    assert 'test -z "$(git status --porcelain=v1)"' in criteria
    assert "rm -rf dist" in criteria
    assert build_command in criteria
    assert "uv run python scripts/package-smoke.py --dist-dir dist" in criteria


def test_isolated_build_constraints_are_complete_exact_hashed_pins() -> None:
    pyproject = tomllib.loads(Path("pyproject.toml").read_text())
    build_requires = cast("list[str]", pyproject["build-system"]["requires"])
    constraints = Path("build-constraints.txt").read_text()
    workflow = Path(".github/workflows/python.yml").read_text()
    criteria = Path(".github/release/criteria.md").read_text()

    pins: dict[str, str] = {}
    for line in constraints.splitlines():
        match = re.match(r"^([a-z0-9-]+)==([^\s\\]+)\s+\\$", line)
        if match:
            pins[match.group(1)] = match.group(2)
    assert set(pins) == {
        "hatchling",
        "packaging",
        "pathspec",
        "pluggy",
        "trove-classifiers",
    }
    assert build_requires == [f"hatchling=={pins['hatchling']}"]
    blocks = re.split(r"(?m)(?=^[a-z0-9-]+==)", constraints)
    requirement_blocks = [
        block for block in blocks if re.match(r"^[a-z0-9-]+==", block)
    ]
    assert len(requirement_blocks) == len(pins)
    assert all(block.count("--hash=sha256:") >= 2 for block in requirement_blocks)
    assert "--no-build-isolation" not in workflow + criteria


def test_package_smoke_strips_checkout_import_path_overrides(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("PYTHONPATH", "/private/checkout/src")
    monkeypatch.setenv("PYTHONHOME", "/private/python-home")
    namespace = cast(
        "dict[str, object]",
        runpy.run_path("scripts/package-smoke.py"),
    )
    raw_environment_factory = namespace["clean_subprocess_environment"]
    assert callable(raw_environment_factory)
    environment_factory = cast(
        "Callable[[], dict[str, str]]",
        raw_environment_factory,
    )

    environment = environment_factory()

    assert "PYTHONPATH" not in environment
    assert "PYTHONHOME" not in environment
