from __future__ import annotations

import ctypes
import errno
import os
import sys
from typing import Final, Protocol, TypeAlias

from health_bridge.launchd.models import (
    LaunchdServiceError,
    LaunchdServiceErrorCode,
)

_RENAME_EXCL: Final = 0x00000004
_RENAME_NOREPLACE: Final = 1
_RenameArguments: TypeAlias = tuple[int, bytes, int, bytes, int]


_PLATFORM_RENAMES: Final = {
    "darwin": ("renameatx_np", _RENAME_EXCL),
    "linux": ("renameat2", _RENAME_NOREPLACE),
}


class _RenameFunction(Protocol):
    def __call__(
        self,
        source_dir_fd: int,
        source_name: bytes,
        destination_dir_fd: int,
        destination_name: bytes,
        flags: int,
    ) -> int: ...


def exclusive_rename(
    source_dir_fd: int,
    source_name: str,
    destination_dir_fd: int,
    destination_name: str,
) -> None:
    """Rename one dir-FD-bound entry without replacing an existing name."""
    try:
        symbol, flags = _PLATFORM_RENAMES[sys.platform]
    except KeyError as exc:
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM) from exc
    try:
        function: _RenameFunction = ctypes.CFUNCTYPE(
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
            use_errno=True,
        )((symbol, ctypes.CDLL(None, use_errno=True)))
        result = _invoke(
            function,
            (
                source_dir_fd,
                os.fsencode(source_name),
                destination_dir_fd,
                os.fsencode(destination_name),
                flags,
            ),
        )
    except (AttributeError, OSError) as exc:
        raise LaunchdServiceError(LaunchdServiceErrorCode.UNSAFE_FILESYSTEM) from exc
    if result == 0:
        return
    error = ctypes.get_errno()
    if error == errno.EEXIST:
        raise FileExistsError(error, "exclusive rename destination exists")
    raise OSError(error, "exclusive rename failed")


def _invoke(
    function: _RenameFunction,
    arguments: _RenameArguments,
) -> int:
    return function(*arguments)
