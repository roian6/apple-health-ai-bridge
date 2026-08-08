from __future__ import annotations

from dataclasses import dataclass
from typing import Final

from health_bridge.mailbox_qa.scenario_contract import (
    DEVICE_SIGNATURE_DOMAIN,
    EVIDENCE_CLASSES,
    RECEIPT_SIGNATURE_DOMAIN,
    SCENARIO_CHECKS,
    SCENARIO_PRODUCERS,
    SYNTHETIC_PAYLOAD_SHA256,
)


@dataclass(frozen=True, slots=True)
class ParentReceiptContract:
    path: str
    sha256: str
    required_markers: tuple[bytes, ...]


def _parent_receipt(
    receipt_kind: str,
    sha256: str,
    additional_markers: tuple[bytes, ...] = (),
) -> ParentReceiptContract:
    return ParentReceiptContract(
        path=f"parent_receipts/{receipt_kind}.synthetic.txt",
        sha256=sha256,
        required_markers=(
            f"receipt_kind={receipt_kind}\n".encode(),
            f"marker=synthetic_{receipt_kind}\n".encode(),
            b"marker=public_neutral_fixture\n",
            *additional_markers,
        ),
    )


PARENT_RECEIPTS: Final = {
    "archive_provenance": _parent_receipt(
        "archive_provenance",
        "737b0a81f404dab577ae1569635d4f49e1924bb60bc5b36fc1a17234585919f0",
    ),
    "cleanup_confirmation": _parent_receipt(
        "cleanup_confirmation",
        "9a2c519fbb1fe78830c58348a75fcff0cd595c856770004e4f29173b6c65b2b4",
    ),
    "delivery_lifecycle": _parent_receipt(
        "delivery_lifecycle",
        "5ff9cd9a7ed0aaeef7d3f38f7cb1494e79b2e3088c03f87bb6d0f27300c1fcae",
    ),
    "installation_validation": _parent_receipt(
        "installation_validation",
        "284948c1f06eb8d66750c830198252294dd16e338396f3c7c50f595f4d670230",
    ),
    "production_preservation": _parent_receipt(
        "production_preservation",
        "8654df0ac2fbc6e098aaf5757ebd4fc69b1959bb0aec35078d9484e4375e6220",
    ),
}

__all__ = [
    "DEVICE_SIGNATURE_DOMAIN",
    "EVIDENCE_CLASSES",
    "PARENT_RECEIPTS",
    "RECEIPT_SIGNATURE_DOMAIN",
    "SCENARIO_CHECKS",
    "SCENARIO_PRODUCERS",
    "SYNTHETIC_PAYLOAD_SHA256",
    "ParentReceiptContract",
]
