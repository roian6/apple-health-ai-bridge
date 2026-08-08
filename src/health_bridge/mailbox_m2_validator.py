from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path
from typing import ClassVar, Final, Literal

from pydantic import BaseModel, ConfigDict, ValidationError, model_validator
from pydantic_core import PydanticCustomError

from health_bridge._milestone_files import read_scoped_regular_file

REPOSITORY_ROOT: Final = Path(__file__).resolve().parents[2]
EVIDENCE_ROOT: Final = ".omo/evidence/icloud-mailbox-delivery"
SHA256_PATTERN: Final = re.compile(r"^[0-9a-f]{64}$")
COMMIT_PATTERN: Final = re.compile(r"^[0-9a-f]{40}$")
STARTING_PLAN_SHA256: Final = (
    "f6e982dc6804c03dd4138a05fc9fad4905073fb070f67b19697b4340478e0aaf"
)
REQUIRED_SCOPE_PATHS: Final = frozenset(
    {
        "fixtures/delivery_compatibility_v1.synthetic.json",
        "fixtures/delivery_v1_swift.synthetic.json",
        "fixtures/README.md",
        "fixtures/health_bridge_batch_v1.synthetic.json",
        "ios/HealthBridgeCompanion/Tests/HealthBridgeCompanionCoreTests/DeliveryCompatibilityMatrixTests.swift",
        "src/health_bridge/_milestone_files.py",
        "src/health_bridge/mailbox_m2_validator.py",
        "tests/scripts/test_delivery_compatibility_runtime.py",
        "scripts/validate-delivery-compatibility.py",
        "scripts/validate-mailbox-milestone.py",
        "tests/scripts/test_validate_delivery_compatibility.py",
        "tests/scripts/test_validate_mailbox_m2.py",
    }
)
REQUIRED_BOUNDARIES: Final = {
    "direct_finalization_owner": "MARK_UPLOADED_ONLY",
    "mailbox_finalization_owner": "COMMITTED_ACK_ONLY",
    "physical_device_inference": "NONE",
    "raw_legacy_ownership": "PRESERVED",
    "todo12_mailbox_lane": "NOT_STARTED_M3",
}


@dataclass(frozen=True, slots=True)
class ReceiptPolicy:
    kind: str
    path: str
    markers: tuple[bytes, ...]


def _receipt(kind: str, filename: str, *markers: bytes) -> ReceiptPolicy:
    return ReceiptPolicy(kind, f"{EVIDENCE_ROOT}/{filename}", markers)


RECEIPT_POLICIES: Final = (
    _receipt("m1_pin", "task-11-m1-pin-manifest.json", b'"verdict": "PASS"'),
    _receipt("legacy_pin", "task-11-legacy-pin.log", b"SCENARIOS=7", b"FAILURES=0"),
    _receipt("mac_pin", "task-11-mac-pin.log", b"MAC_SCENARIOS=5", b"MAC_FAILURES=0"),
    _receipt(
        "worktree_pin",
        "task-11-preexisting-worktree.sha256",
        b".github/release/criteria.md",
    ),
    _receipt(
        "matrix_red",
        "task-11-matrix-red.log",
        b"missing_approved_baseline",
        b"EXIT=1",
    ),
    _receipt("matrix_green", "task-11-matrix-green.json", b'"verdict": "PASS"'),
    _receipt("linux_focused", "task-11-linux-focused.log", b"LINUX_FOCUSED=PASS"),
    _receipt("mac_focused", "task-11-mac-focused.log", b"MAC_FOCUSED=PASS"),
    _receipt(
        "http_mutation",
        "task-11-mutation-qa.log",
        b"python_http_v1_raw_batch",
        b"EXIT=1",
    ),
    _receipt("linux_full", "task-11-full-linux-gates.log", b"FULL_LINUX_GATES=PASS"),
    _receipt("swift_full", "task-11-swift-full.log", b"SWIFT_FULL=PASS"),
    _receipt("simulator_arm64", "task-11-simulator-arm64.log", b"SIMULATOR_ARM64=PASS"),
    _receipt(
        "simulator_x86_64",
        "task-11-simulator-x86_64.log",
        b"SIMULATOR_X86_64=PASS",
    ),
    _receipt(
        "cleanup_parity",
        "task-11-cleanup-parity.log",
        b"CLEANUP_PARITY=PASS",
        b"PHYSICAL_INFERENCE=NONE",
    ),
)
RECEIPT_POLICY_BY_KIND: Final = {policy.kind: policy for policy in RECEIPT_POLICIES}


class M2Model(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid",
        frozen=True,
        strict=True,
    )


class PathDigest(M2Model):
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


class M2Manifest(M2Model):
    v: Literal[1]
    milestone: Literal["M2"]
    verdict: Literal["PASS", "HOLD", "FAIL"]
    head: str
    starting_plan_sha256: Literal[
        "f6e982dc6804c03dd4138a05fc9fad4905073fb070f67b19697b4340478e0aaf"
    ]
    scope: tuple[PathDigest, ...]
    receipts: tuple[ReceiptDigest, ...]
    boundaries: dict[str, str]

    @model_validator(mode="after")
    def exact_shape(self) -> M2Manifest:
        scope_paths = [binding.path for binding in self.scope]
        receipt_kinds = [receipt.kind for receipt in self.receipts]
        receipt_paths = [receipt.path for receipt in self.receipts]
        expected_paths = {policy.kind: policy.path for policy in RECEIPT_POLICIES}
        shape_valid = (
            COMMIT_PATTERN.fullmatch(self.head) is not None
            and len(scope_paths) == len(set(scope_paths))
            and frozenset(scope_paths) == REQUIRED_SCOPE_PATHS
            and len(receipt_kinds) == len(set(receipt_kinds))
            and len(receipt_paths) == len(set(receipt_paths))
            and {receipt.kind: receipt.path for receipt in self.receipts}
            == expected_paths
            and self.boundaries == REQUIRED_BOUNDARIES
        )
        if not shape_valid:
            error_type = "shape"
            error_message = "invalid manifest shape"
            raise PydanticCustomError(error_type, error_message)
        return self


def validate_m2_manifest(manifest_path: Path, commit: str) -> tuple[int, str]:
    try:
        manifest = M2Manifest.model_validate_json(manifest_path.read_bytes())
    except (OSError, ValidationError):
        return 1, "FAIL M2 invalid_manifest\n"
    reason: str | None = None
    if manifest.head != commit:
        reason = "stale_commit"
    elif any(not _file_matches(binding) for binding in manifest.scope):
        reason = "stale_scope"
    elif any(
        not _file_matches(receipt, RECEIPT_POLICY_BY_KIND[receipt.kind].markers)
        for receipt in manifest.receipts
    ):
        reason = "stale_receipt"
    if reason is not None:
        return 1, f"FAIL M2 {reason}\n"
    match manifest.verdict:
        case "PASS":
            outcome = (0, "PASS M2\n")
        case "HOLD":
            outcome = (3, "HOLD M2\n")
        case "FAIL":
            outcome = (1, "FAIL M2 manifest_verdict\n")
    return outcome


def _file_matches(binding: PathDigest, markers: tuple[bytes, ...] = ()) -> bool:
    required_prefix = EVIDENCE_ROOT if markers else None
    content = read_scoped_regular_file(
        REPOSITORY_ROOT,
        binding.path,
        required_prefix,
    )
    return (
        content is not None
        and hashlib.sha256(content).hexdigest() == binding.sha256
        and all(marker in content for marker in markers)
    )
