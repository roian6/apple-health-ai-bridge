from __future__ import annotations

import base64
import binascii
import hashlib
import os
import re
import stat
from pathlib import Path
from typing import Annotated, ClassVar, Final, Literal, Self
from urllib.parse import unquote, urlsplit

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator
from typing_extensions import override

from health_bridge.contract._hbjcs1 import (
    HBJCS1Error,
    hbjcs1_decode,
    hbjcs1_encode,
)

SEAL_SIGNATURE_DOMAIN: Final = b"health-bridge/mailbox/qa/production-identity-seal/v1"
Hex64 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
Base64URL32 = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{43}$")]
Base64URL64 = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{86}$")]
Identifier = Annotated[str, StringConstraints(min_length=1, max_length=256)]
_BUNDLE_PATTERN: Final = re.compile(r"^[A-Za-z0-9.-]+$")


class ProductionSealError(Exception):
    @override
    def __str__(self) -> str:
        return "production identity seal rejected"


def inventory_observes_app_path(values: tuple[str, ...], expected: str) -> bool:
    """Match an app path against exact path or local file-URL inventory values."""
    for value in values:
        if value == expected:
            return True
        parsed = urlsplit(value)
        if (
            parsed.scheme == "file"
            and parsed.netloc in ("", "localhost")
            and unquote(parsed.path) == expected
        ):
            return True
    return False


class SealModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )


class ProductionIdentitySealV1(SealModel):
    v: Literal[1]
    kind: Literal["health_bridge.production_identity_seal.v1"]
    created_at_ms: Annotated[int, Field(ge=0)]
    provenance: Identifier
    bundle_identifier: Identifier
    # The current daily-use app may predate mailbox/iCloud capabilities.  An
    # empty observed set is meaningful and must not force a production upgrade
    # merely to authorize the isolated QA container.
    icloud_containers: list[Identifier]
    url_schemes: Annotated[list[Identifier], Field(min_length=1)]
    keychain_services: Annotated[list[Identifier], Field(min_length=1)]
    keychain_access_groups: Annotated[list[Identifier], Field(min_length=1)]
    display_identity: Identifier
    outbox_roots: Annotated[list[Identifier], Field(min_length=1)]
    receiver_ports: Annotated[
        list[Annotated[int, Field(ge=1024, le=65535)]],
        Field(min_length=1),
    ]
    runtime_roots: Annotated[list[Identifier], Field(min_length=1)]
    database_namespaces: Annotated[list[Identifier], Field(min_length=1)]
    installed_app_path: Identifier
    installed_app_observation_sha256: Hex64
    codesign_team_identifier_sha256: Hex64
    signing_public_key: Base64URL32
    signature: Base64URL64

    @model_validator(mode="after")
    def exact_private_identity(self) -> Self:
        groups = (
            self.icloud_containers,
            self.url_schemes,
            self.keychain_services,
            self.keychain_access_groups,
            self.outbox_roots,
            self.receiver_ports,
            self.runtime_roots,
            self.database_namespaces,
        )
        valid = (
            _BUNDLE_PATTERN.fullmatch(self.bundle_identifier) is not None
            and all(len(set(group)) == len(group) for group in groups)
            and all(Path(root).is_absolute() for root in self.runtime_roots)
            and Path(self.installed_app_path).is_absolute()
        )
        if not valid:
            raise ProductionSealError
        return self


class QAIsolationRequest(SealModel):
    bundle_identifier: Identifier
    container_identifier: Identifier
    url_scheme: Identifier
    keychain_service: Identifier
    keychain_access_groups: tuple[Identifier, ...]
    outbox_root: Identifier
    display_identity: Identifier
    receiver_port: Annotated[int, Field(ge=1024, le=65535)]
    runtime_root: Path
    database_namespace: Identifier
    app_path: Path


def load_production_identity_seal(
    path: Path,
    anchor_sha256: str,
) -> ProductionIdentitySealV1:
    _require_private_regular_file(path)
    try:
        encoded = path.read_bytes()
        document = hbjcs1_decode(encoded)
        seal = ProductionIdentitySealV1.model_validate(document)
        public_key = _decode(seal.signing_public_key, 32)
    except (
        OSError,
        ValueError,
        binascii.Error,
        HBJCS1Error,
        ProductionSealError,
    ) as exc:
        raise ProductionSealError from exc
    if not isinstance(document, dict) or hbjcs1_encode(document) != encoded:
        raise ProductionSealError
    if hashlib.sha256(public_key).hexdigest() != anchor_sha256:
        raise ProductionSealError
    unsigned = dict(document)
    del unsigned["signature"]
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(
            _decode(seal.signature, 64),
            SEAL_SIGNATURE_DOMAIN + b"\0" + hbjcs1_encode(unsigned),
        )
    except (ValueError, binascii.Error, InvalidSignature) as exc:
        raise ProductionSealError from exc
    return seal


def validate_qa_isolation(
    seal: ProductionIdentitySealV1,
    request: QAIsolationRequest,
) -> str:
    profiles = (
        (
            f"{seal.bundle_identifier}.mailboxqa",
            "",
            "QA",
            " Mailbox QA",
        ),
        (
            f"{seal.bundle_identifier}.publicdocuments.mailboxqa",
            "-public-documents",
            "PublicDocumentsQA",
            " Mailbox Public Documents QA",
        ),
    )
    expected = any(
        request.bundle_identifier == bundle
        and request.container_identifier == f"iCloud.{bundle}"
        and any(
            request.url_scheme == f"{scheme}qa{url_suffix}"
            for scheme in seal.url_schemes
        )
        and request.keychain_service == f"{bundle}.mailboxqa"
        and request.keychain_access_groups
        == tuple(
            f"{group[: -len(seal.bundle_identifier)]}{bundle}"
            for group in seal.keychain_access_groups
            if group.endswith(seal.bundle_identifier)
        )
        and any(
            request.outbox_root == f"{root}{outbox_suffix}"
            for root in seal.outbox_roots
        )
        and request.display_identity == f"{seal.display_identity}{display_suffix}"
        for bundle, url_suffix, outbox_suffix, display_suffix in profiles
    )
    collisions = _identity_collisions(seal, request)
    if not expected or collisions:
        raise ProductionSealError
    return production_seal_fingerprint(seal)


