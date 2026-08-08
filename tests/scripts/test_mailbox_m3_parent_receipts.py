from __future__ import annotations

import hashlib
from typing import TYPE_CHECKING

from health_bridge.mailbox_qa.m3_contract import PARENT_RECEIPTS
from tests.scripts.mailbox_m3_v1_support import (
    FULL_IDENTIFIER,
    build_m3_fixture,
    read,
    run,
    write,
)

if TYPE_CHECKING:
    from pathlib import Path

    from health_bridge.contract._hbjcs1 import JsonValue


def _bindings(manifest: dict[str, JsonValue]) -> list[JsonValue]:
    bindings = manifest["parent_receipts"]
    assert isinstance(bindings, list)
    return bindings


def test_parent_receipt_cross_kind_path_substitution_is_rejected(
    tmp_path: Path,
) -> None:
    # Given: one receipt kind rebound to another kind's valid path and digest.
    fixture = build_m3_fixture(tmp_path / "attempt")
    manifest = read(fixture.manifest)
    bindings = _bindings(manifest)
    first = bindings[0]
    second = bindings[1]
    assert isinstance(first, dict)
    assert isinstance(second, dict)
    first["path"] = second["path"]
    first["sha256"] = second["sha256"]
    write(fixture.manifest, manifest)

    # When: the strict validator evaluates independently owned bindings.
    result = run(fixture)

    # Then: valid bytes for the wrong kind cannot pass.
    assert result.stdout == "FAIL M3 stale_parent_receipt\n"


def test_missing_or_duplicate_parent_receipts_are_rejected(tmp_path: Path) -> None:
    # Given: one manifest missing a receipt and one duplicating another kind.
    missing = build_m3_fixture(tmp_path / "missing")
    manifest = read(missing.manifest)
    del _bindings(manifest)[0]
    write(missing.manifest, manifest)
    duplicate = build_m3_fixture(tmp_path / "duplicate")
    manifest = read(duplicate.manifest)
    bindings = _bindings(manifest)
    bindings[0] = bindings[1]
    write(duplicate.manifest, manifest)

    # When: both manifests are validated.
    missing_result = run(missing)
    duplicate_result = run(duplicate)

    # Then: cardinality and uniqueness both fail closed.
    assert missing_result.stdout == "FAIL schema_invalid\n"
    assert duplicate_result.stdout == "FAIL M3 stale_parent_receipt\n"


def test_stale_parent_receipt_digest_is_rejected(tmp_path: Path) -> None:
    # Given: a parent receipt binding with a stale digest.
    fixture = build_m3_fixture(tmp_path / "attempt")
    manifest = read(fixture.manifest)
    binding = _bindings(manifest)[0]
    assert isinstance(binding, dict)
    binding["sha256"] = "00" * 32
    write(fixture.manifest, manifest)

    # When: the strict validator binds the receipt bytes.
    result = run(fixture)

    # Then: stale bytes cannot pass.
    assert result.stdout == "FAIL M3 stale_parent_receipt\n"


def test_rehashed_parent_receipt_without_required_marker_is_rejected(
    tmp_path: Path,
) -> None:
    # Given: canonical replacement bytes whose digest is refreshed but marker is wrong.
    fixture = build_m3_fixture(tmp_path / "attempt")
    receipt = fixture.parent_receipts[0]
    _ = receipt.write_bytes(
        b"receipt_kind=archive_provenance\nmarker=public_neutral_fixture\n"
    )
    manifest = read(fixture.manifest)
    binding = _bindings(manifest)[0]
    assert isinstance(binding, dict)
    binding["sha256"] = hashlib.sha256(receipt.read_bytes()).hexdigest()
    write(fixture.manifest, manifest)

    # When: digest and semantic marker checks are both evaluated.
    result = run(fixture)

    # Then: rehashing semantically invalid bytes cannot pass.
    assert result.stdout == "FAIL M3 stale_parent_receipt\n"


def test_rehashed_parent_receipt_with_forbidden_identifier_is_rejected(
    tmp_path: Path,
) -> None:
    # Given: a marker-complete receipt with a forbidden identifier appended.
    fixture = build_m3_fixture(tmp_path / "attempt")
    receipt = fixture.parent_receipts[0]
    _ = receipt.write_bytes(
        receipt.read_bytes() + f"unrelated_value={FULL_IDENTIFIER}\n".encode()
    )
    manifest = read(fixture.manifest)
    binding = _bindings(manifest)[0]
    assert isinstance(binding, dict)
    binding["sha256"] = hashlib.sha256(receipt.read_bytes()).hexdigest()
    write(fixture.manifest, manifest)

    # When: privacy checks evaluate the rehashed parent receipt.
    result = run(fixture)

    # Then: the identifier is rejected before it can attest PASS.
    assert result.stdout == "FAIL M3 forbidden_identifier\n"


