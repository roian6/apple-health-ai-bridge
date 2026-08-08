from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from typing import TYPE_CHECKING, ClassVar, Final, Literal, Protocol

from pydantic import BaseModel, ConfigDict, ValidationError, model_validator
from pydantic_core import PydanticCustomError

if TYPE_CHECKING:
    from pathlib import Path

RECEIPT_ROOT: Final = "tests/fixtures/mailbox_m1/receipts"
SHA256_PATTERN: Final = re.compile(r"^[0-9a-f]{64}$")
COMMIT_PATTERN: Final = re.compile(r"^[0-9a-f]{40}$")
REQUIRED_SCOPE_PATHS: Final = frozenset(
    {
        "fixtures/delivery_v1_python.synthetic.json",
        "fixtures/delivery_v1_swift.synthetic.json",
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/DeliveryProtocolV1.swift",
        "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/MailboxKeyStore.swift",
        "pyproject.toml",
        "scripts/mailbox_m1_files.py",
        "scripts/validate-mailbox-milestone.py",
        "src/health_bridge/contract/delivery_v1.py",
        "src/health_bridge/ingest.py",
        "src/health_bridge/mailbox_m1_validator.py",
        "src/health_bridge/receiver/_delivery_acceptance_crypto.py",
        "src/health_bridge/receiver/_delivery_acceptance_models.py",
        "src/health_bridge/receiver/delivery_acceptance.py",
        "src/health_bridge/receiver/mailbox_keys.py",
        "src/health_bridge/storage/database.py",
        "src/health_bridge/storage/delivery_receipts.py",
        "src/health_bridge/storage/migrations/008_delivery_receipts.sql",
        "src/health_bridge/storage/sync_runs.py",
        "tests/fixtures/mailbox_m1/scope-anchor.synthetic.json",
        "tests/receiver/delivery_acceptance_support.py",
        "tests/receiver/test_delivery_acceptance.py",
        "tests/receiver/test_delivery_acceptance_failures.py",
        "tests/scripts/mailbox_m1_fixture_support.py",
        "tests/scripts/mailbox_m1_path_support.py",
        "tests/scripts/test_validate_mailbox_m1.py",
        "tests/scripts/test_validate_mailbox_m1_paths.py",
        "uv.lock",
    }
)
FROZEN_SCOPE_DIGESTS: Final = {
    "tests/fixtures/mailbox_m1/scope-anchor.synthetic.json": (
        "c4ce5f392620e2d29dab4edab515dd307f72a81315a009c1d95e77c47f0d1415"
    )
}
REQUIRED_BOUNDARIES: Final = {
    "all_trust_backends_erased": "HOLD_EXTERNAL_TRUST",
    "durable_v4_outbox_publication": "NOT_CLAIMED_M3",
    "physical_device_icloud": "NOT_CLAIMED_M3",
}


class ScopedFileReader(Protocol):
    def __call__(
        self,
        repository_root: Path,
        relative_path: str,
        required_prefix: str | None = None,
    ) -> bytes | None: ...


@dataclass(frozen=True, slots=True)
class M1ValidationContext:
    repository_root: Path
    file_reader: ScopedFileReader


@dataclass(frozen=True, slots=True)
class ReceiptPolicy:
    kind: str
    path: str
    markers: tuple[bytes, ...]


def _receipt(kind: str, filename: str, checkset: str) -> ReceiptPolicy:
    return ReceiptPolicy(
        kind=kind,
        path=f"{RECEIPT_ROOT}/{filename}",
        markers=(
            f'"kind":"{kind}"'.encode(),
            f'"checkset":"{checkset}"'.encode(),
            b'"status":"verified"',
            b'"synthetic":true',
        ),
    )


RECEIPT_POLICIES: Final = (
    _receipt(
        "dependency_contract",
        "dependency-contract.synthetic.json",
        "locked_dependency_and_audit",
    ),
    _receipt(
        "python_exact_bytes",
        "python-exact-bytes.synthetic.json",
        "canonical_delivery_bytes",
    ),
    _receipt("swift_parity", "swift-parity.synthetic.json", "cross_language_parity"),
    _receipt("key_lifecycle", "key-lifecycle.synthetic.json", "key_state_lifecycle"),
    _receipt(
        "migration_rollback",
        "migration-rollback.synthetic.json",
        "durable_migration_rollback",
    ),
    _receipt(
        "transaction_crash_atomicity",
        "transaction-crash-atomicity.synthetic.json",
        "transaction_and_crash_atomicity",
    ),
)
RECEIPT_POLICY_BY_KIND: Final = {policy.kind: policy for policy in RECEIPT_POLICIES}


