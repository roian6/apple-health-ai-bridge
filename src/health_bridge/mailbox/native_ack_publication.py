# ruff: noqa: EM101, S603, TRY003
from __future__ import annotations

import hashlib
import json
import math
import os
import plistlib
import re
import secrets
import selectors
import stat
import struct
import subprocess  # nosec B404
import sys
import time
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import TYPE_CHECKING, Final, cast, final

from health_bridge.contract._delivery_common import MAX_ENVELOPE_BYTES
from health_bridge.contract._hbjcs1 import hbjcs1_decode
from health_bridge.contract.mailbox_capabilities import (
    CAPABILITIES_FILENAME,
    MAX_CAPABILITIES_BYTES,
)
from health_bridge.mailbox.filesystem import (
    MailboxDirectoryHandle,
    MailboxFileError,
    read_final,
    read_final_at,
)
from health_bridge.mailbox.helper_lifecycle import HelperError, require_ready_helper
from health_bridge.mailbox.publication import PublicationState
from health_bridge.receiver.mailbox_bootstrap import (
    MAX_PAIRING_BYTES,
    PairingCancellation,
)

if TYPE_CHECKING:
    from typing import BinaryIO

PROTOCOL_VERSION: Final = 1
DEFAULT_HELPER_APP_NAME: Final = "HealthBridgeMailboxAckPublisher.app"
DEFAULT_HELPER_EXECUTABLE_NAME: Final = "HealthBridgeMailboxAckPublisher"
DEFAULT_TIMEOUT_SECONDS: Final = 90.0
OPAQUE_COMPONENT_LENGTH: Final = 32
MAX_RECEIPT_BYTES: Final = 8_192
MAX_DISCOVERY_BYTES: Final = 128
MAX_HELPER_INFO_BYTES: Final = 65_536
MAX_BUNDLE_ID_LENGTH: Final = 255
MIN_BUNDLE_ID_COMPONENTS: Final = 2
_FRAME_PREFIX_BYTES: Final = 4
_ERROR_EXIT_CODE: Final = 3
_DISCOVERY_FLAG: Final = "--publication-ipc-v1-capabilities"
_PUBLICATION_FLAG: Final = "--publication-ipc-v1"
_DISCOVERY_TOKEN: Final = (
    b"publication-ipc-v1:ack,pairing,receiver_capabilities,storage_probe\n"
)
_WIRE_ERRORS: Final = frozenset(
    {
        "invalid_request",
        "unsafe_storage",
        "storage_access_denied",
        "storage_io_failed",
        "helper_busy",
        "provider_unavailable",
        "destination_conflict",
        "publication_failed",
    }
)
_SUCCESS_FIELDS: Final[dict[str, dict[str, object]]] = {
    "ack": {
        "published": True,
        "exactBytes": True,
        "isUbiquitous": True,
        "uploadErrorAbsent": True,
        "sourceOutsideProvider": True,
        "errorDomain": None,
        "errorCode": None,
    },
    "pairing": {"published": True, "bootstrapVersion": 1},
    "receiver_capabilities": {
        "stored": True,
        "exactBytes": True,
        "isUbiquitous": True,
    },
    "storage_probe": {"storageReady": True},
}


class NativeAckPublicationError(OSError):
    """The signed native ACK helper failed or returned an invalid receipt."""


class NativePairingPublicationErrorCode(StrEnum):
    ACCESS_DENIED = "helper_container_access_denied"
    PUBLICATION_FAILED = "native_pairing_publication_failed"
    UPGRADE_REQUIRED = "native_helper_upgrade_required"


class NativePairingPublicationError(NativeAckPublicationError):
    """A fixed, privacy-safe failure at the native publication boundary."""

    def __init__(self, code: NativePairingPublicationErrorCode) -> None:
        super().__init__(code.value)
        self.code: NativePairingPublicationErrorCode = code


@dataclass(frozen=True, slots=True)
class NativeAckPublisherConfig:
    helper_executable: Path
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
        # Bundle identity remains a trust check, never a private storage address.
        _ = _installed_helper_bundle_id(resolved_home)
        return cls(
            helper_executable=app / "Contents/MacOS" / DEFAULT_HELPER_EXECUTABLE_NAME
        )


