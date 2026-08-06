from __future__ import annotations

import re
import tomllib
from pathlib import Path
from typing import ClassVar

from pydantic import BaseModel, ConfigDict, Field

ROOT = Path(__file__).resolve().parents[2]


class _ManifestModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)


class _Project(_ManifestModel):
    name: str
    dependencies: tuple[str, ...]


class _PyProject(_ManifestModel):
    project: _Project


class _Dependency(_ManifestModel):
    name: str
    specifier: str | None = None


class _LockMetadata(_ManifestModel):
    requirements: tuple[_Dependency, ...] = Field(alias="requires-dist")


class _LockedPackage(_ManifestModel):
    name: str
    dependencies: tuple[_Dependency, ...] = ()
    metadata: _LockMetadata | None = None


class _Lock(_ManifestModel):
    package: tuple[_LockedPackage, ...]


def test_cryptography_is_a_mandatory_locked_core_dependency() -> None:
    # Given: the real project manifest and lock file used to build the package.
    with (ROOT / "pyproject.toml").open("rb") as manifest_file:
        manifest = _PyProject.model_validate(tomllib.load(manifest_file))
    with (ROOT / "uv.lock").open("rb") as lock_file:
        lock = _Lock.model_validate(tomllib.load(lock_file))

    # When: their core requirements, root lock edges, and package records are parsed.
    core_names = {
        re.split(r"[<>=!~;\s\[]", requirement, maxsplit=1)[0].lower().replace("_", "-")
        for requirement in manifest.project.dependencies
    }

    root_package = next(
        item for item in lock.package if item.name == manifest.project.name
    )
    assert root_package.metadata is not None
    root_dependency_names = {item.name for item in root_package.dependencies}
    package_requirement_names = {
        item.name for item in root_package.metadata.requirements
    }
    locked_package_names = {item.name for item in lock.package}

    # Then: cryptography must be mandatory package metadata and fully locked.
    required_locations = {
        "pyproject.toml [project].dependencies": "cryptography" in core_names,
        "uv.lock root dependencies": "cryptography" in root_dependency_names,
        "uv.lock package metadata requires-dist": (
            "cryptography" in package_requirement_names
        ),
        "uv.lock cryptography package record": "cryptography" in locked_package_names,
    }
    missing_locations = sorted(
        location
        for location, is_present in required_locations.items()
        if not is_present
    )
    assert not missing_locations, (
        "cryptography must be a mandatory locked core dependency; missing: "
        + ", ".join(missing_locations)
    )


def test_pydantic_minimum_matches_exclude_if_serialization_contract() -> None:
    with (ROOT / "pyproject.toml").open("rb") as manifest_file:
        manifest = _PyProject.model_validate(tomllib.load(manifest_file))
    with (ROOT / "uv.lock").open("rb") as lock_file:
        lock = _Lock.model_validate(tomllib.load(lock_file))

    project_requirement = next(
        requirement
        for requirement in manifest.project.dependencies
        if requirement.startswith("pydantic")
    )
    root_package = next(
        item for item in lock.package if item.name == manifest.project.name
    )
    assert root_package.metadata is not None
    locked_requirement = next(
        requirement
        for requirement in root_package.metadata.requirements
        if requirement.name == "pydantic"
    )

    assert project_requirement == "pydantic>=2.12"
    assert locked_requirement.specifier == ">=2.12"
