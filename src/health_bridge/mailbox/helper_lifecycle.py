from __future__ import annotations

import hashlib
import io
import os
import plistlib
import re
import shutil
import stat
import subprocess  # nosec B404
import sys
import tempfile
import unicodedata
import zipfile
from contextlib import suppress
from dataclasses import dataclass
from enum import StrEnum, unique
from pathlib import Path, PurePosixPath
from typing import Final, Protocol, cast

from pydantic import ValidationError

from health_bridge import __version__
from health_bridge.launchd.exclusive_rename import exclusive_rename
from health_bridge.launchd.models import LaunchdServiceError
from health_bridge.mailbox.helper_distribution_contract import (
    HELPER_COMPONENT as _HELPER_COMPONENT,
)
from health_bridge.mailbox.helper_distribution_contract import (
    HELPER_RELEASE_MANIFEST_ADAPTER,
    ExactModel,
    HelperReleaseManifest,
    require_approved_helper_distribution,
)
from health_bridge.mailbox.helper_distribution_contract import (
    HELPER_SOURCE_PATH as DISTRIBUTION_HELPER_SOURCE_PATH,
)
from health_bridge.mailbox.helper_distribution_contract import (
    HelperError as _HelperError,
)
from health_bridge.mailbox.helper_distribution_contract import (
    HelperErrorCode as _HelperErrorCode,
)
from health_bridge.mailbox.helper_distribution_contract import (
    HelperOwnership as _HelperOwnership,
)
from health_bridge.mailbox.helper_distribution_verifier import (
    DistributionVerificationRequest,
    LegacyVerificationRequest,
    verify_general_distribution,
    verify_legacy_signature,
    verify_release_distribution,
)
from health_bridge.private_files import ensure_private_directory

HELPER_COMPONENT: Final = _HELPER_COMPONENT
HelperError = _HelperError
HelperErrorCode = _HelperErrorCode
HelperOwnership = _HelperOwnership
HELPER_APP_NAME: Final = f"{HELPER_COMPONENT}.app"
HELPER_EXECUTABLE_NAME: Final = HELPER_COMPONENT
HELPER_SOURCE_PATH: Final = DISTRIBUTION_HELPER_SOURCE_PATH
HELPER_RELATIVE_DIR: Final = Path("Library/Application Support/HealthBridge/helpers")
HELPER_MANIFEST_NAME: Final = f"{HELPER_COMPONENT}.manifest.json"
HELPER_OWNERSHIP_NAME: Final = f".{HELPER_COMPONENT}.ownership.json"
MAX_ARCHIVE_BYTES: Final = 128 * 1024 * 1024
MAX_ARCHIVE_MEMBERS: Final = 512
MAX_ARCHIVE_MEMBER_BYTES: Final = 64 * 1024 * 1024
MAX_ARCHIVE_TOTAL_BYTES: Final = 128 * 1024 * 1024
MAX_MANIFEST_BYTES: Final = 64 * 1024
MAX_PLIST_BYTES: Final = 64 * 1024
MAX_CODESIGN_OUTPUT_BYTES: Final = 1024 * 1024
_CODESIGN_TIMEOUT_SECONDS: Final = 30.0
_SHA256_LENGTH: Final = 64
_GIT_SHA_LENGTH: Final = 40
_LEGACY_V1_INSTALL_VERSIONS: Final = frozenset({"1.1.0"})


@unique
class HelperStatusCode(StrEnum):
    READY = "ready"
    INSTALLED = "installed"
    ALREADY_INSTALLED = "already_installed"
    NOT_INSTALLED = "not_installed"
    FOREIGN_HELPER = "foreign_helper"
    HELPER_DRIFT = "helper_drift"
    UNSUPPORTED_HOST = "unsupported_host"
    UNINSTALLED = "uninstalled"
    ALREADY_UNINSTALLED = "already_uninstalled"
    VALID = "valid"


class HelperResult(ExactModel):
    code: HelperStatusCode


