#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import sys
from pathlib import Path
from typing import TYPE_CHECKING, ClassVar, Final, TypeAlias, cast, final

from health_bridge.mailbox_qa.archive_provenance import (
    QAArchiveProvenanceV1,
    load_archive_provenance,
    write_archive_provenance,
)
from health_bridge.mailbox_qa.production_seal import (
    ProductionIdentitySealV1,
    ProductionSealError,
    QAIsolationRequest,
    inventory_observes_app_path,
    load_production_identity_seal,
    validate_qa_isolation,
)
from health_bridge.private_files import write_private_text_file

if TYPE_CHECKING:
    from health_bridge.contract._hbjcs1 import JsonValue

PlistValue: TypeAlias = (
    str | int | bool | bytes | list["PlistValue"] | dict[str, "PlistValue"]
)

QA_SCHEME: Final = "HealthBridgeCompanionMailboxQA"
QA_TARGET: Final = "HealthBridgeCompanionMailboxQA"
PUBLIC_QA_SCHEME: Final = "HealthBridgeCompanionPublicDocumentsQA"
PUBLIC_QA_TARGET: Final = "HealthBridgeCompanionPublicDocumentsQA"
ALLOWED_QA_LANES: Final = frozenset(
    {
        (QA_SCHEME, QA_TARGET),
        (PUBLIC_QA_SCHEME, PUBLIC_QA_TARGET),
    }
)
QA_SCHEME_REFERENCE_COUNT: Final = 2
FORBIDDEN_SOURCE_PARTS: Final = (
    "HealthKit",
    "ReceiverClient",
    "Background",
    "Settings",
    "ViewModel",
)
QA_SOURCE_MEMBERS: Final = frozenset(
    {
        "DeliveryProtocolV1.swift",
        "DeliveryProtocolV1Ack.swift",
        "DeliveryProtocolV1AckAuthentication.swift",
        "DeliveryProtocolV1Canonical.swift",
        "DeliveryProtocolV1Envelope.swift",
        "DeliveryProtocolV1Models.swift",
        "DeliveryProtocolV1Outbound.swift",
        "DeliveryProtocolV1Payload.swift",
        "BatchV1.swift",
        "FileOutbox.swift",
        "HealthTypeRegistry.swift",
        "MailboxAckClassifier.swift",
        "MailboxAckDeletion.swift",
        "MailboxAckFileReader.swift",
        "MailboxAckModels.swift",
        "MailboxAckOutboxLookup.swift",
        "MailboxAckScanner.swift",
        "MailboxAtomicPublisher.swift",
        "MailboxEnvelopeSealer.swift",
        "MailboxKeyIdentity.swift",
        "MailboxLayoutV1.swift",
        "MailboxLocatorV1.swift",
        "MailboxQAApp.swift",
        "MailboxQAConfiguration.swift",
        "MailboxQADeliveryTransportTypes.swift",
        "MailboxQAHarness.swift",
        "MailboxQAHarnessDependencies.swift",
        "MailboxQAInvocation.swift",
        "MailboxQAModels.swift",
        "MailboxQAReport.swift",
        "MailboxQASyntheticPayload.swift",
        "MailboxRegularFileReader.swift",
        "MailboxTransport.swift",
        "MailboxTransportModels.swift",
        "OutboxDeliveryCoordinator.swift",
        "OutboxDeliveryCoordinatorAck.swift",
        "OutboxDeliveryFinalizers.swift",
        "OutboxDeliveryModels.swift",
    }
)


@final
class Arguments(argparse.Namespace):
    action: str = ""
    seal: Path = Path()
    anchor_sha256: str = ""
    bundle_identifier: str = ""
    container_identifier: str = ""
    url_scheme: str = ""
    keychain_service: str = ""
    keychain_access_group: ClassVar[list[str]] = []
    outbox_root: str = ""
    display_identity: str = ""
    receiver_port: int = 0
    runtime_root: Path = Path()
    database_namespace: str = ""
    app_path: Path = Path()
    project: Path = Path()
    scheme_name: str = QA_SCHEME
    target_name: str = QA_TARGET
    info_plist: Path = Path()
    entitlements_plist: Path = Path()
    inventory: Path = Path()
    expected_commit: str = ""
    qa_executable_sha256: str = ""
    qa_codesign_identity_sha256: str = ""
    provenance: Path = Path()
    cleanup_output: Path = Path()
    inspection_observation: Path = Path()


