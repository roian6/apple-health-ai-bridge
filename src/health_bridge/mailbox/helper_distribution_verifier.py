from __future__ import annotations

import plistlib
import re
from dataclasses import dataclass
from datetime import datetime
from typing import TYPE_CHECKING, Protocol, TypeAlias, cast
from xml.parsers.expat import ExpatError

from health_bridge.mailbox.helper_distribution_contract import (
    HelperDistributionIdentity,
    HelperError,
    HelperErrorCode,
    require_approved_helper_distribution,
)

if TYPE_CHECKING:
    from pathlib import Path

PlistValue: TypeAlias = (
    str
    | bytes
    | int
    | float
    | bool
    | datetime
    | list["PlistValue"]
    | dict[str, "PlistValue"]
)


class CommandResult(Protocol):
    returncode: int
    stdout: bytes
    stderr: bytes


class CommandRunner(Protocol):
    def __call__(self, arguments: list[str]) -> CommandResult: ...


@dataclass(frozen=True, slots=True)
class LegacyVerificationRequest:
    app: Path
    bundle_identifier: str
    icloud_container_identifier: str


@dataclass(frozen=True, slots=True)
class DistributionVerificationRequest(LegacyVerificationRequest):
    bundle_version: str
    bundle_build: str
    distribution: HelperDistributionIdentity


def verify_legacy_signature(
    request: LegacyVerificationRequest,
    codesign_runner: CommandRunner,
) -> None:
    verified = codesign_runner(["--verify", "--strict", "--deep", str(request.app)])
    if verified.returncode != 0:
        raise HelperError(HelperErrorCode.SIGNATURE_INVALID)
    entitlements_result = codesign_runner(
        ["-d", "--entitlements", ":-", str(request.app)]
    )
    if entitlements_result.returncode != 0:
        raise HelperError(HelperErrorCode.ENTITLEMENTS_INVALID)
    entitlements = _parse_plist(
        entitlements_result.stdout + entitlements_result.stderr,
        HelperErrorCode.ENTITLEMENTS_INVALID,
    )
    required = {
        "com.apple.security.app-sandbox": True,
        "com.apple.developer.icloud-container-identifiers": [
            request.icloud_container_identifier
        ],
        "com.apple.developer.ubiquity-container-identifiers": [
            request.icloud_container_identifier
        ],
        "com.apple.developer.icloud-services": ["CloudDocuments"],
    }
    if any(entitlements.get(key) != value for key, value in required.items()):
        raise HelperError(HelperErrorCode.ENTITLEMENTS_INVALID)
    details = codesign_runner(["-d", "--verbose=4", str(request.app)])
    if details.returncode != 0 or not _has_runtime(details.stdout + details.stderr):
        raise HelperError(HelperErrorCode.SIGNATURE_INVALID)


def verify_general_distribution(
    request: DistributionVerificationRequest,
    codesign_runner: CommandRunner,
    platform_runner: CommandRunner,
) -> None:
    require_approved_helper_distribution(
        signing_authority=request.distribution.signing_authority,
        team_identifier=request.distribution.team_identifier,
        bundle_identifier=request.bundle_identifier,
        icloud_container_identifier=request.icloud_container_identifier,
    )
    verified = codesign_runner(["--verify", "--strict", "--deep", str(request.app)])
    if verified.returncode != 0:
        raise HelperError(HelperErrorCode.SIGNATURE_INVALID)
    entitlements_result = codesign_runner(
        ["-d", "--entitlements", ":-", str(request.app)]
    )
    if entitlements_result.returncode != 0:
        raise HelperError(HelperErrorCode.ENTITLEMENTS_INVALID)
    entitlements = _parse_plist(
        entitlements_result.stdout + entitlements_result.stderr,
        HelperErrorCode.ENTITLEMENTS_INVALID,
    )
    expected_entitlements = _expected_entitlements(request)
    if entitlements != expected_entitlements:
        raise HelperError(HelperErrorCode.ENTITLEMENTS_INVALID)
    details = codesign_runner(["-d", "--verbose=4", str(request.app)])
    combined = details.stdout + details.stderr
    timestamp = _metadata_value(combined, b"Timestamp")
    if (
        details.returncode != 0
        or _metadata_value(combined, b"Authority")
        != request.distribution.signing_authority.encode()
        or _metadata_value(combined, b"TeamIdentifier")
        != request.distribution.team_identifier.encode()
        or not timestamp
        or timestamp.lower() == b"none"
        or not _has_runtime(combined)
    ):
        raise HelperError(HelperErrorCode.SIGNATURE_INVALID)
    profile = platform_runner(
        [
            "/usr/bin/security",
            "cms",
            "-D",
            "-i",
            str(request.app / "Contents/embedded.provisionprofile"),
        ]
    )
    if profile.returncode != 0:
        raise HelperError(HelperErrorCode.SIGNATURE_INVALID)
    _verify_profile(
        _parse_plist(profile.stdout, HelperErrorCode.SIGNATURE_INVALID),
        request,
        expected_entitlements,
    )
    assessed = platform_runner(
        [
            "/usr/sbin/spctl",
            "--assess",
            "--type",
            "execute",
            "--verbose=4",
            str(request.app),
        ]
    )
    if assessed.returncode != 0:
        raise HelperError(HelperErrorCode.SIGNATURE_INVALID)


