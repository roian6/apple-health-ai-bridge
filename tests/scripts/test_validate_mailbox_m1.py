from __future__ import annotations

import hashlib
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING

import pytest

from health_bridge.mailbox_m1_validator import RECEIPT_POLICIES
from tests.scripts.mailbox_m1_fixture_support import (
    ManifestFixture,
    ReceiptFixture,
    build_manifest_fixture,
    git_head,
    write_manifest,
)

if TYPE_CHECKING:
    from collections.abc import Callable

REQUIRED_RECEIPTS = tuple(policy.kind for policy in RECEIPT_POLICIES)
REPOSITORY_ROOT = Path.cwd()


def _manifest(tmp_path: Path) -> Path:
    manifest = tmp_path / "m1.json"
    write_manifest(
        manifest,
        build_manifest_fixture(REPOSITORY_ROOT, _head()),
    )
    return manifest


def _head() -> str:
    return git_head(REPOSITORY_ROOT)


def _run(manifest: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            "scripts/validate-mailbox-milestone.py",
            "--milestone",
            "M1",
            "--strict",
            "--commit",
            _head(),
            "--manifest",
            str(manifest),
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )


def _load(manifest: Path) -> ManifestFixture:
    return ManifestFixture.model_validate_json(manifest.read_bytes())


def _write(manifest: Path, value: ManifestFixture) -> None:
    write_manifest(manifest, value)


def _write_unknown_field(manifest: Path, value: ManifestFixture) -> None:
    _ = manifest.write_text(
        f'{value.model_dump_json()[:-1]},"unknown":"field"}}',
        encoding="utf-8",
    )


def _receipt(value: ManifestFixture, kind: str) -> ReceiptFixture:
    return next(receipt for receipt in value.receipts if receipt.kind == kind)


def _replace_receipt(
    value: ManifestFixture,
    kind: str,
    replacement: ReceiptFixture,
) -> ManifestFixture:
    receipts = tuple(
        replacement.model_copy(update={"kind": kind})
        if receipt.kind == kind
        else receipt
        for receipt in value.receipts
    )
    return value.model_copy(update={"receipts": receipts})


def test_strict_m1_validator_accepts_exact_neutral_fixture_bytes(
    tmp_path: Path,
) -> None:
    # Given: an aggregate bound to the exact neutral fixture bytes.
    manifest = _manifest(tmp_path)
    # When: the strict validator checks its current HEAD and evidence bindings.
    result = _run(manifest)
    # Then: the exact aggregate is the only passing shape.
    assert (result.returncode, result.stdout, result.stderr) == (0, "PASS M1\n", "")


@pytest.mark.parametrize(
    ("target_kind", "source_kind"),
    tuple(
        (target, source)
        for target in REQUIRED_RECEIPTS
        for source in REQUIRED_RECEIPTS
        if target != source
    ),
)
def test_strict_m1_validator_rejects_cross_kind_receipt_substitution(
    tmp_path: Path,
    target_kind: str,
    source_kind: str,
) -> None:
    # Given: a valid receipt from another independently owned fixture kind.
    manifest = _manifest(tmp_path)
    value = _load(manifest)
    substituted = _replace_receipt(value, target_kind, _receipt(value, source_kind))
    _write(manifest, substituted)
    # When: its valid path and hash are relabeled as the target receipt kind.
    result = _run(manifest)
    # Then: ownership substitution fails closed rather than producing PASS.
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        "FAIL M1 invalid_manifest\n",
        "",
    )


def test_strict_m1_validator_rejects_same_file_reused_for_every_kind(
    tmp_path: Path,
) -> None:
    # Given: every required kind aliases the valid dependency receipt.
    manifest = _manifest(tmp_path)
    value = _load(manifest)
    source = _receipt(value, "dependency_contract")
    reused = value.model_copy(
        update={
            "receipts": tuple(
                source.model_copy(update={"kind": kind}) for kind in REQUIRED_RECEIPTS
            )
        }
    )
    _write(manifest, reused)
    # When: the strict validator checks the aliased aggregate.
    result = _run(manifest)
    # Then: valid bytes cannot satisfy independent evidence lanes by reuse.
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        "FAIL M1 invalid_manifest\n",
        "",
    )


@pytest.mark.parametrize(
    "wrong_content",
    [pytest.param(False), pytest.param(True)],
)
def test_strict_m1_validator_rejects_wrong_receipt_path_or_content(
    tmp_path: Path,
    wrong_content: bool,
) -> None:
    # Given: either copied valid bytes at a wrong basename or unrelated bytes.
    manifest = _manifest(tmp_path)
    value = _load(manifest)
    transaction_receipt = _receipt(value, "transaction_crash_atomicity")
    contents = (
        b"unrelated synthetic receipt\n"
        if wrong_content
        else Path(transaction_receipt.path).read_bytes()
    )
    wrong_path = tmp_path / "wrong-receipt-name.txt"
    _ = wrong_path.write_bytes(contents)
    replacement = transaction_receipt.model_copy(
        update={
            "path": str(wrong_path),
            "sha256": hashlib.sha256(contents).hexdigest(),
        }
    )
    _write(
        manifest,
        _replace_receipt(value, transaction_receipt.kind, replacement),
    )
    # When: the supplied hash is valid for that wrong path and content.
    result = _run(manifest)
    # Then: digest validity cannot override the independently owned path policy.
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        "FAIL M1 invalid_manifest\n",
        "",
    )


@pytest.mark.parametrize(
    ("mutation", "expected"),
    [
        ("missing", "FAIL M1 invalid_manifest\n"),
        ("stale", "FAIL M1 stale_receipt\n"),
        ("unknown_kind", "FAIL M1 invalid_manifest\n"),
        ("unknown_field", "FAIL M1 invalid_manifest\n"),
    ],
)
def test_strict_m1_validator_rejects_invalid_receipt_aggregate(
    tmp_path: Path,
    mutation: str,
    expected: str,
) -> None:
    # Given: one malformed, missing, stale, or unknown aggregate mutation.
    manifest = _manifest(tmp_path)
    value = _load(manifest)
    first, *remaining = value.receipts
    mutations: dict[str, Callable[[], None]] = {
        "missing": lambda: _write(
            manifest,
            value.model_copy(update={"receipts": tuple(remaining)}),
        ),
        "stale": lambda: _write(
            manifest,
            value.model_copy(
                update={
                    "receipts": (
                        first.model_copy(update={"sha256": "0" * 64}),
                        *remaining,
                    )
                }
            ),
        ),
        "unknown_kind": lambda: _write(
            manifest,
            value.model_copy(
                update={
                    "receipts": (
                        first.model_copy(update={"kind": "unknown_receipt_kind"}),
                        *remaining,
                    )
                }
            ),
        ),
        "unknown_field": lambda: _write_unknown_field(manifest, value),
    }
    _ = mutations[mutation]()
    # When: the strict validator checks the mutated aggregate.
    result = _run(manifest)
    # Then: it emits only the expected redacted failure.
    assert (result.returncode, result.stdout, result.stderr) == (1, expected, "")