@dataclass(frozen=True, slots=True)
class HelperPaths:
    helpers_dir: Path
    app: Path
    manifest: Path
    ownership: Path

    @classmethod
    def production(cls, home: Path | None = None) -> HelperPaths:
        root = Path.home() if home is None else home
        helpers = root / HELPER_RELATIVE_DIR
        return cls(
            helpers_dir=helpers,
            app=helpers / HELPER_APP_NAME,
            manifest=helpers / HELPER_MANIFEST_NAME,
            ownership=helpers / HELPER_OWNERSHIP_NAME,
        )


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


def _validate_helper_release_snapshot(
    archive: Path,
    manifest_path: Path,
    *,
    expected_release: tuple[str, str, str, str] | None = None,
    expected_source_tree: str | None = None,
    expected_version: str | None = None,
) -> tuple[HelperReleaseManifest, bytes, bytes]:
    raw_manifest = _read_regular_bounded(manifest_path, MAX_MANIFEST_BYTES)
    raw_archive = _read_regular_bounded(archive, MAX_ARCHIVE_BYTES)
    try:
        manifest = HELPER_RELEASE_MANIFEST_ADAPTER.validate_json(raw_manifest)
    except ValidationError as exc:
        raise HelperError(HelperErrorCode.INVALID_MANIFEST) from exc
    _validate_manifest_scalars(manifest)
    raw_archive_digest = hashlib.sha256(raw_archive).hexdigest()
    archive_size = len(raw_archive)
    if (
        manifest.artifact.filename != archive.name
        or manifest.artifact.sha256 != raw_archive_digest
        or manifest.artifact.bytes != archive_size
    ):
        raise HelperError(HelperErrorCode.ARTIFACT_MISMATCH)
    if expected_release is not None:
        actual = (
            manifest.release.tag,
            manifest.release.tag_object,
            manifest.release.commit,
            manifest.release.tree,
        )
        if actual != expected_release:
            raise HelperError(HelperErrorCode.SOURCE_MISMATCH)
    if (
        expected_source_tree is not None
        and manifest.source.git_tree != expected_source_tree
    ):
        raise HelperError(HelperErrorCode.SOURCE_MISMATCH)
    if expected_version is not None and manifest.bundle.version != expected_version:
        raise HelperError(HelperErrorCode.SOURCE_MISMATCH)
    with _open_zip_bytes(raw_archive) as package:
        members = _validate_archive_members(package)
        _validate_archived_bundle(package, members, manifest)
    return manifest, raw_archive, raw_manifest


def validate_helper_release(
    archive: Path,
    manifest_path: Path,
    *,
    expected_release: tuple[str, str, str, str] | None = None,
    expected_source_tree: str | None = None,
    expected_version: str | None = None,
) -> HelperReleaseManifest:
    manifest, _, _ = _validate_helper_release_snapshot(
        archive,
        manifest_path,
        expected_release=expected_release,
        expected_source_tree=expected_source_tree,
        expected_version=expected_version,
    )
    return manifest


def validate_general_distribution_helper_release(
    archive: Path,
    manifest_path: Path,
    *,
    expected_release: tuple[str, str, str, str] | None = None,
    expected_source_tree: str | None = None,
    expected_version: str | None = None,
) -> HelperReleaseManifest:
    manifest, _, _ = _validate_helper_release_snapshot(
        archive,
        manifest_path,
        expected_release=expected_release,
        expected_source_tree=expected_source_tree,
        expected_version=expected_version,
    )
    _require_approved_manifest_distribution(manifest)
    return manifest


