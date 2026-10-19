import tomllib
from pathlib import Path
from typing import ClassVar

import pytest
from packaging.requirements import Requirement
from pydantic import BaseModel, ConfigDict, Field


class Project(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)
    dependencies: tuple[str, ...]
    optional: dict[str, tuple[str, ...]] = Field(
        default_factory=dict, alias="optional-dependencies"
    )


class Manifest(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)
    project: Project
    groups: dict[str, tuple[str, ...]] = Field(alias="dependency-groups")


def manifest() -> Manifest:
    return Manifest.model_validate(tomllib.loads(Path("pyproject.toml").read_text()))


def test_atheris_is_pinned_and_exclusively_opt_in() -> None:
    # Given
    parsed = manifest()
    # When
    fuzz = [Requirement(item) for item in parsed.groups["fuzz"]]
    standard = list(parsed.project.dependencies)
    for dependencies in parsed.project.optional.values():
        standard.extend(dependencies)
    for name, dependencies in parsed.groups.items():
        if name != "fuzz":
            standard.extend(dependencies)
    # Then
    assert [item.name for item in fuzz] == ["atheris"]
    assert str(fuzz[0].specifier) == "==3.1.0"
    assert all(Requirement(item).name != "atheris" for item in standard)


@pytest.mark.parametrize(
    ("version", "system", "machine", "implementation", "supported"),
    [
        ("3.11", "Linux", "x86_64", "CPython", False),
        ("3.12", "Linux", "x86_64", "CPython", True),
        ("3.13", "Linux", "x86_64", "CPython", True),
        ("3.14", "Linux", "x86_64", "CPython", True),
        ("3.15", "Linux", "x86_64", "CPython", False),
        ("3.12", "Linux", "aarch64", "CPython", False),
        ("3.12", "Darwin", "x86_64", "CPython", False),
        ("3.12", "Windows", "AMD64", "CPython", False),
        ("3.12", "Linux", "x86_64", "PyPy", False),
    ],
)
def test_engine_group_matches_published_wheels(
    version: str, system: str, machine: str, implementation: str, supported: bool
) -> None:
    # Given
    marker = Requirement(manifest().groups["fuzz"][0]).marker
    assert marker is not None
    # When / Then
    assert (
        marker.evaluate(
            {
                "python_version": version,
                "platform_system": system,
                "platform_machine": machine,
                "platform_python_implementation": implementation,
            }
        )
        is supported
    )


def test_native_ci_requires_campaign_and_dependency_audit() -> None:
    # Given
    workflow = Path(".github/workflows/python.yml").read_text()
    # When
    job = workflow.split("\n  fuzz:\n")[1]
    # Then
    assert "runs-on: ubuntu-24.04" in job
    assert 'python-version: "3.12"' in job
    assert "timeout-minutes: 10" in job
    assert "persist-credentials: false" in job
    assert "uv sync --locked --dev --group fuzz" in job
    assert "uv run --no-sync pip-audit --local --skip-editable" in job
    assert 'uv run --no-sync python -m fuzz.campaign "$scratch"' in job
    assert "uv run --no-sync basedpyright fuzz" in job
    assert "mktemp -d" in job
    assert all(
        token not in job
        for token in (
            "continue-on-error",
            "|| true",
            "if:",
            "pytest",
            "upload-artifact",
        )
    )
