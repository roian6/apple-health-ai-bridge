# CLI reference

`health-bridge` exposes local database queries, stdio MCP, receiver management,
mailbox operations, and developer helpers. In a source checkout, prefix commands
with `uv run`. `--version` prints the installed version. `--help` on any command
or group lists its current options without performing the operation.

Options below are required unless a default or optional status is stated.
Paths are local filesystem paths; use an owner-only directory for databases and
secret outputs. Query and status commands read committed data. Setup, ingest,
receiver administration, and mailbox commands can create or change local state.
See [setup](../setup.md) for pairing and network configuration.

## Synthetic quickstart

From the repository root, set `QA_DB` to a new database filename inside a private
temporary directory (for example, `QA_DIR=$(mktemp -d)` followed by
`QA_DB="$QA_DIR/reference.sqlite"`). Then run:

```bash
uv run health-bridge init --db "$QA_DB"
uv run health-bridge ingest-fixture --db "$QA_DB" --input fixtures/health_bridge_batch_v1.synthetic.json
uv run health-bridge status --db "$QA_DB" --json
uv run health-bridge query synced-metrics --db "$QA_DB"
uv run health-bridge query timeseries --db "$QA_DB" --types steps --start-time 2026-06-01T00:00:00Z --end-time 2026-06-08T00:00:00Z
uv run health-bridge query workouts --db "$QA_DB" --start-date 2026-06-01 --end-date 2026-06-08
uv run health-bridge query sleep-summary --db "$QA_DB" --start-date 2026-06-01 --end-date 2026-06-08
uv run health-bridge query daily-summary --db "$QA_DB" --start-date 2026-06-01 --end-date 2026-06-08
uv run health-bridge query explain-sources --db "$QA_DB"
uv run health-bridge query supported-timeseries-types --category body
uv run health-bridge status --db "$QA_DB" --markdown
uv run health-bridge mcp smoke --db "$QA_DB"
```

The fixture produces three samples, one workout, and one sleep session. The steps
query returns one point with value `4321.0` and unit `count`; workouts returns one
1920-second walking session. Daily summary returns seven days. These are synthetic
examples. Remove your temporary directory when finished.

## Database and setup

