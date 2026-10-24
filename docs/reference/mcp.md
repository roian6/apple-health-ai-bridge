# MCP reference

Start the local, read-only stdio server with `health-bridge mcp start --db PATH`.
It reads an existing committed receiver database. There are eleven tools; no tool
executes SQL supplied by a client or writes health records. See the
[CLI reference](cli.md) for synthetic database setup and the local smoke command.

For daily sleep briefings, use `get_sleep_report` to retain all observed periods
ending on a local wake-date. `get_latest_sleep_period` answers which single
observed period ended most recently; that can be a nap. `get_sleep_summary` retains
its original UTC session-start selection and summed-stage contract.

## Transport and shared contracts

Send one JSON-RPC 2.0 object per line on stdin; read one response per line on
stdout. `initialize` returns protocol version `2024-11-05`, `serverInfo` with
`name: health-bridge` and the installed `version`, and `capabilities.tools: {}`.
`notifications/initialized` produces no response. `ping` returns an empty result.
`tools/list` returns `result.tools[]` entries with `name`, `description`,
`inputSchema`, and read-only, non-destructive, idempotent, closed-world annotations.

Each successful `tools/call` returns `result.content` containing one object with
`type: "text"` and `text: string`. Parse that string as JSON for every tool except
`get_bridge_context_markdown`, whose string is Markdown. There is no separate
structured-result object or aggregate wrapper. Request IDs are echoed.

All argument objects reject extra keys. No-argument tools accept `{}` (omitting
`arguments` also supplies `{}`). Required strings and arrays are not coerced.
The optional `category` defaults to no filter when omitted; its published schema
accepts a string, although the runtime model also accepts null. Prefer omission.

Time arguments are UTC strings exactly `YYYY-MM-DDTHH:MM:SSZ`: offsets, fractions,
invalid calendar dates, and reversed intervals are rejected. Date arguments are
valid `YYYY-MM-DD` strings. All ranges are **inclusive start, exclusive end**;
equal bounds are valid empty ranges. The separate `get_latest_sleep_period` and
`get_sleep_report` use a timezone and inclusive observed-end reference cutoff.
The report alone defaults an omitted reference to one captured UTC instant. Workout and
sleep date bounds mean midnight UTC and select by session **start**, not overlap
or wake date. Selected sessions keep their full duration/stages past the end bound.

The six query results (`list_synced_metrics`, `get_timeseries`, `get_workouts`,
`get_sleep_summary`, `get_daily_summary`, `explain_sources`) share:

| Field | JSON type and meaning |
| --- | --- |
| `period` | Object with `start` and `end` strings. Echoes requested timestamps for timeseries or dates for workout/sleep/daily queries. For synced metrics/sources, preserves the most recently ingested successful batch window with both bounds present, else stored min/max times, else `""` bounds. Deprecated for synced metrics; use its explicit coverage fields below. Source-query semantics are unchanged. |
| `sources_used` | Array of Source objects: `source_key`, `name`, `kind` strings identifying provenance. |
| `missing_data_notes` | Array of strings explaining local coverage, empty data, or limitations. Missing records mean unknown availability, not zero activity. |
| `truncated` | Boolean. Timeseries/workouts have a fixed 500-record cap and set this when more matched. Other query results currently return false. No pagination input exists. |

Arrays may be empty; nullable fields below use JSON null. Numbers are observations
in their returned units, not medical interpretations. Examples below use only
`fixtures/health_bridge_batch_v1.synthetic.json` loaded as shown in the CLI guide.

## Tools

### `get_bridge_status`

