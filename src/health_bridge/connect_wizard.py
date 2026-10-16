import json
import os
import re
import shlex
import shutil
import subprocess  # nosec B404
import sys
from pathlib import Path

import typer
from pydantic import TypeAdapter

from health_bridge.connect_adapters import ADAPTERS, Adapter, effective_path
from health_bridge.connect_config import apply, preview
from health_bridge.connect_probe import probe


def terminal() -> bool:
    return (
        sys.stdin.isatty()
        and sys.stdout.isatty()
        and not any(
            os.environ.get(key) for key in ("CI", "CODEX_THREAD_ID", "CLAUDECODE")
        )
    )


def stable_executable() -> str:
    executable = Path(sys.executable).parent / "health-bridge"
    if not executable.is_file():
        message = "Install the Health Bridge backend before connecting an AI app."
        raise ValueError(message)
    if "_npx" in executable.parts:
        message = "The MCP command must live outside the npx cache. Rerun setup."
        raise ValueError(message)
    return str(executable.absolute())


def inspect_app(adapter: Adapter) -> str:
    if adapter.cli is None:
        return "native_app_unverified"
    executable = shutil.which(adapter.cli)
    if executable is None:
        return "app_not_detected"
    try:
        version = subprocess.run(  # noqa: S603  # nosec B603 - selected installed CLI, fixed flags, no shell.
            [executable, "--version"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        match = re.search(r"\b\d+\.\d+(?:\.\d+)?\b", version.stdout[:4096])
        if version.returncode != 0 or match is None:
            return "app_version_unverified"
        if adapter.name == "openclaw":
            capability = subprocess.run(  # noqa: S603  # nosec B603 - selected installed CLI, fixed help flags, no shell.
                [executable, "mcp", "add", "--help"],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
            if capability.returncode != 0 or not all(
                flag in capability.stdout for flag in ("--command", "--arg")
            ):
                return "app_version_unsupported"
        return "app_version_" + match.group()
    except (OSError, subprocess.TimeoutExpired):
        return "app_version_unverified"


def connect_one(
    client: str,
    db: Path,
    config: Path | None = None,
    *,
    prepared_clients: list[str] | None = None,
) -> bool:
    adapter = ADAPTERS[client]
    path = effective_path(adapter, config)
    executable = stable_executable()
    args = ["mcp", "start", "--db", str(db.absolute())]
    entry = adapter.entry(executable, args)
    change = preview(adapter, path, entry)
    typer.echo(f"App: {client}; profile/config: {path}")
    typer.echo("Host: this computer; access: read-only saved health data.")
    typer.echo("Exact health-bridge entry preview:")
    typer.echo(json.dumps(entry, indent=2))
    app_status = inspect_app(adapter)
    typer.echo(app_status)
    if (
        adapter.name == "openclaw"
        and re.fullmatch(r"app_version_\d+\.\d+(?:\.\d+)?", app_status) is None
    ):
        message = (
            "OpenClaw MCP capability could not be verified; configuration kept. "
            "Install a working compatible CLI, then rerun connect."
        )
        typer.echo(message)
        return False
    if not terminal():
        typer.echo("Preview only. Rerun connect in a terminal to review and consent.")
        return False
    if not typer.confirm(
        "Save only this Health Bridge entry (with a private backup)?", default=False
    ):
        typer.echo("Cancelled. Installation and client configuration are retained.")
        return False
    status = apply(change)
    typer.echo(status)
    if prepared_clients is not None:
        prepared_clients.append(client)
    try:
        typer.echo(probe(executable, args))
    except (OSError, ValueError, subprocess.TimeoutExpired):
        typer.echo(
            "server_probe_failed: check the backend/database, then rerun connect."
        )
        return False
    typer.echo(adapter.reload)
    typer.echo(
        "Configuration and server checks do not prove the app consumed this entry."
    )
    return True


def connection_wizard(
    db: Path,
    requested: tuple[str, ...] = (),
    *,
    prepared_clients: list[str] | None = None,
) -> tuple[str, ...]:
    if not terminal():
        typer.echo("Connect AI later with health-bridge connect in a terminal.")
        return ()
    clients = requested
    if not clients:
        choices = ("Later", *ADAPTERS)
        for number, name in enumerate(choices):
            typer.echo(f"  {number}. {name}")
        selected = TypeAdapter(int).validate_python(
            typer.prompt("Optionally connect your AI app", default=0, type=int)
        )
        if selected == 0:
            return ()
        if selected not in range(1, len(choices)):
            message = "Choose a listed app or connect later."
            raise ValueError(message)
        clients = (choices[selected],)
    configured: list[str] = []
    for client in clients:
        config: Path | None = None
        if client == "vscode":
            typer.echo(
                "In the intended VS Code profile, run MCP: Open User Configuration."
            )
            selected_path = TypeAdapter(str).validate_python(
                typer.prompt("Exact MCP config path (blank for later)", default="")
            )
            if not selected_path:
                continue
            config = Path(selected_path)
        if connect_one(client, db, config, prepared_clients=prepared_clients):
            configured.append(client)
    return tuple(configured)


def ssh_preparation(alias: str) -> None:
    config = Path.home() / ".ssh/config"
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", alias) or not config.is_file():
        message = (
            "Select an existing explicit Host alias from your local ~/.ssh/config."
        )
        raise ValueError(message)
    aliases = [
        word
        for line in config.read_text().splitlines()
        if line.strip().lower().startswith("host ")
        for word in shlex.split(line)[1:]
    ]
    if alias not in aliases:
        message = (
            "Select an explicit Host entry; prepare wildcard/include aliases first."
        )
        raise ValueError(message)
    typer.echo(
        f"Preparation only for existing alias {alias}; no SSH or config changes."
    )
    message = (
        "On the AI computer, verify its existing alias points to the Health Bridge "
        "computer. There, run health-bridge connect --json to obtain the stable "
        "command and database arguments. Prepare the AI host's stdio command as "
        "ssh -T -o BatchMode=yes ALIAS -- COMMAND ARGS with shell quoting. "
        "Verify remotely yourself before granting access. Local GUI config is kept."
    )
    typer.echo(message)