def install_helper(
    archive: Path,
    manifest_path: Path,
    *,
    home: Path | None = None,
    platform: str | None = None,
    verifier: PlatformVerifier | None = None,
) -> HelperResult:
    _require_macos(platform)
    manifest, raw_archive, raw_manifest = _validate_helper_release_snapshot(
        archive,
        manifest_path,
        expected_version=__version__,
    )
    if manifest.distribution_identity is None:
        if __version__ not in _LEGACY_V1_INSTALL_VERSIONS:
            raise HelperError(HelperErrorCode.INVALID_MANIFEST)
    else:
        _require_approved_manifest_distribution(manifest)
    paths = HelperPaths.production(home)
    existing = _entry_presence(paths)
    selected_verifier = verifier
    if any(existing):
        status = read_helper_status(
            home=home,
            platform="darwin",
            verifier=selected_verifier,
        )
        if status.code is HelperStatusCode.READY and _installed_matches_release(
            paths,
            raw_manifest,
            manifest,
        ):
            return HelperResult(code=HelperStatusCode.ALREADY_INSTALLED)
        raise HelperError(HelperErrorCode.FOREIGN_HELPER)
    try:
        ensure_private_directory(paths.helpers_dir.parent)
        _require_private_directory(paths.helpers_dir.parent)
        staging = Path(
            tempfile.mkdtemp(prefix=".helpers-stage-", dir=paths.helpers_dir.parent)
        )
        staging.chmod(0o700)
        try:
            staged_app = staging / HELPER_APP_NAME
            with _open_zip_bytes(raw_archive) as package:
                members = _validate_archive_members(package)
                _extract_archive(package, members, staging)
            _verify_staged_app(staged_app, manifest, selected_verifier)
            app_digest = _tree_digest(staged_app)
            staged_manifest = staging / HELPER_MANIFEST_NAME
            _write_new_private(staged_manifest, raw_manifest)
            ownership = HelperOwnership(
                schema_id="health_bridge.mailbox_ack_helper.ownership.v1",
                schema_version=1,
                app_tree_sha256=app_digest,
                artifact_sha256=manifest.artifact.sha256,
                manifest_sha256=hashlib.sha256(raw_manifest).hexdigest(),
                release_commit=manifest.release.commit,
                source_git_tree=manifest.source.git_tree,
            )
            staged_ownership = staging / HELPER_OWNERSHIP_NAME
            _write_new_private(
                staged_ownership,
                (ownership.model_dump_json() + "\n").encode(),
            )
            _activate_generation(staging, paths)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
    except HelperError:
        raise
    except (OSError, zipfile.BadZipFile, LaunchdServiceError) as exc:
        raise HelperError(HelperErrorCode.UNSAFE_FILESYSTEM) from exc
    return HelperResult(code=HelperStatusCode.INSTALLED)


def read_helper_status(
    *,
    home: Path | None = None,
    platform: str | None = None,
    verifier: PlatformVerifier | None = None,
) -> HelperResult:
    if (sys.platform if platform is None else platform) != "darwin":
        return HelperResult(code=HelperStatusCode.UNSUPPORTED_HOST)
    paths = HelperPaths.production(home)
    present = _entry_presence(paths)
    if not any(present):
        return HelperResult(code=HelperStatusCode.NOT_INSTALLED)
    if not all(present):
        return HelperResult(code=HelperStatusCode.FOREIGN_HELPER)
    try:
        _require_private_directory(paths.helpers_dir)
        _require_private_regular(paths.manifest)
        _require_private_regular(paths.ownership)
        raw_manifest = _read_regular_bounded(paths.manifest, MAX_MANIFEST_BYTES)
        raw_ownership = _read_regular_bounded(paths.ownership, MAX_MANIFEST_BYTES)
        manifest = HELPER_RELEASE_MANIFEST_ADAPTER.validate_json(raw_manifest)
        ownership = HelperOwnership.model_validate_json(raw_ownership)
        _validate_manifest_scalars(manifest)
        if manifest.distribution_identity is not None:
            _require_approved_manifest_distribution(manifest)
        manifest_is_supported = (
            manifest.distribution_identity is not None
            or __version__ in _LEGACY_V1_INSTALL_VERSIONS
        )
        if manifest_is_supported:
            if (
                hashlib.sha256(raw_manifest).hexdigest() != ownership.manifest_sha256
                or manifest.artifact.sha256 != ownership.artifact_sha256
                or manifest.release.commit != ownership.release_commit
                or manifest.source.git_tree != ownership.source_git_tree
                or _tree_digest(paths.app) != ownership.app_tree_sha256
            ):
                return HelperResult(code=HelperStatusCode.HELPER_DRIFT)
            _verify_staged_app(paths.app, manifest, verifier)
    except (HelperError, OSError, ValidationError):
        return HelperResult(code=HelperStatusCode.HELPER_DRIFT)
    return HelperResult(
        code=(
            HelperStatusCode.READY
            if manifest_is_supported
            else HelperStatusCode.HELPER_DRIFT
        )
    )


