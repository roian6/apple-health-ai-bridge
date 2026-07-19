from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import cast

from health_bridge.timeseries_catalog import (
    IOS_LIVE_READABLE_TIMESERIES_TYPE_CODES,
    TIMESERIES_BY_TYPE_CODE,
)

SWIFT_CATALOG = Path(
    "ios/HealthBridgeCompanion/Sources/HealthBridgeCompanionCore/HealthKitTypeCatalog.swift"
)

ALIASES = {
    "active_energy": "energy",
    "body_mass": "weight",
}
AGGREGATIONS = {
    "latest": "latest",
    "minMaxAverage": "min_max_average",
    "sum": "sum",
}


@dataclass(frozen=True)
class SwiftQuantityContract:
    type_code: str
    healthkit_identifier: str
    unit: str
    aggregation: str


def _parse_swift_quantity_contracts() -> tuple[SwiftQuantityContract, ...]:
    source = SWIFT_CATALOG.read_text()
    compact_prefix = r'quantityEntry\("([^"]+)",\s*"[^"]+",\s*"([^"]+)",\s*"([^"]+)"'
    compact_pattern = rf"{compact_prefix}.*?aggregation:\s*\.([A-Za-z]+).*?\),"
    compact_entries = cast(
        "list[tuple[str, str, str, str]]",
        re.findall(compact_pattern, source),
    )
    explicit_entries: list[tuple[str, str, str, str]] = []
    entries_source = source.split(
        "public static let entries: [HealthKitTypeCatalogEntry] = [",
        1,
    )[1]
    blocks = cast(
        "list[str]",
        re.findall(
            r"HealthKitTypeCatalogEntry\((.*?)\n\s*\),",
            entries_source,
            flags=re.DOTALL,
        ),
    )
    for block in blocks:
        if "objectKind: .quantity" not in block:
            continue
        values: dict[str, str] = {}
        for key in ("typeCode", "healthKitIdentifier", "canonicalUnit"):
            match = re.search(rf'{key}:\s*"([^"]+)"', block)
            assert match is not None, (key, block)
            values[key] = match.group(1)
        aggregation = re.search(r"aggregation:\s*\.([A-Za-z]+)", block)
        assert aggregation is not None, block
        explicit_entries.append(
            (
                values["typeCode"],
                values["healthKitIdentifier"],
                values["canonicalUnit"],
                aggregation.group(1),
            )
        )
    return tuple(
        SwiftQuantityContract(
            type_code=type_code,
            healthkit_identifier=identifier,
            unit=unit,
            aggregation=AGGREGATIONS[aggregation],
        )
        for type_code, identifier, unit, aggregation in (
            *compact_entries,
            *explicit_entries,
        )
    )


def test_swift_and_receiver_quantity_contracts_have_exact_canonical_parity() -> None:
    canonical: dict[str, SwiftQuantityContract] = {}
    for entry in _parse_swift_quantity_contracts():
        type_code = ALIASES.get(entry.type_code, entry.type_code)
        canonical_entry = SwiftQuantityContract(
            type_code=type_code,
            healthkit_identifier=entry.healthkit_identifier,
            unit=entry.unit,
            aggregation=entry.aggregation,
        )
        previous = canonical.get(type_code)
        if previous is not None:
            assert previous == canonical_entry
        canonical[type_code] = canonical_entry

    assert set(canonical) == set(IOS_LIVE_READABLE_TIMESERIES_TYPE_CODES)
    for type_code, swift_entry in canonical.items():
        receiver_entry = TIMESERIES_BY_TYPE_CODE[type_code]
        assert swift_entry.healthkit_identifier.startswith("HKQuantityTypeIdentifier")
        assert receiver_entry.unit == swift_entry.unit, type_code
        assert receiver_entry.aggregation == swift_entry.aggregation, type_code
