#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path
from typing import ClassVar, final

from pydantic import ValidationError

from health_bridge.contract._hbjcs1 import hbjcs1_encode
from health_bridge.mailbox_qa.lifecycle import (
    acknowledgment_ready,
    cleanup_receiver,
    create_action_material,
    create_pairing_material,
    health_receiver,
    import_once,
    prepare_receiver,
    receiver_receipt_private_key,
    serve_receiver,
    stop_receiver,
)
from health_bridge.mailbox_qa.production_seal import (
    ProductionSealError,
    load_production_identity_seal,
    production_seal_fingerprint,
)
from health_bridge.mailbox_qa.receiver import QAReceiverConfig
from health_bridge.mailbox_qa.receiver_operations import (
    issue_receiver_receipts,
    run_receiver_operation,
    write_receiver_operation,
)
from health_bridge.mailbox_qa.scenario_issuance import (
    ScenarioIssuanceError,
    load_receipt_context,
)
from health_bridge.private_files import (
    ensure_private_directory,
    write_private_text_file,
)


@final
class Arguments(argparse.Namespace):
    action: str = ""
    runtime_root: Path = Path()
    host: str = ""
    port: int = 0
    namespace: str = ""
    bundle_identifier: str = ""
    container_identifier: str = ""
    url_scheme: str = ""
    keychain_service: str = ""
    keychain_access_group: ClassVar[list[str]] = []
    outbox_root: str = ""
    display_identity: str = ""
    database_namespace: str = ""
    app_path: Path = Path()
    mailbox_root: Path | None = None
    production_seal: Path = Path()
    production_seal_anchor_sha256: str = ""
    run_id: str = ""
    challenge: str = ""
    source_commit: str = ""
    cleanup_receipt: Path | None = None
    operation_observation: Path | None = None
    receipt_context: Path | None = None
    receipt_dir: Path | None = None
    dry_run: bool = False
    fault: str | None = None


def main() -> int:
    args = _parser().parse_args(namespace=Arguments())
    try:
        seal = load_production_identity_seal(
            args.production_seal,
            args.production_seal_anchor_sha256,
        )
        config = QAReceiverConfig(
            runtime_root=args.runtime_root,
            host=args.host,
            port=args.port,
            namespace=args.namespace,
            bundle_identifier=args.bundle_identifier,
            container_identifier=args.container_identifier,
            url_scheme=args.url_scheme,
            keychain_service=args.keychain_service,
            keychain_access_groups=tuple(args.keychain_access_group),
            outbox_root=args.outbox_root,
            display_identity=args.display_identity,
            database_namespace=args.database_namespace,
            app_path=args.app_path,
            mailbox_root_override=args.mailbox_root,
            production_seal=seal,
            production_seal_fingerprint=production_seal_fingerprint(seal),
        )
    except (OSError, ValueError, ValidationError, ProductionSealError):
        return _emit(args.action, "rejected")
    if args.dry_run:
        return _emit(args.action, "validated")
    try:
        status = _execute(args, config)
    except (
        OSError,
        RuntimeError,
        ValueError,
        ValidationError,
        ScenarioIssuanceError,
        sqlite3.Error,
    ):
        return _emit(args.action, "rejected")
    return 1 if status is None else _emit(args.action, status)


def _execute(  # noqa: PLR0911
    args: Arguments,
    config: QAReceiverConfig,
) -> str | None:
    if args.action == "health":
        return "healthy" if health_receiver(config) else "hold"
    if args.action == "ack":
        return "ready" if acknowledgment_ready(config) else "hold"
    if args.action in (
        "pairing",
        "advance",
        "scan-finalize",
        "signed-report",
        "app-cleanup",
    ):
        return _create_invocation(args, config)
    if args.action == "cleanup":
        if args.cleanup_receipt is None:
            return None
        cleanup_receiver(config, args.cleanup_receipt)
        return "complete"
    if args.action in (
        "one-shot-import",
        "duplicate-identical",
        "conflict-rejected",
    ):
        return _execute_receiver_operation(args, config)
    runners = {
        "prepare": lambda: prepare_receiver(config),
        "serve": lambda: serve_receiver(config),
        "import": lambda: import_once(config),
        "stop": lambda: stop_receiver(config),
    }
    runner = runners.get(args.action)
    if runner is None:
        return None
    _ = runner()
    return "complete"


