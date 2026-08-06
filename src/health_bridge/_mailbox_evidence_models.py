from __future__ import annotations

from typing import Annotated, ClassVar, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

Hex16 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{16}$")]
Hex32 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{32}$")]
Hex40 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{40}$")]
Hex64 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
Base64URL32 = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{43}$")]
Base64URL64 = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{86}$")]
ShortText = Annotated[str, StringConstraints(min_length=1, max_length=128)]
BuildText = Annotated[
    str,
    StringConstraints(pattern=r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$"),
]
ConnectionHandle = Annotated[
    str,
    StringConstraints(pattern=r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"),
]


class StrictModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )


class PhysicalPrerequisites(StrictModel):
    v: Literal[1]
    kind: Literal["mailbox_physical_prerequisites"]
    signing: Literal["available", "unavailable"]
    container: Literal["available", "unavailable"]
    device: Literal["available", "unavailable"]
    account: Literal["available", "unavailable"]
    authorization: Literal["available", "unavailable"]

    @property
    def available(self) -> bool:
        return all(
            value == "available"
            for value in (
                self.signing,
                self.container,
                self.device,
                self.account,
                self.authorization,
            )
        )


class PhysicalHarness(StrictModel):
    v: Literal[1]
    kind: Literal["mailbox_physical_harness"]
    run_id: Hex32
    challenge: Base64URL32
    source_commit_sha: Hex40
    archive_sha256: Hex64
    code_directory_hash: Hex40
    signing_identity_sha256: Hex64
    container_identifier_sha256: Hex64
    device_identifier_sha256: Hex64
    device_model: ShortText
    os_version: ShortText
    bundle_identifier_sha256: Hex64
    app_version: BuildText
    build_number: BuildText
    install_receipt_sha256: Hex64
    started_at_ms: Annotated[int, Field(ge=0)]
    expires_at_ms: Annotated[int, Field(ge=0)]


class CodeSignEvidence(StrictModel):
    v: Literal[1]
    kind: Literal["mailbox_codesign_evidence"]
    verified: bool
    archive_sha256: Hex64
    code_directory_hash: Hex40
    signing_identity_sha256: Hex64
    container_identifier_sha256: Hex64
    bundle_identifier_sha256: Hex64
    app_version: BuildText
    build_number: BuildText


class InstallReceipt(StrictModel):
    v: Literal[1]
    kind: Literal["mailbox_install_receipt"]
    install_receipt_sha256: Hex64
    archive_sha256: Hex64
    device_identifier_sha256: Hex64
    device_model: ShortText
    os_version: ShortText
    bundle_identifier_sha256: Hex64
    app_version: BuildText
    build_number: BuildText
    installed_at_ms: Annotated[int, Field(ge=0)]


class ScenarioResult(StrictModel):
    name: Annotated[str, StringConstraints(pattern=r"^[a-z][a-z0-9_]{0,127}$")]
    result: Literal["pass", "fail", "hold"]
    started_at_ms: Annotated[int, Field(ge=0)]
    finished_at_ms: Annotated[int, Field(ge=0)]
    assertion_count: Annotated[int, Field(ge=1)]


class TransitionCounts(StrictModel):
    collected: Annotated[int, Field(ge=0)]
    encrypted: Annotated[int, Field(ge=0)]
    published: Annotated[int, Field(ge=0)]
    provider_observed: Annotated[int, Field(ge=0)]
    ack_verified: Annotated[int, Field(ge=0)]
    committed_finalized: Annotated[int, Field(ge=0)]
    retryable_failure: Annotated[int, Field(ge=0)]
    terminal_failure: Annotated[int, Field(ge=0)]


class PhysicalReport(StrictModel):
    v: Literal[1]
    kind: Literal["mailbox_physical_report"]
    run_id: Hex32
    challenge: Base64URL32
    embedded_commit_sha: Hex40
    bundle_identifier_sha256: Hex64
    app_version: BuildText
    build_number: BuildText
    device_identifier_sha256: Hex64
    device_model: ShortText
    os_version: ShortText
    receiver_fingerprint: Hex16
    device_signing_key_fingerprint: Hex16
    connection_generation: Annotated[int, Field(ge=0)]
    started_at_ms: Annotated[int, Field(ge=0)]
    finished_at_ms: Annotated[int, Field(ge=0)]
    scenario_results: Annotated[
        list[ScenarioResult],
        Field(min_length=1, max_length=128),
    ]
    transition_counts: TransitionCounts
    receipt_id: Annotated[int, Field(ge=0)]
    dataset_generation: Annotated[int, Field(ge=0)]
    signature: Base64URL64


class AnchorBinding(StrictModel):
    run_id: Hex32
    challenge: Base64URL32
    connection_handle: ConnectionHandle
    created_at_ms: Annotated[int, Field(ge=0)]
    expires_at_ms: Annotated[int, Field(ge=0)]
    consumed: bool


class AnchoredConnection(StrictModel):
    connection_handle: ConnectionHandle
    receiver_id: Hex32
    device_id: Hex32
    device_signing_key_id: Hex32
    device_agreement_key_id: Hex32
    receiver_signing_key_id: Hex32
    receiver_agreement_key_id: Hex32
    device_signing_public_key: Base64URL32
    connection_generation: Annotated[int, Field(ge=0)]

    @property
    def full_identifiers(self) -> frozenset[str]:
        return frozenset(
            {
                self.receiver_id,
                self.device_id,
                self.device_signing_key_id,
                self.device_agreement_key_id,
                self.receiver_signing_key_id,
                self.receiver_agreement_key_id,
            }
        )


class AnchorState(StrictModel):
    v: Literal[1]
    kind: Literal["mailbox_evidence_anchor_state"]
    bindings: Annotated[list[AnchorBinding], Field(max_length=10_000)]
    connections: Annotated[list[AnchoredConnection], Field(max_length=10_000)]
