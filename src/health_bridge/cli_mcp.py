import json
from pathlib import Path
from typing import Annotated

import typer

from health_bridge.mcp.server import mcp_smoke_result, serve_stdio

mcp_app = typer.Typer(help="Run the local stdio read-only MCP surface.")


@mcp_app.command()
def start(
    db: Annotated[Path, typer.Option("--db", help="User-owned database path.")],
) -> None:
    serve_stdio(db)


@mcp_app.command()
def smoke(
    db: Annotated[Path, typer.Option("--db", help="User-owned database path.")],
) -> None:
    typer.echo(json.dumps(mcp_smoke_result(db), separators=(",", ":")))
