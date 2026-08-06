from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS_ROOT = ROOT / "ios" / "HealthBridgeCompanion"
PROJECT = IOS_ROOT / "HealthBridgeCompanion.xcodeproj" / "project.pbxproj"
ENTITLEMENTS = IOS_ROOT / "App" / "HealthBridgeCompanion.entitlements"
INFO_PLIST = IOS_ROOT / "App" / "Info.plist"
LAYOUT_SOURCE = (
    IOS_ROOT / "Sources" / "HealthBridgeCompanionCore" / "MailboxLayoutV1.swift"
)
LOCATOR_SOURCE = (
    IOS_ROOT / "Sources" / "HealthBridgeCompanionCore" / "MailboxLocatorV1.swift"
)
DEVICE_BUILD = ROOT / "scripts" / "ios-device-build.sh"


def test_icloud_capability_is_bundle_and_team_neutral() -> None:
    project = PROJECT.read_text(encoding="utf-8")
    entitlements = ENTITLEMENTS.read_text(encoding="utf-8")

    expected_container = "$(HEALTH_BRIDGE_ICLOUD_CONTAINER_IDENTIFIER)"
    assert entitlements.count(f"<string>{expected_container}</string>") == 2
    assert "<string>CloudDocuments</string>" in entitlements
    assert (
        "<string>$(TeamIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)</string>"
        in entitlements
    )
    container_setting = (
        "HEALTH_BRIDGE_ICLOUD_CONTAINER_IDENTIFIER = "
        '"iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)";'
    )
    assert project.count(container_setting) == 2
    assert (
        project.count("PRODUCT_BUNDLE_IDENTIFIER = com.example.HealthBridgeCompanion;")
        == 2
    )
    assert not re.search(r"[A-Z0-9]{10}\.com\.example", project)


def test_signed_build_derives_and_embeds_full_source_commit() -> None:
    script = DEVICE_BUILD.read_text(encoding="utf-8")
    info = INFO_PLIST.read_text(encoding="utf-8")

    assert "<key>HealthBridgeSourceCommit</key>" in info
    assert "<string>$(HEALTH_BRIDGE_SOURCE_COMMIT)</string>" in info
    assert 'git -C "$ROOT_DIR" rev-parse --verify HEAD' in script
    assert '"HEALTH_BRIDGE_SOURCE_COMMIT=$source_commit"' in script
    assert "HealthBridgeSourceCommit" in (
        IOS_ROOT
        / "Sources"
        / "HealthBridgeCompanionCore"
        / "HealthBridgeAppIdentity.swift"
    ).read_text(encoding="utf-8")


def test_layout_source_closes_name_and_filesystem_boundaries() -> None:
    layout = LAYOUT_SOURCE.read_text(encoding="utf-8")
    locator = LOCATOR_SOURCE.read_text(encoding="utf-8")

    for required in (
        'rootDirectoryName = "HealthBridgeMailbox"',
        'versionDirectoryName = "v1"',
        "case deliveries",
        "case acks",
        "case pairing",
        "case quarantine",
        'case delivery = "hbd"',
        'case acknowledgment = "hba"',
        'case invitation = "hbi"',
        'case completion = "hbc"',
        'case quarantine = "hbq"',
        "maximumDeliveryBytes: Int64 = 2_097_152",
        "maximumMetadataBytes: Int64 = 65_536",
        'temporarySuffix = "tmp"',
    ):
        assert required in layout
    for required in (
        "lstat(",
        "S_IFLNK",
        "S_IFDIR",
        "pathReplaced",
        "containerUnavailable",
        "posixPermissions",
        "applicationSupportDirectory",
        "relativeDevicePath",
        ".atomic",
    ):
        assert required in locator
