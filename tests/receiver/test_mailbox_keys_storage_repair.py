import base64
import inspect
import json
import os
import stat
import threading
from collections.abc import Callable
from pathlib import Path

import pytest
from pydantic import JsonValue, TypeAdapter

from health_bridge.receiver.mailbox_keys import (
    MailboxKeyStore,
    MailboxKeyStoreError,
    MailboxKeyStoreErrorCode,
)

_JSON_OBJECT = TypeAdapter(dict[str, JsonValue])


def _store(
    state_dir: Path,
    anchor_dir: Path,
    *,
    transaction_barrier: Callable[[], int] | None = None,
    filesystem_kind: str = "local",
) -> MailboxKeyStore:
    return MailboxKeyStore.for_testing(
        state_dir=state_dir,
        anchor_dir=anchor_dir,
        transaction_barrier=transaction_barrier,
        filesystem_kind=filesystem_kind,
    )


def _rewrite_json(path: Path, update: Callable[[dict[str, JsonValue]], None]) -> None:
    parsed = _JSON_OBJECT.validate_json(path.read_bytes())
    update(parsed)
    _ = path.write_text(json.dumps(parsed, separators=(",", ":")), encoding="utf-8")
    path.chmod(0o600)


def _boolean_version(value: dict[str, JsonValue]) -> None:
    value["v"] = True


def _invalid_base64url(value: dict[str, JsonValue]) -> None:
    value["signing_private_key"] = "!"


def _padded_base64url(value: dict[str, JsonValue]) -> None:
    value["agreement_private_key"] = "AA=="


def _wrong_key_size(value: dict[str, JsonValue]) -> None:
    value["signing_private_key"] = (
        base64.urlsafe_b64encode(b"x" * 31).decode().rstrip("=")
    )


@pytest.mark.parametrize(
    ("mutate"),
    [
        _boolean_version,
        _invalid_base64url,
        _padded_base64url,
        _wrong_key_size,
    ],
    ids=("boolean-version", "invalid-base64url", "padded-base64url", "wrong-key-size"),
)
def test_malformed_identity_state_is_rejected(
    tmp_path: Path,
    mutate: Callable[[dict[str, JsonValue]], None],
) -> None:
    # Given
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    _ = _store(state_dir, anchor_dir).load_or_create()
    _rewrite_json(state_dir / "mailbox-identity.json", mutate)

    # When
    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = _store(state_dir, anchor_dir).public_summary()

    # Then
    assert captured.value.code is MailboxKeyStoreErrorCode.MALFORMED_STATE


def test_corrupt_marker_is_rejected(tmp_path: Path) -> None:
    # Given
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    _ = _store(state_dir, anchor_dir).load_or_create()
    marker = state_dir / "mailbox-store.initialized"
    _ = marker.write_text("corrupt\n", encoding="ascii")
    marker.chmod(0o600)

    # When
    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = _store(state_dir, anchor_dir).load_or_create()

    # Then
    assert captured.value.code is MailboxKeyStoreErrorCode.MALFORMED_STATE


def test_corrupt_anchor_is_rejected(tmp_path: Path) -> None:
    # Given
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    _ = _store(state_dir, anchor_dir).load_or_create()
    anchor = anchor_dir / "mailbox-expected-identity.json"
    _ = anchor.write_text('{"v":true}', encoding="ascii")
    anchor.chmod(0o600)

    # When
    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = _store(state_dir, anchor_dir).load_or_create()

    # Then
    assert captured.value.code is MailboxKeyStoreErrorCode.MALFORMED_STATE


@pytest.mark.parametrize(
    ("relative_path", "content"),
    [
        ("private-store/mailbox-identity.json", b"x" * 4097),
        ("private-store/mailbox-store.initialized", b"x" * 4097),
        ("external-anchor/mailbox-expected-identity.json", b"x" * 4097),
    ],
)
def test_oversized_private_state_is_rejected(
    tmp_path: Path,
    relative_path: str,
    content: bytes,
) -> None:
    # Given
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    _ = _store(state_dir, anchor_dir).load_or_create()
    target = tmp_path / relative_path
    _ = target.write_bytes(content)
    target.chmod(0o600)

    # When / Then
    with pytest.raises(MailboxKeyStoreError):
        _ = _store(state_dir, anchor_dir).load_or_create()


