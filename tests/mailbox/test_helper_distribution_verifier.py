from __future__ import annotations

import plistlib
import subprocess
from dataclasses import dataclass
from typing import TYPE_CHECKING

import pytest

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path

from health_bridge.mailbox import helper_distribution_verifier, helper_lifecycle
from health_bridge.mailbox.helper_distribution_contract import (
    HelperDistributionIdentity,
    HelperError,
    HelperErrorCode,
    HelperNotarization,
    HelperProvisioningProfile,
)
from health_bridge.mailbox.helper_distribution_verifier import (
    DistributionVerificationRequest,
)
from health_bridge.mailbox.helper_lifecycle import (
    HELPER_APP_NAME,
    HELPER_EXECUTABLE_NAME,
    verify_macos_distribution,
    verify_macos_release_distribution,
)


def _fixture_value(*parts: str) -> str:
    return "".join(parts)


BUNDLE_ID = "com.example.HealthBridgeMailboxAckPublisher"
CONTAINER_ID = "iCloud.com.example.HealthBridgeMailboxAckPublisher"
TEAM_ID = _fixture_value("A1B2", "C3D4E5")
PUBLISHER = "Example Health Bridge"
VERSION = "1.1.1"


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
        helper_distribution_verifier,
        "require_approved_helper_distribution",
        allow,
        raising=False,
    )


@dataclass(frozen=True, slots=True)
class RejectionScenario:
    expected_code: HelperErrorCode
    authority: str = f"Developer ID Application: {PUBLISHER} ({TEAM_ID})"
    observed_team: str = TEAM_ID
    timestamp: str = "Timestamp=Aug 17, 2026 at 12:00:00\n"
    flags: str = "flags=0x10000(runtime)\n"
    profile_is_universal: bool = True
    profile_application: str = f"{TEAM_ID}.{BUNDLE_ID}"
    profile_services: str = "*"
    profile_is_valid: bool = True
    staple_code: int = 0
    gatekeeper_code: int = 0


def _distribution() -> HelperDistributionIdentity:
    return HelperDistributionIdentity(
        signing_authority=f"Developer ID Application: {PUBLISHER} ({TEAM_ID})",
        team_identifier=TEAM_ID,
        provisioning_profile=HelperProvisioningProfile(
            provisions_all_devices=True,
            application_identifier=f"{TEAM_ID}.{BUNDLE_ID}",
            team_identifier=TEAM_ID,
            icloud_container_environment="Production",
            icloud_container_identifiers=(CONTAINER_ID,),
            ubiquity_container_identifiers=(CONTAINER_ID,),
        ),
        secure_timestamp=True,
        hardened_runtime=True,
        notarization=HelperNotarization(
            status="Accepted",
            submission_id="12345678-1234-4234-8234-123456789abc",
        ),
        stapled_ticket=True,
        gatekeeper_assessment="accepted",
    )


def _write_app(path: Path) -> None:
    info = path / "Contents/Info.plist"
    info.parent.mkdir(parents=True)
    _ = info.write_bytes(
        plistlib.dumps(
            {
                "CFBundleExecutable": HELPER_EXECUTABLE_NAME,
                "CFBundleIdentifier": BUNDLE_ID,
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": VERSION,
                "CFBundleVersion": "1",
                "HealthBridgeExpectedBundleIdentifier": BUNDLE_ID,
                "HealthBridgeICloudContainerIdentifier": CONTAINER_ID,
            }
        )
    )


def _request(app: Path) -> DistributionVerificationRequest:
    return DistributionVerificationRequest(
        app=app,
        bundle_identifier=BUNDLE_ID,
        icloud_container_identifier=CONTAINER_ID,
        bundle_version=VERSION,
        bundle_build="1",
        distribution=_distribution(),
    )