def verify_release_distribution(
    request: DistributionVerificationRequest,
    codesign_runner: CommandRunner,
    platform_runner: CommandRunner,
) -> None:
    stapled = platform_runner(
        ["/usr/bin/xcrun", "stapler", "validate", str(request.app)]
    )
    if stapled.returncode != 0:
        raise HelperError(HelperErrorCode.SIGNATURE_INVALID)
    verify_general_distribution(request, codesign_runner, platform_runner)


def _expected_entitlements(
    request: DistributionVerificationRequest,
) -> dict[str, str | bool | list[str]]:
    team_identifier = request.distribution.team_identifier
    return {
        "com.apple.application-identifier": (
            f"{team_identifier}.{request.bundle_identifier}"
        ),
        "com.apple.developer.team-identifier": team_identifier,
        "com.apple.developer.icloud-container-environment": "Production",
        "com.apple.security.app-sandbox": True,
        "com.apple.developer.icloud-container-identifiers": [
            request.icloud_container_identifier
        ],
        "com.apple.developer.ubiquity-container-identifiers": [
            request.icloud_container_identifier
        ],
        "com.apple.developer.icloud-services": ["CloudDocuments"],
    }


def _verify_profile(
    profile: dict[str, PlistValue],
    request: DistributionVerificationRequest,
    expected_entitlements: dict[str, str | bool | list[str]],
) -> None:
    distribution = request.distribution
    declared = distribution.provisioning_profile
    raw_entitlements = profile.get("Entitlements")
    if not isinstance(raw_entitlements, dict):
        raise HelperError(HelperErrorCode.ENTITLEMENTS_INVALID)
    profile_entitlements = cast("dict[str, PlistValue]", raw_entitlements)
    expected_services = expected_entitlements["com.apple.developer.icloud-services"]
    profile_services = profile_entitlements.get("com.apple.developer.icloud-services")
    if (
        "ProvisionedDevices" in profile
        or profile.get("ProvisionsAllDevices") is not True
        or profile.get("TeamIdentifier") != [distribution.team_identifier]
        or profile_entitlements.get("com.apple.application-identifier")
        != declared.application_identifier
        or profile_entitlements.get("com.apple.developer.team-identifier")
        != declared.team_identifier
        or profile_entitlements.get("com.apple.developer.icloud-container-identifiers")
        != list(declared.icloud_container_identifiers)
        or profile_entitlements.get(
            "com.apple.developer.ubiquity-container-identifiers"
        )
        != list(declared.ubiquity_container_identifiers)
        or profile_entitlements.get("com.apple.developer.icloud-container-environment")
        != declared.icloud_container_environment
        or declared.icloud_container_environment
        != expected_entitlements["com.apple.developer.icloud-container-environment"]
        or profile_services not in ("*", expected_services)
    ):
        raise HelperError(HelperErrorCode.ENTITLEMENTS_INVALID)


def _parse_plist(raw: bytes, error_code: HelperErrorCode) -> dict[str, PlistValue]:
    start = raw.find(b"<?xml")
    if start < 0:
        start = raw.find(b"<plist")
    end = raw.find(b"</plist>", start)
    if start < 0 or end < 0:
        raise HelperError(error_code)
    try:
        payload = cast(
            "PlistValue",
            plistlib.loads(raw[start : end + len(b"</plist>")]),
        )
    except (ExpatError, plistlib.InvalidFileException) as exc:
        raise HelperError(error_code) from exc
    if not isinstance(payload, dict):
        raise HelperError(error_code)
    return cast("dict[str, PlistValue]", payload)


def _metadata_value(raw: bytes, key: bytes) -> bytes | None:
    match = re.search(rb"^" + re.escape(key) + rb"=(.+)$", raw, re.MULTILINE)
    return None if match is None else match.group(1).strip()


def _has_runtime(raw: bytes) -> bool:
    return (
        re.search(
            rb"^.*flags=.*\bruntime\b.*$",
            raw,
            flags=re.IGNORECASE | re.MULTILINE,
        )
        is not None
    )
