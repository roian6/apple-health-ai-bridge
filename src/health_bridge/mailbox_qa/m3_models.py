from __future__ import annotations

from typing import Annotated, ClassVar, Literal, Self

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

Hex16 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{16}$")]
Hex32 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{32}$")]
Hex40 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{40}$")]
Hex64 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
Base64URL32 = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{43}$")]
Base64URL64 = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{86}$")]
SafeName = Annotated[
    str,
    StringConstraints(pattern=r"^[a-z][a-z0-9_]{2,95}$"),
]
RelativePath = Annotated[
    str,
    StringConstraints(pattern=r"^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$"),
]


class M3Model(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )


class M3Prerequisites(M3Model):
    signing: Literal["available", "unavailable"]
    container: Literal["available", "unavailable"]
    device: Literal["available", "unavailable"]
    account: Literal["available", "unavailable"]
    qa_authorization: Literal["available", "unavailable"]

    @property
    def available(self) -> bool:
        return all(
            item == "available"
            for item in (
                self.signing,
                self.container,
                self.device,
                self.account,
                self.qa_authorization,
            )
        )


class ArtifactBinding(M3Model):
    kind: SafeName
    path: RelativePath
    sha256: Hex64


class ParentReceiptBinding(ArtifactBinding):
    receipt_kind: SafeName


class ScenarioBinding(ArtifactBinding):
    scenario: SafeName


class M3ManifestV1(M3Model):
    v: Literal[1]
    kind: Literal["health_bridge.mailbox_m3_manifest.v1"]
    verdict: Literal["PASS", "HOLD", "FAIL"]
    head: Hex40
    m2_manifest_sha256: Hex64
    qa_bundle_fingerprint: Hex16
    qa_container_fingerprint: Hex16
    production_seal_fingerprint: Hex16
    prerequisites: M3Prerequisites
    parent_receipts: Annotated[
        list[ParentReceiptBinding],
        Field(min_length=5, max_length=5),
    ]
    device_report: ArtifactBinding
    scenario_receipts: Annotated[
        list[ScenarioBinding],
        Field(min_length=16, max_length=16),
    ]


class M3AnchorV1(M3Model):
    v: Literal[1]
    kind: Literal["health_bridge.mailbox_m3_anchor.v1"]
    run_id: Hex32
    challenge: Base64URL32
    head: Hex40
    m2_manifest_sha256: Hex64
    qa_bundle_identifier: str
    qa_container_identifier: str
    qa_bundle_fingerprint: Hex16
    qa_container_fingerprint: Hex16
    production_seal_fingerprint: Hex16
    device_report_public_key: Base64URL32
    receiver_receipt_public_key: Base64URL32
    parent_receipt_public_key: Base64URL32
    full_identifiers: Annotated[list[str], Field(min_length=8, max_length=64)]
    created_at_ms: Annotated[int, Field(ge=0)]
    expires_at_ms: Annotated[int, Field(ge=0)]
    consumed: bool

    @model_validator(mode="after")
    def unique_full_identifiers(self) -> Self:
        if len(set(self.full_identifiers)) != len(self.full_identifiers):
            raise ValueError
        return self


class TransitionCounts(M3Model):
    collected: Annotated[int, Field(ge=0)]
    encrypted: Annotated[int, Field(ge=0)]
    published: Annotated[int, Field(ge=0)]
    provider_observed: Annotated[int, Field(ge=0)]
    ack_verified: Annotated[int, Field(ge=0)]
    committed_finalized: Annotated[int, Field(ge=0)]
    retryable_failure: Annotated[int, Field(ge=0)]
    terminal_failure: Annotated[int, Field(ge=0)]


class DeviceReportV1(M3Model):
    v: Literal[1]
    kind: Literal["health_bridge.mailbox_m3_device_report.v1"]
    run_id: Hex32
    challenge: Base64URL32
    head: Hex40
    qa_bundle_fingerprint: Hex16
    qa_container_fingerprint: Hex16
    executable_sha256: Hex64
    device_fingerprint: Hex16
    device_model: str
    os_version: str
    started_at_ms: Annotated[int, Field(ge=0)]
    finished_at_ms: Annotated[int, Field(ge=0)]
    transition_counts: TransitionCounts
    synthetic_payload_sha256: Hex64
    envelope_sha256: Hex64
    envelope_reuse_count: Annotated[int, Field(ge=0)]
    lifecycle_epoch: Annotated[int, Field(ge=1)]
    restart_epoch: Annotated[int, Field(ge=0)]
    finalization_count: Annotated[int, Field(ge=0)]
    fault_injection_count: Annotated[int, Field(ge=0)]
    foreground_observation_count: Annotated[int, Field(ge=0)]
    background_observation_count: Annotated[int, Field(ge=0)]
    protected_data_available_count: Annotated[int, Field(ge=0)]
    protected_data_unavailable_count: Annotated[int, Field(ge=0)]
    protection_state: Literal["available", "unavailable"]
    signature: Base64URL64


class ScenarioReceiptV1(M3Model):
    v: Literal[1]
    kind: Literal["health_bridge.mailbox_m3_scenario_receipt.v1"]
    scenario: SafeName
    producer: Literal["qa_receiver", "parent_orchestrator"]
    evidence_class: Literal[
        "receiver_commit",
        "provider_observation",
        "device_lifecycle",
        "fault_injection",
        "cleanup",
        "rollback",
        "preservation",
        "provenance",
    ]
    issuance: Literal["operation_v1"]
    operation_id: Hex32
    observation_sha256: Hex64
    verdict: Literal["PASS"]
    run_id: Hex32
    challenge: Base64URL32
    head: Hex40
    qa_bundle_fingerprint: Hex16
    qa_container_fingerprint: Hex16
    started_at_ms: Annotated[int, Field(ge=0)]
    finished_at_ms: Annotated[int, Field(ge=0)]
    assertion_count: Annotated[int, Field(ge=1)]
    checks: Annotated[list[SafeName], Field(min_length=2, max_length=4)]
    signature: Base64URL64
