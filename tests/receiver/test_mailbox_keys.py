import hashlib
import stat
from pathlib import Path

import pytest

from health_bridge.receiver.mailbox_keys import MailboxKeyStore


def _stored_key_files(state_dir: Path) -> tuple[Path, ...]:
    return tuple(sorted(path for path in state_dir.iterdir() if path.is_file()))


def _test_store(state_dir: Path) -> MailboxKeyStore:
    return MailboxKeyStore.for_testing(
        state_dir=state_dir,
        anchor_dir=state_dir.parent / "identity-anchor",
    )


def test_mailbox_key_store_keeps_stable_algorithm_bound_public_identity(
    tmp_path: Path,
) -> None:
    # Given

    state_dir = tmp_path / "keys"
    first_store = _test_store(state_dir)

    # When
    first = first_store.load_or_create()
    reloaded = _test_store(state_dir).load_or_create()

    # Then
    assert first == reloaded
    assert (
        first.signing_key_id
        == hashlib.sha256(b"ed25519\0" + first.signing_public_key).digest()[:16].hex()
    )
    assert (
        first.agreement_key_id
        == hashlib.sha256(b"x25519\0" + first.agreement_public_key).digest()[:16].hex()
    )
    assert first.signing_key_id != first.agreement_key_id


def test_mailbox_key_store_locks_existing_directory_and_secret_files(
    tmp_path: Path,
) -> None:
    # Given

    state_dir = tmp_path / "keys"
    state_dir.mkdir(mode=0o755)

    # When
    _ = _test_store(state_dir).load_or_create()

    # Then
    assert stat.S_IMODE(state_dir.stat().st_mode) == 0o700
    secret_files = _stored_key_files(state_dir)
    assert secret_files
    assert all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in secret_files)


def test_mailbox_key_store_rejects_unsafe_existing_secret_mode_without_leaking_key(
    tmp_path: Path,
) -> None:
    # Given
    from health_bridge.receiver.mailbox_keys import (  # noqa: PLC0415
        MailboxKeyStoreError,
        MailboxKeyStoreErrorCode,
    )

    state_dir = tmp_path / "keys"
    _ = _test_store(state_dir).load_or_create()
    unsafe_file = _stored_key_files(state_dir)[0]
    private_material = unsafe_file.read_bytes()
    unsafe_file.chmod(0o644)

    # When
    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = _test_store(state_dir).public_summary()

    # Then
    assert captured.value.code is MailboxKeyStoreErrorCode.UNSAFE_PERMISSIONS
    diagnostic = repr(captured.value)
    assert private_material.hex() not in diagnostic
    assert private_material.decode("latin1") not in diagnostic


def test_mailbox_key_store_serializes_only_public_ids(tmp_path: Path) -> None:
    # Given
    from health_bridge.receiver.mailbox_keys import (  # noqa: PLC0415
        MailboxKeyLifecycleState,
        MailboxKeyLifecycleSummary,
    )

    store = _test_store(tmp_path / "keys")
    identity = store.load_or_create()

    # When
    summary = store.public_summary()

    # Then
    assert isinstance(summary, MailboxKeyLifecycleSummary)
    assert summary.state is MailboxKeyLifecycleState.ACTIVE
    assert summary.model_dump(mode="json") == {
        "state": "active",
        "signing_key_id": identity.signing_key_id,
        "agreement_key_id": identity.agreement_key_id,
    }


def test_mailbox_key_store_reports_loss_when_persisted_material_disappears(
    tmp_path: Path,
) -> None:
    # Given
    from health_bridge.receiver.mailbox_keys import (  # noqa: PLC0415
        MailboxKeyLifecycleState,
    )

    state_dir = tmp_path / "keys"
    store = _test_store(state_dir)
    _ = store.load_or_create()
    _stored_key_files(state_dir)[0].unlink()

    # When
    summary = store.public_summary()

    # Then
    assert summary.state is MailboxKeyLifecycleState.LOST


def test_mailbox_key_store_does_not_silently_recreate_lost_material(
    tmp_path: Path,
) -> None:
    # Given
    from health_bridge.receiver.mailbox_keys import (  # noqa: PLC0415
        MailboxKeyStoreError,
        MailboxKeyStoreErrorCode,
    )

    state_dir = tmp_path / "keys"
    store = _test_store(state_dir)
    _ = store.load_or_create()
    _stored_key_files(state_dir)[0].unlink()

    # When
    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = store.load_or_create()

    # Then
    assert captured.value.code is MailboxKeyStoreErrorCode.KEY_MATERIAL_LOST


def test_mailbox_key_store_persists_revocation_and_refuses_recreation(
    tmp_path: Path,
) -> None:
    # Given
    from health_bridge.receiver.mailbox_keys import (  # noqa: PLC0415
        MailboxKeyLifecycleState,
        MailboxKeyStoreError,
        MailboxKeyStoreErrorCode,
    )

    state_dir = tmp_path / "keys"
    store = _test_store(state_dir)
    _ = store.load_or_create()

    # When
    revoked = store.revoke()

    # Then
    assert revoked.state is MailboxKeyLifecycleState.REVOKED
    assert _test_store(state_dir).public_summary().state is revoked.state
    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = _test_store(state_dir).load_or_create()
    assert captured.value.code is MailboxKeyStoreErrorCode.KEYS_REVOKED


def test_mailbox_key_store_rotates_only_through_explicit_expected_identity(
    tmp_path: Path,
) -> None:
    # Given

    state_dir = tmp_path / "keys"
    store = _test_store(state_dir)
    first = store.load_or_create()

    # When
    rotated = store.rotate(expected_signing_key_id=first.signing_key_id)

    # Then
    assert rotated.identity.signing_key_id != first.signing_key_id
    assert rotated.identity.agreement_key_id != first.agreement_key_id
    assert _test_store(state_dir).load_or_create() == rotated.identity


def test_mailbox_key_store_rejects_stale_rotation_without_changing_identity(
    tmp_path: Path,
) -> None:
    # Given
    from health_bridge.receiver.mailbox_keys import (  # noqa: PLC0415
        MailboxKeyStoreError,
        MailboxKeyStoreErrorCode,
    )

    state_dir = tmp_path / "keys"
    store = _test_store(state_dir)
    first = store.load_or_create()

    # When
    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = store.rotate(expected_signing_key_id="0" * 32)

    # Then
    assert captured.value.code is MailboxKeyStoreErrorCode.STALE_IDENTITY
    assert _test_store(state_dir).load_or_create() == first