Input: no arguments. Operational counts and freshness, without sample values.

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_bridge_status","arguments":{}}}
```

| Field | JSON type and meaning |
| --- | --- |
| `schema_id` | String, `health_bridge.status.v1`. |
| `counts` | Object of integer counts: `sources`, `health_types`, `samples`, `workouts`, `sleep_sessions`, `deleted_records`, `sync_cursors`, `sync_runs`. |
| `latest_sync` | Null if no sync; otherwise object with integer `sync_run_id`, `sample_count`, `workout_count`, `sleep_session_count`, `deleted_record_count`, `sync_cursor_count`; string `started_at`, `finished_at`, `status`; nullable string `error_summary`, `sync_window_start`, `sync_window_end`. |
| `receiver` | Object: boolean `has_active_token`; integer `active_token_count`, `revoked_token_count`, `total_token_count`; nullable timestamp `latest_token_last_used_at`. |
| `metrics` | Object keyed by type code. Each value has string `display_name`, `category`, `default_unit`, `sensitivity`; integer `record_count`, `cursor_count`; nullable timestamp strings `first_record_start`, `latest_record_end`, `latest_cursor_updated_at`. |
| `sync_cursors` | Array of objects with string `source_key`, `cursor_kind`, `updated_at`; no cursor values. |
| `missing_data_notes` | Array of redaction and sync-coverage notes. |
| `truncated` | Boolean, currently false. |

An initialized empty database has zero counts, null `latest_sync`, empty `metrics`
and cursor arrays, and notes about absent sync/token configuration. The synthetic
fixture has three samples, one workout, and one sleep session.

For each metric, `cursor_count` counts distinct ingestion sources with a recognized
sample-sync checkpoint. A source contributes once even when it retains legacy
foreground, shared anchored, and independent automatic anchored cursors.
`latest_cursor_updated_at` is the newest receiver storage timestamp across those
checkpoints. Dedicated steps, sleep and workout anchors and generic quantity
anchors contribute, including the automatic quantity fallback. Legacy foreground
checkpoints and the `body_mass`/`weight` and `active_energy`/`energy` aliases remain
supported. Stored cursor ownership and values are unchanged by this reporting.

Unknown cursors, bootstrap/reset markers and daily aggregate checkpoints remain
visible in `sync_cursors` without contributing to metric checkpoint counts or
timestamps. In particular, the shared activity aggregate checkpoint does not
identify which metric subset was processed. Per-type daily projection observation
markers are consumed during ingestion and are not stored in `sync_cursors`.

Cursor recency is not sample recency, daily projection freshness, or proof of
complete history. Automatic fallback reads can cover only a recent window.
Quantity `record_count` and record time bounds include both raw samples and daily
projections; they do not describe raw-only coverage. A recent raw checkpoint can
coexist with a `last_known` or `unknown` daily projection. Use the daily query's
projection state and completed-day totals to assess that projection separately.

### `get_bridge_context_markdown`

Input: no arguments. Returns Markdown text beginning `# Health Bridge Context`,
with Store Counts, Latest Sync, Receiver, Synced Metrics, Cursor Freshness, and
Redaction Notes sections. It renders the same status snapshot above; an empty
store shows zero counts and `none` for absent sync/metrics/cursors. Use
`get_bridge_status` for field-level parsing.

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_bridge_context_markdown","arguments":{}}}
```

### `list_supported_timeseries_types`

Input: optional `category` string, an exact case-sensitive filter such as `heart`,
`activity`, or `body`. Omit it to discover categories from `types[].category`.
This is a static catalog and does not require a readable database. An unknown
category gives `types: []` and zero returned counts, retaining total catalog counts.

```json
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_supported_timeseries_types","arguments":{"category":"body"}}}
```

Result: `schema_id` is `health_bridge.supported_timeseries_catalog.v2`;
`total_type_count`, `ios_live_readable_type_count`, and
`ios_background_eligible_type_count` are integer counts for the full catalog.
`returned_type_count`, `returned_ios_live_readable_type_count`, and
`returned_ios_background_eligible_type_count` are integers after filtering.
`missing_data_notes` is an array of caveats. `types` is an array of objects with:

- `type_code`, `unit`, `category`, `description`: strings;
- `aggregation`: `sum`, `min_max_average`, or `latest`;
- `ios_support_status`: `live_readable`, `runtime_gated`, `derived_required`,
  `provider_specific`, `workout_context`, or `metadata_only`;
- `ios_support_note`: string; `ios_live_readable` and `ios_background_eligible`:
  booleans describing support, not actual permission or local availability.

### `list_synced_metrics`

Input: no arguments. Result: shared query fields plus `metrics`, an array of
objects with string `type_code`, `display_name`, `category`, `default_unit`,
`sensitivity`, integer `record_count`, and nullable timestamp strings
`first_record_start` and `latest_record_end`. Counts include all records currently
retained in the local store. No date filter is accepted. Sample bounds are grouped
by metric type across sources; workout and sleep bounds use their session records.
Entries may have zero records, with null per-metric bounds.

| Field | JSON type and meaning |
| --- | --- |
| `stored_coverage` | Null if no observations remain; otherwise an object with `start` equal to the earliest retained record start and `end` equal to the latest retained record end across samples, workouts, and sleep sessions. |
| `latest_sync_window` | Null if no successful batch has complete window metadata; otherwise an object with `start` and `end` from the most recently ingested such batch, ordered by sync-run ID. A newer failed or windowless run does not replace it. |

`period` is deprecated for this tool. Its legacy precedence and empty-string
bounds remain unchanged for compatibility. Clients should use the two explicit
fields instead. They can differ after a narrow, empty, or deletion-only upload.
Deleting observations can shrink stored extents or make them null while the
successful batch window remains populated. Definitions, sources, cursors, and
tombstone timestamps do not contribute to stored extents. An initialized empty
store returns an empty metric array, null explicit fields, and an
unknown-availability note. Registered definitions can remain after every
observation is deleted, with zero counts, null extents, and the empty-data note.

Stored bounds describe record extents. They establish neither gap-free history
nor complete backfill, permissions, freshness, or current daily projections.
Equal bounds can describe a retained instantaneous observation. A successful
batch window also does not establish synchronization completeness for every
metric. Missing observations remain unknown.

Sources reflect the local store. Discover sessions as `workout` and
`sleep_analysis`, then use their dedicated tools. Existing clients that reject
unknown JSON properties must allow the additive global and per-metric fields.

```json
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_synced_metrics","arguments":{}}}
```

### `get_timeseries`

Required input: `type_codes` (array of strings), `start_time`, `end_time` (UTC
timestamp strings). `body_mass` and `active_energy` are accepted aliases for
`weight` and `energy`. Unknown codes, an empty list, or an empty interval return
no points. An empty type list can return without opening the database.

```json
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_timeseries","arguments":{"type_codes":["steps"],"start_time":"2026-06-01T00:00:00Z","end_time":"2026-06-08T00:00:00Z"}}}
```

Result: shared query fields; `requested_types` is the original array of strings;
`points` is an array with string `type_code`, `start_time`, `end_time`, `unit`,
numeric `value`, a `source` object (shared Source), and `metadata` (JSON object).
Points use canonical type codes, ordered by start time, then type, then stored
sample ID to make timestamp ties deterministic, including at the 500-point cap.
Sample IDs are local identities retained during updates. Selection uses
sample start time, not interval overlap; end times are not clipped. The fixture
returns one steps point with `value: 4321.0`, `unit: "count"`, and
`truncated: false`. This is stored sample data, not an automatically deduplicated
activity total.

### `get_workouts`

Required input: `start_date`, `end_date` (date strings).

```json
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_workouts","arguments":{"start_date":"2026-06-01","end_date":"2026-06-08"}}}
```

Result: shared query fields plus `workouts`, an array of objects with string
`workout_type`, `start_time`, `end_time`; integer `duration_seconds`; nullable
numeric `energy_kcal`, `distance_meters`; and `source` (Source). Results are in
start-time order, capped at 500. No matches gives `workouts: []` and a note.
The fixture returns one walking workout lasting 1920 seconds.

### `get_sleep_summary`

Required input: `start_date`, `end_date` (date strings).

```json
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_sleep_summary","arguments":{"start_date":"2026-06-01","end_date":"2026-06-08"}}}
```

Result: shared query fields, integer `session_count`, and `stage_seconds` (object
mapping stored sleep-stage strings to summed integer seconds). No matches gives
zero sessions and `{}`. All stage intervals of selected sessions contribute,
without clipping or overlap deduplication; overlapping sources can double-count.
There is no 500-session cap here. The fixture returns one session.

### `get_latest_sleep_period`

Required input: `timezone` (an IANA key available on the receiver, such as
`Asia/Kolkata`) and `reference_time` (canonical UTC timestamp). There is no
implicit clock or date-only shorthand. CLI and MCP apply the same validation.

```json
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"get_latest_sleep_period","arguments":{"timezone":"Asia/Kolkata","reference_time":"2026-06-08T04:00:00Z"}}}
```

Selection is based on observed periods, with no night-only or nap classifier:

1. Convert the reference instant to the requested timezone. Search from midnight
   six local calendar dates earlier to the reference instant, covering seven local
   dates. This is not a fixed 168-hour UTC range. An ambiguous midnight uses its
   first occurrence (`fold=0`); a nonexistent midnight is normalized through UTC.
   References whose local conversion/window cannot be represented are rejected.
2. Consider positive-duration sessions with `start < reference_time` and
   `end > search_window.start`. Include future-end observations during grouping.
   Join overlapping or touching session envelopes across all sources, transitively;
   any positive gap separates periods. Choose the group with the latest
   `end <= reference_time`. A group with any future end is ineligible, even if some
   member sessions already ended. Future-start sessions are ignored.
3. Keep full selected candidate envelopes, including starts before the search lower bound.
   Do not clip duration to local midnight or the search window. There is no fallback
   to older dates outside this window. Sessions ending at/before the search lower
   bound are excluded, even if they overlap a selected envelope's earlier tail.
   These rules may select a daytime nap or an
   earlier completed group while another group is ongoing. Stored end times do not
   establish physiological completion, a complete night, or completed sync.

This result has its own window fields instead of the shared `period` field:

| Field | JSON type and meaning |
| --- | --- |
| `timezone`, `reference_time` | Echoed strings. |
| `search_window` | Object with UTC `start`, `end`, offset-bearing `local_start`, `local_end`, and `local_end_date` (`YYYY-MM-DD`). End equals the reference instant. |
| `selected_period` | Same timestamp fields, or null if no eligible group or selection was withheld. Local end date labels the observation; it does not classify a night. |
| `sessions` | Up to 500 objects with UTC `start`, `end`, and `source` (shared Source). Ordered by start, end, source key, then stored record identity for ties. No stored IDs are exposed. |
| `stage_intervals` | Up to 500 objects with zero-based `session_index` into `sessions`, stored `stage`, and UTC `start`, `end` clipped to that session. Nonpositive clipped intervals are omitted. |
| `asleep_intervals` | Sorted, disjoint UTC `start`/`end` intervals: the union of all clipped `core`, `deep`, and `rem` evidence across sessions and sources. Touching intervals are merged. |
| `asleep_seconds` | Integer elapsed seconds in `asleep_intervals`, or null when absent/withheld. Uses UTC instants across DST. |
| `awake_seconds`, `in_bed_seconds` | Separate per-category union seconds, or null when absent/withheld. |
| `stage_seconds` | Object mapping observed stage strings to per-stage union seconds. Different stages may overlap: summing these values does not yield asleep time. |
| `sources_used`, `missing_data_notes` | Provenance and limitations, as above. |
| `truncated` | True if either fixed cap is exceeded. No pagination or configurable limit. |

For example, synthetic asleep evidence `[00:00,02:00)` and `[01:00,03:00)`
produces one `[00:00,03:00)` union and 10800 seconds, even across different stages
or sources. Awake/in-bed claims may overlap asleep; they are not subtracted and no
source wins a conflict. Unknown legacy stages remain evidence but are excluded
from asleep; only the current `core`/`deep`/`rem` names count. The current ingestion
contract also recognizes `awake` and `in_bed`; this query adds no stage aliases.

These are receiver-input labels. The current phone maps HealthKit
`asleepUnspecified` to `core` before storage, so `core` is not an exact preserved
Apple stage. Raw HealthKit origin metadata is unavailable to these queries;
they cannot restore it or invent device/source priority.

Missing stages and uncovered time remain unknown. Empty evidence does not imply
zero sleep; observed sums do not imply complete period coverage. Invalid stored
timestamps produce the normal database error. Zero/reversed session envelopes
cannot form periods; nonpositive clipped stage spans contribute no duration.

At more than 500 candidate sessions, selection is withheld (`selected_period:
null`, empty evidence and null totals). At more than 500 stored stage intervals
for the selected group, session timestamps/provenance remain available but all
stage evidence, unions and totals are withheld. Exactly 500 is allowed. Caps
apply before clipping; partial totals are never returned. The timestamp detail
is local health context and should only be retained or shared intentionally.

### `get_daily_summary`

Required input: `start_date`, `end_date` (date strings).

```json
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_daily_summary","arguments":{"start_date":"2026-06-01","end_date":"2026-06-08"}}}
```

Result: shared query fields plus `days`, an array with one entry per requested
calendar date (seven in this example), even if no records exist. Equal bounds
give `days: []`. Each entry has:

| Field | JSON type and meaning |
| --- | --- |
| `date` | `YYYY-MM-DD` string. |
| `sample_counts` | Object mapping type code to integer observed count. |
| `sample_totals` | Object mapping sum-safe type code to numeric sum. |
| `sample_total_semantics` | Object mapping summed type code to `daily_aggregate`, `raw_sample_sum`, `unknown_sum`, or `mixed_sum_semantics`. |
| `daily_activity_totals` | Object mapping type code to numeric sum of completed calendar-day aggregates only. |
| `sample_statistics` | Object mapping type code to a Statistic below. |
| `workout_count`, `sleep_session_count` | Integer counts by UTC session start date. |

A Statistic has string `unit`, `aggregation`; integer `count`; nullable numeric
`total`, `average`, `minimum`, `maximum`, `latest`; nullable string `latest_time`.
Aggregation is selected from recognized sample metadata, then the type catalog,
falling back to `min_max_average`. `sum` fills only `total`; `min_max_average`
fills average/minimum/maximum; `latest` fills latest/value time. Mixed units in a
non-latest group produce `unit: "mixed"`, `aggregation: "mixed_units"`, and null
numeric statistics. Latest selects the latest sample and its unit.

Samples group by `metadata.calendar_day` when present, otherwise UTC start date.
That calendar day may include a sample whose timestamp starts outside the UTC
range. Completed activity totals require an exact day interval in
`time_zone_identifier` (including DST boundaries), paired with `calendar_day`;
legacy data without either uses UTC. Partial intervals, inconsistent metadata,
or explicit non-complete `aggregation_completeness` do not qualify. Raw sums and
unknown sums are not confirmed daily activity. Empty days have empty maps and
zero session counts, which do not establish zero activity. Sources are not
deduplicated into a single clinical or activity judgment.

### `get_sleep_report`

Recommended daily briefing query. Required `timezone` is an available IANA key.
Optional `local_date` is a strict `YYYY-MM-DD` wake-date; omission or null selects
the local date of `reference_time`. Optional `reference_time` is a canonical UTC
timestamp; omission captures current UTC once, at whole-second precision. Optional
`include_intervals` defaults to false. CLI and MCP use the same argument validation.
Unrepresentable local conversions/day bounds are rejected.

```json
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"get_sleep_report","arguments":{"timezone":"Asia/Kolkata","local_date":"2026-06-04","reference_time":"2026-06-08T04:00:00Z"}}}
```

Positive-duration stored session envelopes that overlap or touch belong to one
observed period, transitively across all sources. Any positive gap separates
periods; there is no bedtime, gap threshold, longest/main sleep or nap classifier.
A period qualifies only when its **complete observed end** is at/before the
reference and its end's local date equals the effective wake-date. A midnight end
belongs to the new local date. Return every qualifying period in chronological
order, retaining its full earlier start and stage intervals across midnight.
No eligible received period means an explicit empty result for that date, never
a silent substitution of an older date.

For synthetic sessions 23:00-03:00 and 03:10-07:00, fully covered by asleep stages,
the two recorded contributions total 7h50. The ten-minute gap is not filled.
A later twenty-minute nap adds a third period and brings recorded sleep to 8h10;
it never replaces either earlier period. These are observed records, not a claim
about physiological completion, sync freshness, permissions or biological sleep.

The reader seeds sessions touching the local day's UTC bounds, then expands both
ends until there are no additional overlapping/touching members. Earlier
predecessors and later/future observations are included before deciding membership.
A long session continuing beyond the reference cannot be chopped to manufacture
completed sleep. Day bounds are local midnight to the next local midnight,
normalized through UTC with fold=0 at ambiguous midnight. DST days need not be
24 hours; a skipped local date has no eligible periods.

| Field | JSON type and meaning |
| --- | --- |
| `timezone`, `reference_time` | Effective timezone and the actual captured/provided UTC reference. |
| `requested_local_date`, `local_date` | Requested date or null for default; effective wake-date string. |
| `day_bounds` | UTC `start`/`end`, offset-bearing `local_start`/`local_end`, and `local_end_date`. The end is the next day's boundary, not the reference cutoff. |
| `include_intervals` | Echoed boolean. |
| `status` | `recorded`, `no_eligible_periods`, or `withheld`. `recorded` does not mean complete sleep coverage. |
| `withheld_reason` | Null, `session_limit`, or `stage_limit`. |
| `periods` | Chronological period summaries, described below. |
| `recorded_asleep_seconds`, `recorded_awake_seconds`, `recorded_in_bed_seconds` | Sum of known contributions from disjoint selected periods, or null when absent/withheld. Unknown periods are not counted as zero. |
| `unknown_duration_period_count` | Count without usable asleep evidence, or null when withheld. |
| `incomplete_evidence_period_count` | Count flagged `evidence_incomplete`, or null when withheld. |
| `omitted_after_reference_count` | Candidate connected groups with end after the reference, including ongoing/future observations regardless of wake-date. Null if membership is withheld. |
| `other_wake_date_count` | Remaining candidate groups whose local end date differs from the effective date. Null if membership is withheld. |
| `sources_used`, `missing_data_notes` | Selected source provenance and recorded-data limitations. |
| `truncated` | True when either global read budget is exceeded. |

Each period has `period` (UTC/local bounds and local end date), `session_count`,
`sources_used`, `duration_status` (`recorded`, `unknown`, `withheld`),
`asleep_seconds`, `awake_seconds`, `in_bed_seconds`, `stage_seconds`,
`stage_coverage_seconds`, `uncovered_seconds`, `evidence_incomplete`, and `evidence`.
The calculation is shared with the latest-period query: clip to parent session
(and thus the accepted period), union `core`/`deep`/`rem` across sources for asleep,
and keep independent awake/in-bed and per-stage unions. Conflicting claims can
overlap; per-stage seconds must not be added together as asleep. Receiver `core`
includes phone-mapped unspecified sleep as described above.

`stage_coverage_seconds` is the union of recognized stage claims and
`uncovered_seconds` is period elapsed time minus that coverage. Incomplete evidence
is flagged if asleep is unknown, any time is uncovered, an unknown stage occurs,
or any member session lacks usable recognized stages. Even unflagged evidence
does not establish complete synchronization or biological sleep. Missing/awake-only/
in-bed-only/unknown-stage periods have unknown asleep duration, not zero.
An empty per-stage map means no usable stages; withheld per-stage data is null.

Default `evidence` is null. With `include_intervals=true`, it contains `sessions`
(UTC start/end and Source), `stage_intervals` (period-local zero-based
`session_index`, stored `stage`, clipped UTC start/end), and `asleep_intervals`
(disjoint UTC union). A computed empty array differs from absent/withheld evidence.
No raw record IDs or additional device metadata are exposed.

The entire report shares a 500-session budget and a 500-stage-row budget, with
only one additional row read to detect each overflow. Limits apply before clipping
and across all periods, not per period. Membership must be complete before any
selection is returned. A session overflow withholds periods and totals; a stage
overflow keeps selected timestamps/provenance but withholds **all** period
durations, evidence and day totals. Partial earlier sums are never presented as
complete. Exactly 500 is accepted. All reads use one read-only transaction.

### `explain_sources`

Input: no arguments. Result: shared query fields plus `sources` (array of
Source objects extended with nullable string `bundle_id`, `device_model`) and
`sync_cursors` (array with string `source_key`, `cursor_kind`, `updated_at`).
It reports provenance and cursor freshness, never cursor values. Empty stores
return empty arrays and missing-data notes.

```json
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"explain_sources","arguments":{}}}
```

## Errors

Failures return an `error` object with integer `code` and string `message` instead
of `result`. Check every response even when the server process exits successfully.

| Code | Meaning |
| --- | --- |
| `-32700` | Malformed JSON input line: `Parse error.` |
| `-32600` | Invalid request shape. |
| `-32601` | Unknown method: `Method not found.` |
| `-32602` | Unknown read-only tool or invalid arguments (missing/extra keys, wrong types, invalid/reversed dates). |
| `-32000` | Tool data read/validation failure: `Health Bridge database is unavailable.` This intentionally does not disclose database details. |
| `-32603` | Unexpected request failure at the stdio boundary. |

An initialized store with no matching records is a successful result, not a
database error. A missing, unsafe, or unreadable database fails tools that read
it. `tools/list` and the static supported-type catalog remain discoverable.
