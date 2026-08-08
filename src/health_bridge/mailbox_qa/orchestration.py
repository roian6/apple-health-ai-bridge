from __future__ import annotations

from typing import Annotated, ClassVar, Final, Literal

from pydantic import BaseModel, ConfigDict, Field

SCENARIOS: Final = (
    "create_challenge",
    "build_qa_provenance",
    "invoke_fresh_pairing",
    "advance_collected",
    "advance_encrypted",
    "inject_publisher_enospc",
    "advance_published",
    "signed_qa_app_provenance",
    "actual_icloud_publication",
    "advance_provider_observed",
    "delay_importer_ack",
    "terminate_relaunch",
    "persisted_encoder_bytes_encrypted_unchanged",
    "restart_retry",
    "one_shot_importer",
    "strict_receiver_parse_without_reserialization",
    "authenticated_committed_ack",
    "scan_finalize",
    "provider_delay",
    "duplicate_identical",
    "conflict_rejected",
    "lock_unlock",
    "foreground_background_termination",
    "quota_disk_fault",
    "signed_report",
    "cleanup",
    "rollback",
    "production_preservation",
)
FAULT_SCENARIOS: Final = frozenset({"lock_unlock"})


class OrchestrationState(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )

    v: Literal[1]
    kind: Literal["health_bridge.mailbox_qa_orchestration_state.v1"]
    run_reference: Annotated[
        str,
        Field(pattern=r"^[a-z0-9][a-z0-9-]{2,63}$"),
    ]
    next_index: Annotated[int, Field(ge=0, le=len(SCENARIOS))]
    status: Literal["active", "hold", "complete"]
    hold_reason: (
        Literal[
            "external_prerequisite",
            "faithful_instrumentation_unavailable",
        ]
        | None
    )

    @property
    def next_scenario(self) -> str | None:
        if self.status != "active" or self.next_index == len(SCENARIOS):
            return None
        return SCENARIOS[self.next_index]

    def advance(self, completed_scenario: str) -> OrchestrationState:
        if self.status != "active" or completed_scenario != self.next_scenario:
            raise ValueError
        next_index = self.next_index + 1
        return self.model_copy(
            update={
                "next_index": next_index,
                "status": "complete" if next_index == len(SCENARIOS) else "active",
            }
        )

    def hold_for_missing_instrumentation(self) -> OrchestrationState:
        return self.model_copy(
            update={
                "status": "hold",
                "hold_reason": "faithful_instrumentation_unavailable",
            }
        )


def new_orchestration(run_reference: str) -> OrchestrationState:
    return OrchestrationState(
        v=1,
        kind="health_bridge.mailbox_qa_orchestration_state.v1",
        run_reference=run_reference,
        next_index=0,
        status="active",
        hold_reason=None,
    )


__all__ = ["FAULT_SCENARIOS", "SCENARIOS", "OrchestrationState", "new_orchestration"]
