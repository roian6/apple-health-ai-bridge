from __future__ import annotations

import json
import plistlib
import tomllib
from pathlib import Path
from typing import cast

from pydantic import BaseModel

from health_bridge import __version__

ROOT = Path(__file__).parents[2]


class LockedPackage(BaseModel):
    name: str
    version: str


class ProjectLock(BaseModel):
    package: list[LockedPackage]


def test_current_receiver_preserves_ios_1_1_1_build_50() -> None:
    with (ROOT / "pyproject.toml").open("rb") as handle:
        project = cast("dict[str, object]", tomllib.load(handle)["project"])
    component_versions = cast(
        "dict[str, object]",
        json.loads((ROOT / "component-versions.json").read_text()),
    )
    receiver = cast("dict[str, object]", component_versions["receiver_cli"])
    ios = cast("dict[str, object]", component_versions["ios_companion"])
    server = cast("dict[str, object]", json.loads((ROOT / "server.json").read_text()))
    package_init = (ROOT / "src/health_bridge/__init__.py").read_text()
    helper_info = cast(
        "dict[str, object]",
        plistlib.loads(
            (ROOT / "macos/HealthBridgeMailboxAckPublisher/Info.plist").read_bytes()
        ),
    )
    ios_project = (
        ROOT
        / "ios/HealthBridgeCompanion/HealthBridgeCompanion.xcodeproj/project.pbxproj"
    ).read_text()

    assert project["version"] == __version__
    assert f'__version__: Final = "{__version__}"' in package_init
    assert server["version"] == __version__
    assert receiver == {
        "release_tag": f"receiver-v{__version__}",
        "version": __version__,
    }
    assert component_versions["release_scope"] == "receiver"
    assert helper_info["CFBundleShortVersionString"] == __version__
    assert helper_info["CFBundleVersion"] == "1"
    assert ios == {"build": "50", "marketing_version": "1.1.1"}
    assert ios_project.count("MARKETING_VERSION = 1.1.1;") == 2
    assert ios_project.count("CURRENT_PROJECT_VERSION = 50;") == 2


def test_current_receiver_lock_matches_project_version() -> None:
    lock = ProjectLock.model_validate(tomllib.loads((ROOT / "uv.lock").read_text()))
    project = LockedPackage.model_validate(
        tomllib.loads((ROOT / "pyproject.toml").read_text())["project"]
    )

    packages = [package for package in lock.package if package.name == project.name]

    assert len(packages) == 1
    assert packages[0].version == project.version == __version__


def test_receiver_1_1_1_release_notes_are_receiver_only_and_helper_bound() -> None:
    notes_path = ROOT / ".github/release/notes-receiver-v1.1.1.md"

    assert notes_path.is_file()
    notes = notes_path.read_text(encoding="utf-8")
    for marker in (
        "Receiver/CLI 1.1.1",
        "Receiver-only release",
        "Compatible iOS Companion: `1.1.0 (39)`",
        "Compatible Batch Protocol: `health_bridge.batch.v1 (1.0.0)`",
        "No TestFlight update is required",
        "@receiver-v1.1.1",
        "HealthBridgeMailboxAckPublisher-1.1.1.zip",
        "HealthBridgeMailboxAckPublisher-1.1.1.manifest.json",
        "Developer ID",
        "notarized",
        "Gatekeeper",
    ):
        assert marker in notes
    assert (ROOT / ".github/release/notes-receiver-v1.1.0.md").is_file()
