# health_bridge.batch.v1 Contract

`health_bridge.batch.v1` is the public batch shape for synthetic fixtures and
HealthKit-derived sync payloads. The contract is intentionally batch-oriented so
sync processes can send one bounded window at a time while preserving source and
cursor provenance.

## Versioning

- `schema_id` must be `health_bridge.batch.v1`.
- `schema_version` must use semantic versioning with major version `1`.
- Consumers must reject unknown major versions before reading records.
- Additive optional fields may appear in later `1.x` schemas only after the JSON
  Schema and contract docs are updated.

## Top-Level Shape

Required fields:

- `schema_id`
- `schema_version`
- `generated_at`
- `export_window`
- `sources`
- `health_types`
- `samples`
- `workouts`
- `sleep_sessions`
- `deleted_records`
- `sync`

All timestamps are UTC ISO 8601 strings ending in `Z`. Values are observations
with source context, not interpretations.

## Sources

Each source has a stable `source_key`, display name, source kind, optional bundle
identifier, and optional device model. Fixture source keys are synthetic.

## Types and Aliases

`health_types` defines the type registry used by the batch. Each type includes:

- `type_code`
- `display_name`
- `category`
- `default_unit`
- `sensitivity`
- `aliases`

Aliases keep future HealthKit identifiers separate from the stable bridge type
code.

## Samples

Samples represent scalar or interval observations. Required identity fields are
`client_record_id`, `source_key`, `type_code`, `start_time`, `end_time`, `value`,
and `unit`. Ingest uses source plus client record identity for idempotent
storage.

## Workouts

Workouts use `client_record_id`, `source_key`, `workout_type`, `start_time`,
`end_time`, and measured fields such as duration, energy, and distance where
present.

## Sleep

Sleep sessions contain session-level identity plus stage intervals. Intervals
must fit within the session window and must carry a stage label from the
contract's allowed list.

The iOS sleep lane uses `HKAnchoredObjectQuery` child additions/deletions and a
private, backup-excluded manifest. The manifest retains raw child UUIDs, the
last HealthKit anchor, currently published grouped sessions, a random local
identity namespace, a monotonic revision sequence, the installation-scoped
source key, and the current ordered reset epoch. A changed group gets a
new never-reused `client_record_id`; its prior identity is emitted as a
`sleep_session` tombstone in the same FIFO payload. An unchanged group retains
its identity. This supports shorter ends, shifted starts, stage-only changes,
and full deletion without treating an empty snapshot as proof of deletion.

The exact encoded payload and its post-delivery manifest are written to a private
journal before the payload enters the outbox. The manifest anchor is committed
only after the tracked FIFO item is removed by a successful receiver response.
The first successful **non-empty** anchored baseline for an ordered reset epoch is
authoritative for that installation-scoped source and replaces older receiver
sleep rows transactionally. An empty first read may persist and upload its anchor
and reset epoch, but the receiver records it as non-authoritative and deletes
nothing. A later non-empty retry for the same epoch applies the baseline. Reset
batches without a matching anchored-sleep cursor are rejected transactionally.
The receiver accepts a higher `v2:<epoch>` reset. A lower epoch is rejected with
HTTP `409` and the receiver's structured `minimum_reset_epoch` floor. An equal
epoch is idempotent: an already-authoritative baseline is ignored and returns
success, while an earlier non-authoritative empty baseline may be completed by the
first non-empty baseline for that same epoch. The receiver conservatively rejects
a different legacy UUID reset after a legacy baseline is established. Record
identity remains in a separate stable namespace, so reset ordering never reuses
retired `client_record_id` values.

## Deleted Records

`deleted_records` carries tombstones from a source so later ingest can preserve
record removals without requiring the original value. Receiver ingest retains
sleep tombstones for both source deletions and displaced/rejected revisions, so
late overlap or outbox replay cannot resurrect an obsolete session identity.

## Sync Context

`sync` includes the batch `sync_window` and source cursors. Missing data in a
future query surface must remain unknown availability: it can reflect no record,
permission limits, source gaps, or sync gaps.