@pytest.mark.parametrize(
    "relative_path",
    [
        "private-store/mailbox-identity.json",
        "private-store/mailbox-store.initialized",
        "external-anchor/mailbox-expected-identity.json",
    ],
)
def test_hard_linked_state_is_rejected(tmp_path: Path, relative_path: str) -> None:
    # Given
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    _ = _store(state_dir, anchor_dir).load_or_create()
    os.link(tmp_path / relative_path, tmp_path / "extra-link")

    # When
    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = _store(state_dir, anchor_dir).load_or_create()

    # Then
    assert captured.value.code is MailboxKeyStoreErrorCode.UNSAFE_PERMISSIONS


def test_final_component_symlink_is_rejected(tmp_path: Path) -> None:
    # Given
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    _ = _store(state_dir, anchor_dir).load_or_create()
    identity = state_dir / "mailbox-identity.json"
    saved = tmp_path / "saved-identity"
    _ = identity.replace(saved)
    identity.symlink_to(saved)

    # When
    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = _store(state_dir, anchor_dir).load_or_create()

    # Then
    assert captured.value.code is MailboxKeyStoreErrorCode.UNSAFE_PERMISSIONS


def test_symlinked_ancestor_is_rejected(tmp_path: Path) -> None:
    # Given
    real_root = tmp_path / "real"
    real_root.mkdir()
    linked_root = tmp_path / "linked"
    linked_root.symlink_to(real_root, target_is_directory=True)

    # When
    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = _store(linked_root / "private-store", tmp_path / "anchor").load_or_create()

    # Then
    assert captured.value.code is MailboxKeyStoreErrorCode.UNSAFE_PERMISSIONS


def test_unsafe_directory_mode_is_rejected(tmp_path: Path) -> None:
    # Given
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    _ = _store(state_dir, anchor_dir).load_or_create()
    state_dir.chmod(0o755)

    # When
    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = _store(state_dir, anchor_dir).load_or_create()

    # Then
    assert captured.value.code is MailboxKeyStoreErrorCode.UNSAFE_PERMISSIONS
    assert stat.S_IMODE(state_dir.stat().st_mode) == 0o755


@pytest.mark.parametrize(
    "component", ["Mobile Documents", "CloudStorage", "iCloud Drive"]
)
def test_cloud_synced_storage_roots_are_rejected(
    tmp_path: Path,
    component: str,
) -> None:
    # Given
    root = tmp_path / component

    # When
    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = _store(root / "private-store", root / "anchor").load_or_create()

    # Then
    assert captured.value.code is MailboxKeyStoreErrorCode.PROHIBITED_STORAGE


def test_network_filesystem_is_rejected_by_explicit_test_probe(tmp_path: Path) -> None:
    # Given
    # When
    with pytest.raises(MailboxKeyStoreError) as captured:
        _ = _store(
            tmp_path / "private-store",
            tmp_path / "anchor",
            filesystem_kind="network",
        ).load_or_create()

    # Then
    assert captured.value.code is MailboxKeyStoreErrorCode.PROHIBITED_STORAGE


def test_synthetic_temp_root_requires_explicit_test_factory(tmp_path: Path) -> None:
    # When / Then
    with pytest.raises(TypeError):
        _ = inspect.signature(MailboxKeyStore).bind(tmp_path / "keys")
    _ = MailboxKeyStore.for_testing(
        state_dir=tmp_path / "keys",
        anchor_dir=tmp_path / "anchor",
    ).load_or_create()


def test_concurrent_callers_use_barrier_without_flaky_sleep(tmp_path: Path) -> None:
    # Given
    barrier = threading.Barrier(2)
    state_dir = tmp_path / "private-store"
    anchor_dir = tmp_path / "external-anchor"
    returned: list[str] = []

    def initialize() -> None:
        returned.append(
            _store(
                state_dir,
                anchor_dir,
                transaction_barrier=barrier.wait,
            )
            .load_or_create()
            .signing_key_id
        )

    threads = (threading.Thread(target=initialize), threading.Thread(target=initialize))

    # When
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=10)

    # Then
    assert len(returned) == 2
    assert returned[0] == returned[1]
