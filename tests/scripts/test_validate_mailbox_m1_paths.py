from __future__ import annotations

import hashlib
from typing import TYPE_CHECKING

import pytest

from tests.scripts.mailbox_m1_fixture_support import write_manifest
from tests.scripts.mailbox_m1_path_support import (
    BindingClass,
    isolated_repository,
    replace_ancestor_with_symlink,
    replace_manifest_path,
    replace_with_directory,
    replace_with_final_symlink,
    replace_with_hard_link,
    run_fifo_swap,
    target_path,
)

if TYPE_CHECKING:
    from pathlib import Path


@pytest.mark.parametrize(
    "binding_class",
    [pytest.param("receipt"), pytest.param("scope")],
)
@pytest.mark.parametrize(
    "indirection",
    [
        pytest.param("final_symlink"),
        pytest.param("ancestor_symlink"),
        pytest.param("hard_link"),
    ],
)
def test_strict_m1_validator_rejects_filesystem_indirection(
    tmp_path: Path,
    binding_class: BindingClass,
    indirection: str,
) -> None:
    # Given: an exact isolated M1 repository whose approved path is redirected.
    repository = isolated_repository(tmp_path)
    target = target_path(repository, binding_class)
    if indirection == "final_symlink":
        replace_with_final_symlink(repository, target)
    elif indirection == "ancestor_symlink":
        replace_ancestor_with_symlink(repository, binding_class)
    else:
        replace_with_hard_link(repository, target)
    # When: the real strict validator reads the exact current manifest.
    result = repository.run()
    expected_reason = "stale_receipt" if binding_class == "receipt" else "stale_scope"
    # Then: valid bytes and hashes cannot cross a filesystem-indirection boundary.
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        f"FAIL M1 {expected_reason}\n",
        "",
    )


@pytest.mark.parametrize(
    "binding_class",
    [pytest.param("receipt"), pytest.param("scope")],
)
def test_strict_m1_validator_rejects_non_regular_artifact(
    tmp_path: Path,
    binding_class: BindingClass,
) -> None:
    # Given: an approved path replaced by a directory rather than a regular file.
    repository = isolated_repository(tmp_path)
    replace_with_directory(target_path(repository, binding_class))
    # When: the real strict validator checks the isolated repository.
    result = repository.run()
    expected_reason = "stale_receipt" if binding_class == "receipt" else "stale_scope"
    # Then: it rejects the unsafe file type with no traceback.
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        f"FAIL M1 {expected_reason}\n",
        "",
    )


def test_strict_m1_validator_rejects_rehashed_receipt_without_required_marker(
    tmp_path: Path,
) -> None:
    # Given: exact receipt ownership with modified bytes and a matching new digest.
    repository = isolated_repository(tmp_path)
    receipt_path = target_path(repository, "receipt")
    content = b'{"kind":"dependency_contract","status":"unverified","synthetic":true}\n'
    _ = receipt_path.write_bytes(content)
    receipts = tuple(
        receipt.model_copy(update={"sha256": hashlib.sha256(content).hexdigest()})
        if receipt.kind == "dependency_contract"
        else receipt
        for receipt in repository.manifest.receipts
    )
    write_manifest(
        repository.manifest_path,
        repository.manifest.model_copy(update={"receipts": receipts}),
    )
    # When: the strict validator checks the rehashed modified receipt.
    result = repository.run()
    # Then: semantic marker enforcement fails closed independently of the digest.
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        "FAIL M1 stale_receipt\n",
        "",
    )


@pytest.mark.parametrize(
    "binding_class",
    [pytest.param("receipt"), pytest.param("scope")],
)
@pytest.mark.parametrize(
    "with_writer",
    [pytest.param(False), pytest.param(True)],
)
def test_strict_m1_validator_rejects_fifo_swap_without_hanging(
    tmp_path: Path,
    binding_class: BindingClass,
    *,
    with_writer: bool,
) -> None:
    # Given: an approved regular artifact swapped to a FIFO at final-open time.
    repository = isolated_repository(tmp_path)
    # When: the real strict CLI is invoked through a bounded subprocess.
    result = run_fifo_swap(
        repository,
        binding_class,
        with_writer=with_writer,
    )
    expected_reason = "stale_receipt" if binding_class == "receipt" else "stale_scope"
    # Then: neither absent writers nor partial FIFO bytes can block or be accepted.
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        f"FAIL M1 {expected_reason}\n",
        "",
    )


@pytest.mark.parametrize(
    "binding_class",
    [pytest.param("receipt"), pytest.param("scope")],
)
@pytest.mark.parametrize(
    "replacement",
    [pytest.param("../escape"), pytest.param("/absolute/escape")],
)
def test_strict_m1_validator_rejects_non_relative_manifest_path(
    tmp_path: Path,
    binding_class: BindingClass,
    replacement: str,
) -> None:
    # Given: an exact manifest with one approved path changed to an escape path.
    repository = isolated_repository(tmp_path)
    replace_manifest_path(repository, binding_class, replacement)
    # When: the real strict validator parses the mutated manifest.
    result = repository.run()
    # Then: the closed path mapping rejects it before filesystem access.
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        "FAIL M1 invalid_manifest\n",
        "",
    )