def test_rehashed_production_preservation_cannot_replace_trusted_bytes(
    tmp_path: Path,
) -> None:
    # Given: all required preservation markers plus an untrusted appended claim.
    fixture = build_m3_fixture(tmp_path / "attempt")
    contract = PARENT_RECEIPTS["production_preservation"]
    receipt = fixture.root / contract.path
    _ = receipt.write_bytes(receipt.read_bytes() + b"marker=forged_preservation\n")
    manifest = read(fixture.manifest)
    binding = _bindings(manifest)[-1]
    assert isinstance(binding, dict)
    assert binding["receipt_kind"] == "production_preservation"
    binding["sha256"] = hashlib.sha256(receipt.read_bytes()).hexdigest()
    write(fixture.manifest, manifest)

    # When: the fixed parent-receipt contract evaluates the refreshed digest.
    result = run(fixture)

    # Then: manifest-controlled bytes cannot replace the trusted fixture.
    assert result.stdout == "FAIL M3 stale_parent_receipt\n"


def test_missing_or_replaced_external_m2_manifest_is_rejected(tmp_path: Path) -> None:
    # Given: one run missing the independently supplied M2 artifact and one with
    # attacker-authored replacement bytes.
    missing = build_m3_fixture(tmp_path / "missing")
    missing.m2_manifest.unlink()
    replaced = build_m3_fixture(tmp_path / "replaced")
    _ = replaced.m2_manifest.write_bytes(b"{}")

    # When: the strict validator evaluates both external artifact bindings.
    missing_result = run(missing)
    replaced_result = run(replaced)

    # Then: neither a receipt marker nor manifest-controlled hash can replace M2.
    assert missing_result.stdout == "FAIL M3 stale_m2\n"
    assert replaced_result.stdout == "FAIL M3 stale_m2\n"


def test_m2_digest_must_match_private_anchor_and_manifest(tmp_path: Path) -> None:
    # Given: a different canonical, schema-valid PASS M2 manifest for the same
    # commit, rebound only in the caller-controlled public M3 manifest.
    fixture = build_m3_fixture(tmp_path / "attempt")
    replacement_m2 = read(fixture.m2_manifest)
    scope = replacement_m2["scope"]
    assert isinstance(scope, list)
    first_scope_entry = scope[0]
    assert isinstance(first_scope_entry, dict)
    first_scope_entry["sha256"] = "03" * 32
    write(fixture.m2_manifest, replacement_m2)
    manifest = read(fixture.manifest)
    manifest["m2_manifest_sha256"] = hashlib.sha256(
        fixture.m2_manifest.read_bytes()
    ).hexdigest()
    write(fixture.manifest, manifest)

    # When: the independent private-anchor binding is evaluated.
    result = run(fixture)

    # Then: public M2 bytes and M3 manifest cannot jointly rebind trust.
    assert result.stdout == "FAIL M3 stale_m2\n"


def test_m2_manifest_must_be_canonical_pass_for_same_commit(tmp_path: Path) -> None:
    # Given: a schema-valid M2 artifact with a HOLD verdict, rebound in both
    # manifest and private anchor to isolate semantic validation.
    fixture = build_m3_fixture(tmp_path / "attempt")
    m2 = read(fixture.m2_manifest)
    m2["verdict"] = "HOLD"
    write(fixture.m2_manifest, m2)
    digest = hashlib.sha256(fixture.m2_manifest.read_bytes()).hexdigest()
    manifest = read(fixture.manifest)
    manifest["m2_manifest_sha256"] = digest
    write(fixture.manifest, manifest)
    anchor = read(fixture.anchor)
    anchor["m2_manifest_sha256"] = digest
    write(fixture.anchor, anchor)
    fixture.anchor.chmod(0o600)

    # When: digest and M2 semantics are both evaluated.
    result = run(fixture)

    # Then: a non-PASS parent milestone cannot authorize M3.
    assert result.stdout == "FAIL M3 stale_m2\n"