@final
class NativeAckPublisher:
    def __init__(self, config: NativeAckPublisherConfig) -> None:
        if not math.isfinite(config.timeout_seconds) or config.timeout_seconds <= 0:
            raise ValueError
        self._config = config

    def _deadline(self) -> float:
        return time.monotonic() + min(
            self._config.timeout_seconds, DEFAULT_TIMEOUT_SECONDS
        )

    def require_native_pairing(self) -> None:
        self._discover(self._deadline())

    def _discover(self, deadline: float) -> None:
        _require_executable(self._config.helper_executable)
        code, output = self._exchange(_DISCOVERY_FLAG, b"", deadline)
        if code < 0:
            raise NativePairingPublicationError(
                NativePairingPublicationErrorCode.PUBLICATION_FAILED
            )
        if code != 0 or output != _DISCOVERY_TOKEN:
            raise NativePairingPublicationError(
                NativePairingPublicationErrorCode.UPGRADE_REQUIRED
            )

    def probe_protocol_storage(self) -> None:
        """Ask the helper to test its own private storage without provider lookup."""
        self._submit({"operation": "storage_probe"}, b"", self._deadline())

    def publish_pairing(self, directory: Path, payload: bytes) -> None:
        deadline = self._deadline()
        invitation = directory.name
        _require_opaque_component(invitation)
        if not payload or len(payload) > MAX_PAIRING_BYTES:
            raise NativeAckPublicationError("invalid pairing completion size")
        final_name = "completion.hbp"
        if b'"kind":"cancelled"' in payload:
            cancellation = PairingCancellation.model_validate(hbjcs1_decode(payload))
            if (
                cancellation.kind != "cancelled"
                or cancellation.invitation_id != invitation
            ):
                raise NativeAckPublicationError("invalid cancellation receipt")
            final_name = "cancelled.hbp"
        self._submit(
            {
                "operation": "pairing",
                "invitationID": invitation,
                "finalName": final_name,
            },
            payload,
            deadline,
        )
        try:
            content = read_final(
                directory / final_name, maximum_bytes=MAX_PAIRING_BYTES
            ).content
        except (OSError, MailboxFileError) as exc:
            raise NativePairingPublicationError(
                NativePairingPublicationErrorCode.PUBLICATION_FAILED
            ) from exc
        if content != payload:
            raise NativePairingPublicationError(
                NativePairingPublicationErrorCode.PUBLICATION_FAILED
            )
        _ = _remaining(deadline)

    def publish_capabilities(
        self, directory: MailboxDirectoryHandle, payload: bytes
    ) -> None:
        """Store bounded bytes at the helper's fixed metadata target, then reread it."""
        deadline = self._deadline()
        directory.validate_attached()
        receiver, device = directory.receiver_name, directory.device_name
        _require_opaque_component(receiver)
        _require_opaque_component(device)
        if not payload or len(payload) > MAX_CAPABILITIES_BYTES:
            raise NativeAckPublicationError("invalid capability metadata size")
        self._submit(
            {
                "operation": "receiver_capabilities",
                "receiver": receiver,
                "device": device,
            },
            payload,
            deadline,
        )
        directory.validate_attached()
        final = read_final_at(
            directory.mailbox_fd,
            CAPABILITIES_FILENAME,
            maximum_bytes=MAX_CAPABILITIES_BYTES,
        )
        if final.content != payload:
            raise NativePairingPublicationError(
                NativePairingPublicationErrorCode.PUBLICATION_FAILED
            )
        directory.validate_attached()
        _ = _remaining(deadline)

    def __call__(
        self, directory: MailboxDirectoryHandle, final_name: str, payload: bytes
    ) -> PublicationState:
        deadline = self._deadline()
        directory.validate_attached()
        receiver, device = directory.receiver_name, directory.device_name
        _require_opaque_component(receiver)
        _require_opaque_component(device)
        if not _valid_final_name(final_name):
            raise NativeAckPublicationError("invalid ACK filename")
        if not payload or len(payload) > MAX_ENVELOPE_BYTES:
            raise NativeAckPublicationError("ACK payload exceeds protocol limit")
        self._submit(
            {
                "operation": "ack",
                "receiver": receiver,
                "device": device,
                "finalName": final_name,
            },
            payload,
            deadline,
        )
        directory.validate_attached()
        final = read_final_at(
            directory.acks_fd, final_name, maximum_bytes=MAX_ENVELOPE_BYTES
        )
        if final.content != payload:
            raise NativePairingPublicationError(
                NativePairingPublicationErrorCode.PUBLICATION_FAILED
            )
        directory.validate_attached()
        _ = _remaining(deadline)
        return PublicationState.CREATED

    def _submit(
        self,
        target: dict[str, object],
        payload: bytes,
        deadline: float,
    ) -> None:
        self._discover(deadline)
        request = {
            **target,
            "version": PROTOCOL_VERSION,
            "requestID": secrets.token_hex(16),
            "byteCount": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }
        metadata = _canonical_json(request)
        frame = struct.pack(">I", len(metadata)) + metadata + payload
        code, response = self._exchange(_PUBLICATION_FLAG, frame, deadline)
        _validate_response(request, code, response)
        _ = _remaining(deadline)

    def _exchange(self, flag: str, frame: bytes, deadline: float) -> tuple[int, bytes]:
        """Concurrently write and drain bounded anonymous pipes under one deadline."""
        _ = _remaining(deadline)
        try:
            # Verified executable and fixed flag only; no shell or private paths.
            with subprocess.Popen(  # nosec B603
                [str(self._config.helper_executable), flag],
                stdin=subprocess.PIPE if frame else subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                close_fds=True,
                bufsize=0,
            ) as process:
                try:
                    output = _exchange_pipes(process, frame, deadline)
                    code = process.wait(timeout=_remaining(deadline))
                    return code, output
                finally:
                    if process.poll() is None:
                        process.kill()
                    _ = process.wait()
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise NativePairingPublicationError(
                NativePairingPublicationErrorCode.PUBLICATION_FAILED
            ) from exc


