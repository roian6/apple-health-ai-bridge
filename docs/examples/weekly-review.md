# Reproduce the weekly review example

The README's two-week comparison uses [synthetic records](../../fixtures/readme-weekly-review.synthetic.json): fourteen sleep sessions and six walking workouts, dated June 1–14, 2026. All timestamps use UTC.

## Load the sample history

From a source checkout with the [development environment](../../CONTRIBUTING.md#development-setup) installed, create a fresh sample database in your home directory:

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

## Read the comparison

For these records:

- June 1–7 contains seven sleep sessions averaging **7h 24m**, and four workouts totaling **160 minutes**, on Monday, Wednesday, Friday, and Sunday.
- June 8–14 contains seven sleep sessions averaging **6h 42m**, and two workouts totaling **80 minutes**, on Saturday and Sunday.
- Average recorded sleep is **42 minutes shorter** in the second week, and the workouts are concentrated on the weekend.

Average sleep is the sum of `core`, `deep`, and `rem` stage seconds divided by the returned session count. Workout minutes are the sum of `duration_seconds` divided by sixty. This fixture has one sleep session per date; the denominator comes from the records rather than assuming every requested day has a session.

A question such as “I'm planning next week's routine. How did my sleep and workouts change over the last two weeks?” gives an assistant both the records and the reason for looking at them. Your follow-up can then focus on what will fit into the coming week.
