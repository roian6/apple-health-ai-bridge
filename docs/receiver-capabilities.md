# Receiver nutrition capability contract

Use explicit capability discovery before enabling nutrition delivery. Package
versions, a successful `/health` response, and acceptance of older health types
are not nutrition support evidence. `/health` remains a liveness endpoint with
its existing response shape.

## Discovery

Send `GET /v1/capabilities` to the configured Receiver using
`Authorization: Bearer <receiver credential>`. This uses the same credential
validation as `POST /v1/batches`, including revoked and device-bound credentials.
It does not create a pairing or grant new permissions. Authentication retains
its existing token last-used bookkeeping.

A successful response is HTTP 200, `Content-Type: application/json`, and
`Cache-Control: no-store`, with this body:

```json
{
  "schema_id": "health_bridge.receiver_capabilities.v1",
  "batch_schema_id": "health_bridge.batch.v1",
  "nutrition_supported": true
}
```

All three fields are required. Match both schema identifiers exactly and require
a JSON Boolean for `nutrition_supported`; strings, numbers and null are invalid.
Unknown additional fields may be ignored. `ReceiverCapabilitiesV1` in
`health_bridge.contract.receiver_capabilities` implements this body contract.
HTTP status, authenticated destination and connection identity must also be
checked by the consumer; parsing a body alone is not authentication.
The companion also requires the exact `Content-Type: application/json` and
`Cache-Control: no-store` response headers before decoding. Missing or different
header values leave support unknown.

Missing, malformed, invalid or revoked credentials receive HTTP 401 with
`{"error":"unauthorized"}` and `WWW-Authenticate: Bearer`. An authentication
storage failure receives HTTP 500 with
`{"error":"authentication_temporarily_unavailable"}`. Neither response is
capability evidence. Unknown routes return HTTP 404.

## Meaning of nutrition support

`nutrition_supported: true` declares that the Receiver accepts nutrition
`health_types` entries and samples in the existing batch protocol and preserves
the existing query aggregation for these five types:

| Type code | Unit | Daily aggregation |
| --- | --- | --- |
| `dietary_energy_consumed` | `kcal` | Sum |
| `dietary_protein` | `g` | Sum |
| `dietary_carbohydrates` | `g` | Sum |
| `dietary_fat_total` | `g` | Sum |
| `dietary_fiber` | `g` | Sum |

Their catalog category is `nutrition`. Nutrition-only batches, mixed batches
and catalogs without nutrition samples are valid when the rest of the payload
satisfies `health_bridge.batch.v1`. Repeated sample identities are not summed
twice. Dietary energy remains separate from active and basal energy.

This fixed five-type promise does not extend to arbitrary future nutrition
types. The capability schema identifier is not a package version. The batch
schema remains `health_bridge.batch.v1`, version `1.0.0`; discovery does not
change package or component versions.

## Consumer decisions

- **Supported:** HTTP 200 from the current authenticated Receiver with the
  recognized body and Boolean `true`. Nutrition may be submitted; this is not
  an acknowledgment that any records were delivered.
- **Unsupported:** A valid recognized body with Boolean `false`. Withhold
  nutrition while preserving supported synchronization.
- **Unknown:** Legacy Receiver returning 404, `/health`-only information,
  timeout, offline connection, unauthorized/error response, malformed body,
  missing field or unrecognized schema. Do not infer support from a version
  string or report offline delivery as successful.

For unsupported or unknown support, withhold nutrition from both `samples` and
`health_types`; preserve supported existing records and durable pending work.
Do not advance nutrition anchors for unsent records. Recheck after an upgrade
or reconnect and deliver the retained or deliberately recollected window with
stable record identities so retries remain idempotent.

Bind discovery to the active Receiver URL and credential/connection identity.
Discard the decision when that identity changes, including a Mailbox binding or
generation change; never copy support from another Receiver or keep an earlier
success as fresh evidence after a failed probe.

The declaration describes the shared Receiver batch acceptance contract used by
Direct and opt-in Mailbox ingestion. Mailbox clients may discover it over the
configured authenticated HTTP connection; if that connection cannot be probed,
support is unknown. There is no new Mailbox discovery message, pairing field or
transport fallback. A capability response does not establish Mailbox worker
health, iCloud availability, delivery or acknowledgment.

Capability discovery says nothing about HealthKit read permission or available
records. No observed nutrition data remains unknown/unavailable, not a numeric
zero or proof of permission denial. An actual zero-valued sample is a record.
Only the existing delivery acknowledgment advances delivered state.
