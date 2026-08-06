from dataclasses import dataclass
from typing import Never, assert_never

from health_bridge.receiver._mailbox_key_crypto import (
    anchor_for,
    continuity_matches,
    identity_from_anchor,
    provisioning_for,
    public_identity,
)
from health_bridge.receiver._mailbox_key_models import (
    ExpectedIdentityAnchor,
    MailboxKeyLifecycleState,
    MailboxKeyStoreError,
    MailboxKeyStoreErrorCode,
    ProvisioningAnchor,
    StoredMailboxKeys,
    verify_mailbox_key_continuity,
)


@dataclass(frozen=True, slots=True)
class ReconciliationWrites:
    anchor: ExpectedIdentityAnchor | None
    provisioning: ProvisioningAnchor | None


def required_reconciliation(
    stored: StoredMailboxKeys,
    anchor: ExpectedIdentityAnchor,
    provisioning: ProvisioningAnchor,
) -> ReconciliationWrites:
    committed = provisioning.expected
    committed_generation = provisioning.generation
    if (
        stored.generation == committed_generation
        and anchor.generation == committed_generation - 1
    ):
        _validate_forward_transition(anchor, stored)
        if anchor_for(stored) != committed:
            _rollback()
        return ReconciliationWrites(anchor=committed, provisioning=None)
    if (
        stored.generation < committed_generation
        or anchor.generation < committed_generation
    ):
        _rollback()
    if (
        stored.generation > committed_generation + 1
        or anchor.generation > committed_generation + 1
        or anchor.generation > stored.generation
    ):
        _rollback()
    if anchor.generation == committed_generation and anchor != committed:
        _rollback()
    if stored.generation == committed_generation:
        if anchor.generation != committed_generation or anchor_for(stored) != committed:
            _rollback()
        return ReconciliationWrites(anchor=None, provisioning=None)
    _validate_forward_transition(committed, stored)
    desired_anchor = anchor_for(stored)
    if anchor.generation == committed_generation:
        anchor_write: ExpectedIdentityAnchor | None = desired_anchor
    elif anchor == desired_anchor:
        anchor_write = None
    else:
        _rollback()
    return ReconciliationWrites(
        anchor=anchor_write,
        provisioning=provisioning_for(desired_anchor),
    )


def _validate_forward_transition(
    committed: ExpectedIdentityAnchor,
    stored: StoredMailboxKeys,
) -> None:
    if stored.generation != committed.generation + 1:
        _rollback()
    if committed.state is not MailboxKeyLifecycleState.ACTIVE:
        _rollback()
    old = identity_from_anchor(committed)
    current = public_identity(stored)
    state = stored.state
    if state is MailboxKeyLifecycleState.ACTIVE:
        continuity = stored.continuity
        if continuity is None:
            _rollback()
        verify_mailbox_key_continuity(continuity)
        if not continuity_matches(continuity, old, current):
            _rollback()
        return
    if state is MailboxKeyLifecycleState.REVOKED:
        if current != old or stored.continuity != committed.continuity:
            _rollback()
        return
    if state is MailboxKeyLifecycleState.LOST:
        raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.MALFORMED_STATE)
    assert_never(state)


def _rollback() -> Never:
    raise MailboxKeyStoreError(MailboxKeyStoreErrorCode.ROLLBACK_DETECTED)
