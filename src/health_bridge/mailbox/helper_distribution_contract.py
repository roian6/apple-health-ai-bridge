from __future__ import annotations

import hashlib
import hmac
from enum import StrEnum, unique
from typing import Annotated, ClassVar, Final, Literal, TypeAlias

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter
from typing_extensions import override

HELPER_COMPONENT: Final = "HealthBridgeMailboxAckPublisher"
HELPER_SOURCE_PATH: Final = "macos/HealthBridgeMailboxAckPublisher"
_APPROVED_SIGNING_AUTHORITY_SHA256: Final = (
    "f7399b254d834701db7c7045b1a44333072c916d87db301328eee1d91d531219"
)
_APPROVED_TEAM_IDENTIFIER_SHA256: Final = (
    "b41289a03a1282b2ebe94058c86a906c0b566ffac30b99118605431fc148c258"
)
_APPROVED_BUNDLE_IDENTIFIER_SHA256: Final = (
    "65217119e1a5f60de43e67ffeabba47b739e13b0393c720ec3ece6445b98ab63"
)
_APPROVED_ICLOUD_CONTAINER_IDENTIFIER_SHA256: Final = (
    "e8e3c43c77b4dc6bee850c04a95a9e455d56e422dc38e05815a5bc80e63dfff3"
)


@unique
class HelperErrorCode(StrEnum):
    UNSUPPORTED_HOST = "unsupported_host"
    INVALID_MANIFEST = "invalid_manifest"
    UNSAFE_ARCHIVE = "unsafe_archive"
    ARTIFACT_MISMATCH = "artifact_mismatch"
    SOURCE_MISMATCH = "source_mismatch"
    SIGNATURE_INVALID = "signature_invalid"
    ENTITLEMENTS_INVALID = "entitlements_invalid"
    FOREIGN_HELPER = "foreign_helper"
    HELPER_DRIFT = "helper_drift"
    UNSAFE_FILESYSTEM = "unsafe_filesystem"


_ERROR_MESSAGES: Final[dict[HelperErrorCode, str]] = {
    HelperErrorCode.UNSUPPORTED_HOST: (
        "Mailbox helper lifecycle is unavailable on this host."
    ),
    HelperErrorCode.INVALID_MANIFEST: "Mailbox helper manifest is invalid.",
    HelperErrorCode.UNSAFE_ARCHIVE: "Mailbox helper archive is unsafe.",
    HelperErrorCode.ARTIFACT_MISMATCH: (
        "Mailbox helper artifact does not match its manifest."
    ),
    HelperErrorCode.SOURCE_MISMATCH: (
        "Mailbox helper source identity does not match this release."
    ),
    HelperErrorCode.SIGNATURE_INVALID: "Mailbox helper signature is invalid.",
    HelperErrorCode.ENTITLEMENTS_INVALID: "Mailbox helper entitlements are invalid.",
    HelperErrorCode.FOREIGN_HELPER: "Mailbox helper location contains unowned content.",
    HelperErrorCode.HELPER_DRIFT: "Installed mailbox helper has drifted.",
    HelperErrorCode.UNSAFE_FILESYSTEM: "Mailbox helper filesystem is unsafe.",
}


class HelperError(Exception):
    def __init__(self, code: HelperErrorCode) -> None:
        super().__init__()
        self.code: HelperErrorCode = code

    @override
    def __str__(self) -> str:
        return _ERROR_MESSAGES[self.code]


def require_approved_helper_distribution(
    *,
    signing_authority: str,
    team_identifier: str,
    bundle_identifier: str,
    icloud_container_identifier: str,
) -> None:
    observed = (
        signing_authority,
        team_identifier,
        bundle_identifier,
        icloud_container_identifier,
    )
    approved_digests = (
        _APPROVED_SIGNING_AUTHORITY_SHA256,
        _APPROVED_TEAM_IDENTIFIER_SHA256,
        _APPROVED_BUNDLE_IDENTIFIER_SHA256,
        _APPROVED_ICLOUD_CONTAINER_IDENTIFIER_SHA256,
    )
    if any(
        not hmac.compare_digest(
            hashlib.sha256(value.encode()).hexdigest(),
            approved_digest,
        )
        for value, approved_digest in zip(observed, approved_digests, strict=True)
    ):
        raise HelperError(HelperErrorCode.INVALID_MANIFEST)


class ExactModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )


class HelperArtifact(ExactModel):
    bytes: int
    filename: str
    sha256: str


class HelperBundle(ExactModel):
    build: str
    identifier: str
    icloud_container_identifier: str
    version: str


class HelperReleaseIdentity(ExactModel):
    commit: str
    tag: str
    tag_object: str
    tree: str


class HelperSourceIdentity(ExactModel):
    git_tree: str
    path: Literal["macos/HealthBridgeMailboxAckPublisher"]


class HelperProvisioningProfile(ExactModel):
    provisions_all_devices: Literal[True]
    application_identifier: str
    team_identifier: str
    icloud_container_environment: Literal["Production"]
    icloud_container_identifiers: tuple[str, ...]
    ubiquity_container_identifiers: tuple[str, ...]


class HelperNotarization(ExactModel):
    status: Literal["Accepted"]
    submission_id: str


class HelperDistributionIdentity(ExactModel):
    signing_authority: str
    team_identifier: str
    provisioning_profile: HelperProvisioningProfile
    secure_timestamp: Literal[True]
    hardened_runtime: Literal[True]
    notarization: HelperNotarization
    stapled_ticket: Literal[True]
    gatekeeper_assessment: Literal["accepted"]


class HelperReleaseManifestV1(ExactModel):
    schema_id: Literal["health_bridge.mailbox_ack_helper.release.v1"]
    schema_version: Literal[1]
    component: Literal["HealthBridgeMailboxAckPublisher"]
    artifact: HelperArtifact
    bundle: HelperBundle
    release: HelperReleaseIdentity
    source: HelperSourceIdentity

    @property
    def distribution_identity(self) -> None:
        return None


class HelperReleaseManifestV2(ExactModel):
    schema_id: Literal["health_bridge.mailbox_ack_helper.release.v2"]
    schema_version: Literal[2]
    component: Literal["HealthBridgeMailboxAckPublisher"]
    artifact: HelperArtifact
    bundle: HelperBundle
    release: HelperReleaseIdentity
    source: HelperSourceIdentity
    distribution: HelperDistributionIdentity

    @property
    def distribution_identity(self) -> HelperDistributionIdentity:
        return self.distribution


HelperReleaseManifest: TypeAlias = HelperReleaseManifestV1 | HelperReleaseManifestV2
HELPER_RELEASE_MANIFEST_ADAPTER: Final[TypeAdapter[HelperReleaseManifest]] = (
    TypeAdapter(
        Annotated[
            HelperReleaseManifestV1 | HelperReleaseManifestV2,
            Field(discriminator="schema_version"),
        ]
    )
)


class HelperOwnership(ExactModel):
    schema_id: Literal["health_bridge.mailbox_ack_helper.ownership.v1"]
    schema_version: Literal[1]
    app_tree_sha256: str
    artifact_sha256: str
    manifest_sha256: str
    release_commit: str
    source_git_tree: str
