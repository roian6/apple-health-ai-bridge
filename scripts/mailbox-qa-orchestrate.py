#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import final

from health_bridge.contract._hbjcs1 import JsonValue, hbjcs1_encode
from health_bridge.mailbox_qa.device_operations import (
    DeviceOperationError,
    issue_device_observed_receipts,
    load_private_owner_key,
)
from health_bridge.mailbox_qa.operation_progress import create_challenge
from health_bridge.mailbox_qa.orchestration import (
    OrchestrationState,
    new_orchestration,
)
from health_bridge.mailbox_qa.parent_operations import (
    ParentOperationError,
    issue_parent_artifact_receipts,
    observe_delayed_ack,
)
from health_bridge.mailbox_qa.production_seal import (
    ProductionIdentitySealV1,
    ProductionSealError,
    load_production_identity_seal,
    validate_qa_runtime_root,
)
from health_bridge.mailbox_qa.scenario_issuance import load_receipt_context
from health_bridge.private_files import (
    ensure_private_directory,
    write_private_text_file,
)


@final
class Arguments(argparse.Namespace):
    action: str = ""
    state: Path = Path()
    run_reference: str = ""
    run_root: Path = Path()
    production_seal: Path = Path()
    production_seal_anchor_sha256: str = ""
    device_report: Path | None = None
    validator_anchor: Path | None = None
    receipt_context: Path | None = None
    parent_receipt_key: Path | None = None
    receipt_dir: Path | None = None
    provider_envelope: Path | None = None
    provenance: Path | None = None
    install_inspection: Path | None = None
    cleanup_output: Path | None = None
    receiver_cleanup: Path | None = None
    inventory_before: Path | None = None
    inventory_after: Path | None = None
    delayed_ack: Path | None = None
    maximum_wait_seconds: int = 0


def main() -> int:
    args = _parser().parse_args(namespace=Arguments())
    try:
        seal = load_production_identity_seal(
            args.production_seal,
            args.production_seal_anchor_sha256,
        )
        validate_qa_runtime_root(seal, args.run_root)
        if args.action == "issue-device-receipts":
            return _issue_device_receipts(args)
        if args.action == "issue-artifact-receipts":
            return _issue_artifact_receipts(args, seal)
        if args.action == "observe-ack-delay":
            return _observe_ack_delay(args)
        return _execute(args)
    except (
        OSError,
        ValueError,
        DeviceOperationError,
        ParentOperationError,
        ProductionSealError,
    ):
        return _emit_rejected()


def _issue_device_receipts(args: Arguments) -> int:
    if (
        args.device_report is None
        or args.validator_anchor is None
        or args.receipt_context is None
        or args.parent_receipt_key is None
        or args.receipt_dir is None
    ):
        raise DeviceOperationError
    context = load_receipt_context(args.receipt_context)
    receipts = issue_device_observed_receipts(
        args.device_report,
        args.validator_anchor,
        context,
        load_private_owner_key(args.parent_receipt_key),
        provider_envelope=args.provider_envelope,
    )
    return _write_receipts(args.receipt_dir, receipts)


def _issue_artifact_receipts(
    args: Arguments,
    seal: ProductionIdentitySealV1,
) -> int:
    paths = (
        args.provenance,
        args.install_inspection,
        args.cleanup_output,
        args.receiver_cleanup,
        args.inventory_before,
        args.inventory_after,
        args.receipt_context,
        args.parent_receipt_key,
        args.receipt_dir,
    )
    if any(path is None for path in paths):
        raise ParentOperationError
    if (
        args.provenance is None
        or args.install_inspection is None
        or args.cleanup_output is None
        or args.receiver_cleanup is None
        or args.inventory_before is None
        or args.inventory_after is None
        or args.receipt_context is None
        or args.parent_receipt_key is None
        or args.receipt_dir is None
    ):
        raise ParentOperationError
    receipts = issue_parent_artifact_receipts(
        args.provenance,
        args.install_inspection,
        args.cleanup_output,
        args.receiver_cleanup,
        args.inventory_before,
        args.inventory_after,
        seal,
        load_receipt_context(args.receipt_context),
        load_private_owner_key(args.parent_receipt_key),
    )
    return _write_receipts(args.receipt_dir, receipts)