def require_ready_helper(
    home: Path | None = None,
    *,
    verifier: PlatformVerifier | None = None,
) -> None:
    status = read_helper_status(home=home, platform="darwin", verifier=verifier)
    if status.code is HelperStatusCode.READY:
        return
    if status.code is HelperStatusCode.NOT_INSTALLED:
        raise HelperError(HelperErrorCode.FOREIGN_HELPER)
    raise HelperError(HelperErrorCode.HELPER_DRIFT)


def uninstall_helper(
    *,
    home: Path | None = None,
    platform: str | None = None,
    verifier: PlatformVerifier | None = None,
) -> HelperResult:
    _require_macos(platform)
    paths = HelperPaths.production(home)
    if not any(_entry_presence(paths)):
        return HelperResult(code=HelperStatusCode.ALREADY_UNINSTALLED)
    verified_identity = _directory_identity(paths.helpers_dir)
    status = read_helper_status(
        home=home,
        platform="darwin",
        verifier=verifier,
    )
    if status.code is not HelperStatusCode.READY:
        code = (
            HelperErrorCode.HELPER_DRIFT
            if status.code is HelperStatusCode.HELPER_DRIFT
            else HelperErrorCode.FOREIGN_HELPER
        )
        raise HelperError(code)
    if _directory_identity(paths.helpers_dir) != verified_identity:
        raise HelperError(HelperErrorCode.HELPER_DRIFT)
    retirement = paths.helpers_dir.with_name(
        f".helpers-retired-{os.getpid()}-{os.urandom(8).hex()}"
    )
    try:
        parent_fd = os.open(
            paths.helpers_dir.parent,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
        )
        try:
            exclusive_rename(
                parent_fd,
                paths.helpers_dir.name,
                parent_fd,
                retirement.name,
            )
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
    except (OSError, LaunchdServiceError) as exc:
        raise HelperError(HelperErrorCode.UNSAFE_FILESYSTEM) from exc
    try:
        retired_identity = _directory_identity(retirement)
    except OSError as exc:
        raise HelperError(HelperErrorCode.UNSAFE_FILESYSTEM) from exc
    if retired_identity != verified_identity:
        raise HelperError(HelperErrorCode.HELPER_DRIFT)
    return HelperResult(code=HelperStatusCode.UNINSTALLED)


def verify_macos_helper(
    app: Path,
    *,
    bundle_identifier: str,
    bundle_version: str,
    bundle_build: str,
    icloud_container_identifier: str,
) -> None:
    _validate_bundle_info(
        _read_regular_bounded(app / "Contents/Info.plist", MAX_PLIST_BYTES),
        bundle_identifier=bundle_identifier,
        bundle_version=bundle_version,
        bundle_build=bundle_build,
        icloud_container_identifier=icloud_container_identifier,
    )
    verify_legacy_signature(
        LegacyVerificationRequest(
            app=app,
            bundle_identifier=bundle_identifier,
            icloud_container_identifier=icloud_container_identifier,
        ),
        _run_codesign,
    )


def verify_macos_distribution(request: DistributionVerificationRequest) -> None:
    _validate_distribution_bundle(request)
    verify_general_distribution(request, _run_codesign, _run_platform_command)


