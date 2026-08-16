# ruff: noqa: EM101, S603, TRY003
from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import secrets
import stat
import subprocess  # nosec B404
import sys
import tempfile
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path
from typing import Final, cast, final

from health_bridge.contract._delivery_common import MAX_ENVELOPE_BYTES
from health_bridge.mailbox.filesystem import MailboxDirectoryHandle, read_final_at
from health_bridge.mailbox.helper_lifecycle import HelperError, require_ready_helper
from health_bridge.mailbox.publication import PublicationState
from health_bridge.private_files import (
    PRIVATE_FILE_MODE,
    ensure_private_directory,
    write_private_text_file,
)

PROTOCOL_VERSION: Final = 1
DEFAULT_HELPER_APP_NAME: Final = "HealthBridgeMailboxAckPublisher.app"
DEFAULT_HELPER_EXECUTABLE_NAME: Final = "HealthBridgeMailboxAckPublisher"
DEFAULT_TIMEOUT_SECONDS: Final = 90.0
OPAQUE_COMPONENT_LENGTH: Final = 32
MAX_RECEIPT_BYTES: Final = 8_192
MAX_HELPER_INFO_BYTES: Final = 65_536
MAX_BUNDLE_ID_LENGTH: Final = 255
MIN_BUNDLE_ID_COMPONENTS: Final = 2


class NativeAckPublicationError(OSError):
    """The signed native ACK helper failed or returned an invalid receipt."""


@dataclass(frozen=True, slots=True)
class NativeAckPublisherConfig:
    helper_executable: Path
    protocol_root: Path
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS

    @classmethod
    def production(cls, *, home: Path | None = None) -> NativeAckPublisherConfig:
        resolved_home = Path.home() if home is None else home
        if sys.platform == "darwin":
            try:
                require_ready_helper(resolved_home)
            except HelperError as exc:
                raise NativeAckPublicationError(
                    "native ACK helper is not ready"
                ) from exc
        app = (
            resolved_home
            / "Library/Application Support/HealthBridge/helpers"
            / DEFAULT_HELPER_APP_NAME
        )
        bundle_id = _installed_helper_bundle_id(resolved_home)
        protocol_root = (
            resolved_home
            / "Library/Containers"
            / bundle_id
            / "Data/Library/Application Support/HealthBridgeAckPublisher"
        )
        return cls(
            helper_executable=(app / "Contents/MacOS" / DEFAULT_HELPER_EXECUTABLE_NAME),
            protocol_root=protocol_root,
        )


@final
class NativeAckPublisher:
    def __init__(self, config: NativeAckPublisherConfig) -> None:
        if config.timeout_seconds <= 0:
            raise ValueError
        self._config = config

    def __call__(
        self,
        directory: MailboxDirectoryHandle,
        final_name: str,
        payload: bytes,
    ) -> PublicationState:
        receiver = directory.path.parent.name
        device = directory.path.name
        _require_opaque_component(receiver)
        _require_opaque_component(device)
        if not _valid_final_name(final_name):
            raise NativeAckPublicationError("invalid ACK filename")
        if len(payload) > MAX_ENVELOPE_BYTES:
            raise NativeAckPublicationError("ACK payload exceeds protocol limit")
        executable = self._config.helper_executable
        _require_executable(executable)
        request_id = secrets.token_hex(16)
        requests = self._config.protocol_root / "requests"
        staging = self._config.protocol_root / "staging"
        receipts = self._config.protocol_root / "receipts"
        for path in (self._config.protocol_root, requests, staging, receipts):
            ensure_private_directory(path)
            _require_owner_private_directory(path)
        source = staging / f"{request_id}.hba"
        request_path = requests / f"{request_id}.json"
        receipt_path = receipts / f"{request_id}.json"
        digest = hashlib.sha256(payload).hexdigest()
        request = {
            "version": PROTOCOL_VERSION,
            "requestID": request_id,
            "receiver": receiver,
            "device": device,
            "finalName": final_name,
            "byteCount": len(payload),
            "sha256": digest,
        }
        try:
            _write_private_bytes(source, payload)
            write_private_text_file(
                request_path,
                json.dumps(request, separators=(",", ":"), sort_keys=True),
            )
            try:
                completed = subprocess.run(  # nosec B603
                    [str(executable), request_id],
                    check=False,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=self._config.timeout_seconds,
                    close_fds=True,
                )
            except subprocess.TimeoutExpired as exc:
                raise NativeAckPublicationError("native ACK helper timed out") from exc
            if completed.returncode != 0:
                raise NativeAckPublicationError("native ACK helper failed")
            receipt = _read_receipt(receipt_path)
            expected = {
                "version": PROTOCOL_VERSION,
                "requestID": request_id,
                "receiver": receiver,
                "device": device,
                "finalName": final_name,
                "byteCount": len(payload),
                "sha256": digest,
                "published": True,
                "exactBytes": True,
                "isUbiquitous": True,
                "uploadErrorAbsent": True,
                "sourceOutsideProvider": True,
                "errorDomain": None,
                "errorCode": None,
            }
            if receipt != expected:
                raise NativeAckPublicationError("native ACK helper receipt mismatch")
            directory.validate_attached()
            final = read_final_at(
                directory.acks_fd,
                final_name,
                maximum_bytes=MAX_ENVELOPE_BYTES,
            )
            if final.content != payload:
                raise NativeAckPublicationError("published ACK content mismatch")
            directory.validate_attached()
            return PublicationState.CREATED
        finally:
            _unlink_protocol_file(receipt_path)
            _unlink_protocol_file(request_path)
            _unlink_protocol_file(source)


