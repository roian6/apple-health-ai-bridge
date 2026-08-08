from __future__ import annotations

import os
import pathlib
import sys
from ipaddress import IPv4Address, IPv4Network, ip_address
from typing import Annotated, ClassVar, Final, Self, TypeAlias

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    model_validator,
)
from pydantic_core import PydanticCustomError

from health_bridge.mailbox_qa.production_seal import (
    ProductionIdentitySealV1,
    ProductionSealError,
    QAIsolationRequest,
    validate_qa_isolation,
)

QA_ISOLATION_ERROR: Final = "qa_isolation"
QA_ISOLATION_MESSAGE: Final = "QA receiver configuration is not isolated"
QA_PROCESS_ERROR: Final = "qa_process"
QA_PROCESS_MESSAGE: Final = "QA receiver process identity is invalid"
PathType: TypeAlias = pathlib.Path
QA_NETWORKS: Final = (
    IPv4Network((0x0A000000, 8)),
    IPv4Network((0x64400000, 10)),
    IPv4Network((0x7F000000, 8)),
    IPv4Network((0xAC100000, 12)),
    IPv4Network((0xC0A80000, 16)),
)
Namespace = Annotated[
    str,
    StringConstraints(pattern=r"^qa-[a-z0-9][a-z0-9-]{2,63}$"),
]
BundleIdentifier = Annotated[
    str,
    StringConstraints(pattern=r"^[A-Za-z0-9.-]+\.mailboxqa$"),
]
ContainerIdentifier = Annotated[
    str,
    StringConstraints(pattern=r"^iCloud\.[A-Za-z0-9.-]+\.mailboxqa$"),
]


class QAReceiverConfig(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )

    runtime_root: PathType
    host: str
    port: Annotated[int, Field(ge=1024, le=65535)]
    namespace: Namespace
    bundle_identifier: BundleIdentifier
    container_identifier: ContainerIdentifier
    url_scheme: Annotated[
        str,
        StringConstraints(pattern=r"^healthbridgeqa[a-z0-9-]*$"),
    ]
    keychain_service: str
    keychain_access_groups: tuple[str, ...]
    outbox_root: str
    display_identity: str
    database_namespace: str
    app_path: PathType
    mailbox_root_override: PathType | None = None
    production_seal: ProductionIdentitySealV1
    production_seal_fingerprint: Annotated[
        str,
        StringConstraints(pattern=r"^[0-9a-f]{16}$"),
    ]

    @model_validator(mode="after")
    def isolated_values(self) -> Self:
        root = self.runtime_root.resolve(strict=True)
        mode = root.stat().st_mode & 0o777
        address = ip_address(self.host)
        try:
            seal_fingerprint = validate_qa_isolation(
                self.production_seal,
                QAIsolationRequest(
                    bundle_identifier=self.bundle_identifier,
                    container_identifier=self.container_identifier,
                    url_scheme=self.url_scheme,
                    keychain_service=self.keychain_service,
                    keychain_access_groups=self.keychain_access_groups,
                    outbox_root=self.outbox_root,
                    display_identity=self.display_identity,
                    receiver_port=self.port,
                    runtime_root=root,
                    database_namespace=self.database_namespace,
                    app_path=self.app_path,
                ),
            )
        except ProductionSealError as exc:
            raise PydanticCustomError(
                QA_ISOLATION_ERROR,
                QA_ISOLATION_MESSAGE,
            ) from exc
        prohibited = (
            not isinstance(address, IPv4Address)
            or not any(address in network for network in QA_NETWORKS)
            or seal_fingerprint != self.production_seal_fingerprint
            or "prod" in self.namespace
            or ".git" in root.parts
            or "qa" not in root.name.lower()
            or mode & 0o077 != 0
            or not root.is_dir()
            or root.is_symlink()
        )
        if self.mailbox_root_override is not None:
            expected_mailbox = (
                pathlib.Path.home()
                / "Library/Mobile Documents"
                / self.container_identifier.replace(".", "~")
                / "Documents/HealthBridgeMailbox/v1"
            )
            prohibited = prohibited or (
                sys.platform != "darwin"
                or self.mailbox_root_override != expected_mailbox
                or expected_mailbox.parent.is_symlink()
            )
        if prohibited:
            raise PydanticCustomError(
                QA_ISOLATION_ERROR,
                QA_ISOLATION_MESSAGE,
            )
        return self

    @property
    def database_path(self) -> PathType:
        return self.runtime_root / "receiver.sqlite"

    @property
    def token_path(self) -> PathType:
        return self.runtime_root / "private/token"

    @property
    def mailbox_root(self) -> PathType:
        return self.mailbox_root_override or self.runtime_root / "mailbox-qa"

    @property
    def state_path(self) -> PathType:
        return self.runtime_root / "qa-receiver-state.json"

    @property
    def receipt_key_path(self) -> PathType:
        return self.runtime_root / "private/receiver-receipt-key"

    def require_owner_process(self, pid: int) -> None:
        if pid <= 1 or pid == os.getppid():
            raise PydanticCustomError(
                QA_PROCESS_ERROR,
                QA_PROCESS_MESSAGE,
            )
