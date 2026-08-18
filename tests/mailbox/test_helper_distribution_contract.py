from __future__ import annotations

import copy
import hashlib
import json
import plistlib
import zipfile
from typing import TYPE_CHECKING, cast

import pytest

if TYPE_CHECKING:
    from pathlib import Path

    from health_bridge.mailbox.helper_distribution_contract import (
        HelperDistributionIdentity,
    )
    from health_bridge.mailbox.helper_distribution_verifier import (
        DistributionVerificationRequest,
    )

from health_bridge.mailbox import helper_lifecycle
from health_bridge.mailbox.helper_lifecycle import (
    HELPER_APP_NAME,
    HELPER_COMPONENT,
    HELPER_EXECUTABLE_NAME,
    HelperError,
    HelperErrorCode,
    HelperStatusCode,
    install_helper,
    read_helper_status,
    validate_helper_release,
)


def _fixture_value(*parts: str) -> str:
    return "".join(parts)


BUNDLE_ID = "com.example.HealthBridgeMailboxAckPublisher"
CONTAINER_ID = "iCloud.com.example.HealthBridgeMailboxAckPublisher"
TEAM_ID = _fixture_value("A1B2", "C3D4E5")
PUBLISHER = "Example Health Bridge"
VERSION = "1.1.1"
TAG = f"receiver-v{VERSION}"