def default_native_ack_publisher() -> NativeAckPublisher:
    return NativeAckPublisher(NativeAckPublisherConfig.production())


def _require_opaque_component(value: str) -> None:
    if len(value) != OPAQUE_COMPONENT_LENGTH or any(
        character not in "0123456789abcdef" for character in value
    ):
        raise NativeAckPublicationError("invalid mailbox component")


def _installed_helper_bundle_id(home: Path) -> str:
    contents_descriptor = _open_owner_directory_chain(
        home,
        (
            "Library",
            "Application Support",
            "HealthBridge",
            "helpers",
            DEFAULT_HELPER_APP_NAME,
            "Contents",
        ),
    )
    try:
        raw_info = _read_owner_regular_at(
            contents_descriptor,
            "Info.plist",
            maximum_bytes=MAX_HELPER_INFO_BYTES,
        )
    finally:
        os.close(contents_descriptor)
    try:
        value = cast("object", plistlib.loads(raw_info))
    except plistlib.InvalidFileException as exc:
        raise NativeAckPublicationError(
            "native ACK helper bundle identity is unavailable"
        ) from exc
    if not isinstance(value, dict):
        raise NativeAckPublicationError("native ACK helper bundle identity is invalid")
    mapping = cast("dict[object, object]", value)
    bundle_id = mapping.get("CFBundleIdentifier")
    if (
        not isinstance(bundle_id, str)
        or len(bundle_id) > MAX_BUNDLE_ID_LENGTH
        or len(bundle_id.split(".")) < MIN_BUNDLE_ID_COMPONENTS
        or any(
            re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", component) is None
            for component in bundle_id.split(".")
        )
    ):
        raise NativeAckPublicationError("native ACK helper bundle identity is invalid")
    return bundle_id


def _open_owner_directory_chain(home: Path, components: tuple[str, ...]) -> int:
    flags = (
        os.O_RDONLY
        | _required_open_flag("O_DIRECTORY")
        | _required_open_flag("O_NOFOLLOW")
        | _required_open_flag("O_CLOEXEC")
    )
    descriptor = -1
    try:
        descriptor = os.open(home, flags)
        _require_owner_directory_descriptor(descriptor)
        for component in components:
            next_descriptor = os.open(component, flags, dir_fd=descriptor)
            try:
                _require_owner_directory_descriptor(next_descriptor)
            except Exception:
                os.close(next_descriptor)
                raise
            os.close(descriptor)
            descriptor = next_descriptor
    except OSError as exc:
        if descriptor >= 0:
            os.close(descriptor)
        raise NativeAckPublicationError(
            "native ACK helper bundle identity is unavailable"
        ) from exc
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        raise
    return descriptor


