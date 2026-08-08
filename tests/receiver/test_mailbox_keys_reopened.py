import json
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path
from typing import cast

import pytest
from typer.testing import CliRunner

from health_bridge.cli import app
from health_bridge.private_files import write_private_text_file
from health_bridge.receiver import _mailbox_key_policy
from health_bridge.receiver.mailbox_keys import (
    MailboxKeyStore,
    MailboxKeyStoreError,
    MailboxKeyStoreErrorCode,
)

_RUNNER = CliRunner()


def _store(state_dir: Path, anchor_dir: Path) -> MailboxKeyStore:
    return MailboxKeyStore.for_testing(
        state_dir=state_dir,
        anchor_dir=anchor_dir,
    )


def _generation_path(anchor_dir: Path) -> Path:
    return (
        anchor_dir.parent
        / f"{anchor_dir.name}.provisioning"
        / ("mailbox-provisioning-anchor.json")
    )


def test_initialized_identity_without_external_anchor_fails_closed(
    tmp_path: Path,
) -> None:
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    store = _store(state_dir, anchor_dir)
    _ = store.load_or_create()
    (anchor_dir / "mailbox-expected-identity.json").unlink()

    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = _store(state_dir, anchor_dir).load_or_create()

    assert captured.value.code is MailboxKeyStoreErrorCode.KEY_MATERIAL_LOST
    assert not (anchor_dir / "mailbox-expected-identity.json").exists()


def test_transplanted_private_identity_cannot_seed_a_missing_anchor(
    tmp_path: Path,
) -> None:
    target_state = tmp_path / "target-private"
    target_anchor = tmp_path / "target-anchor"
    donor_state = tmp_path / "donor-private"
    donor_anchor = tmp_path / "donor-anchor"
    target = _store(target_state, target_anchor)
    original = target.load_or_create()
    donor = _store(donor_state, donor_anchor).load_or_create()
    _ = shutil.copyfile(
        donor_state / "mailbox-identity.json",
        target_state / "mailbox-identity.json",
    )
    (target_state / "mailbox-identity.json").chmod(0o600)
    (target_anchor / "mailbox-expected-identity.json").unlink()

    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = _store(target_state, target_anchor).load_or_create()

    assert captured.value.code is MailboxKeyStoreErrorCode.KEY_MATERIAL_LOST
    assert donor.signing_key_id != original.signing_key_id
    assert not (target_anchor / "mailbox-expected-identity.json").exists()


@pytest.mark.parametrize("transition", ["rotation", "revocation"])
def test_external_generation_rejects_coordinated_mutable_snapshot_rollback(
    tmp_path: Path,
    transition: str,
) -> None:
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    store = _store(state_dir, anchor_dir)
    first = store.load_or_create()
    identity_snapshot = (state_dir / "mailbox-identity.json").read_bytes()
    anchor_snapshot = (anchor_dir / "mailbox-expected-identity.json").read_bytes()
    if transition == "rotation":
        _ = store.rotate(expected_signing_key_id=first.signing_key_id)
    else:
        _ = store.revoke()
    assert _generation_path(anchor_dir).exists()
    _ = (state_dir / "mailbox-identity.json").write_bytes(identity_snapshot)
    (state_dir / "mailbox-identity.json").chmod(0o600)
    _ = (anchor_dir / "mailbox-expected-identity.json").write_bytes(anchor_snapshot)
    (anchor_dir / "mailbox-expected-identity.json").chmod(0o600)

    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = _store(state_dir, anchor_dir).load_or_create()

    assert captured.value.code.value == "rollback_detected"


@pytest.mark.parametrize(
    "remaining",
    ["marker-only", "private-complete", "anchor-complete"],
)
def test_interrupted_initialization_never_blesses_partial_state(
    tmp_path: Path,
    remaining: str,
) -> None:
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    _ = _store(state_dir, anchor_dir).load_or_create()
    generation_path = _generation_path(anchor_dir)
    if remaining == "marker-only":
        (state_dir / "mailbox-identity.json").unlink()
        (anchor_dir / "mailbox-expected-identity.json").unlink()
        generation_path.unlink()
    elif remaining == "private-complete":
        (anchor_dir / "mailbox-expected-identity.json").unlink()
        generation_path.unlink()
    else:
        generation_path.unlink()

    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = _store(state_dir, anchor_dir).load_or_create()

    assert captured.value.code is MailboxKeyStoreErrorCode.KEY_MATERIAL_LOST