def verify_macos_release_distribution(
    request: DistributionVerificationRequest,
) -> None:
    _validate_distribution_bundle(request)
    verify_release_distribution(request, _run_codesign, _run_platform_command)


def _validate_distribution_bundle(request: DistributionVerificationRequest) -> None:
    _validate_bundle_info(
        _read_regular_bounded(request.app / "Contents/Info.plist", MAX_PLIST_BYTES),
        bundle_identifier=request.bundle_identifier,
        bundle_version=request.bundle_version,
        bundle_build=request.bundle_build,
        icloud_container_identifier=request.icloud_container_identifier,
    )


def _run_codesign(arguments: list[str]) -> subprocess.CompletedProcess[bytes]:
    return _run_bounded_command(["/usr/bin/codesign", *arguments])


def _run_platform_command(arguments: list[str]) -> subprocess.CompletedProcess[bytes]:
    return _run_bounded_command(arguments)


def _run_bounded_command(arguments: list[str]) -> subprocess.CompletedProcess[bytes]:
    try:
        completed = subprocess.run(  # noqa: S603  # nosec B603
            arguments,
            check=False,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=_CODESIGN_TIMEOUT_SECONDS,
            close_fds=True,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise HelperError(HelperErrorCode.SIGNATURE_INVALID) from exc
    if (
        len(completed.stdout) > MAX_CODESIGN_OUTPUT_BYTES
        or len(completed.stderr) > MAX_CODESIGN_OUTPUT_BYTES
    ):
        raise HelperError(HelperErrorCode.SIGNATURE_INVALID)
    return completed


def _validate_manifest_scalars(manifest: HelperReleaseManifest) -> None:
    values = (
        manifest.artifact.sha256,
        manifest.release.tag_object,
        manifest.release.commit,
        manifest.release.tree,
        manifest.source.git_tree,
    )
    if (
        not _is_lower_hex(values[0], _SHA256_LENGTH)
        or any(not _is_lower_hex(value, _GIT_SHA_LENGTH) for value in values[1:])
        or manifest.artifact.bytes < 1
        or manifest.artifact.bytes > MAX_ARCHIVE_BYTES
        or Path(manifest.artifact.filename).name != manifest.artifact.filename
        or manifest.artifact.filename
        != f"{HELPER_COMPONENT}-{manifest.bundle.version}.zip"
        or manifest.release.tag != f"receiver-v{manifest.bundle.version}"
        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{1,254}", manifest.bundle.identifier)
        is None
        or re.fullmatch(
            r"iCloud\.[A-Za-z0-9][A-Za-z0-9.-]{1,254}",
            manifest.bundle.icloud_container_identifier,
        )
        is None
        or re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", manifest.bundle.version) is None
        or not manifest.bundle.build.isdecimal()
    ):
        raise HelperError(HelperErrorCode.INVALID_MANIFEST)
    distribution = manifest.distribution_identity
    if distribution is None:
        return
    profile = distribution.provisioning_profile
    team_identifier = distribution.team_identifier
    expected_application = f"{team_identifier}.{manifest.bundle.identifier}"
    expected_containers = (manifest.bundle.icloud_container_identifier,)
    authority_prefix = "Developer ID Application: "
    if (
        re.fullmatch(r"[A-Z0-9]{10}", team_identifier) is None
        or re.fullmatch(
            r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
            distribution.notarization.submission_id,
        )
        is None
        or not distribution.signing_authority.startswith(authority_prefix)
        or distribution.signing_authority == authority_prefix
        or not distribution.signing_authority.endswith(f" ({team_identifier})")
        or profile.team_identifier != team_identifier
        or profile.application_identifier != expected_application
        or profile.icloud_container_identifiers != expected_containers
        or profile.ubiquity_container_identifiers != expected_containers
    ):
        raise HelperError(HelperErrorCode.INVALID_MANIFEST)


def _is_lower_hex(value: str, length: int) -> bool:
    return len(value) == length and all(
        character in "0123456789abcdef" for character in value
    )


def _read_regular_bounded(path: Path, maximum: int) -> bytes:
    try:
        initial = path.lstat()
        if not stat.S_ISREG(initial.st_mode) or stat.S_ISLNK(initial.st_mode):
            raise HelperError(HelperErrorCode.UNSAFE_FILESYSTEM)  # noqa: TRY301
        if initial.st_size < 0 or initial.st_size > maximum:
            raise HelperError(HelperErrorCode.UNSAFE_FILESYSTEM)  # noqa: TRY301
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
        )
        try:
            opened = os.fstat(descriptor)
            if (initial.st_dev, initial.st_ino) != (opened.st_dev, opened.st_ino):
                raise HelperError(HelperErrorCode.UNSAFE_FILESYSTEM)
            chunks: list[bytes] = []
            received = 0
            while True:
                chunk = os.read(descriptor, min(64 * 1024, maximum + 1 - received))
                if not chunk:
                    break
                chunks.append(chunk)
                received += len(chunk)
                if received > maximum:
                    raise HelperError(HelperErrorCode.UNSAFE_FILESYSTEM)
            return b"".join(chunks)
        finally:
            os.close(descriptor)
    except HelperError:
        raise
    except OSError as exc:
        raise HelperError(HelperErrorCode.UNSAFE_FILESYSTEM) from exc


