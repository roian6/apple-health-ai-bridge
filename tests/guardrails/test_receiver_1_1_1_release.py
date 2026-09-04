from __future__ import annotations

import json
import plistlib
import tomllib
from pathlib import Path
from typing import cast

ROOT = Path(__file__).parents[2]


def test_ios_1_1_1_build_41_leaves_receiver_1_1_1_unchanged() -> None:
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

    assert project["version"] == "1.1.1"
    assert '__version__: Final = "1.1.1"' in package_init
    assert server["version"] == "1.1.1"
    assert receiver == {"release_tag": "receiver-v1.1.1", "version": "1.1.1"}
    assert component_versions["release_scope"] == "ios"
    assert helper_info["CFBundleShortVersionString"] == "1.1.1"
    assert ios == {"build": "41", "marketing_version": "1.1.1"}
    assert ios_project.count("MARKETING_VERSION = 1.1.1;") == 2
    assert ios_project.count("CURRENT_PROJECT_VERSION = 41;") == 2


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