def main() -> int:
    args = _parser().parse_args(namespace=Arguments())
    try:
        if args.action == "assert-target":
            _assert_target(args.project, args.scheme_name, args.target_name)
            return _emit("target_validated")
        _validate_lane(args.scheme_name, args.target_name)
        seal = load_production_identity_seal(args.seal, args.anchor_sha256)
        request = QAIsolationRequest(
            bundle_identifier=args.bundle_identifier,
            container_identifier=args.container_identifier,
            url_scheme=args.url_scheme,
            keychain_service=args.keychain_service,
            keychain_access_groups=tuple(args.keychain_access_group),
            outbox_root=args.outbox_root,
            display_identity=args.display_identity,
            receiver_port=args.receiver_port,
            runtime_root=args.runtime_root,
            database_namespace=args.database_namespace,
            app_path=args.app_path,
        )
        fingerprint = validate_qa_isolation(seal, request)
        if args.action == "write-provenance":
            write_archive_provenance(
                args.provenance,
                QAArchiveProvenanceV1(
                    v=1,
                    kind="health_bridge.mailbox_qa_archive_provenance.v1",
                    source_commit=args.expected_commit,
                    production_seal_fingerprint=fingerprint,
                    executable_sha256=args.qa_executable_sha256,
                    codesign_identity_sha256=args.qa_codesign_identity_sha256,
                    scheme=args.scheme_name,
                    target=args.target_name,
                ),
            )
        if args.action == "inspect-install":
            _inspect_install(args, seal, fingerprint)
        if args.action == "confirm-install":
            _confirm_install(args, seal)
        if args.action == "confirm-rollback":
            _confirm_rollback(args, seal)
        return _emit("validated", fingerprint)
    except (OSError, ValueError, KeyError, ProductionSealError):
        return _emit("rejected", None, status=1)


def _validate_lane(scheme_name: str, target_name: str) -> None:
    if (scheme_name, target_name) not in ALLOWED_QA_LANES:
        raise ProductionSealError


def _assert_target(project: Path, scheme_name: str, target_name: str) -> None:
    _validate_lane(scheme_name, target_name)
    text = project.read_text(encoding="utf-8")
    target = re.search(
        "".join(
            (
                rf"/\* {re.escape(target_name)} \*/ = \{{\n\s+isa = PBXNativeTarget;",
                r"(?P<body>.*?)\n\s+\};",
            )
        ),
        text,
        re.DOTALL,
    )
    if target is None:
        raise ProductionSealError
    source_phase = re.search(
        r"(?P<identifier>[A-F0-9]{24}) /\* Sources \*/",
        target.group("body"),
    )
    if source_phase is None:
        raise ProductionSealError
    phase = re.search(
        "".join(
            (
                rf"{source_phase.group('identifier')} /\* Sources \*/ = ",
                r"\{isa = PBXSourcesBuildPhase;.*?files = \((?P<body>.*?)\); ",
            )
        ),
        text,
        re.DOTALL,
    )
    if phase is None:
        raise ProductionSealError
    members = re.findall(
        r"/\* ([A-Za-z0-9]+\.swift) in Sources \*/",
        phase.group("body"),
    )
    scheme = (
        project.parent / f"xcshareddata/xcschemes/{scheme_name}.xcscheme"
    ).read_text(encoding="utf-8")
    if (
        set(members) != set(QA_SOURCE_MEMBERS)
        or len(members) != len(QA_SOURCE_MEMBERS)
        or "MailboxQAApp.swift" not in members
        or any(part in member for member in members for part in FORBIDDEN_SOURCE_PARTS)
        or scheme.count(f'BlueprintName="{target_name}"') != QA_SCHEME_REFERENCE_COUNT
        or 'BlueprintName="HealthBridgeCompanion"' in scheme
    ):
        raise ProductionSealError