@pytest.mark.parametrize(
    ("verifier", "expected_platform_calls"),
    [
        (
            verify_macos_distribution,
            [
                ["/usr/bin/security", "cms", "-D"],
                ["/usr/sbin/spctl", "--assess", "--type"],
            ],
        ),
        (
            verify_macos_release_distribution,
            [
                ["/usr/bin/xcrun", "stapler", "validate"],
                ["/usr/bin/security", "cms", "-D"],
                ["/usr/sbin/spctl", "--assess", "--type"],
            ],
        ),
    ],
)
def test_macos_verifier_accepts_exact_general_distribution_identity(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    verifier: Callable[[DistributionVerificationRequest], None],
    expected_platform_calls: list[list[str]],
) -> None:
    app = tmp_path / HELPER_APP_NAME
    _write_app(app)
    application_identifier = f"{TEAM_ID}.{BUNDLE_ID}"
    entitlements = {
        "com.apple.application-identifier": application_identifier,
        "com.apple.developer.team-identifier": TEAM_ID,
        "com.apple.developer.icloud-container-environment": "Production",
        "com.apple.security.app-sandbox": True,
        "com.apple.developer.icloud-container-identifiers": [CONTAINER_ID],
        "com.apple.developer.ubiquity-container-identifiers": [CONTAINER_ID],
        "com.apple.developer.icloud-services": ["CloudDocuments"],
    }
    codesign_responses = iter(
        (
            subprocess.CompletedProcess([], 0, b"", b""),
            subprocess.CompletedProcess([], 0, plistlib.dumps(entitlements), b""),
            subprocess.CompletedProcess(
                [],
                0,
                b"",
                (
                    f"Authority=Developer ID Application: {PUBLISHER} ({TEAM_ID})\n"
                    f"TeamIdentifier={TEAM_ID}\n"
                    "Timestamp=Aug 17, 2026 at 12:00:00\n"
                    "flags=0x10000(runtime)\n"
                ).encode(),
            ),
        )
    )
    profile_entitlements = {
        key: value
        for key, value in entitlements.items()
        if key != "com.apple.security.app-sandbox"
    }
    profile_entitlements["com.apple.developer.icloud-services"] = "*"
    profile = plistlib.dumps(
        {
            "ProvisionsAllDevices": True,
            "TeamIdentifier": [TEAM_ID],
            "Entitlements": profile_entitlements,
        }
    )
    platform_calls: list[list[str]] = []

    def next_codesign(_arguments: list[str]) -> subprocess.CompletedProcess[bytes]:
        return next(codesign_responses)

    def next_platform(arguments: list[str]) -> subprocess.CompletedProcess[bytes]:
        platform_calls.append(arguments)
        if arguments[0] == "/usr/bin/security":
            return subprocess.CompletedProcess([], 0, profile, b"")
        return subprocess.CompletedProcess([], 0, b"", b"")

    monkeypatch.setattr(helper_lifecycle, "_run_codesign", next_codesign)
    monkeypatch.setattr(
        helper_lifecycle,
        "_run_platform_command",
        next_platform,
        raising=False,
    )

    verifier(_request(app))

    assert [call[:3] for call in platform_calls] == expected_platform_calls