class PathDigest(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", frozen=True)

    path: str
    sha256: str

    @model_validator(mode="after")
    def exact_digest(self) -> PathDigest:
        if SHA256_PATTERN.fullmatch(self.sha256) is None:
            error_type = "sha256"
            error_message = "invalid sha256"
            raise PydanticCustomError(error_type, error_message)
        return self


class ReceiptDigest(PathDigest):
    kind: str


class M1Manifest(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", frozen=True)

    v: Literal[1]
    milestone: Literal["M1"]
    verdict: Literal["PASS", "HOLD", "FAIL"]
    head: str
    scope: tuple[PathDigest, ...]
    receipts: tuple[ReceiptDigest, ...]
    boundaries: dict[str, str]

    @model_validator(mode="after")
    def exact_shape(self) -> M1Manifest:
        if COMMIT_PATTERN.fullmatch(self.head) is None:
            error_type = "head"
            error_message = "invalid head"
            raise PydanticCustomError(error_type, error_message)
        scope_paths = [binding.path for binding in self.scope]
        if (
            len(scope_paths) != len(set(scope_paths))
            or frozenset(scope_paths) != REQUIRED_SCOPE_PATHS
        ):
            error_type = "scope"
            error_message = "invalid scope"
            raise PydanticCustomError(error_type, error_message)
        kinds = [receipt.kind for receipt in self.receipts]
        paths = [receipt.path for receipt in self.receipts]
        hashes = [receipt.sha256 for receipt in self.receipts]
        kind_paths = {receipt.kind: receipt.path for receipt in self.receipts}
        expected_kind_paths = {policy.kind: policy.path for policy in RECEIPT_POLICIES}
        if (
            len(kinds) != len(set(kinds))
            or len(paths) != len(set(paths))
            or len(hashes) != len(set(hashes))
            or kind_paths != expected_kind_paths
        ):
            error_type = "receipts"
            error_message = "invalid receipts"
            raise PydanticCustomError(error_type, error_message)
        if self.boundaries != REQUIRED_BOUNDARIES:
            error_type = "boundaries"
            error_message = "invalid boundaries"
            raise PydanticCustomError(error_type, error_message)
        return self


def validate_m1_manifest(
    manifest_path: Path,
    commit: str,
    context: M1ValidationContext,
) -> tuple[int, str]:
    try:
        manifest = M1Manifest.model_validate_json(manifest_path.read_bytes())
    except (OSError, ValidationError):
        return 1, "FAIL M1 invalid_manifest\n"
    reason: str | None = None
    if manifest.head != commit:
        reason = "stale_commit"
    elif any(
        not _scope_binding_matches(binding, context) for binding in manifest.scope
    ):
        reason = "stale_scope"
    elif any(
        not _file_matches(
            receipt,
            context,
            RECEIPT_POLICY_BY_KIND[receipt.kind].markers,
        )
        for receipt in manifest.receipts
    ):
        reason = "stale_receipt"
    if reason is not None:
        return 1, f"FAIL M1 {reason}\n"
    match manifest.verdict:
        case "PASS":
            return 0, "PASS M1\n"
        case "HOLD":
            return 3, "HOLD M1\n"
        case "FAIL":
            return 1, "FAIL M1 manifest_verdict\n"


def _scope_binding_matches(
    binding: PathDigest,
    context: M1ValidationContext,
) -> bool:
    frozen_digest = FROZEN_SCOPE_DIGESTS.get(binding.path)
    if frozen_digest is not None:
        return binding.sha256 == frozen_digest
    return _file_matches(binding, context)


def _file_matches(
    binding: PathDigest,
    context: M1ValidationContext,
    markers: tuple[bytes, ...] = (),
) -> bool:
    required_prefix = RECEIPT_ROOT if markers else None
    content = context.file_reader(
        context.repository_root,
        binding.path,
        required_prefix,
    )
    return (
        content is not None
        and hashlib.sha256(content).hexdigest() == binding.sha256
        and all(marker in content for marker in markers)
    )


__all__ = [
    "FROZEN_SCOPE_DIGESTS",
    "RECEIPT_POLICIES",
    "REQUIRED_BOUNDARIES",
    "REQUIRED_SCOPE_PATHS",
    "M1ValidationContext",
    "validate_m1_manifest",
]
