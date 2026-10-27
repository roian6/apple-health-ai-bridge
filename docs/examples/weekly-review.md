# Reproduce the weekly review example

This two-week comparison uses [synthetic records](../../fixtures/readme-weekly-review.synthetic.json): fourteen sleep sessions and six walking workouts, dated June 1–14, 2026. All timestamps use UTC.

You can try it without an iPhone, a receiver network route, or personal health data. You need a Mac or Linux computer with the [development environment](../../.github/CONTRIBUTING.md#development-setup). The example proves the local query and MCP path; it does not demonstrate phone pairing or background sync.

## Load the sample history

From a source checkout with the [development environment](../../.github/CONTRIBUTING.md#development-setup) installed, create a fresh sample database in your home directory:

```bash
EXAMPLE_DIR="$(mktemp -d "$HOME/health-bridge-example.XXXXXX")"
export EXAMPLE_DB="$EXAMPLE_DIR/health.sqlite"
uv run health-bridge init --db "$EXAMPLE_DB"
uv run health-bridge ingest-fixture \
  --db "$EXAMPLE_DB" \
  --input fixtures/readme-weekly-review.synthetic.json
```

## Query both weeks

The end date is exclusive, so the first pair covers June 1–7 and the second covers June 8–14:

```bash
uv run health-bridge query sleep-summary \
  --db "$EXAMPLE_DB" --start-date 2026-06-01 --end-date 2026-06-08
uv run health-bridge query workouts \
  --db "$EXAMPLE_DB" --start-date 2026-06-01 --end-date 2026-06-08
uv run health-bridge query sleep-summary \
  --db "$EXAMPLE_DB" --start-date 2026-06-08 --end-date 2026-06-15
uv run health-bridge query workouts \
  --db "$EXAMPLE_DB" --start-date 2026-06-08 --end-date 2026-06-15
```

An MCP client reads the same observations through `get_sleep_summary` and `get_workouts`, using `start_date` and `end_date` with those same ranges. To explore the example in an assistant, [connect the stdio server](../setup.md#connect-an-mcp-client-intentionally) using `EXAMPLE_DB` as its database path.

## Check the MCP connection

Run the local MCP smoke check against the sample store:

```bash
uv run health-bridge mcp smoke --db "$EXAMPLE_DB"
```

The result lists the available tools and reports `sleep_analysis` with 14 records and `workout` with 6 records. This check starts and calls the local MCP server; it does not configure an AI client.

For a direct tool query, call `get_sleep_summary` with:

```json
{"start_date":"2026-06-01","end_date":"2026-06-08"}
```

<details>
<summary>Inspect the returned sleep data</summary>

The MCP response contains this JSON in its text content. The CLI sleep query returns the same data:

```json
{
  "period": {"start": "2026-06-01", "end": "2026-06-08"},
  "session_count": 7,
  "stage_seconds": {
    "core": 123480,
    "deep": 25200,
    "rem": 37800
  },
  "sources_used": [{
    "source_key": "synthetic.watch.bravo",
    "name": "Synthetic Watch Bravo",
    "kind": "watch"
  }],
  "missing_data_notes": [
    "Returned observations reflect only records present in this local SQLite store for the requested period; absent records remain unknown."
  ],
  "truncated": false
}
```

These are tool results from synthetic records, not a generated assistant answer. See the [MCP reference](../reference/mcp.md) for the request and response format.

</details>

## Read the comparison

For these records:

- June 1–7 contains seven sleep sessions averaging **7h 24m**, and four workouts totaling **160 minutes**, on Monday, Wednesday, Friday, and Sunday.
- June 8–14 contains seven sleep sessions averaging **6h 42m**, and two workouts totaling **80 minutes**, on Saturday and Sunday.
- Average recorded sleep is **42 minutes shorter** in the second week, and the workouts are concentrated on the weekend.

Average sleep is the sum of `core`, `deep`, and `rem` stage seconds divided by the returned session count. Workout minutes are the sum of `duration_seconds` divided by sixty. This fixture has one sleep session per date; the denominator comes from the records rather than assuming every requested day has a session.

In your connected assistant, ask: “How did my sleep and workouts change between June 1–7 and June 8–14, 2026?” Use those fixed dates: asking about the last two weeks would query a different period as time passes.

After trying the example, disconnect any client you pointed at the sample database and remove only the temporary directory stored in `EXAMPLE_DIR`. Keep your real receiver database separate.
