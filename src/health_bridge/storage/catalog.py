import sqlite3

from pydantic import ValidationError

from health_bridge.contract import HealthBridgeBatchV1
from health_bridge.storage.sqlite_rows import fetch_one_int
from health_bridge.timeseries_catalog import canonical_sample_type_code

UPSERT_SOURCE_SQL = (
    "insert into sources (source_key, name, kind, bundle_id, device_model) "
    "values (?, ?, ?, ?, ?) on conflict(source_key) do update set "
    "name = excluded.name, kind = excluded.kind, bundle_id = excluded.bundle_id, "
    "device_model = excluded.device_model, "
    "updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
)
UPSERT_HEALTH_TYPE_SQL = (
    "insert into health_types (type_code, display_name, category, default_unit, "
    "sensitivity) values (?, ?, ?, ?, ?) on conflict(type_code) do update set "
    "display_name = excluded.display_name, category = excluded.category, "
    "default_unit = excluded.default_unit, sensitivity = excluded.sensitivity, "
    "updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
)
INSERT_ALIAS_SQL = (
    "insert into health_type_aliases (type_code, alias) values (?, ?) "
    "on conflict(type_code, alias) do nothing"
)
MISSING_SOURCE_ERROR = "source was not available after catalog upsert"


def upsert_catalog(connection: sqlite3.Connection, batch: HealthBridgeBatchV1) -> None:
    for source in batch.sources:
        _ = connection.execute(
            UPSERT_SOURCE_SQL,
            (
                source.source_key,
                source.name,
                source.kind,
                source.bundle_id,
                source.device_model,
            ),
        )
    for health_type in batch.health_types:
        canonical_type_code = canonical_sample_type_code(health_type.type_code)
        _ = connection.execute(
            UPSERT_HEALTH_TYPE_SQL,
            (
                canonical_type_code,
                health_type.display_name,
                health_type.category,
                health_type.default_unit,
                health_type.sensitivity,
            ),
        )
        aliases = set(health_type.aliases)
        if canonical_type_code != health_type.type_code:
            aliases.add(health_type.type_code)
        for alias in sorted(aliases):
            _ = connection.execute(INSERT_ALIAS_SQL, (canonical_type_code, alias))


def source_id(connection: sqlite3.Connection, source_key: str) -> int:
    try:
        source_id_value = fetch_one_int(
            connection,
            "select source_id from sources where source_key = ?",
            (source_key,),
        )
    except ValidationError as exc:
        raise sqlite3.IntegrityError(MISSING_SOURCE_ERROR) from exc
    if source_id_value <= 0:
        raise sqlite3.IntegrityError(MISSING_SOURCE_ERROR)
    return source_id_value