def _inspect_install(
    args: Arguments,
    seal: ProductionIdentitySealV1,
    production_seal_fingerprint: str,
) -> None:
    info = _plist(args.info_plist)
    entitlements = _plist(args.entitlements_plist)
    required_info = (
        info["CFBundleIdentifier"] == args.bundle_identifier
        and info["HealthBridgeQAICloudContainerIdentifier"] == args.container_identifier
        and info["HealthBridgeQAKeychainService"] == args.keychain_service
        and info["HealthBridgeQAOutboxRoot"] == args.outbox_root
        and info["CFBundleDisplayName"] == args.display_identity
        and info["HealthBridgeQASourceCommit"] == args.expected_commit
        and info["HealthBridgeQASchemeName"] == args.scheme_name
        and info["HealthBridgeQATargetName"] == args.target_name
    )
    containers = entitlements["com.apple.developer.icloud-container-identifiers"]
    access_groups = entitlements["keychain-access-groups"]
    application_identifier = entitlements["application-identifier"]
    entitlement_valid = (
        containers == [args.container_identifier]
        and access_groups == args.keychain_access_group
        and application_identifier in args.keychain_access_group
        and not any("healthkit" in key.lower() for key in entitlements)
        and not any(
            _contains_text(entitlements, value)
            for value in _sealed_identity_values(seal)
        )
    )
    inventory = _json_value(args.inventory)
    inventory_values = tuple(_strings(inventory))
    inventory_valid = (
        seal.bundle_identifier in inventory_values
        and inventory_observes_app_path(inventory_values, seal.installed_app_path)
        and args.bundle_identifier != seal.bundle_identifier
        and args.bundle_identifier not in inventory_values
        and str(args.app_path) not in inventory_values
    )
    provenance = load_archive_provenance(args.provenance)
    provenance_valid = (
        provenance.source_commit == args.expected_commit
        and provenance.production_seal_fingerprint == production_seal_fingerprint
        and provenance.executable_sha256 == args.qa_executable_sha256
        and provenance.codesign_identity_sha256 == args.qa_codesign_identity_sha256
        and provenance.scheme == args.scheme_name
        and provenance.target == args.target_name
    )
    if (
        not required_info
        or not entitlement_valid
        or not inventory_valid
        or not provenance_valid
    ):
        raise ProductionSealError
    write_private_text_file(
        args.inspection_observation,
        json.dumps(
            {
                "v": 1,
                "kind": "health_bridge.mailbox_qa_install_inspection.v1",
                "result": "validated",
                "source_commit": args.expected_commit,
                "production_seal_fingerprint": production_seal_fingerprint,
                "executable_sha256": args.qa_executable_sha256,
                "codesign_identity_sha256": args.qa_codesign_identity_sha256,
                "info_plist_sha256": hashlib.sha256(
                    args.info_plist.read_bytes()
                ).hexdigest(),
                "entitlements_sha256": hashlib.sha256(
                    args.entitlements_plist.read_bytes()
                ).hexdigest(),
                "inventory_sha256": hashlib.sha256(
                    args.inventory.read_bytes()
                ).hexdigest(),
            },
            sort_keys=True,
            separators=(",", ":"),
        ),
    )


def _confirm_install(
    args: Arguments,
    seal: ProductionIdentitySealV1,
) -> None:
    inventory = _json_value(args.inventory)
    values = tuple(_strings(inventory))
    if (
        seal.bundle_identifier not in values
        or not inventory_observes_app_path(values, seal.installed_app_path)
        or args.bundle_identifier not in values
    ):
        raise ProductionSealError


def _confirm_rollback(
    args: Arguments,
    seal: ProductionIdentitySealV1,
) -> None:
    inventory = _json_value(args.inventory)
    values = tuple(_strings(inventory))
    cleanup = _json_value(args.cleanup_output)
    cleanup_valid = cleanup == {
        "action": "cleanup",
        "kind": "health_bridge.mailbox_qa_invocation_output.v1",
        "status": "qa_artifacts_removed",
        "v": 1,
    }
    if (
        seal.bundle_identifier not in values
        or not inventory_observes_app_path(values, seal.installed_app_path)
        or args.bundle_identifier in values
        or not cleanup_valid
    ):
        raise ProductionSealError


