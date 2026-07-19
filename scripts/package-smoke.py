#!/usr/bin/env python3
# ruff: noqa: T201,S603
"""Inspect and smoke-test built wheel/sdist release artifacts.

Run this only after the hash-constrained ``uv build`` command in
``.github/release/criteria.md``. The smoke installs the wheel in a
fresh environment so repository imports cannot hide missing package data.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import stat
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import NoReturn, cast

ROOT = Path(__file__).resolve().parents[1]
SOURCE_MIGRATIONS = ROOT / "src/health_bridge/storage/migrations"
SYNTHETIC_FIXTURE = ROOT / "fixtures/health_bridge_batch_v1.synthetic.json"
FORBIDDEN_MEMBER_PARTS = {
    ".codegraph",
    ".coverage",
    ".git",
    ".hermes",
    ".public-release-denylist.local",
    ".tmp",
    ".venv",
    "__pycache__",
    "htmlcov",
}
FORBIDDEN_OUTPUT_MARKERS = (
    "bearer_token",
    "healthbridge://pair",
    "pairing_url",
)


class PackageSmokeError(RuntimeError):
    """Raised when a built release artifact fails a release invariant."""


def fail(message: str) -> NoReturn:
    """Abort with one concise package-smoke failure."""
    raise PackageSmokeError(message)


def clean_subprocess_environment() -> dict[str, str]:
    """Return an environment that cannot import from the source checkout."""
    environment = dict(os.environ)
    _ = environment.pop("PYTHONPATH", None)
    _ = environment.pop("PYTHONHOME", None)
    return environment


def run(command: list[str], *, cwd: Path) -> subprocess.CompletedProcess[str]:
    """Run a fixed local command and surface bounded diagnostics on failure."""
    result = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
        env=clean_subprocess_environment(),
    )
    if result.returncode != 0:
        executable = Path(command[0]).name
        stderr = result.stderr.strip()[-2000:]
        fail(f"{executable} failed with exit {result.returncode}: {stderr}")
    return result


def artifact_members(path: Path) -> list[str]:
    """Return normalized member names from a wheel or source distribution."""
    if path.suffix == ".whl":
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            for member in members:
                member_type = stat.S_IFMT(member.external_attr >> 16)
                if member_type not in {0, stat.S_IFREG, stat.S_IFDIR}:
                    fail(f"{path.name} contains a non-regular archive member")
            return [member.filename for member in members]
    with tarfile.open(path) as archive:
        members = archive.getmembers()
        if any(not member.isfile() and not member.isdir() for member in members):
            fail(f"{path.name} contains a non-regular archive member")
        return [member.name for member in members]


def validate_member_paths(artifact: Path, members: list[str]) -> None:
    """Reject private/tool-state members and archive path traversal."""
    for member in members:
        member_path = PurePosixPath(member)
        if member_path.is_absolute() or ".." in member_path.parts:
            fail(f"{artifact.name} contains an unsafe archive path")
        blocked = FORBIDDEN_MEMBER_PARTS.intersection(member_path.parts)
        if blocked:
            blocked_text = ", ".join(sorted(blocked))
            prefix = f"{artifact.name} contains forbidden private/tool-state paths:"
            fail(f"{prefix} {blocked_text}")


def migration_names(members: list[str]) -> set[str]:
    """Return packaged SQL migration basenames."""
    return {
        PurePosixPath(member).name
        for member in members
        if "/storage/migrations/" in f"/{member}" and member.endswith(".sql")
    }


def select_artifacts(dist_dir: Path) -> tuple[Path, Path]:
    """Require exactly one wheel and one source distribution."""
    wheels = sorted(dist_dir.glob("*.whl"))
    sdists = sorted(dist_dir.glob("*.tar.gz"))
    if len(wheels) != 1 or len(sdists) != 1:
        required = "dist directory must contain exactly one wheel and one .tar.gz"
        artifact_kind = "source distribution"
        fail(f"{required} {artifact_kind}")
    return wheels[0], sdists[0]


def validate_artifacts(wheel: Path, sdist: Path) -> list[str]:
    """Inspect both artifacts and return expected migration IDs."""
    expected_files = sorted(
        path.name for path in SOURCE_MIGRATIONS.glob("[0-9][0-9][0-9]_*.sql")
    )
    if not expected_files:
        fail("no source migrations found")
    expected_set = set(expected_files)

    for artifact in (wheel, sdist):
        members = artifact_members(artifact)
        validate_member_paths(artifact, members)
        packaged = migration_names(members)
        if packaged != expected_set:
            missing = sorted(expected_set - packaged)
            unexpected = sorted(packaged - expected_set)
            detail = f"missing={missing}, unexpected={unexpected}"
            fail(f"{artifact.name} migration mismatch; {detail}")

    return [Path(name).stem for name in expected_files]


def venv_executable(venv: Path, name: str) -> Path:
    """Resolve a virtual-environment executable on POSIX or Windows."""
    posix = venv / "bin" / name
    if posix.exists():
        return posix
    suffix = ".exe" if name in {"python", "health-bridge"} else ""
    return venv / "Scripts" / f"{name}{suffix}"


def smoke_installed_wheel(wheel: Path, expected_migrations: list[str]) -> None:
    """Install the wheel cleanly and run synthetic CLI/MCP checks."""
    uv = shutil.which("uv")
    if uv is None:
        fail("uv executable not found")

    with tempfile.TemporaryDirectory(prefix="health-bridge-package-smoke-") as temp:
        temp_root = Path(temp)
        venv = temp_root / "venv"
        _ = run([uv, "venv", str(venv)], cwd=temp_root)
        python = venv_executable(venv, "python")
        _ = run(
            [uv, "pip", "install", "--python", str(python), str(wheel)],
            cwd=temp_root,
        )
        cli = venv_executable(venv, "health-bridge")
        _ = run([str(cli), "--help"], cwd=temp_root)

        database = temp_root / "fresh.sqlite"
        _ = run([str(cli), "init", "--db", str(database)], cwd=temp_root)
        with sqlite3.connect(database) as connection:
            rows = cast(
                "list[tuple[str]]",
                connection.execute(
                    "select migration_id from schema_migrations order by migration_id"
                ).fetchall(),
            )
            applied = [row[0] for row in rows]
        if applied != expected_migrations:
            prefix = "installed wheel initialized unexpected migrations;"
            fail(f"{prefix} expected={expected_migrations}, applied={applied}")

        _ = run(
            [
                str(cli),
                "ingest-fixture",
                "--db",
                str(database),
                "--input",
                str(SYNTHETIC_FIXTURE),
            ],
            cwd=temp_root,
        )
        status = run(
            [str(cli), "status", "--db", str(database), "--markdown"],
            cwd=temp_root,
        ).stdout
        smoke = run(
            [str(cli), "mcp", "smoke", "--db", str(database)],
            cwd=temp_root,
        ).stdout
        if not status.strip():
            fail("installed wheel returned empty Markdown status")
        if any(marker in status for marker in FORBIDDEN_OUTPUT_MARKERS):
            fail("installed wheel status exposed a forbidden secret-shaped marker")
        raw_payload = cast("object", json.loads(smoke))
        if not isinstance(raw_payload, dict):
            fail("installed wheel MCP smoke returned an invalid root result")
        payload = cast("dict[str, object]", raw_payload)
        raw_context_result = payload.get("context_result", {})
        if not isinstance(raw_context_result, dict):
            fail("installed wheel MCP smoke returned an invalid context result")
        context_result = cast("dict[str, object]", raw_context_result)
        if context_result.get("forbidden_hits") != []:
            fail("installed wheel MCP smoke reported forbidden output")


def main() -> int:
    """Run release-artifact validation."""
    parser = argparse.ArgumentParser(description=__doc__)
    _ = parser.add_argument(
        "--dist-dir",
        type=Path,
        default=Path("dist"),
        help="Directory containing exactly one wheel and one .tar.gz sdist.",
    )
    raw_args = cast("dict[str, object]", vars(parser.parse_args()))
    raw_dist_dir = raw_args.get("dist_dir")
    if not isinstance(raw_dist_dir, Path):
        fail("--dist-dir must resolve to a path")
    dist_dir = raw_dist_dir.resolve()
    if not dist_dir.is_dir():
        fail(f"distribution directory does not exist: {dist_dir}")

    wheel, sdist = select_artifacts(dist_dir)
    expected_migrations = validate_artifacts(wheel, sdist)
    smoke_installed_wheel(wheel, expected_migrations)
    artifact_checks = "wheel/sdist contents, migrations, fresh install"
    runtime_checks = "synthetic status, and MCP smoke"
    print(f"PASS: {artifact_checks}, {runtime_checks}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
