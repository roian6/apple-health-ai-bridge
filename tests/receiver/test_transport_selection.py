from pathlib import Path

import pytest

import health_bridge.receiver.transports as transport_module


def test_direct_transport_rejects_mailbox_configuration(tmp_path: Path) -> None:
    # Given
    mailbox_root = tmp_path / "mailbox"

    # When / Then
    with pytest.raises(
        ValueError,
        match=r"^Mailbox configuration requires --transport icloud-mailbox\.$",
    ):
        _ = transport_module.select_receiver_transport(
            "direct",
            mailbox_root=mailbox_root,
            icloud_container_identifier=None,
            platform="linux",
            home=tmp_path,
        )


def test_direct_transport_rejects_icloud_container_configuration(
    tmp_path: Path,
) -> None:
    with pytest.raises(
        ValueError,
        match=r"^Mailbox configuration requires --transport icloud-mailbox\.$",
    ):
        _ = transport_module.select_receiver_transport(
            "direct",
            mailbox_root=None,
            icloud_container_identifier="iCloud.dev.synthetic.HealthBridge",
            platform="linux",
            home=tmp_path,
        )


def test_mailbox_transport_requires_configuration(tmp_path: Path) -> None:
    # Given / When / Then
    with pytest.raises(
        ValueError,
        match=r"^Encrypted iCloud Mailbox requires --mailbox-root\.$",
    ):
        _ = transport_module.select_receiver_transport(
            "icloud-mailbox",
            mailbox_root=None,
            icloud_container_identifier=None,
            platform="darwin",
            home=tmp_path,
        )


def test_mailbox_transport_requires_expected_icloud_container_identifier(
    tmp_path: Path,
) -> None:
    mailbox_root = (
        tmp_path
        / "Library/Mobile Documents/iCloud~dev~synthetic~HealthBridge"
        / "Documents/HealthBridgeMailbox/v1"
    )
    mailbox_root.mkdir(parents=True)

    with pytest.raises(
        ValueError,
        match=(
            r"^Encrypted iCloud Mailbox requires "
            r"--icloud-container-identifier\.$"
        ),
    ):
        _ = transport_module.select_receiver_transport(
            "icloud-mailbox",
            mailbox_root=mailbox_root,
            icloud_container_identifier=None,
            platform="darwin",
            home=tmp_path,
        )


def test_mailbox_transport_fails_closed_on_linux(tmp_path: Path) -> None:
    # Given
    mailbox_root = tmp_path / "mailbox"

    # When / Then
    with pytest.raises(
        ValueError,
        match=r"^Encrypted iCloud Mailbox is unavailable on this host\.$",
    ):
        _ = transport_module.select_receiver_transport(
            "icloud-mailbox",
            mailbox_root=mailbox_root,
            icloud_container_identifier="iCloud.dev.synthetic.HealthBridge",
            platform="linux",
            home=tmp_path,
        )


def test_mailbox_transport_accepts_supported_mac_icloud_documents_topology(
    tmp_path: Path,
) -> None:
    # Given
    mailbox_root = (
        tmp_path
        / "Library/Mobile Documents/iCloud~dev~example~HealthBridgeCompanion"
        / "Documents/HealthBridgeMailbox/v1"
    )
    mailbox_root.mkdir(parents=True)

    # When
    selected = transport_module.select_receiver_transport(
        "icloud-mailbox",
        mailbox_root=mailbox_root,
        icloud_container_identifier="iCloud.dev.example.HealthBridgeCompanion",
        platform="darwin",
        home=tmp_path,
    )

    # Then
    assert selected is transport_module.ReceiverTransport.MAILBOX


def test_mailbox_transport_rejects_unsupported_mac_path(tmp_path: Path) -> None:
    # Given
    mailbox_root = tmp_path / "Documents/HealthBridgeMailbox/v1"
    mailbox_root.mkdir(parents=True)

    # When / Then
    with pytest.raises(
        ValueError,
        match=r"^Encrypted iCloud Mailbox topology is unavailable\.$",
    ):
        _ = transport_module.select_receiver_transport(
            "icloud-mailbox",
            mailbox_root=mailbox_root,
            icloud_container_identifier="iCloud.dev.example.HealthBridgeCompanion",
            platform="darwin",
            home=tmp_path,
        )


def test_mailbox_transport_rejects_different_icloud_container_component(
    tmp_path: Path,
) -> None:
    mailbox_root = (
        tmp_path
        / "Library/Mobile Documents/iCloud~dev~synthetic~DifferentApp"
        / "Documents/HealthBridgeMailbox/v1"
    )
    mailbox_root.mkdir(parents=True)

    with pytest.raises(
        ValueError,
        match=r"^Encrypted iCloud Mailbox topology is unavailable\.$",
    ):
        _ = transport_module.select_receiver_transport(
            "icloud-mailbox",
            mailbox_root=mailbox_root,
            icloud_container_identifier="iCloud.dev.synthetic.HealthBridge",
            platform="darwin",
            home=tmp_path,
        )


def test_mailbox_transport_rejects_symlink_home_before_creating_mailbox(
    tmp_path: Path,
) -> None:
    target_home = tmp_path / "target-home"
    documents = (
        target_home
        / "Library/Mobile Documents/iCloud~dev~synthetic~HealthBridge/Documents"
    )
    documents.mkdir(parents=True)
    linked_home = tmp_path / "linked-home"
    linked_home.symlink_to(target_home, target_is_directory=True)

    with pytest.raises(
        ValueError,
        match=r"^Encrypted iCloud Mailbox topology is unavailable\.$",
    ):
        _ = transport_module.select_receiver_transport(
            "icloud-mailbox",
            mailbox_root=(
                linked_home
                / "Library/Mobile Documents/iCloud~dev~synthetic~HealthBridge"
                / "Documents/HealthBridgeMailbox/v1"
            ),
            icloud_container_identifier="iCloud.dev.synthetic.HealthBridge",
            platform="darwin",
            home=linked_home,
        )

    assert not (documents / "HealthBridgeMailbox").exists()