def _open_zip_bytes(content: bytes) -> zipfile.ZipFile:
    try:
        return zipfile.ZipFile(io.BytesIO(content), "r")
    except (OSError, zipfile.BadZipFile) as exc:
        raise HelperError(HelperErrorCode.UNSAFE_ARCHIVE) from exc


def _validate_archive_members(package: zipfile.ZipFile) -> tuple[zipfile.ZipInfo, ...]:
    members = tuple(package.infolist())
    if not members or len(members) > MAX_ARCHIVE_MEMBERS:
        raise HelperError(HelperErrorCode.UNSAFE_ARCHIVE)
    seen: set[str] = set()
    total = 0
    for member in members:
        name = member.filename
        path = PurePosixPath(name)
        canonical = unicodedata.normalize("NFC", name).casefold()
        mode = member.external_attr >> 16
        file_type = stat.S_IFMT(mode)
        is_directory = member.is_dir()
        if (
            not name
            or "\\" in name
            or name.startswith("/")
            or path.is_absolute()
            or any(part in {"", ".", ".."} for part in path.parts)
            or any(part.endswith((".", " ")) for part in path.parts)
            or path.parts[0] != HELPER_APP_NAME
            or canonical in seen
            or (file_type not in {0, stat.S_IFREG, stat.S_IFDIR})
            or (is_directory and file_type not in {0, stat.S_IFDIR})
            or (not is_directory and file_type == stat.S_IFDIR)
            or member.file_size < 0
            or member.file_size > MAX_ARCHIVE_MEMBER_BYTES
        ):
            raise HelperError(HelperErrorCode.UNSAFE_ARCHIVE)
        seen.add(canonical)
        total += member.file_size
        if total > MAX_ARCHIVE_TOTAL_BYTES:
            raise HelperError(HelperErrorCode.UNSAFE_ARCHIVE)
    required = {
        f"{HELPER_APP_NAME}/Contents/Info.plist",
        f"{HELPER_APP_NAME}/Contents/MacOS/{HELPER_EXECUTABLE_NAME}",
        f"{HELPER_APP_NAME}/Contents/_CodeSignature/CodeResources",
    }
    if not required.issubset({member.filename for member in members}):
        raise HelperError(HelperErrorCode.UNSAFE_ARCHIVE)
    return members


