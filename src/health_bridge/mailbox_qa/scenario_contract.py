from __future__ import annotations

from typing import Final, Literal, TypeAlias

SYNTHETIC_PAYLOAD_SHA256: Final = (
    "766959e9b22c188f99ea887bd033ee01d755999c5bde6fc2e9e24d2237876efd"
)
DEVICE_SIGNATURE_DOMAIN: Final = b"health-bridge/mailbox/m3/v1/device-report/signature"
RECEIPT_SIGNATURE_DOMAIN: Final = (
    b"health-bridge/mailbox/m3/v1/scenario-receipt/signature"
)
Producer: TypeAlias = Literal["qa_receiver", "parent_orchestrator"]

SCENARIO_PRODUCERS: Final[dict[str, Producer]] = {
    "actual_icloud_publication": "parent_orchestrator",
    "one_shot_importer": "qa_receiver",
    "authenticated_committed_ack": "parent_orchestrator",
    "restart_retry": "parent_orchestrator",
    "provider_delay": "parent_orchestrator",
    "duplicate_identical": "qa_receiver",
    "conflict_rejected": "qa_receiver",
    "lock_unlock": "parent_orchestrator",
    "foreground_background_termination": "parent_orchestrator",
    "quota_disk_fault": "parent_orchestrator",
    "persisted_encoder_bytes_encrypted_unchanged": "parent_orchestrator",
    "strict_receiver_parse_without_reserialization": "qa_receiver",
    "signed_qa_app_provenance": "parent_orchestrator",
    "cleanup": "parent_orchestrator",
    "rollback": "parent_orchestrator",
    "production_preservation": "parent_orchestrator",
}
EVIDENCE_CLASSES: Final = {
    "actual_icloud_publication": "provider_observation",
    "provider_delay": "provider_observation",
    "lock_unlock": "device_lifecycle",
    "foreground_background_termination": "device_lifecycle",
    "quota_disk_fault": "fault_injection",
    "signed_qa_app_provenance": "provenance",
    "cleanup": "cleanup",
    "rollback": "rollback",
    "production_preservation": "preservation",
}
SCENARIO_CHECKS: Final = {
    "actual_icloud_publication": (
        "qa_container_observed",
        "provider_visible_regular_file",
    ),
    "one_shot_importer": ("single_import_run", "delivery_committed_once"),
    "authenticated_committed_ack": (
        "ack_signature_verified",
        "committed_status_bound",
        "durable_before_ack",
    ),
    "restart_retry": ("retry_survived_restart", "single_final_commit"),
    "provider_delay": ("delay_observed", "bounded_retry_succeeded"),
    "duplicate_identical": ("duplicate_classified", "no_second_commit"),
    "conflict_rejected": (
        "conflicting_same_name_rejected",
        "quarantine_observed",
        "no_conflicting_commit",
    ),
    "lock_unlock": ("locked_attempt_bounded", "unlock_retry_succeeded"),
    "foreground_background_termination": (
        "foreground_published",
        "background_retry_observed",
        "termination_recovery_succeeded",
    ),
    "quota_disk_fault": (
        "local_publisher_enospc_injected",
        "real_icloud_quota_not_claimed",
        "recovery_succeeded",
    ),
    "persisted_encoder_bytes_encrypted_unchanged": (
        "payload_bytes_unchanged",
        "envelope_bytes_unchanged",
    ),
    "strict_receiver_parse_without_reserialization": (
        "strict_parse_succeeded",
        "no_reserialization",
    ),
    "signed_qa_app_provenance": (
        "executable_hash_bound",
        "codesign_identity_bound",
        "qa_entitlements_bound",
    ),
    "cleanup": ("qa_process_stopped", "qa_runtime_removed"),
    "rollback": ("qa_app_removed", "qa_container_artifacts_removed"),
    "production_preservation": (
        "production_identity_unchanged",
        "production_state_unchanged",
    ),
}

__all__ = [
    "DEVICE_SIGNATURE_DOMAIN",
    "EVIDENCE_CLASSES",
    "RECEIPT_SIGNATURE_DOMAIN",
    "SCENARIO_CHECKS",
    "SCENARIO_PRODUCERS",
    "SYNTHETIC_PAYLOAD_SHA256",
]
