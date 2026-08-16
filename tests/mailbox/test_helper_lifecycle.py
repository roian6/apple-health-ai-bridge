from __future__ import annotations

import hashlib
import json
import plistlib
import subprocess
import sys
import warnings
import zipfile
from typing import TYPE_CHECKING, Protocol, cast

import pytest
from typer.testing import CliRunner

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path

from health_bridge.cli import app
from health_bridge.mailbox import helper_lifecycle
from health_bridge.mailbox.helper_lifecycle import (
    HELPER_APP_NAME,
    HELPER_COMPONENT,
    HELPER_EXECUTABLE_NAME,
    HelperError,
    HelperErrorCode,
    HelperPaths,
    HelperStatusCode,
    install_helper,
    read_helper_status,
    uninstall_helper,
    validate_helper_release,
    verify_macos_helper,
)

BUNDLE_ID = "com.example.HealthBridgeMailboxAckPublisher"
CONTAINER_ID = "iCloud.com.example.HealthBridgeMailboxAckPublisher"
TAG = "receiver-v1.1.0"
TAG_OBJECT = "1" * 40
COMMIT = "2" * 40
TREE = "3" * 40
SOURCE_TREE = "4" * 40


class PlatformVerifier(Protocol):
    def __call__(
        self,
        app: Path,
        *,
        bundle_identifier: str,
        bundle_version: str,
        bundle_build: str,
        icloud_container_identifier: str,
    ) -> None: ...


def _write_archive(
    path: Path,
    *,
    extra_members: dict[str, bytes] | None = None,
    unsafe_member: zipfile.ZipInfo | None = None,
) -> None:
    info = plistlib.dumps(
        {
            "CFBundleExecutable": HELPER_EXECUTABLE_NAME,
            "CFBundleIdentifier": BUNDLE_ID,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.1.0",
            "CFBundleVersion": "1",
            "HealthBridgeExpectedBundleIdentifier": BUNDLE_ID,
            "HealthBridgeICloudContainerIdentifier": CONTAINER_ID,
        },
        sort_keys=True,
    )
    members = {
        f"{HELPER_APP_NAME}/Contents/Info.plist": info,
        f"{HELPER_APP_NAME}/Contents/MacOS/{HELPER_EXECUTABLE_NAME}": (
            b"synthetic signed executable"
        ),
        f"{HELPER_APP_NAME}/Contents/_CodeSignature/CodeResources": (
            b"synthetic signature metadata"
        ),
    }
    members.update(extra_members or {})
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in members.items():
            member = zipfile.ZipInfo(name)
            member.create_system = 3
            mode = 0o100700 if "/MacOS/" in name else 0o100600
            member.external_attr = mode << 16
            archive.writestr(member, content)
        if unsafe_member is not None:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                archive.writestr(unsafe_member, b"unsafe")


