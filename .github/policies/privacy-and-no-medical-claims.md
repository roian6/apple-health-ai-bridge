# Privacy and Claims Guardrails

Apple Health AI Bridge is a local-first data bridge. It should preserve source,
time range, unit, and sync context without turning observations into clinical
interpretation.

## Required Defaults

- Use synthetic fixture data in Git.
- Keep the default workflow local and user-owned.
- Do not add hidden network calls, telemetry, analytics, advertising hooks,
  third-party AI calls, hosted relay behavior, or data-mining paths.
- Do not log secrets, pairing material, credentials, tokens, real exports, or
  raw private records.
- Treat missing records as unknown availability. Possible causes include no
  record, permission limits, source gaps, or sync gaps.
- Keep future query and MCP surfaces read-only by default.

## Allowed Language

- "source-grounded observations"
- "local bridge"
- "selected records"
- "provenance"
- "sync window"
- "missing-data notes"
- "not enough data to say what is absent"

## Forbidden-Language Guardrail Examples

Only this section may contain the exact phrases below. They are examples of
wording to reject from README copy, fixture assertions, tool descriptions, and
normal contract docs.

- "medical advice"
- "diagnosis"
- "treatment"
- "health-risk"
- "recovery-score"
- "readiness score"

## Response Rules for Future Query Tools

Every future user-facing response should include:

- the requested period or date range;
- sources used;
- missing-data notes;
- truncation status when applicable;
- a plain statement when data is unavailable or sparse.

Future tools should not infer behavior or absence from missing records.