def _create_invocation(args: Arguments, config: QAReceiverConfig) -> str | None:
    if args.action == "pairing":
        _ = create_pairing_material(
            config,
            run_id=args.run_id,
            challenge=args.challenge,
            source_commit=args.source_commit,
        )
        return "complete"
    if args.action in ("advance", "scan-finalize", "signed-report", "app-cleanup"):
        action = {
            "advance": "advance",
            "scan-finalize": "scan_finalize",
            "signed-report": "signed_report",
            "app-cleanup": "cleanup",
        }[args.action]
        if args.fault is not None and args.action != "advance":
            return None
        _ = create_action_material(
            config,
            action=action,
            run_id=args.run_id,
            challenge=args.challenge,
            source_commit=args.source_commit,
            fault=args.fault,
        )
        return "complete"
    return None


def _execute_receiver_operation(
    args: Arguments,
    config: QAReceiverConfig,
) -> str | None:
    if (
        args.operation_observation is None
        or args.receipt_context is None
        or args.receipt_dir is None
    ):
        return None
    operation = {
        "one-shot-import": "one_shot_importer",
        "duplicate-identical": "duplicate_identical",
        "conflict-rejected": "conflict_rejected",
    }[args.action]
    observation = run_receiver_operation(config, operation)
    write_receiver_operation(args.operation_observation, observation)
    context = load_receipt_context(args.receipt_context)
    receipts = issue_receiver_receipts(
        observation,
        context,
        receiver_receipt_private_key(config),
    )
    ensure_private_directory(args.receipt_dir)
    for receipt in receipts:
        scenario = receipt["scenario"]
        if not isinstance(scenario, str):
            raise TypeError
        write_private_text_file(
            args.receipt_dir / f"{scenario}.hbjcs1",
            hbjcs1_encode(receipt).decode("utf-8"),
        )
    return "complete"


def _emit(action: str, status: str) -> int:
    _ = sys.stdout.write(
        json.dumps(
            {
                "v": 1,
                "kind": "health_bridge.mailbox_qa_lifecycle_receipt.v1",
                "action": action,
                "status": status,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    )
    if status == "hold":
        return 3
    return 1 if status == "rejected" else 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    _ = parser.add_argument(
        "action",
        choices=(
            "prepare",
            "serve",
            "health",
            "pairing",
            "advance",
            "scan-finalize",
            "signed-report",
            "app-cleanup",
            "import",
            "ack",
            "stop",
            "cleanup",
            "one-shot-import",
            "duplicate-identical",
            "conflict-rejected",
        ),
    )
    _ = parser.add_argument("--runtime-root", type=Path, required=True)
    _ = parser.add_argument("--host", required=True)
    _ = parser.add_argument("--port", type=int, required=True)
    _ = parser.add_argument("--namespace", required=True)
    _ = parser.add_argument("--bundle-identifier", required=True)
    _ = parser.add_argument("--container-identifier", required=True)
    _ = parser.add_argument("--url-scheme", required=True)
    _ = parser.add_argument("--keychain-service", required=True)
    _ = parser.add_argument("--keychain-access-group", action="append", required=True)
    _ = parser.add_argument("--outbox-root", required=True)
    _ = parser.add_argument("--display-identity", required=True)
    _ = parser.add_argument("--database-namespace", required=True)
    _ = parser.add_argument("--app-path", type=Path, required=True)
    _ = parser.add_argument("--mailbox-root", type=Path)
    _ = parser.add_argument("--production-seal", type=Path, required=True)
    _ = parser.add_argument("--production-seal-anchor-sha256", required=True)
    _ = parser.add_argument("--run-id", default="")
    _ = parser.add_argument("--challenge", default="")
    _ = parser.add_argument("--source-commit", default="")
    _ = parser.add_argument("--cleanup-receipt", type=Path)
    _ = parser.add_argument("--operation-observation", type=Path)
    _ = parser.add_argument("--receipt-context", type=Path)
    _ = parser.add_argument("--receipt-dir", type=Path)
    _ = parser.add_argument("--dry-run", action="store_true")
    _ = parser.add_argument("--fault", choices=("publisher_enospc",))
    return parser


if __name__ == "__main__":
    raise SystemExit(main())
