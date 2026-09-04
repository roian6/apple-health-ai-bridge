import shutil
from pathlib import Path

import pytest

from tests.guardrails.release_version_fixtures import (
    ReleaseTree,
    commit_release_tree,
    init_release_repo,
    write_release_tree,
)

ROOT = Path(__file__).parents[2]


@pytest.fixture
def receiver_release_repo(tmp_path: Path) -> Path:
    repo = init_release_repo(tmp_path)
    write_release_tree(
        repo,
        ReleaseTree(
            receiver_version="1.1.1",
            release_tag="receiver-v1.1.1",
            release_scope="receiver",
            ios_version="1.1.0",
            ios_build="39",
            batch_version="1.0.0",
        ),
    )
    helper = ROOT / "macos/HealthBridgeMailboxAckPublisher"
    _ = shutil.copytree(helper, repo / helper.relative_to(ROOT), dirs_exist_ok=True)
    _ = commit_release_tree(repo, "synthetic receiver release")
    return repo