| Command | Inputs | Output and behavior |
| --- | --- | --- |
| `health-bridge init` | `--db PATH` | Initializes/migrates the database; prints `initialized: PATH`. Unsafe group/other-writable parent directories are rejected. |
| `health-bridge ingest-fixture` | `--db PATH`, `--input PATH` to batch-v1 synthetic JSON | Ingests a fixture; prints `ingested:` followed by integer `sources`, `health_types`, `samples`, `workouts`, `sleep_sessions`, `deleted_records`, `sync_cursors` counts. Invalid fixture/schema or storage failures exit 1. |
| `health-bridge status` | `--db PATH`; optional `--json`, `--markdown`, `--output PATH` | Default: table counts and `last_sync_status`, plus `last_sync_error` when present. JSON is the [MCP status model](mcp.md#get_bridge_status); Markdown is its context rendering. JSON/Markdown are mutually exclusive. `--output` requires one and writes it to a file, printing `wrote: PATH`. |
| `health-bridge setup` | Options below | Initializes local onboarding, creates a private pairing page, verifies local MCP, and emits a human-readable summary or `--json` manifest. Does not start the receiver. |

Setup options:

| Option | Type/default and purpose |
| --- | --- |
| `--receiver-url` | Required string: exact phone-reachable `/v1/batches` URL on your configured private route. Documentation hostnames are rejected. |
| `--db` | Path, default `~/.local/share/health-bridge/health.sqlite`. |
| `--setup-page` | Path, default `~/.local/share/health-bridge/pairing.html`; contains a temporary pairing secret. |
| `--label` | String, default `iPhone`. |
| `--transport` | `direct` (default) or explicit `icloud-mailbox`. |
| `--mailbox-root` | Optional existing macOS iCloud Documents `HealthBridgeMailbox/v1` path, required for mailbox mode. |
| `--icloud-container-identifier` | Optional string identifying the expected mailbox container, required for mailbox mode. |
| `--receiver-host`, `--receiver-port` | Bind host string `127.0.0.1`, integer port `8765` (1-65535). |
| `--allow-nonlocal-receiver-address` | Flag, default false; permits an intentional numeric HTTP proxy address not assigned to this host. |
| `--configure-client` | Optional repeatable client name (`hermes` or `openclaw`); explicitly configures and verifies selected clients. Omission leaves client settings alone. |
| `--json` | Flag, default false; emits the secret-redacted setup manifest. |

The setup JSON has `schema_id: "health_bridge.onboarding"`, `schema_version: 2`;
string paths/URLs `db`, `receiver_url`, `receiver_health_url`, `setup_page`;
`pairing_schema_id`, `invitation_expires_at`, `selected_transport` strings;
`receiver_start_command`, `local_mcp_self_test_command`, `next_steps` arrays of
strings; `local_mcp_status`, `client_configuration_status`, `warning` strings;
`detected_mcp_clients`, `configured_mcp_clients` string arrays. `access_descriptors`
contains objects with `id`, `protocol`, `transport`, `command` strings, `args`
string array, nullable `cwd`, and `env_refs` string map. `registrar_plans` contains
`name` string, `detected` boolean, `add_command` and `verify_command` string arrays.
Invalid route/transport/client configuration exits 1.

## Queries

`health-bridge query` prints one JSON object per invocation. Its output models
are the same as the matching [MCP tools](mcp.md#tools), including provenance,
missing-data notes, and truncation. All queries except the static supported-type
catalog require `--db PATH`.

| Command | Additional inputs | Output |
| --- | --- | --- |
| `health-bridge query synced-metrics` | None | `list_synced_metrics`: local catalog and counts. |
| `health-bridge query supported-timeseries-types` | Optional `--category STRING`, exact case-sensitive filter; no DB required | `list_supported_timeseries_types`: support/aggregation catalog. |
| `health-bridge query timeseries` | `--types STRING` (comma-separated codes), `--start-time STRING`, `--end-time STRING` | `get_timeseries`: at most 500 stored points. Spaces around type codes and empty comma entries are removed. |
| `health-bridge query workouts` | `--start-date STRING`, `--end-date STRING` | `get_workouts`: at most 500 sessions. |
| `health-bridge query sleep-summary` | `--start-date STRING`, `--end-date STRING` | `get_sleep_summary`: session count and stage seconds. |
| `health-bridge query daily-summary` | `--start-date STRING`, `--end-date STRING` | `get_daily_summary`: per-day counts, statistics, and qualified totals. |
| `health-bridge query explain-sources` | None | `explain_sources`: source and cursor metadata without cursor values. |

Use UTC `YYYY-MM-DDTHH:MM:SSZ` timestamps and `YYYY-MM-DD` dates, with ordered
inclusive-start/exclusive-end bounds. The CLI passes strings directly to query
functions; it does **not** apply MCP's strict date argument validation. Do not
depend on CLI rejection of malformed or reversed ranges. Date bounds select
workouts/sleep by UTC start date. Daily samples use `calendar_day` metadata when
present, otherwise UTC start date; see the MCP reference for timezone/completeness
and aggregation semantics. Empty matches succeed with empty data and notes;
daily queries still return entries for empty days. Missing data is unknown.

## MCP

`health-bridge mcp` provides local stdio integration without a hosted client.

| Command | Inputs | Output |
| --- | --- | --- |
| `health-bridge mcp start` | `--db PATH` | Reads newline-delimited JSON-RPC on stdin and writes responses on stdout until EOF. See [transport and errors](mcp.md#transport-and-shared-contracts). |
| `health-bridge mcp smoke` | `--db PATH` | JSON: `listed_tools` string array, `called_tool` (`list_synced_metrics`), `call_result` with `metrics` (`type_code` string/`record_count` integer) and `missing_data_notes`; `context_tool` and `context_result` with string `title`, booleans `has_store_counts`, `has_redaction_notes`, and array `forbidden_hits`. |

## Receiver

`health-bridge receiver` manages uploads and device access. Commands require
`--db PATH` except `smoke`; `start` can instead load `--service-config PATH`.

| Command | Inputs | Output and effects |
| --- | --- | --- |
| `health-bridge receiver start` | Optional `--host` (`127.0.0.1`), `--port` (8765); `--db` or `--service-config`; optional `--mailbox-root`, `--icloud-container-identifier` | Runs the HTTP receiver until stopped. Service config supplies validated mailbox settings; conflicting CLI overrides are rejected. No single JSON result. |
| `health-bridge receiver create-token` | `--label STRING`; exactly one of `--print-secret` or `--output-secret PATH` | Creates a token. Secret JSON has `label`, `token`, `token_prefix`, `warning` strings. File mode prints `label`, `secret_file`, `token_prefix`, `warning` instead. Refuses implicit secret stdout; output failure revokes the new token. |
| `health-bridge receiver create-pairing` | `--label STRING`, `--receiver-url STRING`; options below | Creates a single-use invitation by default and outputs JSON or a private setup page. |
| `health-bridge receiver list-devices` | Optional `--include-revoked` flag (false) | JSON `devices` array with string `device_ref`, `label`, `platform`, `last_paired_at`, and nullable string `revoked_at`. Empty list is valid. |
| `health-bridge receiver revoke-device` | `--device-ref STRING` from list-devices | JSON `revoked_device_ref` string and `revoked_token_count` integer. Invalid/unavailable references exit 1. |
| `health-bridge receiver revoke-token` | `--token-prefix STRING` | Revokes matching token; JSON `revoked_token_prefix` string. |
| `health-bridge receiver purge` | Optional `--confirm` flag (false) | Default dry run. Confirmation deletes only the validated database/sidecar scope. JSON has string `status`, `database`, `warning`, string array `paths`, boolean `confirm_required`; recovery failures add string `quarantine_path` and string arrays `quarantined_paths`, `truncated_paths`. Does not erase the phone's HealthKit store. |
| `health-bridge receiver smoke` | `--input PATH`, `--token STRING`; optional `--url` (`http://127.0.0.1:8765/v1/batches`) | POSTs the input batch to that endpoint. Prints response JSON plus integer `http_status`. This mutates the target receiver; use synthetic data. HTTP/network failures exit 1. |

Pairing options: `--transport` (`direct` by default, or `icloud-mailbox`),
optional `--mailbox-root` and `--icloud-container-identifier` (required in mailbox
mode), `--format` (`setup-page` default, `json`, or `deeplink`), `--setup-page PATH`
(required for setup-page), `--print-secret` (required for json/deeplink stdout),
and `--legacy-v1` (default false, issues a long-lived bearer bundle; no mailbox).
Normal setup-page JSON returns string `label`, `setup_page`, `pairing_schema_id`,
`invitation_expires_at`, `warning`. Deeplink mode replaces the page path with
secret `pairing_url`; JSON mode exposes the complete pairing bundle plus that
URL. Legacy summaries use `token_prefix` instead of invitation fields. Keep all
secret output private; neither the guide nor its examples need a live credential.

Purge statuses include `dry-run`, `purged`, `already-absent`, and
`recovery-required`. A busy/unsafe store or failed recovery exits 1. Follow the
reported recovery instructions before restarting the receiver.

## Mailbox

`health-bridge mailbox` manages explicit Encrypted iCloud Mailbox integration.
The production workflow requires macOS and the verified signed ACK helper.

| Command | Inputs | Output and effects |
| --- | --- | --- |
| `health-bridge mailbox import` | `--db PATH`, `--mailbox PATH` (per-device directory), `--once`; optional `--json` | One bounded import/ACK pass. Integer counts `imported`, `idempotent`, `quarantined`, `retryable`, `conflict`, `skipped`, as JSON or `key=value` text. Missing `--once` or unavailable/busy inputs exit 2; inspect counts even on success. |
| `health-bridge mailbox keys` | Group | Receiver mailbox identity operations. |
| `health-bridge mailbox keys doctor` | Optional `--state-dir PATH` (isolated temporary synthetic QA only), `--json` | Loads or creates local keys. JSON/text reports `status`, `state`, `signing_key_id`, `agreement_key_id`; JSON error has `status: "error"` and `error_code` and exits 2. Key material is omitted. |
| `health-bridge mailbox helper` | Group | Signed helper lifecycle. |
| `health-bridge mailbox service` | Group | Explicit per-user LaunchAgent lifecycle. |

Every helper/service command supports optional `--json` (default false), returning
`{"code":"..."}` on success or handled failure. Otherwise it prints `code: ...`
on success and a diagnostic on failure. Codes describe readiness/ownership; they
are not health data. Failure/not-ready status exits 1.

| Command | Other inputs | Effect |
| --- | --- | --- |
| `health-bridge mailbox helper verify` | `--archive PATH`, `--manifest PATH` | Structurally verifies downloaded helper assets against the installed component version; success code `valid`. |
| `health-bridge mailbox helper install` | `--archive PATH`, `--manifest PATH` | Verifies and installs an exact signed helper without overwriting foreign content. |
| `health-bridge mailbox helper status` | None | Readiness code, successful only for `ready`. |
| `health-bridge mailbox helper uninstall` | None | Retires only an owned helper generation. |
| `health-bridge mailbox service validate` | `--executable PATH`, `--db PATH`, `--mailbox-root PATH`, `--icloud-container-identifier STRING` | Validates inputs without installing. Executable must be absolute; DB/root must already exist. |
| `health-bridge mailbox service install` | Same four options as validate | Installs and starts the per-user service; requires ready helper. |
| `health-bridge mailbox service upgrade` | Same four options as validate | Replaces an owned service generation with validated settings. |
| `health-bridge mailbox service status` | None | Inspects service/helper/health; successful only for `running_healthy`. |
| `health-bridge mailbox service restart` | None | Restarts owned service with bounded recovery. |
| `health-bridge mailbox service uninstall` | None | Stops service and removes only owned service files; already uninstalled is successful. |

Common service states include `not_installed`, `manifest_drift`, `helper_not_ready`,
and `helper_drift`. Unsupported hosts and invalid ownership/permissions fail;
do not treat an emitted JSON object as proof of success without the exit status.

## Developer helpers

`health-bridge dev` contains explicit setup and diagnostic helpers. These are not
needed for ordinary read-only queries. All commands below require `--db PATH`.

| Command | Additional options | Output and behavior |
| --- | --- | --- |
| `health-bridge dev receiver-systemd` | `--host` (`127.0.0.1`), `--port` (8765), `--working-directory PATH` (cwd), `--service-name` (`health-bridge-receiver`) | JSON strings `service_name`, `unit_path`, `unit_text`, `warning`; string arrays `write_unit_command`, `enable_now_command`, `restart_command`, `stop_command`, `health_check_command`. Generates instructions; does not install/start systemd. |
| `health-bridge dev device-session` | `--label` (`ios-companion`), `--receiver-url` (`http://127.0.0.1:8765/v1/batches`), `--setup-page` (`.tmp/health-bridge-device-session.html`), `--receiver-host` (`127.0.0.1`), `--receiver-port` (8765), `--watch-seconds` (7200) | Creates local session/pairing page. JSON has string paths/URLs/label, `pairing_schema_id`, `invitation_expires_at`, integer `baseline_sync_run_id`, command arrays `receiver_start_command`, `receiver_systemd_command`, `watch_new_sync_runs_command`, `validate_anchored_steps_command`, string array `next_steps`, string `warning`. |
| `health-bridge dev validate-anchored-steps` | `--source-key` (`apple_health.phone`) | JSON `schema_id`, `source_key`, `type_code`, `verdict` strings; integer `raw_sample_count`, `legacy_daily_sample_count`, `sample_tombstone_count`, `legacy_daily_tombstone_count`; booleans `has_anchor_cursor`, `has_bootstrap_cursor`; nullable timestamps `latest_raw_sample_end`, `latest_tombstone_deleted_at`; `missing_data_notes` string array. No cursor values. |
| `health-bridge dev watch-sync-runs` | Required `--after-sync-run-id INTEGER`; `--timeout-seconds` (7200), `--poll-seconds` (2.0) | JSON lines: `event: "new_sync_run"` with sync ID/status/timestamps/counts/error/window metadata; final `event: "watch_timeout"` with integer `after_sync_run_id`, `elapsed_seconds`, integer array `seen_sync_run_ids`. |

Older hidden `dev-*` aliases remain compatibility surfaces; use the visible
`dev` commands for new scripts.

## Exit and error handling

Exit 0 means the command completed; Typer usage errors (missing options, invalid
option types) normally exit 2. Handled database access failures exit 1 with
`Health Bridge database is unavailable.` Never assume an empty store and an
unavailable database are interchangeable. Other handled failures are noted above;
unexpected exceptions can exit nonzero with diagnostic output. Default human
output is not a stable parsing format: prefer JSON where offered and inspect
the process exit status. The long-running MCP server reports per-request errors
inside JSON-RPC rather than exiting for each invalid call.
