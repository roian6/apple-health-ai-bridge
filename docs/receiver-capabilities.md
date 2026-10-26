# Receiver capability contract

Use explicit capability discovery before enabling nutrition delivery. Package
versions, a successful `/health` response, and acceptance of older health types
are not nutrition support evidence. `/health` remains a liveness endpoint with
its existing response shape.

## Direct HTTP discovery

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

- **Supported:** A valid declaration for the current connection with Boolean
  `true`, received through its active transport. Nutrition may be submitted;
  this is not an acknowledgment that any records were delivered.
- **Unsupported:** A valid recognized body with Boolean `false`. Withhold
  nutrition while preserving supported synchronization.
- **Unknown:** Legacy Receiver returning 404, `/health`-only information,
  timeout, offline connection, unauthorized/error response, malformed body,
  missing field or unrecognized schema. Do not infer support from a version
  string or report offline delivery as successful.

For unsupported or unknown support, withhold nutrition from both `samples` and
`health_types`; preserve supported existing records and durable pending work.
Do not advance nutrition anchors for unsent records. Recheck at the next normal synchronization opportunity after an upgrade and
deliver the retained or deliberately recollected window with
stable record identities so retries remain idempotent.

Bind discovery to the active transport and current connection identity. Direct
HTTP additionally binds the Receiver URL and credential.
Discard the decision when that identity changes, including a Mailbox binding or
generation change; never copy support from another Receiver or keep an earlier
success as fresh evidence after a failed probe.

## iCloud Mailbox discovery

An active Mailbox connection reads one Receiver-signed file, including connections
that still retain inactive HTTP credentials. It never probes or falls back to
those credentials. URL-free paired connections use the same path:

```text
Documents/HealthBridgeMailbox/v1/<receiver_id>/<device_id>/receiver-capabilities.json
```

The Receiver publishes this optional metadata after ordinary importer/ACK work
in an existing eligible maintenance pass. It loads existing trusted connection
state and signing keys; discovery does not generate keys or change pairing.
Identical content is not rewritten. Changed content uses the native helper's
fixed-target atomic replacement operation. Updating an existing connection does
not require re-pairing or a dummy health batch. An older helper that cannot store
the declaration leaves support unknown without stopping ordinary ingestion/ACKs.

The maximum file size is **8,192 bytes**, checked before parsing. The canonical
HBJCS1 object has exactly these outer fields:

| Field | Required value |
| --- | --- |
| `v` | Integer `1` |
| `kind` | `receiver_capabilities` |
| `receiver_id`, `device_id` | Current paired 32-character lowercase hex identifiers |
| `connection_generation` | Current nonnegative Int64 wire generation |
| `receiver_signing_key_id` | Current trusted Receiver Ed25519 key ID |
| `capabilities` | The capability body shown above |
| `signature` | Canonical unpadded base64url Ed25519 signature |

The signature preimage is UTF-8
`health-bridge/mailbox/v1/receiver-capabilities/signature`, one NUL byte, and
HBJCS1 encoding of the complete object with only `signature` removed. The public
key comes from existing pairing trust, never from the file. Unknown **nested**
capability fields are included in signature verification before known fields
are projected into the common typed model. Valid compatible additions preserve
known behavior; unsigned changes to unknown fields invalidate the declaration.
Unknown outer fields, duplicates, wrong identities/keys/generation, malformed
required fields and invalid signatures leave support unknown.

The file contains connection identifiers but no health values, token, private
binding, raw keys, timestamp or revision counter. It is signed metadata, not an
encrypted health payload. A valid signature authenticates origin, integrity and
connection binding. It does **not** prove that this is the latest cloud copy,
that the Receiver is online, or that any data was received.

Reads are bounded and coordinated off the main actor. A missing or unavailable
cloud item triggers one download request and leaves support unknown until a
later normal opportunity; there is no polling, watcher or persistent capability
cache. Unsafe paths and unresolved conflicts fail closed. Connection replacement,
cancellation or closed operation admission invalidates late results.

Unknown or unsupported nutrition remains dirty and retains its pending payload
and cursor. A held nutrition type does not stop traversal to a later supported
type. The existing FIFO/projection rules still apply to delivery. Already
published work remains eligible for its valid authenticated ACK even when the
capability file is missing or invalid; only that ACK can finalize its progress.

Capability discovery says nothing about HealthKit read permission or available
records. No observed nutrition data remains unknown/unavailable, not a numeric
zero or proof of permission denial. An actual zero-valued sample is a record.
Only the existing delivery acknowledgment advances delivered state.