def _read_owner_regular_at(
    directory_descriptor: int,
    name: str,
    *,
    maximum_bytes: int,
) -> bytes:
    flags = (
        os.O_RDONLY
        | _required_open_flag("O_NOFOLLOW")
        | _required_open_flag("O_CLOEXEC")
    )
    descriptor = -1
    try:
        descriptor = os.open(name, flags, dir_fd=directory_descriptor)
        initial = os.fstat(descriptor)
        if (
            not stat.S_ISREG(initial.st_mode)
            or initial.st_uid != os.geteuid()
            or initial.st_size > maximum_bytes
        ):
            raise NativeAckPublicationError(
                "native ACK helper bundle identity is unsafe"
            )
        content = bytearray()
        while len(content) <= maximum_bytes:
            chunk = os.read(descriptor, min(16_384, maximum_bytes + 1))
            if not chunk:
                break
            content.extend(chunk)
        final = os.fstat(descriptor)
        if len(content) > maximum_bytes or (
            initial.st_dev,
            initial.st_ino,
            initial.st_size,
            initial.st_mtime_ns,
            initial.st_ctime_ns,
        ) != (
            final.st_dev,
            final.st_ino,
            final.st_size,
            final.st_mtime_ns,
            final.st_ctime_ns,
        ):
            raise NativeAckPublicationError(
                "native ACK helper bundle identity is unsafe"
            )
        return bytes(content)
    except OSError as exc:
        raise NativeAckPublicationError(
            "native ACK helper bundle identity is unavailable"
        ) from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _required_open_flag(name: str) -> int:
    value = getattr(os, name, None)
    if not isinstance(value, int) or value == 0:
        raise NativeAckPublicationError("native ACK helper path safety unavailable")
    return value


def _require_owner_directory_descriptor(descriptor: int) -> None:
    result = os.fstat(descriptor)
    if not stat.S_ISDIR(result.st_mode) or result.st_uid != os.geteuid():
        raise NativeAckPublicationError("native ACK helper bundle identity is unsafe")


def _valid_final_name(value: str) -> bool:
    stem, separator, suffix = value.partition(".")
    return (
        separator == "."
        and suffix == "hba"
        and len(stem) == OPAQUE_COMPONENT_LENGTH
        and all(character in "0123456789abcdef" for character in stem)
    )


def _require_executable(path: Path) -> None:
    try:
        result = path.lstat()
    except OSError as exc:
        raise NativeAckPublicationError("native ACK helper unavailable") from exc
    if (
        not stat.S_ISREG(result.st_mode)
        or stat.S_ISLNK(result.st_mode)
        or result.st_uid != os.geteuid()
        or not os.access(path, os.X_OK)
    ):
        raise NativeAckPublicationError("native ACK helper is unsafe")


def _require_owner_private_directory(path: Path) -> None:
    result = path.lstat()
    if (
        not stat.S_ISDIR(result.st_mode)
        or stat.S_ISLNK(result.st_mode)
        or result.st_uid != os.geteuid()
        or bool(result.st_mode & 0o077)
    ):
        raise NativeAckPublicationError("native ACK protocol directory is unsafe")


def _write_private_bytes(path: Path, content: bytes) -> None:
    descriptor = -1
    temporary: Path | None = None
    try:
        descriptor, raw_path = tempfile.mkstemp(
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
        )
        temporary = Path(raw_path)
        os.fchmod(descriptor, PRIVATE_FILE_MODE)
        with os.fdopen(descriptor, "wb") as output:
            descriptor = -1
            _ = output.write(content)
            output.flush()
            os.fsync(output.fileno())
        if path.exists() or path.is_symlink():
            raise NativeAckPublicationError("native ACK protocol collision")
        _ = temporary.replace(path)
        temporary = None
        path.chmod(PRIVATE_FILE_MODE)
        directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _read_receipt(path: Path) -> dict[str, object]:
    result = path.lstat()
    if (
        not stat.S_ISREG(result.st_mode)
        or stat.S_ISLNK(result.st_mode)
        or result.st_uid != os.geteuid()
        or bool(result.st_mode & 0o077)
        or result.st_size > MAX_RECEIPT_BYTES
    ):
        raise NativeAckPublicationError("native ACK helper receipt is unsafe")
    try:
        value = cast("object", json.loads(path.read_text(encoding="utf-8")))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise NativeAckPublicationError("native ACK helper receipt is invalid") from exc
    if not isinstance(value, dict):
        raise NativeAckPublicationError("native ACK helper receipt is invalid")
    mapping = cast("dict[object, object]", value)
    if not all(isinstance(key, str) for key in mapping):
        raise NativeAckPublicationError("native ACK helper receipt is invalid")
    return {cast("str", key): item for key, item in mapping.items()}


def _unlink_protocol_file(path: Path) -> None:
    with suppress(OSError):
        path.unlink(missing_ok=True)
