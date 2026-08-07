from __future__ import annotations

import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, TypeAlias

from tests.scripts.mailbox_m1_fixture_support import (
    ManifestFixture,
    build_manifest_fixture,
    git_head,
    write_manifest,
)

BindingClass: TypeAlias = Literal["receipt", "scope"]

REPOSITORY_ROOT = Path.cwd()
RECEIPT_KIND = "dependency_contract"
SCOPE_PATH = "fixtures/delivery_v1_python.synthetic.json"
FIFO_SWAP_PROGRAM = r"""
import os
import runpy
import sys
import threading
from pathlib import Path

target = Path(sys.argv[1])
with_writer = sys.argv[2] == "writer"
commit = sys.argv[3]
manifest = sys.argv[4]
sys.path.insert(0, str(Path("scripts").resolve()))
import mailbox_m1_files

real_open = os.open
swapped = False

def write_partial_fifo() -> None:
    descriptor = real_open(target, os.O_WRONLY | getattr(os, "O_CLOEXEC", 0))
    try:
        os.write(descriptor, b"untrusted-partial-fifo-bytes")
    except BrokenPipeError:
        pass
    finally:
        os.close(descriptor)

def racing_open(path, flags, mode=0o777, *, dir_fd=None):
    global swapped
    if not swapped and path == target.name and not flags & os.O_DIRECTORY:
        target.unlink()
        os.mkfifo(target)
        if with_writer:
            threading.Thread(target=write_partial_fifo, daemon=True).start()
        swapped = True
    return real_open(path, flags, mode, dir_fd=dir_fd)

class OsProxy:
    open = staticmethod(racing_open)
    supports_dir_fd = {*os.supports_dir_fd, racing_open}
    supports_follow_symlinks = os.supports_follow_symlinks

    def __getattr__(self, name):
        return getattr(os, name)

mailbox_m1_files.os = OsProxy()
sys.argv = [
    "scripts/validate-mailbox-milestone.py",
    "--milestone",
    "M1",
    "--strict",
    "--commit",
    commit,
    "--manifest",
    manifest,
]
runpy.run_path("scripts/validate-mailbox-milestone.py", run_name="__main__")
"""


@dataclass(frozen=True, slots=True)
class IsolatedRepository:
    root: Path
    manifest_path: Path
    manifest: ManifestFixture

    def run(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                "scripts/validate-mailbox-milestone.py",
                "--milestone",
                "M1",
                "--strict",
                "--commit",
                self.manifest.head,
                "--manifest",
                self.manifest_path.name,
            ],
            cwd=self.root,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )


def isolated_repository(tmp_path: Path) -> IsolatedRepository:
    manifest = build_manifest_fixture(
        REPOSITORY_ROOT,
        git_head(REPOSITORY_ROOT),
    )
    root = tmp_path / "repository"
    bindings = (*manifest.scope, *manifest.receipts)
    for relative_path in {binding.path for binding in bindings}:
        source = REPOSITORY_ROOT / relative_path
        destination = root / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        _ = shutil.copyfile(source, destination)
    manifest_path = root / "m1-manifest.synthetic.json"
    write_manifest(manifest_path, manifest)
    return IsolatedRepository(root=root, manifest_path=manifest_path, manifest=manifest)


def run_fifo_swap(
    repository: IsolatedRepository,
    binding_class: BindingClass,
    *,
    with_writer: bool,
) -> subprocess.CompletedProcess[str]:
    writer_mode = "writer" if with_writer else "no-writer"
    return subprocess.run(
        [
            sys.executable,
            "-c",
            FIFO_SWAP_PROGRAM,
            str(target_path(repository, binding_class)),
            writer_mode,
            repository.manifest.head,
            repository.manifest_path.name,
        ],
        cwd=repository.root,
        check=False,
        capture_output=True,
        text=True,
        timeout=3,
    )


def target_path(repository: IsolatedRepository, binding_class: BindingClass) -> Path:
    relative_path = (
        next(
            receipt.path
            for receipt in repository.manifest.receipts
            if receipt.kind == RECEIPT_KIND
        )
        if binding_class == "receipt"
        else SCOPE_PATH
    )
    return repository.root / relative_path


def replace_with_final_symlink(repository: IsolatedRepository, target: Path) -> None:
    outside = repository.root.parent / f"outside-{target.name}"
    _ = shutil.copyfile(target, outside)
    target.unlink()
    target.symlink_to(outside)


def replace_ancestor_with_symlink(
    repository: IsolatedRepository,
    binding_class: BindingClass,
) -> None:
    relative_ancestor = (
        Path("tests/fixtures/mailbox_m1/receipts")
        if binding_class == "receipt"
        else Path("fixtures")
    )
    ancestor = repository.root / relative_ancestor
    outside = repository.root.parent / f"outside-{binding_class}-ancestor"
    _ = shutil.move(ancestor, outside)
    ancestor.symlink_to(outside, target_is_directory=True)


def replace_with_hard_link(repository: IsolatedRepository, target: Path) -> None:
    outside = repository.root.parent / f"outside-hardlink-{target.name}"
    _ = shutil.copyfile(target, outside)
    target.unlink()
    os.link(outside, target)


def replace_with_directory(target: Path) -> None:
    target.unlink()
    target.mkdir()


def replace_manifest_path(
    repository: IsolatedRepository,
    binding_class: BindingClass,
    replacement_path: str,
) -> None:
    manifest = repository.manifest
    if binding_class == "receipt":
        receipts = tuple(
            receipt.model_copy(update={"path": replacement_path})
            if receipt.kind == RECEIPT_KIND
            else receipt
            for receipt in manifest.receipts
        )
        mutated = manifest.model_copy(update={"receipts": receipts})
    else:
        scope = tuple(
            binding.model_copy(update={"path": replacement_path})
            if binding.path == SCOPE_PATH
            else binding
            for binding in manifest.scope
        )
        mutated = manifest.model_copy(update={"scope": scope})
    write_manifest(repository.manifest_path, mutated)