@pytest.mark.parametrize(
    "scenario",
    [
        RejectionScenario(
            expected_code=HelperErrorCode.SIGNATURE_INVALID,
            authority=f"Apple Development: {PUBLISHER} ({TEAM_ID})",
        ),
        RejectionScenario(
            expected_code=HelperErrorCode.SIGNATURE_INVALID,
            observed_team="Z9Y8X7W6V5",
        ),
        RejectionScenario(
            expected_code=HelperErrorCode.SIGNATURE_INVALID,
            timestamp="",
        ),
        RejectionScenario(
            expected_code=HelperErrorCode.SIGNATURE_INVALID,
            timestamp="Timestamp=   \n",
        ),
        RejectionScenario(
            expected_code=HelperErrorCode.SIGNATURE_INVALID,
            timestamp="Timestamp=NoNe\n",
        ),
        RejectionScenario(
            expected_code=HelperErrorCode.SIGNATURE_INVALID,
            flags="flags=0x0(none)\n",
        ),
        RejectionScenario(
            expected_code=HelperErrorCode.ENTITLEMENTS_INVALID,
            profile_is_universal=False,
        ),
        RejectionScenario(
            expected_code=HelperErrorCode.ENTITLEMENTS_INVALID,
            profile_application=f"{TEAM_ID}.com.example.Wrong",
        ),
        RejectionScenario(
            expected_code=HelperErrorCode.ENTITLEMENTS_INVALID,
            profile_services="CloudKit",
        ),
        RejectionScenario(
            expected_code=HelperErrorCode.SIGNATURE_INVALID,
            profile_is_valid=False,
        ),
        RejectionScenario(
            expected_code=HelperErrorCode.SIGNATURE_INVALID,
            staple_code=1,
        ),
        RejectionScenario(
            expected_code=HelperErrorCode.SIGNATURE_INVALID,
            gatekeeper_code=1,
        ),
    ],
)
def test_macos_verifier_rejects_non_general_distribution_artifacts(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    scenario: RejectionScenario,
) -> None:
    app = tmp_path / HELPER_APP_NAME
    _write_app(app)
    application_identifier = f"{TEAM_ID}.{BUNDLE_ID}"
    entitlements: dict[str, object] = {
        "com.apple.application-identifier": application_identifier,
        "com.apple.developer.team-identifier": TEAM_ID,
        "com.apple.developer.icloud-container-environment": "Production",
        "com.apple.security.app-sandbox": True,
        "com.apple.developer.icloud-container-identifiers": [CONTAINER_ID],
        "com.apple.developer.ubiquity-container-identifiers": [CONTAINER_ID],
        "com.apple.developer.icloud-services": ["CloudDocuments"],
    }
    profile_entitlements = dict(entitlements)
    _ = profile_entitlements.pop("com.apple.security.app-sandbox")
    profile_entitlements["com.apple.application-identifier"] = (
        scenario.profile_application
    )
    profile_entitlements["com.apple.developer.icloud-services"] = (
        scenario.profile_services
    )
    profile: dict[str, object] = {
        "ProvisionsAllDevices": scenario.profile_is_universal,
        "TeamIdentifier": [TEAM_ID],
        "Entitlements": profile_entitlements,
    }
    if not scenario.profile_is_universal:
        profile["ProvisionedDevices"] = ["synthetic-device"]
    details = (
        f"Authority={scenario.authority}\n"
        f"TeamIdentifier={scenario.observed_team}\n"
        f"{scenario.timestamp}{scenario.flags}"
    ).encode()
    codesign_responses = iter(
        (
            subprocess.CompletedProcess([], 0, b"", b""),
            subprocess.CompletedProcess([], 0, plistlib.dumps(entitlements), b""),
            subprocess.CompletedProcess([], 0, b"", details),
        )
    )
    profile_output = (
        plistlib.dumps(profile) if scenario.profile_is_valid else b"not a profile"
    )

    def next_codesign(
        _arguments: list[str],
    ) -> subprocess.CompletedProcess[bytes]:
        return next(codesign_responses)

    def next_platform(
        arguments: list[str],
    ) -> subprocess.CompletedProcess[bytes]:
        if arguments[0] == "/usr/bin/security":
            return subprocess.CompletedProcess([], 0, profile_output, b"")
        if arguments[0] == "/usr/bin/xcrun":
            return subprocess.CompletedProcess([], scenario.staple_code, b"", b"")
        return subprocess.CompletedProcess([], scenario.gatekeeper_code, b"", b"")

    monkeypatch.setattr(
        helper_lifecycle,
        "_run_codesign",
        next_codesign,
    )
    monkeypatch.setattr(
        helper_lifecycle,
        "_run_platform_command",
        next_platform,
    )

    verifier = (
        verify_macos_release_distribution
        if scenario.staple_code != 0
        else verify_macos_distribution
    )
    with pytest.raises(HelperError) as raised:
        verifier(_request(app))

    assert raised.value.code is scenario.expected_code
