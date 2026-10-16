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

Completed daily projections for selected cumulative activity types accept an
explicit finite zero from a HealthKit statistics sum. A requery replaces the
previous total using the same `hk-daily-activity-<type>-<day>` record identity;
negative, nonfinite, incomplete, and unselected aggregates are not published.
A missing sum, absent result, or permission-ambiguous empty query remains unknown
and emits neither a zero nor a derived-record tombstone. A raw-sample tombstone
removes only its raw identity, not the separately identified daily projection.
The companion sends a `daily_projection_observation:<canonical-type>` cursor
with an installation-local outbox namespace and durable sequence, actual raw
record intervals, a readable raw baseline window when available, or the completed
statistics query window. This order is reserved before reading, persisted by the
existing outbox, and acknowledged independently for raw and daily representations;
wall-clock timestamps and opaque HealthKit anchors are not revision numbers.
These observations describe scope and ordering, not HealthKit authorization.

The receiver retains raw interval preimages in existing sync cursors and marks
only overlapping projections from the same source/type stale after a mutation.
An unknown statistics bucket marks its queried projection unknown. Values, record
counts, and provenance remain available in `sample_statistics` and
`last_known_daily_activity_totals`; `daily_projection_status` explains freshness.
Stale, unknown, and legacy projections are excluded from current
`daily_activity_totals` and `sample_totals`. A later authoritative finite positive
or zero from a completed statistics requery restores a fresh total, even when
raw results remain unreadable. Raw and daily observations are acknowledged
independently; an unknown raw read does not advance the raw anchor. Older/equal
ordered observations and unordered legacy daily replays cannot overwrite a newer
projection. A replacement outbox namespace is established by a scoped read or
mutation and retires its predecessor; this transition does not invalidate dates.
An existing acknowledged legacy HealthKit anchor continues delivering deletions.

A deletion without any raw preimage has unknown day scope: no date, zero, or
global invalidation is inferred. Legacy projections remain `legacy_unknown`,
and responses explain unresolved correction scope. An unresolved deletion does
not change any projection row or infer an affected date. Queries conservatively
mark older observations of that source/type unknown until an authoritative
statistics requery replaces them. Other sources and types remain independent.
There is no all-history requery
or automatic deletion of derived records. Completed intervals follow the recorded
local calendar/time zone, including 23-hour and 25-hour days.

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