def _validate_archived_bundle(
    package: zipfile.ZipFile,
    members: tuple[zipfile.ZipInfo, ...],
    manifest: HelperReleaseManifest,
) -> None:
    info_name = f"{HELPER_APP_NAME}/Contents/Info.plist"
    member = next(candidate for candidate in members if candidate.filename == info_name)
    if member.file_size > MAX_PLIST_BYTES:
        raise HelperError(HelperErrorCode.UNSAFE_ARCHIVE)
    try:
        info = package.read(member)
    except (OSError, RuntimeError, zipfile.BadZipFile) as exc:
        raise HelperError(HelperErrorCode.UNSAFE_ARCHIVE) from exc
    _validate_bundle_info(
        info,
        bundle_identifier=manifest.bundle.identifier,
        bundle_version=manifest.bundle.version,
        bundle_build=manifest.bundle.build,
        icloud_container_identifier=manifest.bundle.icloud_container_identifier,
    )


def _validate_bundle_info(
    raw: bytes,
    *,
    bundle_identifier: str,
    bundle_version: str,
    bundle_build: str,
    icloud_container_identifier: str,
) -> None:
    try:
        payload = cast("object", plistlib.loads(raw))
    except plistlib.InvalidFileException as exc:
        raise HelperError(HelperErrorCode.ARTIFACT_MISMATCH) from exc
    expected = {
        "CFBundleExecutable": HELPER_EXECUTABLE_NAME,
        "CFBundleIdentifier": bundle_identifier,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": bundle_version,
        "CFBundleVersion": bundle_build,
        "HealthBridgeExpectedBundleIdentifier": bundle_identifier,
        "HealthBridgeICloudContainerIdentifier": icloud_container_identifier,
    }
    if not isinstance(payload, dict) or any(
        cast("dict[object, object]", payload).get(key) != value
        for key, value in expected.items()
    ):
        raise HelperError(HelperErrorCode.ARTIFACT_MISMATCH)


def _extract_archive(
    package: zipfile.ZipFile,
    members: tuple[zipfile.ZipInfo, ...],
    destination: Path,
) -> None:
    for member in sorted(
        members,
        key=lambda value: (len(PurePosixPath(value.filename).parts), value.filename),
    ):
        target = destination.joinpath(*PurePosixPath(member.filename).parts)
        if member.is_dir():
            _ensure_private_extract_directory(target, destination)
            continue
        _ensure_private_extract_directory(target.parent, destination)
        try:
            content = package.read(member)
        except (OSError, RuntimeError, zipfile.BadZipFile) as exc:
            raise HelperError(HelperErrorCode.UNSAFE_ARCHIVE) from exc
        if len(content) != member.file_size:
            raise HelperError(HelperErrorCode.UNSAFE_ARCHIVE)
        _write_new_private(target, content)
        archived_mode = member.external_attr >> 16
        target.chmod(0o700 if archived_mode & 0o111 else 0o600)


def _ensure_private_extract_directory(path: Path, root: Path) -> None:
    try:
        relative = path.relative_to(root)
    except ValueError as exc:
        raise HelperError(HelperErrorCode.UNSAFE_ARCHIVE) from exc
    current = root
    _require_private_directory(current)
    for component in relative.parts:
        current = current / component
        with suppress(FileExistsError):
            current.mkdir(mode=0o700)
        _require_private_directory(current)


def _write_new_private(path: Path, content: bytes) -> None:
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as output:
            _ = output.write(content)
            output.flush()
            os.fsync(output.fileno())
    finally:
        os.close(descriptor)


def _verify_staged_app(
    app: Path,
    manifest: HelperReleaseManifest,
    verifier: PlatformVerifier | None,
) -> None:
    arguments = {
        "bundle_identifier": manifest.bundle.identifier,
        "bundle_version": manifest.bundle.version,
        "bundle_build": manifest.bundle.build,
        "icloud_container_identifier": manifest.bundle.icloud_container_identifier,
    }
    if verifier is not None:
        verifier(app, **arguments)
        return
    distribution = manifest.distribution_identity
    if distribution is None:
        verify_macos_helper(app, **arguments)
        return
    _require_approved_manifest_distribution(manifest)
    verify_macos_distribution(
        DistributionVerificationRequest(
            app=app,
            bundle_identifier=manifest.bundle.identifier,
            icloud_container_identifier=manifest.bundle.icloud_container_identifier,
            bundle_version=manifest.bundle.version,
            bundle_build=manifest.bundle.build,
            distribution=distribution,
        )
    )


