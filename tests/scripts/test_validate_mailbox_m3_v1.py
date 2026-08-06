from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

from tests.scripts.mailbox_m3_v1_support import (
    FULL_IDENTIFIER,
    build_m3_fixture,
    read,
    refresh_binding,
    run,
    write,
)
from tests.scripts.production_seal_support import write_synthetic_production_seal

M3 = Path("scripts/validate-mailbox-m3-v1.py")
HEAD = "6eb12a4fb29543e691c7e930f385dc4f9964598f"


def _run(manifest: Path, anchor: Path) -> subprocess.CompletedProcess[str]:
    seal = anchor.parent / "synthetic-production-seal.hbjcs1"
    seal.parent.mkdir(parents=True, exist_ok=True)
    seal_anchor, _ = write_synthetic_production_seal(seal)
    return subprocess.run(
        [
            sys.executable,
            str(M3),
            "--strict",
            "--commit",
            HEAD,
            "--manifest",
            str(manifest),
            "--m2-manifest",
            str(manifest.parent / "missing-m2-manifest.hbjcs1"),
            "--anchor",
            str(anchor),
            "--production-seal",
            str(seal),
            "--production-seal-anchor-sha256",
            seal_anchor,
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def test_m3_v1_missing_manifest_is_schema_invalid(tmp_path: Path) -> None:
    # Given: no evidence manifest or validator-local anchor.
    # When: the versioned strict command is invoked.
    result = _run(tmp_path / "missing.hbjcs1", tmp_path / "anchor.hbjcs1")
    missing_parent = _run(
        tmp_path / "absent/missing.hbjcs1",
        tmp_path / "absent/anchor.hbjcs1",
    )

    # Then: schema-invalid keeps the contracted exit and redacted diagnostic.
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        "FAIL schema_invalid\n",
        "",
    )
    assert (
        missing_parent.returncode,
        missing_parent.stdout,
        missing_parent.stderr,
    ) == (
        1,
        "FAIL schema_invalid\n",
        "",
    )


def test_old_dispatcher_does_not_accept_m3(tmp_path: Path) -> None:
    # Given: the immutable M2-era dispatcher.
    # When: a caller attempts to route M3 through it.
    result = subprocess.run(
        [
            sys.executable,
            "scripts/validate-mailbox-milestone.py",
            "--milestone",
            "M3",
            "--strict",
            "--commit",
            HEAD,
            "--manifest",
            str(tmp_path / "m3.hbjcs1"),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    # Then: its pinned behavior remains unsupported, not silently upgraded.
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        "FAIL M1 unsupported_invocation\n",
        "",
    )


def test_m3_v1_accepts_one_report_and_independent_signed_receipts(
    tmp_path: Path,
) -> None:
    # Given: one canonical device report and the exact scenario receipt set.
    fixture = build_m3_fixture(tmp_path / "attempt")

    # When: the strict versioned validator consumes the challenge.
    result = run(fixture)

    # Then: M3 passes once and the validator-local anchor is consumed.
    assert (result.returncode, result.stdout, result.stderr) == (0, "PASS M3\n", "")
    assert read(fixture.anchor)["consumed"] is True


def test_m3_v1_holds_when_external_prerequisite_is_missing(tmp_path: Path) -> None:
    # Given: an explicit unavailable QA signing prerequisite.
    fixture = build_m3_fixture(
        tmp_path / "attempt",
        prerequisites_available=False,
    )

    # When: the strict validator evaluates the manifest.
    result = run(fixture)

    # Then: it emits the contracted external HOLD without reading physical proof.
    assert (result.returncode, result.stdout, result.stderr) == (
        3,
        "HOLD M3 external_prerequisite\n",
        "",
    )


def test_generic_pass_receipt_cannot_create_m3_pass(tmp_path: Path) -> None:
    # Given: a receipt replaced by a generic caller-authored PASS object.
    fixture = build_m3_fixture(tmp_path / "attempt")
    receipt = fixture.receipts[0]
    write(receipt, {"verdict": "PASS"})
    refresh_binding(fixture, receipt)

    # When: the validator parses the independently bound receipt.
    result = run(fixture)

    # Then: the schema fails before a verdict can be trusted.
    assert result.returncode == 1
    assert result.stdout == "FAIL M3 schema_invalid\n"


def test_generic_signed_receipt_without_operation_issuance_is_rejected(
    tmp_path: Path,
) -> None:
    # Given: a formerly valid receipt stripped of operation-owned issuance fields.
    fixture = build_m3_fixture(tmp_path / "attempt")
    receipt = fixture.receipts[0]
    document = read(receipt)
    del document["issuance"]
    del document["operation_id"]
    del document["observation_sha256"]
    write(receipt, document)
    refresh_binding(fixture, receipt)

    # When: the validator evaluates a generic signed-PASS-shaped document.
    result = run(fixture)

    # Then: exact schema rejects it before the PASS literal is meaningful.
    assert result.stdout == "FAIL M3 schema_invalid\n"


def test_m3_rejects_invalid_private_production_seal_before_evidence(
    tmp_path: Path,
) -> None:
    # Given: a complete evidence set whose caller-private seal signature is invalid.
    fixture = build_m3_fixture(tmp_path / "attempt")
    seal = read(fixture.production_seal)
    seal["signature"] = "A" * 86
    write(fixture.production_seal, seal)
    fixture.production_seal.chmod(0o600)

    # When: the strict validator evaluates the private production anchor.
    result = run(fixture)

    # Then: the run fails closed without consuming its one-use anchor.
    assert result.stdout == "FAIL M3 production_seal_invalid\n"
    assert read(fixture.anchor)["consumed"] is False


@pytest.mark.parametrize(
    "forbidden_key",
    [
        "receiver_id",
        "device_id",
        "device_signing_key_id",
        "device_agreement_key_id",
        "receiver_signing_key_id",
        "receiver_agreement_key_id",
        "sender_signing_key_id",
        "sender_agreement_key_id",
    ],
)
def test_full_identifier_field_is_rejected_before_signature(
    tmp_path: Path,
    forbidden_key: str,
) -> None:
    # Given: a forbidden identifier field plus an invalid signature.
    fixture = build_m3_fixture(tmp_path / "attempt")
    report = read(fixture.report)
    report[forbidden_key] = FULL_IDENTIFIER
    report["signature"] = "A" * 86
    write(fixture.report, report)
    refresh_binding(fixture, fixture.report)

    # When: privacy and signature checks are ordered.
    result = run(fixture)

    # Then: privacy rejects first without echoing the identifier.
    assert result.returncode == 1
    assert result.stdout == "FAIL M3 forbidden_identifier\n"
    assert FULL_IDENTIFIER not in result.stdout


def test_renamed_identifier_and_report_public_key_are_rejected(
    tmp_path: Path,
) -> None:
    # Given: two independently invalid evidence attempts.
    renamed = build_m3_fixture(tmp_path / "renamed")
    report = read(renamed.report)
    report["correlation_label"] = FULL_IDENTIFIER
    write(renamed.report, report)
    refresh_binding(renamed, renamed.report)
    supplied_key = build_m3_fixture(tmp_path / "supplied-key")
    report = read(supplied_key.report)
    report["alternate_public_key"] = "A" * 43
    write(supplied_key.report, report)
    refresh_binding(supplied_key, supplied_key.report)

    # When: both are evaluated before signature acceptance.
    renamed_result = run(renamed)
    key_result = run(supplied_key)

    # Then: renamed values and report-supplied keys are both closed.
    assert renamed_result.stdout == "FAIL M3 forbidden_identifier\n"
    assert key_result.stdout == "FAIL M3 forbidden_data\n"


def test_tampered_receipt_and_symlink_are_rejected(tmp_path: Path) -> None:
    # Given: one altered signed receipt and one symlinked receipt.
    tampered = build_m3_fixture(tmp_path / "tampered")
    receipt = tampered.receipts[0]
    document = read(receipt)
    started_at_ms = document["started_at_ms"]
    assert isinstance(started_at_ms, int)
    document["started_at_ms"] = started_at_ms + 1
    write(receipt, document)
    refresh_binding(tampered, receipt)
    linked = build_m3_fixture(tmp_path / "linked")
    receipt = linked.receipts[0]
    target = linked.root / "outside.hbjcs1"
    _ = target.write_bytes(receipt.read_bytes())
    receipt.unlink()
    receipt.symlink_to(target)

    # When: signature and no-follow file checks run.
    tampered_result = run(tampered)
    linked_result = run(linked)

    # Then: neither altered content nor a symlink can attest PASS.
    assert tampered_result.stdout == "FAIL M3 signature_invalid\n"
    assert linked_result.stdout == "FAIL M3 artifact_binding\n"


def test_unknown_or_missing_scenario_evidence_is_closed(tmp_path: Path) -> None:
    # Given: an unknown receipt field and a manifest missing one scenario.
    unknown = build_m3_fixture(tmp_path / "unknown")
    receipt = unknown.receipts[0]
    document = read(receipt)
    document["observation"] = "caller supplied"
    write(receipt, document)
    refresh_binding(unknown, receipt)
    missing = build_m3_fixture(tmp_path / "missing")
    manifest = read(missing.manifest)
    bindings = manifest["scenario_receipts"]
    assert isinstance(bindings, list)
    del bindings[0]
    write(missing.manifest, manifest)

    # When: exact schemas and the required set are evaluated.
    unknown_result = run(unknown)
    missing_result = run(missing)

    # Then: both fail without accepting a partial evidence set.
    assert unknown_result.stdout == "FAIL M3 schema_invalid\n"
    assert missing_result.stdout == "FAIL schema_invalid\n"


@pytest.mark.parametrize(
    "malformed",
    [
        b'{"kind":"health_bridge.mailbox_m3_manifest.v1","v":1,"v":1}',
        b'{ "kind":"health_bridge.mailbox_m3_manifest.v1","v":1}',
    ],
)
def test_duplicate_keys_and_noncanonical_bytes_are_schema_invalid(
    tmp_path: Path,
    malformed: bytes,
) -> None:
    # Given: duplicate-key or noncanonical manifest bytes.
    fixture = build_m3_fixture(tmp_path / "attempt")
    _ = fixture.manifest.write_bytes(malformed)

    # When: the strict HBJCS1 reader evaluates the manifest.
    result = run(fixture)

    # Then: alternate encodings never reach signature evaluation.
    assert result.stdout == "FAIL schema_invalid\n"


def test_path_traversal_and_stale_commit_are_rejected(tmp_path: Path) -> None:
    # Given: one traversal binding and one manifest for a different commit.
    traversal = build_m3_fixture(tmp_path / "traversal")
    manifest = read(traversal.manifest)
    report_binding = manifest["device_report"]
    assert isinstance(report_binding, dict)
    report_binding["path"] = "../device-report.hbjcs1"
    write(traversal.manifest, manifest)
    stale = build_m3_fixture(tmp_path / "stale")
    manifest = read(stale.manifest)
    manifest["head"] = "ab" * 20
    write(stale.manifest, manifest)

    # When: scoped-path and commit anchors are evaluated.
    traversal_result = run(traversal)
    stale_result = run(stale)

    # Then: both attempts fail closed with redacted diagnostics.
    assert traversal_result.stdout == "FAIL M3 artifact_binding\n"
    assert stale_result.stdout == "FAIL M3 stale_commit\n"


def test_stale_challenge_empty_transitions_and_wrong_checks_are_rejected(
    tmp_path: Path,
) -> None:
    # Given: three signed-object shapes that are semantically stale or empty.
    stale = build_m3_fixture(tmp_path / "stale")
    report = read(stale.report)
    report["challenge"] = "A" * 43
    write(stale.report, report)
    refresh_binding(stale, stale.report)
    empty = build_m3_fixture(tmp_path / "empty")
    report = read(empty.report)
    counts = report["transition_counts"]
    assert isinstance(counts, dict)
    counts["published"] = 0
    write(empty.report, report)
    refresh_binding(empty, empty.report)
    wrong = build_m3_fixture(tmp_path / "wrong")
    receipt = wrong.receipts[0]
    document = read(receipt)
    document["checks"] = ["caller_passed", "unanchored_observation"]
    write(receipt, document)
    refresh_binding(wrong, receipt)

    # When: challenge, transition, and exact-check bindings are evaluated.
    results = (run(stale), run(empty), run(wrong))

    # Then: none can become PASS even before their stale signatures are checked.
    assert all(result.stdout == "FAIL M3 artifact_binding\n" for result in results)