def _write_manifest(path: Path, archive: Path, **updates: object) -> None:
    payload: dict[str, object] = {
        "schema_id": "health_bridge.mailbox_ack_helper.release.v1",
        "schema_version": 1,
        "component": HELPER_COMPONENT,
        "artifact": {
            "bytes": archive.stat().st_size,
            "filename": "HealthBridgeMailboxAckPublisher-1.1.0.zip",
            "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        },
        "bundle": {
            "build": "1",
            "identifier": BUNDLE_ID,
            "icloud_container_identifier": CONTAINER_ID,
            "version": "1.1.0",
        },
        "release": {
            "commit": COMMIT,
            "tag": TAG,
            "tag_object": TAG_OBJECT,
            "tree": TREE,
        },
        "source": {
            "git_tree": SOURCE_TREE,
            "path": "macos/HealthBridgeMailboxAckPublisher",
        },
    }
    payload.update(updates)
    _ = path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _release(tmp_path: Path) -> tuple[Path, Path]:
    archive = tmp_path / "HealthBridgeMailboxAckPublisher-1.1.0.zip"
    manifest = tmp_path / "HealthBridgeMailboxAckPublisher-1.1.0.manifest.json"
    _write_archive(archive)
    _write_manifest(manifest, archive)
    return archive, manifest


def test_macos_verifier_ignores_diagnostics_after_complete_entitlements_plist(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    app = tmp_path / HELPER_APP_NAME
    info = app / "Contents/Info.plist"
    info.parent.mkdir(parents=True)
    _ = info.write_bytes(
        plistlib.dumps(
            {
                "CFBundleExecutable": HELPER_EXECUTABLE_NAME,
                "CFBundleIdentifier": BUNDLE_ID,
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.1.0",
                "CFBundleVersion": "1",
                "HealthBridgeExpectedBundleIdentifier": BUNDLE_ID,
                "HealthBridgeICloudContainerIdentifier": CONTAINER_ID,
            }
        )
    )
    entitlements = plistlib.dumps(
        {
            "com.apple.security.app-sandbox": True,
            "com.apple.developer.icloud-container-identifiers": [CONTAINER_ID],
            "com.apple.developer.ubiquity-container-identifiers": [CONTAINER_ID],
            "com.apple.developer.icloud-services": ["CloudDocuments"],
        }
    )
    responses = iter(
        (
            subprocess.CompletedProcess([], 0, b"", b""),
            subprocess.CompletedProcess(
                [],
                0,
                entitlements,
                b"Executable=/private/helper\n",
            ),
            subprocess.CompletedProcess([], 0, b"", b"flags=0x10000(runtime)\n"),
        )
    )

    def next_codesign_result(
        _arguments: list[str],
    ) -> subprocess.CompletedProcess[bytes]:
        return next(responses)

    monkeypatch.setattr(
        helper_lifecycle,
        "_run_codesign",
        next_codesign_result,
    )

    verify_macos_helper(
        app,
        bundle_identifier=BUNDLE_ID,
        bundle_version="1.1.0",
        bundle_build="1",
        icloud_container_identifier=CONTAINER_ID,
    )


def test_macos_verifier_rejects_malformed_complete_entitlements_plist(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    app = tmp_path / HELPER_APP_NAME
    info = app / "Contents/Info.plist"
    info.parent.mkdir(parents=True)
    _ = info.write_bytes(
        plistlib.dumps(
            {
                "CFBundleExecutable": HELPER_EXECUTABLE_NAME,
                "CFBundleIdentifier": BUNDLE_ID,
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.1.0",
                "CFBundleVersion": "1",
                "HealthBridgeExpectedBundleIdentifier": BUNDLE_ID,
                "HealthBridgeICloudContainerIdentifier": CONTAINER_ID,
            }
        )
    )
    malformed = b"<?xml version='1.0'?><plist><dict><key>broken</dict></plist>"
    responses = iter(
        (
            subprocess.CompletedProcess([], 0, b"", b""),
            subprocess.CompletedProcess([], 0, malformed, b""),
        )
    )

    def next_codesign_result(
        _arguments: list[str],
    ) -> subprocess.CompletedProcess[bytes]:
        return next(responses)

    monkeypatch.setattr(helper_lifecycle, "_run_codesign", next_codesign_result)

    with pytest.raises(HelperError) as raised:
        verify_macos_helper(
            app,
            bundle_identifier=BUNDLE_ID,
            bundle_version="1.1.0",
            bundle_build="1",
            icloud_container_identifier=CONTAINER_ID,
        )

    assert raised.value.code is HelperErrorCode.ENTITLEMENTS_INVALID


def _verifier(calls: list[Path]) -> PlatformVerifier:
    def verify(
        app: Path,
        *,
        bundle_identifier: str,
        bundle_version: str,
        bundle_build: str,
        icloud_container_identifier: str,
    ) -> None:
        assert bundle_identifier == BUNDLE_ID
        assert bundle_version == "1.1.0"
        assert bundle_build == "1"
        assert icloud_container_identifier == CONTAINER_ID
        assert app.name == HELPER_APP_NAME
        calls.append(app)

    return verify


@pytest.mark.parametrize(
    "unsafe_name",
    [
        "../outside",
        "/absolute",
        f"{HELPER_APP_NAME}/../../outside",
        "Other.app/Contents/Info.plist",
        f"{HELPER_APP_NAME}\\Contents\\escape",
    ],
)
def test_structural_validation_rejects_unsafe_or_extra_archive_roots(
    tmp_path: Path,
    unsafe_name: str,
) -> None:
    archive, manifest = _release(tmp_path)
    _write_archive(archive, extra_members={unsafe_name: b"unsafe"})
    _write_manifest(manifest, archive)

    with pytest.raises(HelperError) as raised:
        _ = validate_helper_release(archive, manifest)

    assert raised.value.code is HelperErrorCode.UNSAFE_ARCHIVE
    assert str(tmp_path) not in str(raised.value)


@pytest.mark.parametrize("kind", ["symlink", "duplicate", "oversized"])
def test_structural_validation_rejects_links_duplicates_and_limits(
    tmp_path: Path,
    kind: str,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    archive, manifest = _release(tmp_path)
    member = zipfile.ZipInfo(f"{HELPER_APP_NAME}/Contents/Resources/unsafe")
    member.create_system = 3
    member.external_attr = (0o120777 if kind == "symlink" else 0o100600) << 16
    if kind == "duplicate":
        member.filename = f"{HELPER_APP_NAME}/Contents/Info.plist"
    if kind == "oversized":
        monkeypatch.setattr(helper_lifecycle, "MAX_ARCHIVE_MEMBER_BYTES", 6)
    _write_archive(archive, unsafe_member=member)
    _write_manifest(manifest, archive)

    with pytest.raises(HelperError) as raised:
        _ = validate_helper_release(archive, manifest)

    assert raised.value.code is HelperErrorCode.UNSAFE_ARCHIVE


def test_validation_binds_archive_digest_bundle_and_release_source(
    tmp_path: Path,
) -> None:
    archive, manifest = _release(tmp_path)
    payload = cast("dict[str, object]", json.loads(manifest.read_text()))
    release = cast("dict[str, object]", payload["release"])
    release["commit"] = "f" * 40
    _ = manifest.write_text(json.dumps(payload), encoding="utf-8")

    with pytest.raises(HelperError) as raised:
        _ = validate_helper_release(
            archive,
            manifest,
            expected_release=(TAG, TAG_OBJECT, COMMIT, TREE),
            expected_source_tree=SOURCE_TREE,
        )

    assert raised.value.code is HelperErrorCode.SOURCE_MISMATCH


def test_validation_can_bind_helper_to_installed_receiver_version(
    tmp_path: Path,
) -> None:
    archive, manifest = _release(tmp_path)

    with pytest.raises(HelperError) as raised:
        _ = validate_helper_release(
            archive,
            manifest,
            expected_version="1.2.0",
        )

    assert raised.value.code is HelperErrorCode.SOURCE_MISMATCH


def test_install_is_private_verified_atomic_and_idempotent(tmp_path: Path) -> None:
    archive, manifest = _release(tmp_path)
    home = tmp_path / "synthetic-home"
    home.mkdir(mode=0o700)
    calls: list[Path] = []

    first = install_helper(
        archive,
        manifest,
        home=home,
        platform="darwin",
        verifier=_verifier(calls),
    )
    second = install_helper(
        archive,
        manifest,
        home=home,
        platform="darwin",
        verifier=_verifier(calls),
    )

    paths = HelperPaths.production(home)
    assert first.code is HelperStatusCode.INSTALLED
    assert second.code is HelperStatusCode.ALREADY_INSTALLED
    assert paths.app.is_dir()
    assert paths.ownership.is_file()
    assert paths.manifest.is_file()
    assert paths.helpers_dir.stat().st_mode & 0o077 == 0
    assert paths.ownership.stat().st_mode & 0o077 == 0
    assert len(calls) >= 2


def test_install_uses_one_validated_archive_and_manifest_snapshot(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    archive, manifest = _release(tmp_path)
    original_manifest = manifest.read_bytes()
    home = tmp_path / "synthetic-home"
    home.mkdir(mode=0o700)
    original_validate_members = cast(
        "Callable[[zipfile.ZipFile], tuple[zipfile.ZipInfo, ...]]",
        helper_lifecycle.__dict__["_validate_archive_members"],
    )
    calls = 0

    def replace_inputs_after_snapshot(
        package: zipfile.ZipFile,
    ) -> tuple[zipfile.ZipInfo, ...]:
        nonlocal calls
        calls += 1
        members = original_validate_members(package)
        if calls == 1:
            _ = archive.replace(tmp_path / "validated-archive.zip")
            _ = archive.write_bytes(b"replacement archive bytes")
            _ = manifest.replace(tmp_path / "validated-manifest.json")
            _ = manifest.write_text("{}", encoding="utf-8")
        return members

    monkeypatch.setattr(
        helper_lifecycle,
        "_validate_archive_members",
        replace_inputs_after_snapshot,
    )

    result = install_helper(
        archive,
        manifest,
        home=home,
        platform="darwin",
        verifier=_verifier([]),
    )

    paths = HelperPaths.production(home)
    assert result.code is HelperStatusCode.INSTALLED
    assert calls == 2
    assert paths.manifest.read_bytes() == original_manifest
    assert (
        read_helper_status(
            home=home,
            platform="darwin",
            verifier=_verifier([]),
        ).code
        is HelperStatusCode.READY
    )


def test_already_installed_uses_validated_manifest_snapshot(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    archive, manifest = _release(tmp_path)
    home = tmp_path / "synthetic-home"
    verifier = _verifier([])
    _ = install_helper(
        archive,
        manifest,
        home=home,
        platform="darwin",
        verifier=verifier,
    )
    original_status = helper_lifecycle.read_helper_status
    replaced = False

    def replace_manifest_after_validation(
        *,
        home: Path | None = None,
        platform: str | None = None,
        verifier: PlatformVerifier | None = None,
    ) -> object:
        nonlocal replaced
        if not replaced:
            replaced = True
            _ = manifest.replace(tmp_path / "validated-idempotent-manifest.json")
            _ = manifest.write_text("{}", encoding="utf-8")
        return original_status(home=home, platform=platform, verifier=verifier)

    monkeypatch.setattr(
        helper_lifecycle,
        "read_helper_status",
        replace_manifest_after_validation,
    )

    result = install_helper(
        archive,
        manifest,
        home=home,
        platform="darwin",
        verifier=verifier,
    )

    assert replaced is True
    assert result.code is HelperStatusCode.ALREADY_INSTALLED


def test_install_activation_failure_leaves_no_partial_generation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    archive, manifest = _release(tmp_path)
    home = tmp_path / "synthetic-home"
    home.mkdir(mode=0o700)

    activation_failure = "synthetic activation failure"

    def fail_activation(*_args: object, **_kwargs: object) -> None:
        raise OSError(activation_failure)

    monkeypatch.setattr(helper_lifecycle, "exclusive_rename", fail_activation)

    with pytest.raises(HelperError) as raised:
        _ = install_helper(
            archive,
            manifest,
            home=home,
            platform="darwin",
            verifier=_verifier([]),
        )

    paths = HelperPaths.production(home)
    assert raised.value.code is HelperErrorCode.UNSAFE_FILESYSTEM
    assert not paths.helpers_dir.exists()
    assert list(paths.helpers_dir.parent.glob(".helpers-stage-*")) == []


def test_uninstall_activation_failure_preserves_complete_ready_generation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    archive, manifest = _release(tmp_path)
    home = tmp_path / "synthetic-home"
    verifier = _verifier([])
    _ = install_helper(
        archive,
        manifest,
        home=home,
        platform="darwin",
        verifier=verifier,
    )

    retirement_failure = "synthetic retirement failure"

    def fail_retirement(*_args: object, **_kwargs: object) -> None:
        raise OSError(retirement_failure)

    monkeypatch.setattr(helper_lifecycle, "exclusive_rename", fail_retirement)

    with pytest.raises(HelperError) as raised:
        _ = uninstall_helper(
            home=home,
            platform="darwin",
            verifier=verifier,
        )

    paths = HelperPaths.production(home)
    status = read_helper_status(home=home, platform="darwin", verifier=verifier)
    assert raised.value.code is HelperErrorCode.UNSAFE_FILESYSTEM
    assert status.code is HelperStatusCode.READY
    assert paths.app.is_dir()
    assert paths.manifest.is_file()
    assert paths.ownership.is_file()


def test_uninstall_race_never_deletes_replacement_generation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    archive, manifest = _release(tmp_path)
    home = tmp_path / "synthetic-home"
    verifier = _verifier([])
    _ = install_helper(
        archive,
        manifest,
        home=home,
        platform="darwin",
        verifier=verifier,
    )
    paths = HelperPaths.production(home)
    saved_generation = paths.helpers_dir.with_name("saved-owned-generation")
    original_rename = cast(
        "Callable[[int, str, int, str], None]",
        helper_lifecycle.__dict__["exclusive_rename"],
    )
    raced = False

    def replace_before_retirement(
        source_fd: int,
        source_name: str,
        destination_fd: int,
        destination_name: str,
    ) -> None:
        nonlocal raced
        if source_name == paths.helpers_dir.name and not raced:
            raced = True
            _ = paths.helpers_dir.replace(saved_generation)
            paths.helpers_dir.mkdir(mode=0o700)
            foreign = paths.helpers_dir / "foreign.txt"
            _ = foreign.write_text("foreign replacement", encoding="utf-8")
            foreign.chmod(0o600)
        original_rename(source_fd, source_name, destination_fd, destination_name)

    monkeypatch.setattr(helper_lifecycle, "exclusive_rename", replace_before_retirement)

    with pytest.raises(HelperError) as raised:
        _ = uninstall_helper(
            home=home,
            platform="darwin",
            verifier=verifier,
        )

    retired = list(paths.helpers_dir.parent.glob(".helpers-retired-*"))
    assert raised.value.code is HelperErrorCode.HELPER_DRIFT
    assert raced is True
    assert not paths.helpers_dir.exists()
    assert saved_generation.is_dir()
    assert len(retired) == 1
    assert (retired[0] / "foreign.txt").read_text(encoding="utf-8") == (
        "foreign replacement"
    )


def test_install_refuses_foreign_target_without_overwrite(tmp_path: Path) -> None:
    archive, manifest = _release(tmp_path)
    home = tmp_path / "synthetic-home"
    paths = HelperPaths.production(home)
    paths.app.mkdir(parents=True)
    foreign = paths.app / "foreign.txt"
    _ = foreign.write_text("foreign synthetic content", encoding="utf-8")

    with pytest.raises(HelperError) as raised:
        _ = install_helper(
            archive,
            manifest,
            home=home,
            platform="darwin",
            verifier=_verifier([]),
        )

    assert raised.value.code is HelperErrorCode.FOREIGN_HELPER
    assert foreign.read_text(encoding="utf-8") == "foreign synthetic content"


def test_status_and_uninstall_refuse_drifted_owned_generation(tmp_path: Path) -> None:
    archive, manifest = _release(tmp_path)
    home = tmp_path / "synthetic-home"
    verifier = _verifier([])
    _ = install_helper(
        archive,
        manifest,
        home=home,
        platform="darwin",
        verifier=verifier,
    )
    paths = HelperPaths.production(home)
    executable = paths.app / "Contents/MacOS" / HELPER_EXECUTABLE_NAME
    _ = executable.write_bytes(b"drifted synthetic executable")

    status = read_helper_status(
        home=home,
        platform="darwin",
        verifier=verifier,
    )
    with pytest.raises(HelperError) as raised:
        _ = uninstall_helper(
            home=home,
            platform="darwin",
            verifier=verifier,
        )

    assert status.code is HelperStatusCode.HELPER_DRIFT
    assert raised.value.code is HelperErrorCode.HELPER_DRIFT
    assert paths.app.is_dir()
    assert executable.read_bytes() == b"drifted synthetic executable"


def test_uninstall_retires_only_exact_owned_generation(tmp_path: Path) -> None:
    archive, manifest = _release(tmp_path)
    home = tmp_path / "synthetic-home"
    verifier = _verifier([])
    _ = install_helper(
        archive,
        manifest,
        home=home,
        platform="darwin",
        verifier=verifier,
    )

    result = uninstall_helper(
        home=home,
        platform="darwin",
        verifier=verifier,
    )
    repeated = uninstall_helper(
        home=home,
        platform="darwin",
        verifier=verifier,
    )

    paths = HelperPaths.production(home)
    retired = list(paths.helpers_dir.parent.glob(".helpers-retired-*"))
    assert result.code is HelperStatusCode.UNINSTALLED
    assert repeated.code is HelperStatusCode.ALREADY_UNINSTALLED
    assert not paths.app.exists()
    assert not paths.manifest.exists()
    assert not paths.ownership.exists()
    assert len(retired) == 1
    assert (retired[0] / HELPER_APP_NAME).is_dir()
    assert (retired[0] / helper_lifecycle.HELPER_MANIFEST_NAME).is_file()
    assert (retired[0] / helper_lifecycle.HELPER_OWNERSHIP_NAME).is_file()


def test_install_fails_closed_off_macos(tmp_path: Path) -> None:
    archive, manifest = _release(tmp_path)
    home = tmp_path / "synthetic-home"
    home.mkdir(mode=0o700)

    with pytest.raises(HelperError) as raised:
        _ = install_helper(archive, manifest, home=home, platform="linux")

    assert raised.value.code is HelperErrorCode.UNSUPPORTED_HOST


def test_uninstall_fails_closed_off_macos(tmp_path: Path) -> None:
    home = tmp_path / "synthetic-home"
    home.mkdir(mode=0o700)

    with pytest.raises(HelperError) as raised:
        _ = uninstall_helper(home=home, platform="linux")

    assert raised.value.code is HelperErrorCode.UNSUPPORTED_HOST


def test_helper_cli_exposes_explicit_lifecycle_and_structural_verify(
    tmp_path: Path,
) -> None:
    archive, manifest = _release(tmp_path)

    help_result = CliRunner().invoke(app, ["mailbox", "helper", "--help"])
    verified = CliRunner().invoke(
        app,
        [
            "mailbox",
            "helper",
            "verify",
            "--archive",
            str(archive),
            "--manifest",
            str(manifest),
            "--json",
        ],
    )

    assert help_result.exit_code == 0
    for command in ("install", "status", "uninstall", "verify"):
        assert command in help_result.stdout
    assert verified.exit_code == 0
    assert json.loads(verified.stdout) == {"code": "valid"}
    assert str(tmp_path) not in verified.output


def test_helper_cli_mutation_error_is_fixed_and_private_off_macos(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    archive, manifest = _release(tmp_path)
    monkeypatch.setattr(sys, "platform", "linux")

    result = CliRunner().invoke(
        app,
        [
            "mailbox",
            "helper",
            "install",
            "--archive",
            str(archive),
            "--manifest",
            str(manifest),
            "--json",
        ],
    )

    assert result.exit_code == 1
    assert json.loads(result.stdout) == {"code": "unsupported_host"}
    assert str(tmp_path) not in result.output