@pytest.mark.parametrize("transition", ["rotation", "revocation"])
@pytest.mark.parametrize("crash_after", ["private-state", "expected-anchor"])
def test_interrupted_transition_recovers_only_a_verified_forward_generation(
    tmp_path: Path,
    transition: str,
    crash_after: str,
) -> None:
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    store = _store(state_dir, anchor_dir)
    first = store.load_or_create()
    paths = (
        state_dir / "mailbox-identity.json",
        anchor_dir / "mailbox-expected-identity.json",
        _generation_path(anchor_dir),
    )
    old_snapshot = tuple(path.read_bytes() for path in paths)
    if transition == "rotation":
        rotated = store.rotate(expected_signing_key_id=first.signing_key_id)
        expected_key_id = rotated.identity.signing_key_id
        expected_state = "active"
    else:
        revoked = store.revoke()
        expected_key_id = first.signing_key_id
        expected_state = revoked.state.value
    new_snapshot = tuple(path.read_bytes() for path in paths)
    for path, content in zip(paths, old_snapshot, strict=True):
        _ = path.write_bytes(content)
        path.chmod(0o600)
    _ = paths[0].write_bytes(new_snapshot[0])
    paths[0].chmod(0o600)
    if crash_after == "expected-anchor":
        _ = paths[1].write_bytes(new_snapshot[1])
        paths[1].chmod(0o600)

    summary = _store(state_dir, anchor_dir).public_summary()

    assert summary.state.value == expected_state
    assert summary.signing_key_id == expected_key_id
    assert tuple(path.read_bytes() for path in paths) == new_snapshot


def test_atomic_private_write_fsyncs_file_and_parent_directory(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[bool] = []
    original = os.fsync

    def record_fsync(descriptor: int) -> None:
        calls.append(stat.S_ISDIR(os.fstat(descriptor).st_mode))
        original(descriptor)

    monkeypatch.setattr(os, "fsync", record_fsync)
    write_private_text_file(tmp_path / "durable.txt", "synthetic")

    assert calls == [False, True]


def test_low_order_x25519_peer_maps_to_closed_typed_error(tmp_path: Path) -> None:
    store = _store(tmp_path / "private-store", tmp_path / "external-anchor")
    _ = store.load_or_create()

    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = store.exchange(bytes(32))

    assert captured.value.code is MailboxKeyStoreErrorCode.MALFORMED_STATE


@pytest.mark.skipif(
    sys.platform != "linux",
    reason="exercises Linux filesystem classification",
)
def test_unknown_linux_filesystem_is_not_classified_as_local(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def unknown_filesystem(_path: Path) -> str:
        return "synthetic-unknown-fs"

    monkeypatch.setattr(
        _mailbox_key_policy,
        "_linux_filesystem_type",
        unknown_filesystem,
    )

    assert _mailbox_key_policy.filesystem_kind(tmp_path).value == "unknown"


def test_exact_temp_state_dir_doctor_command_is_supported(tmp_path: Path) -> None:
    result = _RUNNER.invoke(
        app,
        [
            "mailbox",
            "keys",
            "doctor",
            "--state-dir",
            str(tmp_path / "keys"),
            "--json",
        ],
    )

    assert result.exit_code == 0
    payload = cast("dict[str, object]", json.loads(result.stdout))
    assert set(payload) == {
        "agreement_key_id",
        "signing_key_id",
        "state",
        "status",
    }


@pytest.mark.parametrize(
    ("state_dir", "expected"),
    [
        (Path.cwd() / ".non-temp-mailbox-keys", "prohibited_storage"),
        (
            Path(tempfile.gettempdir()) / "CloudStorage" / "keys",
            "prohibited_storage",
        ),
    ],
)
def test_state_dir_doctor_rejects_arbitrary_or_cloud_roots(
    state_dir: Path,
    expected: str,
) -> None:
    result = _RUNNER.invoke(
        app,
        [
            "mailbox",
            "keys",
            "doctor",
            "--state-dir",
            str(state_dir),
            "--json",
        ],
    )

    assert result.exit_code == 2
    assert json.loads(result.stdout) == {"status": "error", "error_code": expected}
    assert str(state_dir) not in result.stdout


def test_first_use_unsafe_ancestor_returns_redacted_typed_error(
    tmp_path: Path,
) -> None:
    unsafe = tmp_path / "unsafe"
    unsafe.mkdir(mode=0o777)
    unsafe.chmod(0o777)
    state_dir = unsafe / "keys"

    result = _RUNNER.invoke(
        app,
        [
            "mailbox",
            "keys",
            "doctor",
            "--state-dir",
            str(state_dir),
            "--json",
        ],
    )

    assert result.exit_code == 2
    assert json.loads(result.stdout) == {
        "status": "error",
        "error_code": "unsafe_permissions",
    }
    assert str(state_dir) not in result.stdout