def production_seal_fingerprint(seal: ProductionIdentitySealV1) -> str:
    encoded = hbjcs1_encode(seal.model_dump(mode="json"))
    return hashlib.sha256(encoded).hexdigest()[:16]


def validate_qa_runtime_root(
    seal: ProductionIdentitySealV1,
    runtime_root: Path,
) -> None:
    root = runtime_root.resolve(strict=True)
    entry = root.lstat()
    collides = any(
        _paths_overlap(root, Path(production_root))
        for production_root in (*seal.runtime_roots, seal.installed_app_path)
    )
    if (
        not root.is_dir()
        or root.is_symlink()
        or "qa" not in root.name.lower()
        or (os.name == "posix" and entry.st_mode & 0o077)
        or collides
    ):
        raise ProductionSealError


def _identity_collisions(
    seal: ProductionIdentitySealV1,
    request: QAIsolationRequest,
) -> bool:
    qa_values = (
        request.bundle_identifier,
        request.container_identifier,
        request.url_scheme,
        request.keychain_service,
        *request.keychain_access_groups,
        request.outbox_root,
        request.display_identity,
    )
    production_values = (
        seal.bundle_identifier,
        *seal.icloud_containers,
        *seal.url_schemes,
        *seal.keychain_services,
        *seal.keychain_access_groups,
        *seal.outbox_roots,
        seal.display_identity,
    )
    roots_collide = any(
        _paths_overlap(request.runtime_root, Path(root))
        or _paths_overlap(request.app_path, Path(root))
        for root in (*seal.runtime_roots, seal.installed_app_path)
    )
    namespace_collides = any(
        request.database_namespace == namespace
        or request.database_namespace.startswith(f"{namespace}-")
        or namespace.startswith(f"{request.database_namespace}-")
        for namespace in seal.database_namespaces
    )
    return (
        any(value in production_values for value in qa_values)
        or _unsafe_identity_overlap(seal, request)
        or request.receiver_port in seal.receiver_ports
        or roots_collide
        or namespace_collides
        or _paths_overlap(request.app_path, Path(seal.installed_app_path))
    )


def _unsafe_identity_overlap(
    seal: ProductionIdentitySealV1,
    request: QAIsolationRequest,
) -> bool:
    safe_pairs = {
        (request.bundle_identifier, seal.bundle_identifier),
        (request.keychain_service, seal.bundle_identifier),
        (request.display_identity, seal.display_identity),
        *(
            (request.container_identifier, value)
            for value in seal.icloud_containers
            if request.container_identifier
            in (
                f"{value}.mailboxqa",
                f"{value}.publicdocuments.mailboxqa",
            )
        ),
        *(
            (request.url_scheme, value)
            for value in seal.url_schemes
            if request.url_scheme
            in (
                f"{value}qa",
                f"{value}qa-public-documents",
            )
        ),
        *(
            (request.keychain_service, value)
            for value in seal.keychain_services
            if request.keychain_service.startswith(f"{value}.")
        ),
        *(
            (group, value)
            for group in request.keychain_access_groups
            for value in seal.keychain_access_groups
            if group.endswith(
                (
                    f"{seal.bundle_identifier}.mailboxqa",
                    f"{seal.bundle_identifier}.publicdocuments.mailboxqa",
                )
            )
            and value.endswith(seal.bundle_identifier)
        ),
        *(
            (request.outbox_root, value)
            for value in seal.outbox_roots
            if request.outbox_root
            in (
                f"{value}QA",
                f"{value}PublicDocumentsQA",
            )
        ),
    }
    qa_values = (
        request.bundle_identifier,
        request.container_identifier,
        request.url_scheme,
        request.keychain_service,
        *request.keychain_access_groups,
        request.outbox_root,
        request.display_identity,
    )
    production_values = (
        seal.bundle_identifier,
        *seal.icloud_containers,
        *seal.url_schemes,
        *seal.keychain_services,
        *seal.keychain_access_groups,
        *seal.outbox_roots,
        seal.display_identity,
    )
    return any(
        (qa, production) not in safe_pairs
        and (qa.startswith(production) or production.startswith(qa))
        for qa in qa_values
        for production in production_values
    )


def _paths_overlap(left: Path, right: Path) -> bool:
    left_absolute = left.absolute()
    right_absolute = right.absolute()
    return left_absolute.is_relative_to(
        right_absolute
    ) or right_absolute.is_relative_to(left_absolute)


def _require_private_regular_file(path: Path) -> None:
    entry = path.lstat()
    if (
        not stat.S_ISREG(entry.st_mode)
        or entry.st_nlink != 1
        or (os.name == "posix" and entry.st_mode & 0o077)
    ):
        raise ProductionSealError


def _decode(value: str, expected: int) -> bytes:
    decoded = base64.urlsafe_b64decode(value + "=" * ((4 - len(value) % 4) % 4))
    if len(decoded) != expected or _encode(decoded) != value:
        raise ProductionSealError
    return decoded


def _encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


__all__ = [
    "ProductionIdentitySealV1",
    "ProductionSealError",
    "QAIsolationRequest",
    "inventory_observes_app_path",
    "load_production_identity_seal",
    "production_seal_fingerprint",
    "validate_qa_isolation",
    "validate_qa_runtime_root",
]
