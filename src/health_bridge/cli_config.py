import os
from pathlib import Path
from typing import ClassVar, Final

import typer
from pydantic import BaseModel, ConfigDict

from health_bridge.cli_setup import SetupRequest
from health_bridge.private_files import require_private_parent, write_private_text_file

CONFIG_ERROR: Final = "Run health-bridge setup or pass --db with an existing database."


class InstalledDatabase(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, extra="forbid")
    db: str
    setup: SetupRequest | None = None
    service_name: str = "health-bridge-receiver"


def config_path() -> Path:
    return Path.home() / ".config/health-bridge/config.json"


def save_database(
    db: Path,
    setup: SetupRequest | None = None,
    service_name: str = "health-bridge-receiver",
) -> None:
    write_private_text_file(
        config_path(),
        InstalledDatabase(
            db=str(db.resolve()), setup=setup, service_name=service_name
        ).model_dump_json(),
    )


def saved_configuration() -> InstalledDatabase | None:
    if not config_path().exists():
        return None
    _ = resolve_database(None)
    return InstalledDatabase.model_validate_json(config_path().read_text())


def resolve_database(db: Path | None) -> Path:
    if db is None:
        try:
            path = config_path()
            require_private_parent(path.parent)
            entry = path.lstat()
            if path.is_symlink() or (
                os.name == "posix"
                and (entry.st_uid != os.geteuid() or entry.st_mode & 0o077)
            ):
                raise typer.BadParameter(CONFIG_ERROR)
            db = Path(InstalledDatabase.model_validate_json(path.read_text()).db)
            if not db.is_absolute():
                raise typer.BadParameter(CONFIG_ERROR)
        except (OSError, ValueError):
            raise typer.BadParameter(CONFIG_ERROR) from None
    if not db.is_file():
        raise typer.BadParameter(CONFIG_ERROR)
    return db
