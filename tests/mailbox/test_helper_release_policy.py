from __future__ import annotations

from typing import TYPE_CHECKING

import pytest

if TYPE_CHECKING:
    from pathlib import Path

from health_bridge.mailbox import helper_lifecycle
from health_bridge.mailbox.helper_distribution_contract import (
    require_approved_helper_distribution,
)
from health_bridge.mailbox.helper_lifecycle import HelperError, HelperErrorCode
from tests.mailbox.test_helper_distribution_contract import write_release


def _identity_value(*parts: str) -> str:
    return "".join(parts)


def test_release_policy_rejects_v1_while_structural_inspection_accepts_it(
    tmp_path: Path,
) -> None:
    archive, manifest = write_release(tmp_path, schema_version=1)
    inspected = helper_lifecycle.validate_helper_release(archive, manifest)

    with pytest.raises(HelperError) as raised:
        _ = helper_lifecycle.validate_general_distribution_helper_release(
            archive,
            manifest,
        )

    assert inspected.schema_version == 1
    assert raised.value.code is HelperErrorCode.INVALID_MANIFEST


def test_release_policy_rejects_self_consistent_wrong_publisher_and_team(
    tmp_path: Path,
) -> None:
    archive, manifest = write_release(tmp_path, schema_version=2)

    with pytest.raises(HelperError) as raised:
        _ = helper_lifecycle.validate_general_distribution_helper_release(
            archive,
            manifest,
        )

    assert raised.value.code is HelperErrorCode.INVALID_MANIFEST


def test_approved_distribution_policy_accepts_public_owner_identity() -> None:
    team_identifier = _identity_value("Y3BJ", "C2J65L")

    require_approved_helper_distribution(
        signing_authority=(
            f"Developer ID Application: Chanhyo Jung ({team_identifier})"
        ),
        team_identifier=team_identifier,
        bundle_identifier=_identity_value(
            "dev.", "chanhyo.", "healthbridge", ".mailbox.ackpublisher"
        ),
        icloud_container_identifier=_identity_value(
            "iCloud.", "dev.", "chanhyo.", "healthbridge"
        ),
    )


def test_approved_distribution_policy_rejects_wrong_self_consistent_identity() -> None:
    wrong_team_identifier = _identity_value("A1B2", "C3D4E5")
    with pytest.raises(HelperError) as raised:
        require_approved_helper_distribution(
            signing_authority=(
                "Developer ID Application: Example Health Bridge "
                f"({wrong_team_identifier})"
            ),
            team_identifier=wrong_team_identifier,
            bundle_identifier="com.example.HealthBridgeMailboxAckPublisher",
            icloud_container_identifier=(
                "iCloud.com.example.HealthBridgeMailboxAckPublisher"
            ),
        )

    assert raised.value.code is HelperErrorCode.INVALID_MANIFEST