def _observe_ack_delay(args: Arguments) -> int:
    if (
        args.delayed_ack is None
        or args.receipt_context is None
        or args.parent_receipt_key is None
        or args.receipt_dir is None
    ):
        raise ParentOperationError
    receipt = observe_delayed_ack(
        args.delayed_ack,
        load_receipt_context(args.receipt_context),
        load_private_owner_key(args.parent_receipt_key),
        maximum_wait_seconds=args.maximum_wait_seconds,
    )
    return _write_receipts(args.receipt_dir, (receipt,))


def _write_receipts(
    receipt_dir: Path,
    receipts: tuple[dict[str, JsonValue], ...],
) -> int:
    ensure_private_directory(receipt_dir)
    for receipt in receipts:
        scenario = receipt["scenario"]
        if not isinstance(scenario, str):
            raise DeviceOperationError
        write_private_text_file(
            receipt_dir / f"{scenario}.hbjcs1",
            hbjcs1_encode(receipt).decode("utf-8"),
        )
    _ = sys.stdout.write(
        json.dumps(
            {
                "v": 1,
                "kind": "health_bridge.mailbox_qa_operation_issuance.v1",
                "status": "observed",
                "receipt_count": len(receipts),
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    )
    return 0


def _execute(args: Arguments) -> int:
    if args.action == "init":
        state = new_orchestration(args.run_reference)
    else:
        state = OrchestrationState.model_validate_json(args.state.read_bytes())
        if args.action == "next":
            return _emit(state)
        if args.action != "execute" or state.next_scenario is None:
            return 1
        if state.next_scenario == "create_challenge":
            _ = create_challenge(args.run_root, state.run_reference)
            state = state.advance("create_challenge")
        else:
            return _emit(state, hold=True)
    write_private_text_file(args.state, state.model_dump_json())
    return _emit(state)


def _emit_rejected() -> int:
    _ = sys.stdout.write(
        json.dumps(
            {
                "v": 1,
                "kind": "health_bridge.mailbox_qa_orchestration_receipt.v1",
                "status": "rejected",
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    )
    return 1


def _emit(state: OrchestrationState, *, hold: bool = False) -> int:
    _ = sys.stdout.write(
        json.dumps(
            {
                "v": 1,
                "kind": "health_bridge.mailbox_qa_orchestration_receipt.v1",
                "status": "hold" if hold else state.status,
                "next_scenario": state.next_scenario,
                "hold_reason": (
                    "device_or_provider_observation_required"
                    if hold
                    else state.hold_reason
                ),
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    )
    return 3 if hold or state.status == "hold" else 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    _ = parser.add_argument(
        "action",
        choices=(
            "init",
            "next",
            "execute",
            "issue-device-receipts",
            "issue-artifact-receipts",
            "observe-ack-delay",
        ),
    )
    _ = parser.add_argument("--state", type=Path, required=True)
    _ = parser.add_argument("--run-reference", default="")
    _ = parser.add_argument("--run-root", type=Path, required=True)
    _ = parser.add_argument("--production-seal", type=Path, required=True)
    _ = parser.add_argument(
        "--production-seal-anchor-sha256",
        required=True,
    )
    _ = parser.add_argument("--device-report", type=Path)
    _ = parser.add_argument("--validator-anchor", type=Path)
    _ = parser.add_argument("--receipt-context", type=Path)
    _ = parser.add_argument("--parent-receipt-key", type=Path)
    _ = parser.add_argument("--receipt-dir", type=Path)
    _ = parser.add_argument("--provider-envelope", type=Path)
    _ = parser.add_argument("--provenance", type=Path)
    _ = parser.add_argument("--install-inspection", type=Path)
    _ = parser.add_argument("--cleanup-output", type=Path)
    _ = parser.add_argument("--receiver-cleanup", type=Path)
    _ = parser.add_argument("--inventory-before", type=Path)
    _ = parser.add_argument("--inventory-after", type=Path)
    _ = parser.add_argument("--delayed-ack", type=Path)
    _ = parser.add_argument("--maximum-wait-seconds", type=int, default=0)
    return parser


if __name__ == "__main__":
    raise SystemExit(main())
