import json
from pathlib import Path
from typing import Annotated

import typer
from pydantic import ValidationError
from ruamel.yaml.error import YAMLError
from tomlkit.exceptions import ParseError

from health_bridge.cli_config import resolve_database
from health_bridge.connect_adapters import ADAPTERS
from health_bridge.connect_wizard import (
    connect_one,
    connection_wizard,
    ssh_preparation,
    stable_executable,
)


def connect(
    client: Annotated[str | None, typer.Option("--client")] = None,
    config: Annotated[
        Path | None,
        typer.Option(
            "--config", help="Exact effective app/profile MCP configuration file."
        ),
    ] = None,
    db: Annotated[Path | None, typer.Option("--db")] = None,
    json_output: Annotated[
        bool,
        typer.Option(
            "--json", help="Export local stdio preparation only; never changes clients."
        ),
    ] = False,
    ssh_alias: Annotated[
        str | None,
        typer.Option(
            "--ssh-alias",
            help="Prepare another-machine access with an existing alias; does not SSH.",
        ),
    ] = None,
) -> None:
    try:
        if ssh_alias:
            ssh_preparation(ssh_alias)
            return
        database = db.absolute() if db else resolve_database(None)
        if json_output:
            typer.echo(
                json.dumps(
                    {
                        "status": "preparation_only",
                        "command": stable_executable(),
                        "args": ["mcp", "start", "--db", str(database)],
                        "host": "this computer",
                        "access": "read-only",
                    }
                )
            )
            return
        if client:
            if client not in ADAPTERS:
                raise typer.BadParameter("Choose one of: " + ", ".join(ADAPTERS))
            _ = connect_one(client, database, config)
        else:
            _ = connection_wizard(database)
    except (ValidationError, YAMLError, ParseError, UnicodeError):
        message = "Cannot parse the selected client config safely; it was retained."
        raise typer.BadParameter(message) from None
    except (OSError, TypeError, ValueError) as exc:
        raise typer.BadParameter(str(exc)) from None
    except (EOFError, KeyboardInterrupt, typer.Abort):
        typer.echo(
            "AI connection paused. Your installation and saved records are kept."
        )