def _exchange_pipes(
    process: subprocess.Popen[bytes],
    frame: bytes,
    deadline: float,
) -> bytes:
    """Pump both pipes without letting either direction block the other."""
    limit = MAX_RECEIPT_BYTES + _FRAME_PREFIX_BYTES if frame else MAX_DISCOVERY_BYTES
    # stdout=PIPE in the only caller guarantees this binary stream.
    stdout = cast("BinaryIO", process.stdout)
    with selectors.DefaultSelector() as selector:
        os.set_blocking(stdout.fileno(), False)
        _ = selector.register(stdout, selectors.EVENT_READ)
        if process.stdin is not None:
            os.set_blocking(process.stdin.fileno(), False)
            _ = selector.register(process.stdin, selectors.EVENT_WRITE)
        offset = 0
        output = bytearray()
        while selector.get_map():
            events = selector.select(_remaining(deadline))
            if not events:
                raise TimeoutError
            for key, _mask in events:
                if key.fileobj is process.stdin and process.stdin is not None:
                    offset += _write_available(key.fd, memoryview(frame)[offset:])
                    if offset == len(frame):
                        _ = selector.unregister(process.stdin)
                        process.stdin.close()
                else:
                    try:
                        chunk = os.read(key.fd, min(65_536, limit + 1 - len(output)))
                    except (BlockingIOError, InterruptedError):
                        continue
                    if not chunk:
                        _ = selector.unregister(stdout)
                        stdout.close()
                    else:
                        output.extend(chunk)
                        if len(output) > limit:
                            raise NativePairingPublicationError(
                                NativePairingPublicationErrorCode.PUBLICATION_FAILED
                            )
        return bytes(output)


def _write_available(descriptor: int, content: memoryview[int]) -> int:
    try:
        return os.write(descriptor, content[:65_536])
    except (BlockingIOError, InterruptedError):
        return 0


def _remaining(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise NativePairingPublicationError(
            NativePairingPublicationErrorCode.PUBLICATION_FAILED
        )
    return remaining


def _canonical_json(value: dict[str, object]) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False
    ).encode("ascii")


def _unique_receipt_fields(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for name, value in pairs:
        if name in result:
            raise NativePairingPublicationError(
                NativePairingPublicationErrorCode.PUBLICATION_FAILED
            )
        result[name] = value
    return result


def _same_fields(actual: dict[str, object], expected: dict[str, object]) -> bool:
    return actual.keys() == expected.keys() and all(
        type(actual[key]) is type(value) and actual[key] == value
        for key, value in expected.items()
    )


def _validate_response(request: dict[str, object], code: int, response: bytes) -> None:
    failure = NativePairingPublicationErrorCode.PUBLICATION_FAILED
    if len(response) < _FRAME_PREFIX_BYTES:
        raise NativePairingPublicationError(failure)
    size = int.from_bytes(response[:_FRAME_PREFIX_BYTES], "big")
    if (
        not 1 <= size <= MAX_RECEIPT_BYTES
        or len(response) != size + _FRAME_PREFIX_BYTES
    ):
        raise NativePairingPublicationError(failure)
    try:
        actual = cast(
            "object", json.loads(response[4:], object_pairs_hook=_unique_receipt_fields)
        )
    except (ValueError, UnicodeDecodeError, RecursionError) as exc:
        raise NativePairingPublicationError(failure) from exc
    if not isinstance(actual, dict):
        raise NativePairingPublicationError(failure)
    fields = cast("dict[str, object]", actual)
    expected: dict[str, object] = {**request, "status": "ok"}
    operation = request["operation"]
    if not isinstance(operation, str) or operation not in _SUCCESS_FIELDS:
        raise NativePairingPublicationError(failure)
    expected.update(_SUCCESS_FIELDS[operation])
    wire_code = fields.get("code")
    if (
        code == _ERROR_EXIT_CODE
        and isinstance(wire_code, str)
        and wire_code in _WIRE_ERRORS
    ):
        error = {**request, "status": "error", "code": wire_code}
        if _same_fields(fields, error) and response[4:] == _canonical_json(error):
            if wire_code == "storage_access_denied":
                raise NativePairingPublicationError(
                    NativePairingPublicationErrorCode.ACCESS_DENIED
                )
            raise NativePairingPublicationError(failure)
    if (
        code != 0
        or not _same_fields(fields, expected)
        or response[4:] != _canonical_json(expected)
    ):
        raise NativePairingPublicationError(failure)


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