@pytest.fixture(autouse=True)
def allow_synthetic_distribution_policy(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def allow(
        *,
        signing_authority: str,
        team_identifier: str,
        bundle_identifier: str,
        icloud_container_identifier: str,
    ) -> None:
        del (
            signing_authority,
            team_identifier,
            bundle_identifier,
            icloud_container_identifier,
        )

    monkeypatch.setattr(
        helper_lifecycle,
        "require_approved_helper_distribution",
        allow,
        raising=False,
    )


def _write_archive(path: Path) -> None:
    info = plistlib.dumps(
        {
            "CFBundleExecutable": HELPER_EXECUTABLE_NAME,
            "CFBundleIdentifier": BUNDLE_ID,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": VERSION,
            "CFBundleVersion": "1",
            "HealthBridgeExpectedBundleIdentifier": BUNDLE_ID,
            "HealthBridgeICloudContainerIdentifier": CONTAINER_ID,
        },
        sort_keys=True,
    )
    members = {
        f"{HELPER_APP_NAME}/Contents/Info.plist": info,
        f"{HELPER_APP_NAME}/Contents/MacOS/{HELPER_EXECUTABLE_NAME}": b"signed",
        f"{HELPER_APP_NAME}/Contents/_CodeSignature/CodeResources": b"signature",
    }
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in members.items():
            member = zipfile.ZipInfo(name)
            member.create_system = 3
            member.external_attr = (0o100700 if "/MacOS/" in name else 0o100600) << 16
            archive.writestr(member, content)


def manifest_payload(archive: Path, *, schema_version: int) -> dict[str, object]:
    payload: dict[str, object] = {
        "schema_id": (
            "health_bridge.mailbox_ack_helper.release.v2"
            if schema_version == 2
            else "health_bridge.mailbox_ack_helper.release.v1"
        ),
        "schema_version": schema_version,
        "component": HELPER_COMPONENT,
        "artifact": {
            "bytes": archive.stat().st_size,
            "filename": archive.name,
            "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        },
        "bundle": {
            "build": "1",
            "identifier": BUNDLE_ID,
            "icloud_container_identifier": CONTAINER_ID,
            "version": VERSION,
        },
        "release": {
            "commit": "2" * 40,
            "tag": TAG,
            "tag_object": "1" * 40,
            "tree": "3" * 40,
        },
        "source": {
            "git_tree": "4" * 40,
            "path": "macos/HealthBridgeMailboxAckPublisher",
        },
    }
    if schema_version == 2:
        payload["distribution"] = {
            "signing_authority": (f"Developer ID Application: {PUBLISHER} ({TEAM_ID})"),
            "team_identifier": TEAM_ID,
            "provisioning_profile": {
                "provisions_all_devices": True,
                "application_identifier": f"{TEAM_ID}.{BUNDLE_ID}",
                "team_identifier": TEAM_ID,
                "icloud_container_environment": "Production",
                "icloud_container_identifiers": [CONTAINER_ID],
                "ubiquity_container_identifiers": [CONTAINER_ID],
            },
            "secure_timestamp": True,
            "hardened_runtime": True,
            "notarization": {
                "status": "Accepted",
                "submission_id": "12345678-1234-4234-8234-123456789abc",
            },
            "stapled_ticket": True,
            "gatekeeper_assessment": "accepted",
        }
    return payload


def write_release(tmp_path: Path, *, schema_version: int) -> tuple[Path, Path]:
    archive = tmp_path / f"{HELPER_COMPONENT}-{VERSION}.zip"
    manifest = tmp_path / f"{HELPER_COMPONENT}-{VERSION}.manifest.json"
    _write_archive(archive)
    _ = manifest.write_text(
        json.dumps(
            manifest_payload(archive, schema_version=schema_version),
            sort_keys=True,
        ),
        encoding="utf-8",
    )
    return archive, manifest


def test_v2_manifest_is_structurally_inspectable_when_distribution_is_valid(
    tmp_path: Path,
) -> None:
    archive, manifest = write_release(tmp_path, schema_version=2)

    inspected = validate_helper_release(archive, manifest)

    assert inspected.schema_version == 2
    assert inspected.distribution.team_identifier == TEAM_ID


def test_v1_manifest_remains_structurally_inspectable_for_history(
    tmp_path: Path,
) -> None:
    archive, manifest = write_release(tmp_path, schema_version=1)

    inspected = validate_helper_release(archive, manifest)

    assert inspected.schema_version == 1


@pytest.mark.parametrize(
    ("path", "invalid_value"),
    [
        (("distribution", "signing_authority"), "Apple Development: Wrong"),
        (("distribution", "team_identifier"), "WRONGTEAM1"),
        (
            ("distribution", "provisioning_profile", "provisions_all_devices"),
            False,
        ),
        (
            ("distribution", "provisioning_profile", "application_identifier"),
            f"{TEAM_ID}.com.example.Wrong",
        ),
        (("distribution", "secure_timestamp"), False),
        (("distribution", "hardened_runtime"), False),
        (("distribution", "notarization", "status"), "Invalid"),
        (("distribution", "stapled_ticket"), False),
        (("distribution", "gatekeeper_assessment"), "rejected"),
    ],
)
def test_v2_manifest_rejects_invalid_general_distribution_claims(
    tmp_path: Path,
    path: tuple[str, ...],
    invalid_value: str | bool,
) -> None:
    archive, manifest = write_release(tmp_path, schema_version=2)
    payload = copy.deepcopy(manifest_payload(archive, schema_version=2))
    target: dict[str, object] = payload
    for key in path[:-1]:
        target = cast("dict[str, object]", target[key])
    target[path[-1]] = invalid_value
    _ = manifest.write_text(json.dumps(payload), encoding="utf-8")

    with pytest.raises(HelperError) as raised:
        _ = validate_helper_release(archive, manifest)

    assert raised.value.code is HelperErrorCode.INVALID_MANIFEST


def test_receiver_1_1_1_install_rejects_v1_before_platform_verification(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    archive, manifest = write_release(tmp_path, schema_version=1)
    verifier_called = False

    def verifier(*_args: object, **_kwargs: object) -> None:
        nonlocal verifier_called
        verifier_called = True

    monkeypatch.setattr(helper_lifecycle, "__version__", VERSION)

    with pytest.raises(HelperError) as raised:
        _ = install_helper(
            archive,
            manifest,
            home=tmp_path / "home",
            platform="darwin",
            verifier=verifier,
        )

    assert raised.value.code is HelperErrorCode.INVALID_MANIFEST
    assert verifier_called is False


def test_receiver_1_1_1_default_install_verifies_v2_distribution_identity(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    archive, manifest = write_release(tmp_path, schema_version=2)
    observed: list[HelperDistributionIdentity | None] = []

    def verifier(request: DistributionVerificationRequest) -> None:
        assert request.bundle_identifier == BUNDLE_ID
        assert request.bundle_version == VERSION
        assert request.bundle_build == "1"
        assert request.icloud_container_identifier == CONTAINER_ID
        observed.append(request.distribution)

    monkeypatch.setattr(helper_lifecycle, "__version__", VERSION)
    monkeypatch.setattr(helper_lifecycle, "verify_macos_distribution", verifier)

    _ = install_helper(
        archive,
        manifest,
        home=tmp_path / "home",
        platform="darwin",
    )

    assert len(observed) == 1
    assert observed[0] is not None
    assert observed[0].team_identifier == TEAM_ID


def test_receiver_1_1_1_readiness_rejects_owned_v1_generation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    archive, manifest = write_release(tmp_path, schema_version=1)
    home = tmp_path / "home"
    verifier_calls = 0

    def verifier(*_args: object, **_kwargs: object) -> None:
        nonlocal verifier_calls
        verifier_calls += 1

    monkeypatch.setattr(helper_lifecycle, "__version__", VERSION)
    monkeypatch.setattr(
        helper_lifecycle,
        "_LEGACY_V1_INSTALL_VERSIONS",
        frozenset({VERSION}),
    )
    _ = install_helper(
        archive,
        manifest,
        home=home,
        platform="darwin",
        verifier=verifier,
    )
    monkeypatch.setattr(
        helper_lifecycle,
        "_LEGACY_V1_INSTALL_VERSIONS",
        frozenset({"1.1.0"}),
    )
    verifier_calls = 0

    status = read_helper_status(home=home, platform="darwin", verifier=verifier)

    assert status.code is HelperStatusCode.HELPER_DRIFT
    assert verifier_calls == 0