def _require_approved_manifest_distribution(
    manifest: HelperReleaseManifest,
) -> None:
    distribution = manifest.distribution_identity
    if distribution is None:
        raise HelperError(HelperErrorCode.INVALID_MANIFEST)
    require_approved_helper_distribution(
        signing_authority=distribution.signing_authority,
        team_identifier=distribution.team_identifier,
        bundle_identifier=manifest.bundle.identifier,
        icloud_container_identifier=manifest.bundle.icloud_container_identifier,
    )


def _tree_digest(root: Path) -> str:
    _require_private_directory(root)
    digest = hashlib.sha256()
    total = 0
    ordered = sorted(
        root.rglob("*"), key=lambda value: value.relative_to(root).as_posix()
    )
    for count, path in enumerate(ordered, start=1):
        metadata = path.lstat()
        relative = path.relative_to(root).as_posix().encode()
        if stat.S_ISLNK(metadata.st_mode) or not (
            stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)
        ):
            raise HelperError(HelperErrorCode.HELPER_DRIFT)
        if metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
            raise HelperError(HelperErrorCode.HELPER_DRIFT)
        digest.update(b"d\0" if stat.S_ISDIR(metadata.st_mode) else b"f\0")
        digest.update(relative)
        digest.update(b"\0")
        if stat.S_ISREG(metadata.st_mode):
            content = _read_regular_bounded(path, MAX_ARCHIVE_MEMBER_BYTES)
            digest.update(content)
            total += len(content)
        if count > MAX_ARCHIVE_MEMBERS or total > MAX_ARCHIVE_TOTAL_BYTES:
            raise HelperError(HelperErrorCode.HELPER_DRIFT)
    return digest.hexdigest()


def _directory_identity(path: Path) -> tuple[int, int]:
    metadata = path.lstat()
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & 0o077
    ):
        raise HelperError(HelperErrorCode.UNSAFE_FILESYSTEM)
    return metadata.st_dev, metadata.st_ino


def _entry_presence(paths: HelperPaths) -> tuple[bool, bool, bool]:
    return (
        os.path.lexists(paths.app),
        os.path.lexists(paths.manifest),
        os.path.lexists(paths.ownership),
    )


def _require_private_directory(path: Path) -> None:
    metadata = path.lstat()
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & 0o077
    ):
        raise HelperError(HelperErrorCode.UNSAFE_FILESYSTEM)


def _require_private_regular(path: Path) -> None:
    metadata = path.lstat()
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & 0o077
    ):
        raise HelperError(HelperErrorCode.UNSAFE_FILESYSTEM)


def _activate_generation(staging: Path, paths: HelperPaths) -> None:
    parent_fd = os.open(
        paths.helpers_dir.parent,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
    )
    try:
        exclusive_rename(
            parent_fd,
            staging.name,
            parent_fd,
            paths.helpers_dir.name,
        )
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def _installed_matches_release(
    paths: HelperPaths,
    supplied_manifest: bytes,
    manifest: HelperReleaseManifest,
) -> bool:
    try:
        installed = _read_regular_bounded(paths.manifest, MAX_MANIFEST_BYTES)
        ownership = HelperOwnership.model_validate_json(
            _read_regular_bounded(paths.ownership, MAX_MANIFEST_BYTES)
        )
    except (HelperError, ValidationError):
        return False
    return (
        installed == supplied_manifest
        and ownership.artifact_sha256 == manifest.artifact.sha256
        and ownership.release_commit == manifest.release.commit
        and ownership.source_git_tree == manifest.source.git_tree
    )


def _require_macos(platform: str | None) -> None:
    if (sys.platform if platform is None else platform) != "darwin":
        raise HelperError(HelperErrorCode.UNSUPPORTED_HOST)
