import plistlib
import shutil
from pathlib import Path

import pytest
from pydantic import TypeAdapter

from tests.guardrails.release_version_fixtures import (
    ReleaseTree,
    commit_release_tree,
    git_output,
    init_release_repo,
    write_release_tree,
)

ROOT = Path(__file__).parents[2]


@pytest.fixture(scope="session")
def receiver_release_template(tmp_path_factory: pytest.TempPathFactory) -> Path:
    repo = init_release_repo(tmp_path_factory.mktemp("receiver-release-template"))
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
    helper_info = repo / helper.relative_to(ROOT) / "Info.plist"
    with helper_info.open("rb") as handle:
        info = TypeAdapter(dict[str, str | bool]).validate_python(plistlib.load(handle))
    info["CFBundleShortVersionString"] = "1.1.1"
    _ = helper_info.write_bytes(plistlib.dumps(info))
    _ = commit_release_tree(repo, "synthetic receiver release")
    return repo


@pytest.fixture
def receiver_release_repo(tmp_path: Path, receiver_release_template: Path) -> Path:
    repo = tmp_path / "repo"
    _ = shutil.copytree(receiver_release_template, repo)
    _ = git_output(repo, "config", "core.hooksPath", str(repo / ".git/hooks"))
    return repo
