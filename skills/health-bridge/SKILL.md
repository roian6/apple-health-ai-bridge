---
name: health-bridge
description: Read the user's synced Apple Health data.
license: Apache-2.0
---

# Health Bridge

Use the installed `health-bridge` CLI to answer questions about synced Apple Health data. Queries are read-only. Run commands on the computer that stores the receiver database; setup does not grant your AI command access. An existing user-approved SSH connection can be used when the AI runs elsewhere. A one-shot npm runner does not install a command on PATH: preserve that exact approved runner prefix for the commands below. Do not bootstrap another receiver or change package versions to perform a read.

## Read data

1. Run `health-bridge status --json` and `health-bridge query synced-metrics`. Check recent delivery and which metrics actually have stored data before choosing a query. Setup remembers the database; do not repeatedly ask the user for its path.
2. Choose the smallest requested time range and query below. Date ranges use observation dates, with an exclusive end date. Timeseries bounds must be timezone-aware timestamps; translate the user's local range before querying.
3. Answer using the returned units, observation times and source provenance. Report missing or stale coverage instead of treating it as zero activity or current data.

Use your terminal tool for these commands, replacing the range placeholders:

```sh
health-bridge query daily-summary --start-date START_DATE --end-date END_DATE
health-bridge query sleep-summary --start-date START_DATE --end-date END_DATE
health-bridge query workouts --start-date START_DATE --end-date END_DATE
health-bridge query timeseries --types TYPE_CODES --start-time START_TIMESTAMP --end-time END_TIMESTAMP
health-bridge query explain-sources
```

`TYPE_CODES` is a comma-separated selection from `synced-metrics`. `health-bridge query supported-timeseries-types` describes supported types and units; it is not evidence that the user has synced those types.

## Missing data or configuration

- If setup is missing, ask the user to complete receiver setup. An explicitly selected existing database can be read with `--db PATH`; do not create a new database or receiver to make a query succeed.
- Human-terminal setup resumes existing connections and finishes only after authenticated nonempty delivery is saved and a read-only query returns nonempty records. `health-bridge query synced-metrics` shows the saved kinds of data and their dates. The AI still needs command access to that computer; setup does not automatically register this Skill or an AI app. CLI/JSON and optional local MCP provide read access. Automation uses `--no-input` or `--json`; these modes never prompt, wait, open a browser or configure a client. Do not capture a private invitation on the agent's behalf.
- For authorized setup on a Mac, the iCloud menu discovers a matching helper and its Documents folder, then prepares the initial phone connection separately. Tailscale is the connection app on both devices: use the same account and enable it on the iPhone. The signed 1.1.3 helper files are not publicly available yet. Use another offered connection or pause if matching local files are unavailable; never substitute an older helper or claim synthetic tests prove iCloud delivery.
- Empty results mean no matching synced records. They do not reveal which HealthKit permissions the user granted or whether data exists on the phone.
- Setup's confirmed-upload state requires a successful nonempty authenticated upload and observations still stored for that installation. Older or imported records remain queryable while setup waits for that confirmation. The connection page expires at the original invitation deadline; its expiry does not require re-pairing to read existing data.
- An ingestion timestamp is not the observation timestamp. State the actual covered period when discussing freshness.
- Do not change pairing, automatic-sync settings, or delete/reset data as part of a read request.
- Keep setup links, credentials, database paths and raw data out of public logs or unrelated artifacts. Return only data needed to answer the user's question.

## Verification

A successful read returns the requested nonempty observations, or an explicit, accurately scoped no-data result. A healthy receiver, accepted empty batch, or supported-type listing alone does not prove the requested data is available.
