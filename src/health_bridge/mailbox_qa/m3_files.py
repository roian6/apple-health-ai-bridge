from __future__ import annotations

import hashlib
import os
from pathlib import Path
from typing import TYPE_CHECKING, Final, TypeVar

from pydantic import BaseModel, ValidationError

from health_bridge._milestone_files import read_scoped_regular_file
from health_bridge.contract._hbjcs1 import (
    HBJCS1Error,
    JsonValue,
    hbjcs1_decode,
    hbjcs1_encode,
)
from health_bridge.mailbox_qa.m3_errors import M3FailureCode, M3ValidationError

if TYPE_CHECKING:
    from health_bridge.mailbox_qa.m3_models import ArtifactBinding

REPOSITORY_ROOT: Final = Path(__file__).resolve().parents[3]
MAX_DOCUMENT_BYTES: Final = 1_048_576
ModelT = TypeVar("ModelT", bound=BaseModel)


def external_file(path: Path) -> tuple[Path, str]:
    absolute = path.absolute()
    parent = absolute.parent.resolve(strict=True)
    try:
        _ = parent.relative_to(REPOSITORY_ROOT)
    except ValueError:
        return parent, absolute.name
    raise M3ValidationError(M3FailureCode.SCHEMA_INVALID)


def read_document(root: Path, relative_path: str) -> dict[str, JsonValue]:
    encoded = read_scoped_regular_file(root, relative_path)
    if encoded is None or len(encoded) > MAX_DOCUMENT_BYTES:
        raise M3ValidationError(M3FailureCode.SCHEMA_INVALID)
    try:
        value = hbjcs1_decode(encoded)
    except HBJCS1Error as exc:
        raise M3ValidationError(M3FailureCode.SCHEMA_INVALID) from exc
    if hbjcs1_encode(value) != encoded or not isinstance(value, dict):
        raise M3ValidationError(M3FailureCode.SCHEMA_INVALID)
    return value


def parse_document(document: dict[str, JsonValue], model: type[ModelT]) -> ModelT:
    try:
        return model.model_validate(document)
    except ValidationError as exc:
        raise M3ValidationError(M3FailureCode.SCHEMA_INVALID) from exc


def validate_anchor_file(path: Path) -> None:
    entry = path.lstat()
    if not path.is_file() or path.is_symlink() or entry.st_nlink != 1:
        raise M3ValidationError(M3FailureCode.ANCHOR_UNSAFE)
    if os.name == "posix" and entry.st_mode & 0o077:
        raise M3ValidationError(M3FailureCode.ANCHOR_UNSAFE)


def bound_document(
    root: Path,
    binding: ArtifactBinding,
) -> dict[str, JsonValue]:
    content = read_scoped_regular_file(root, binding.path)
    if content is None or hashlib.sha256(content).hexdigest() != binding.sha256:
        raise M3ValidationError(M3FailureCode.ARTIFACT_BINDING)
    return read_document(root, binding.path)


__all__ = [
    "REPOSITORY_ROOT",
    "bound_document",
    "external_file",
    "parse_document",
    "read_document",
    "validate_anchor_file",
]
