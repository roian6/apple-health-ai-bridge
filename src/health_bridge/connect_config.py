import io
import os
import secrets
from collections.abc import MutableMapping
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, TextIO, cast

import tomlkit
from pydantic import JsonValue, TypeAdapter
from ruamel.yaml import YAML

from health_bridge.connect_adapters import Adapter
from health_bridge.connect_json import insert_json, read_json


class YamlCodec(Protocol):
    preserve_quotes: bool | None

    def load(self, stream: str) -> object: ...

    def dump(self, data: object, stream: TextIO) -> None: ...


@dataclass(frozen=True, slots=True)
class Change:
    adapter: Adapter
    path: Path
    entry: dict[str, JsonValue]
    before: bytes | None
    after: bytes


def _container(
    document: MutableMapping[str, object], keys: tuple[str, ...]
) -> MutableMapping[str, object]:
    container = document
    for key in keys:
        if key not in container:
            container[key] = {}
        child = container[key]
        if not isinstance(child, MutableMapping):
            message = "MCP configuration container must be a mapping."
            raise TypeError(message)
        container = cast("MutableMapping[str, object]", child)
    return container


def _shared_mapping(document: MutableMapping[str, object], target: object) -> bool:
    pending: list[object] = [document]
    seen: set[int] = set()
    references = 0
    while pending:
        item = pending.pop()
        if item is target:
            references += 1
        if id(item) in seen:
            continue
        seen.add(id(item))
        if isinstance(item, MutableMapping):
            pending.extend(cast("MutableMapping[str, object]", item).values())
        elif isinstance(item, list):
            pending.extend(cast("list[object]", item))
    return references > 1


def _read(path: Path) -> bytes | None:
    if path.is_symlink() or any(p.is_symlink() for p in path.parents):
        message = "Refusing a symlink in the selected configuration path."
        raise ValueError(message)
    if not path.exists():
        return None
    if not path.is_file() or path.stat().st_size > 4 * 1024 * 1024:
        message = "Configuration must be a regular file smaller than 4 MiB."
        raise ValueError(message)
    return path.read_bytes()


def _require_matching_entry(existing: object, entry: dict[str, JsonValue]) -> None:
    if (
        existing is None
        or TypeAdapter(dict[str, JsonValue]).validate_python(existing) != entry
    ):
        message = "health-bridge entry conflict; choose another profile."
        raise ValueError(message)


def preview(adapter: Adapter, path: Path, entry: dict[str, JsonValue]) -> Change:
    before = _read(path)
    text = before.decode("utf-8") if before is not None else ""
    yaml = cast("YamlCodec", YAML(typ="rt"))
    yaml.preserve_quotes = True
    yaml_prefix = ""
    if adapter.format == "toml":
        document = cast("MutableMapping[str, object]", tomlkit.parse(text))
    elif adapter.format == "yaml":
        loaded: object = yaml.load(text) if text.strip() else {}
        if loaded is None:
            loaded = {}
            yaml_prefix = text
        if not isinstance(loaded, MutableMapping):
            message = "YAML configuration must be a mapping."
            raise ValueError(message)
        document = cast("MutableMapping[str, object]", loaded)
    else:
        document = cast("MutableMapping[str, object]", read_json(text or "{}"))
    container = _container(document, adapter.keys)
    if adapter.format == "yaml" and _shared_mapping(document, container):
        message = "MCP mapping uses a shared YAML alias; select an independent config."
        raise ValueError(message)
    existing = container.get("health-bridge")
    if "health-bridge" in container:
        _require_matching_entry(existing, entry)
        return Change(adapter, path, entry, before, before or b"")
    container["health-bridge"] = entry
    if adapter.format == "toml":
        after = tomlkit.dumps(document)
    elif adapter.format == "yaml":
        stream = io.StringIO()
        yaml.dump(document, stream)
        after = yaml_prefix + stream.getvalue()
    else:
        after = insert_json(text or "{}\n", (*adapter.keys, "health-bridge"), entry)
        _ = read_json(after)
    return Change(adapter, path, entry, before, after.encode())


def apply(change: Change) -> str:
    path = change.path
    if _read(path) != change.before:
        message = "Configuration changed since preview; preview and confirm again."
        raise ValueError(message)
    if change.before == change.after:
        return "already_prepared"
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = path.with_name(path.name + ".health-bridge-lock")
    with lock.open("xb"):
        try:
            if _read(path) != change.before:
                message = (
                    "Configuration changed since preview; preview and confirm again."
                )
                raise ValueError(message)
            if change.before is not None:
                backup = path.with_name(
                    path.name + ".health-bridge-backup-" + secrets.token_hex(8)
                )
                with backup.open("xb") as stream:
                    backup.chmod(0o600)
                    _ = stream.write(change.before)
            stage = path.with_name(
                path.name + ".health-bridge-stage-" + secrets.token_hex(8)
            )
            try:
                with stage.open("xb") as stream:
                    stage.chmod(0o600)
                    _ = stream.write(change.after)
                    stream.flush()
                    os.fsync(stream.fileno())
                staged = preview(change.adapter, stage, change.entry)
                if staged.before != change.after or staged.after != change.after:
                    message = "Prepared readback failed; original config retained."
                    raise ValueError(message)
                if _read(path) != change.before:
                    message = "Configuration changed; preserved the newer file."
                    raise ValueError(message)
                _ = stage.replace(path)
            finally:
                stage.unlink(missing_ok=True)
            readback = preview(change.adapter, path, change.entry)
            if readback.before != change.after or readback.after != change.after:
                message = "Configuration readback differs; inspect the private backup."
                raise ValueError(message)
        finally:
            lock.unlink()
    return "configuration_prepared"