def _plist(path: Path) -> dict[str, PlistValue]:
    value = cast("object", plistlib.loads(path.read_bytes()))
    if not isinstance(value, dict):
        raise ProductionSealError
    mapping = cast("dict[object, object]", value)
    if not all(isinstance(key, str) for key in mapping):
        raise ProductionSealError
    return cast("dict[str, PlistValue]", mapping)


def _json_value(path: Path) -> JsonValue:
    return cast("JsonValue", json.loads(path.read_bytes()))


def _contains_text(value: PlistValue, text: str) -> bool:
    return any(item == text for item in _strings(value))


def _sealed_identity_values(seal: ProductionIdentitySealV1) -> tuple[str, ...]:
    return (
        seal.bundle_identifier,
        *seal.icloud_containers,
        *seal.url_schemes,
        *seal.keychain_services,
        *seal.keychain_access_groups,
        seal.display_identity,
        *seal.outbox_roots,
        *seal.runtime_roots,
        *seal.database_namespaces,
        seal.installed_app_path,
    )


def _strings(value: PlistValue | JsonValue) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [item for child in value for item in _strings(child)]
    if isinstance(value, dict):
        return [item for child in value.values() for item in _strings(child)]
    return []


def _emit(
    result: str,
    fingerprint: str | None = None,
    *,
    status: int = 0,
) -> int:
    output: dict[str, int | str] = {
        "v": 1,
        "kind": "health_bridge.production_identity_seal_check.v1",
        "result": result,
    }
    if fingerprint is not None:
        output["seal_fingerprint"] = fingerprint
    _ = sys.stdout.write(
        json.dumps(output, sort_keys=True, separators=(",", ":")) + "\n"
    )
    return status


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="action", required=True)
    target = subparsers.add_parser("assert-target")
    _ = target.add_argument("--project", type=Path, required=True)
    _ = target.add_argument("--scheme-name", default=QA_SCHEME)
    _ = target.add_argument("--target-name", default=QA_TARGET)
    for action in (
        "validate",
        "write-provenance",
        "inspect-install",
        "confirm-install",
        "confirm-rollback",
    ):
        command = subparsers.add_parser(action)
        _add_isolation_arguments(command)
        if action in ("write-provenance", "inspect-install"):
            _ = command.add_argument("--expected-commit", required=True)
            _ = command.add_argument("--qa-executable-sha256", required=True)
            _ = command.add_argument(
                "--qa-codesign-identity-sha256",
                required=True,
            )
            _ = command.add_argument("--provenance", type=Path, required=True)
        if action == "inspect-install":
            _ = command.add_argument("--info-plist", type=Path, required=True)
            _ = command.add_argument("--entitlements-plist", type=Path, required=True)
            _ = command.add_argument("--inventory", type=Path, required=True)
            _ = command.add_argument(
                "--inspection-observation",
                type=Path,
                required=True,
            )
        if action in ("confirm-install", "confirm-rollback"):
            _ = command.add_argument("--inventory", type=Path, required=True)
        if action == "confirm-rollback":
            _ = command.add_argument("--cleanup-output", type=Path, required=True)
    return parser


def _add_isolation_arguments(parser: argparse.ArgumentParser) -> None:
    _ = parser.add_argument("--seal", type=Path, required=True)
    _ = parser.add_argument("--anchor-sha256", required=True)
    _ = parser.add_argument("--scheme-name", default=QA_SCHEME)
    _ = parser.add_argument("--target-name", default=QA_TARGET)
    _ = parser.add_argument("--bundle-identifier", required=True)
    _ = parser.add_argument("--container-identifier", required=True)
    _ = parser.add_argument("--url-scheme", required=True)
    _ = parser.add_argument("--keychain-service", required=True)
    _ = parser.add_argument("--keychain-access-group", action="append", required=True)
    _ = parser.add_argument("--outbox-root", required=True)
    _ = parser.add_argument("--display-identity", required=True)
    _ = parser.add_argument("--receiver-port", type=int, required=True)
    _ = parser.add_argument("--runtime-root", type=Path, required=True)
    _ = parser.add_argument("--database-namespace", required=True)
    _ = parser.add_argument("--app-path", type=Path, required=True)


if __name__ == "__main__":
    raise SystemExit(main())
