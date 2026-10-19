# MCP reference

Start the local, read-only stdio server with `health-bridge mcp start --db PATH`.
It reads an existing committed receiver database. There are nine tools; no tool
executes SQL supplied by a client or writes health records. See the
[CLI reference](cli.md) for synthetic database setup and the local smoke command.

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
equal bounds are valid empty ranges. There is no timezone argument. Workout and
sleep date bounds mean midnight UTC and select by session **start**, not overlap
or wake date. Selected sessions keep their full duration/stages past the end bound.

The six query results (`list_synced_metrics`, `get_timeseries`, `get_workouts`,
`get_sleep_summary`, `get_daily_summary`, `explain_sources`) share:

| Field | JSON type and meaning |
| --- | --- |
| `period` | Object with `start` and `end` strings. Echoes requested timestamps for timeseries or dates for workout/sleep/daily queries; latest successful sync window, else stored min/max times, for synced metrics/sources. Empty store bounds are `""`. |
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
`sensitivity`, and integer `record_count`. Entries may have zero records;
an initialized empty store returns an empty array and an unknown-availability note.
Sources reflect the local store. Discover sessions as `workout` and
`sleep_analysis`, then use their dedicated tools.

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
Points use canonical type codes, ordered by start time then type. Selection uses
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
