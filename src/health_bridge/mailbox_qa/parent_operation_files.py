from __future__ import annotations

import hashlib
import json
import os
import stat
from typing import TYPE_CHECKING, cast

if TYPE_CHECKING:
    from pathlib import Path

    from health_bridge.contract._hbjcs1 import JsonValue
    from health_bridge.mailbox_qa.production_seal import ProductionIdentitySealV1

SHA256_TEXT_LENGTH = 64


class ParentOperationFileError(Exception):
    pass


def private_json(path: Path) -> dict[str, JsonValue]:
    try:
        value = cast("JsonValue", json.loads(regular_bytes(path, private=True)))
    except (OSError, ValueError, UnicodeError) as exc:
        raise ParentOperationFileError from exc
    if not isinstance(value, dict):
        raise ParentOperationFileError
    return value


def regular_bytes(path: Path, *, private: bool) -> bytes:
    entry = path.lstat()
    if (
        not stat.S_ISREG(entry.st_mode)
        or entry.st_nlink != 1
        or (private and os.name == "posix" and entry.st_mode & 0o077)
    ):
        raise ParentOperationFileError
    return path.read_bytes()


def sha256(path: Path) -> str:
    return hashlib.sha256(regular_bytes(path, private=True)).hexdigest()


def strings(value: JsonValue) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [item for child in value for item in strings(child)]
    if isinstance(value, dict):
        return [item for child in value.values() for item in strings(child)]
    return []


def production_snapshot(
    values: tuple[str, ...],
    seal: ProductionIdentitySealV1,
) -> tuple[str, ...]:
    needles = (
        seal.bundle_identifier,
        seal.installed_app_path,
        seal.installed_app_observation_sha256,
        seal.codesign_team_identifier_sha256,
    )
    return tuple(sorted(value for value in values if value in needles))


def is_sha256(value: JsonValue | None) -> bool:
    return (
        isinstance(value, str)
        and len(value) == SHA256_TEXT_LENGTH
        and all(character in "0123456789abcdef" for character in value)
    )


__all__ = [
    "ParentOperationFileError",
    "is_sha256",
    "private_json",
    "production_snapshot",
    "regular_bytes",
    "sha256",
    "strings",
]
