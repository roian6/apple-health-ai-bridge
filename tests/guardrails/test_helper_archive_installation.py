from __future__ import annotations

import json
import plistlib
import sys
import zipfile
from types import SimpleNamespace
from typing import TYPE_CHECKING

import pytest

from health_bridge.mailbox import helper_lifecycle
from health_bridge.mailbox.helper_lifecycle import (
    HELPER_APP_NAME,
    HELPER_EXECUTABLE_NAME,
    HELPER_MANIFEST_NAME,
    HELPER_OWNERSHIP_NAME,
    HelperError,
    HelperErrorCode,
)
from scripts import verify_helper_distribution
from tests.mailbox.test_helper_distribution_contract import manifest_payload
from tests.mailbox.test_helper_lifecycle import (
    BUNDLE_ID,
    CONTAINER_ID,
    VERSION,
    allow_synthetic_distribution_policy,
)

if TYPE_CHECKING:
    from pathlib import Path

    from health_bridge.mailbox.helper_distribution_verifier import (
        DistributionVerificationRequest,
    )

__all__ = ["allow_synthetic_distribution_policy"]


def _release(tmp_path: Path, metadata_path: str | None = None) -> tuple[Path, Path]:
    archive = tmp_path / f"{HELPER_EXECUTABLE_NAME}-{VERSION}.zip"
    manifest = archive.with_suffix(".manifest.json")
    members = {
        "Contents/Info.plist": plistlib.dumps(
            {
                "CFBundleExecutable": HELPER_EXECUTABLE_NAME,
                "CFBundleIdentifier": BUNDLE_ID,
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": VERSION,
                "CFBundleVersion": "1",
                "HealthBridgeExpectedBundleIdentifier": BUNDLE_ID,
                "HealthBridgeICloudContainerIdentifier": CONTAINER_ID,
            }
        ),
        f"Contents/MacOS/{HELPER_EXECUTABLE_NAME}": b"synthetic signed executable",
        "Contents/_CodeSignature/CodeResources": b"synthetic signature metadata",
    }
    if metadata_path is not None:
        members[metadata_path] = b"AppleDouble"
    with zipfile.ZipFile(archive, "w") as package:
        for name, content in members.items():
            member = zipfile.ZipInfo(f"{HELPER_APP_NAME}/{name}")
            member.create_system = 3
            member.external_attr = (0o100700 if "/MacOS/" in name else 0o100600) << 16
            package.writestr(member, content)
    _ = manifest.write_text(
        json.dumps(manifest_payload(archive, schema_version=2, version=VERSION)),
        encoding="utf-8",
    )
    return archive, manifest


def _arguments(
    monkeypatch: pytest.MonkeyPatch, archive: Path, manifest: Path, app: Path | None
) -> None:
    args = ["verify_helper_distribution.py", "--archive", str(archive)]
    args.extend(["--manifest", str(manifest)])
    if app is not None:
        args.extend(["--app", str(app)])
    monkeypatch.setattr(sys, "argv", args)
    monkeypatch.setattr(
        verify_helper_distribution,
        "sys",
        SimpleNamespace(platform="darwin", stdout=sys.stdout),
    )
    monkeypatch.setattr(helper_lifecycle, "sys", SimpleNamespace(platform="darwin"))


@pytest.mark.parametrize("supply_app", [True, False])
@pytest.mark.parametrize("release_rejects", [False, True])
def test_release_gate_verifies_installed_archive_and_cleans_private_home(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    supply_app: bool,
    release_rejects: bool,
) -> None:
    # Given: the ZIP differs from an unrelated clean app supplied by a caller.
    archive, manifest = _release(tmp_path)
    unrelated_app = tmp_path / HELPER_APP_NAME
    unrelated_app.mkdir()
    _arguments(monkeypatch, archive, manifest, unrelated_app if supply_app else None)
    staged_apps: list[Path] = []
    installed_apps: list[Path] = []

    def verify_consumer(request: DistributionVerificationRequest) -> None:
        executable = request.app / "Contents/MacOS" / HELPER_EXECUTABLE_NAME
        assert executable.read_bytes() == b"synthetic signed executable"
        staged_apps.append(request.app)

    def verify_release(request: DistributionVerificationRequest) -> None:
        executable = request.app / "Contents/MacOS" / HELPER_EXECUTABLE_NAME
        assert executable.read_bytes() == b"synthetic signed executable"
        assert request.app != unrelated_app
        assert (request.app.parent / HELPER_OWNERSHIP_NAME).is_file()
        assert (request.app.parent / HELPER_MANIFEST_NAME).read_bytes() == (
            manifest.read_bytes()
        )
        assert request.app.parent.stat().st_mode & 0o077 == 0
        installed_apps.append(request.app)
        if release_rejects:
            raise HelperError(HelperErrorCode.SIGNATURE_INVALID)

    monkeypatch.setattr(helper_lifecycle, "verify_macos_distribution", verify_consumer)
    monkeypatch.setattr(
        verify_helper_distribution, "verify_macos_release_distribution", verify_release
    )

    # When: the release command qualifies the ZIP using simulated native trust.
    if release_rejects:
        with pytest.raises(SystemExit) as raised:
            _ = verify_helper_distribution.main()
        assert isinstance(raised.value.__cause__, HelperError)
        assert raised.value.__cause__.code is HelperErrorCode.SIGNATURE_INVALID
    else:
        assert verify_helper_distribution.main() == 0

    # Then: the real lifecycle ran and its temporary home was removed either way.
    assert len(staged_apps) == 1
    assert len(installed_apps) == 1
    assert not staged_apps[0].exists()
    private_home = installed_apps[0].parents[4]
    assert not private_home.exists()
    assert unrelated_app.is_dir()


@pytest.mark.parametrize(
    "metadata_path", ["Contents/._Info.plist", "Contents/Resources/__MACOSX/child"]
)
def test_unrelated_clean_app_cannot_certify_metadata_archive(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    metadata_path: str,
) -> None:
    # Given: a valid manifest digest for a ZIP with inline metadata and a clean app.
    archive, manifest = _release(tmp_path, metadata_path)
    unrelated_app = tmp_path / HELPER_APP_NAME
    unrelated_app.mkdir()
    _arguments(monkeypatch, archive, manifest, unrelated_app)
    verified: list[Path] = []

    def verify_native(request: DistributionVerificationRequest) -> None:
        verified.append(request.app)

    monkeypatch.setattr(helper_lifecycle, "verify_macos_distribution", verify_native)
    monkeypatch.setattr(
        verify_helper_distribution, "verify_macos_release_distribution", verify_native
    )

    # When: a caller attempts to qualify the malformed ZIP with the clean app.
    with pytest.raises(SystemExit) as raised:
        _ = verify_helper_distribution.main()

    # Then: native verification of the unrelated app cannot hide archive metadata.
    assert verified == []
    assert isinstance(raised.value.__cause__, HelperError)
    assert raised.value.__cause__.code is HelperErrorCode.UNSAFE_ARCHIVE
