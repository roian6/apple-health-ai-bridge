from __future__ import annotations

import importlib.util
import io
import tarfile
import zipfile
from pathlib import Path
from typing import Protocol, cast

import pytest


class PackageSmokeModule(Protocol):
    PackageSmokeError: type[Exception]

    def artifact_members(self, path: Path) -> list[str]: ...


def _load_package_smoke() -> PackageSmokeModule:
    script = Path("scripts/package-smoke.py")
    spec = importlib.util.spec_from_file_location("package_smoke", script)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return cast("PackageSmokeModule", cast("object", module))


@pytest.mark.parametrize(
    "member_type", [tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE]
)
def test_sdist_rejects_non_regular_archive_members(
    tmp_path: Path,
    member_type: bytes,
) -> None:
    package_smoke = _load_package_smoke()
    artifact = tmp_path / "synthetic.tar.gz"
    with tarfile.open(artifact, "w:gz") as archive:
        regular = tarfile.TarInfo("package/regular.txt")
        regular.size = 4
        archive.addfile(regular, io.BytesIO(b"safe"))
        unsafe = tarfile.TarInfo("package/unsafe")
        unsafe.type = member_type
        unsafe.linkname = "regular.txt"
        archive.addfile(unsafe)

    with pytest.raises(package_smoke.PackageSmokeError):
        _ = package_smoke.artifact_members(artifact)


def test_wheel_rejects_symlink_members(tmp_path: Path) -> None:
    package_smoke = _load_package_smoke()
    artifact = tmp_path / "synthetic.whl"
    with zipfile.ZipFile(artifact, "w") as archive:
        member = zipfile.ZipInfo("package/unsafe")
        member.create_system = 3
        member.external_attr = 0o120777 << 16
        archive.writestr(member, "regular.txt")

    with pytest.raises(package_smoke.PackageSmokeError):
        _ = package_smoke.artifact_members(artifact)
