# Mailbox delivery V1

Mailbox delivery V1 wraps an existing `health_bridge.batch.v1` byte string in
an authenticated, encrypted envelope. The sender hashes and encrypts the same
immutable bytes that its outbox already persisted. Envelope construction never
decodes, normalizes, or re-encodes that batch.

## Encoding boundaries

Envelope, ACK, and receipt metadata use HBJCS1. This profile requires canonical
UTF-8 JSON, sorted lower-ASCII snake-case object keys, no whitespace, signed
64-bit integers, and lowercase control-character escapes. Floats, duplicate or
unknown fields, alternate escapes, invalid UTF-8, and noncanonical bytes are
rejected before signature verification.

Batch plaintext does not use HBJCS1. After envelope authentication and AES-GCM
decryption, the receiver retains the exact plaintext bytes. It rejects payloads
over 1,048,576 bytes, invalid UTF-8, malformed or trailing JSON, duplicate keys
at any depth, and non-finite number tokens. It then passes those same bytes to
the unchanged strict `HealthBridgeBatchV1.model_validate_json` parser. Valid
whitespace, key order, string escapes, and finite-number spellings do not need
to match a reserialization.

## Cryptographic identity

Delivery uses an ephemeral X25519 sender key, the receiver's static X25519 key,
HKDF-SHA256, AES-256-GCM, and the sender's Ed25519 signature. ACKs use the
receiver and device static X25519 keys and the receiver's Ed25519 signature.
The production envelope constructor generates a fresh ephemeral key and 12-byte
CSPRNG nonce for every call. Deterministic entropy is confined to the internal
golden-vector sealer and is not part of the public constructor parameters.
Delivery and ACK directions have separate salt, key, AAD, nonce, ID, and
signature domains. Key IDs bind the lowercase algorithm name, one NUL byte, and
the raw 32-byte public key.

ACK encryption is deterministic for one complete receipt. Its ID, key, and
nonce bind the exact canonical receipt bytes, so regenerating a committed,
retryable, or terminal ACK produces identical bytes. Published error codes are
closed and carry no free text.

The public structural schema is
`schemas/health_bridge.delivery.v1.schema.json`. Canonical-byte, key-trust,
signature, AEAD, and receiver parsing requirements are enforced by the protocol
implementation rather than JSON Schema alone.

## Local self-test

Run:

```bash
uv run python -m health_bridge.contract.delivery_v1 \
  --self-test fixtures/delivery_v1.synthetic.json
```

The command uses runtime-generated ephemeral test keys, encrypts the exact
synthetic batch fixture bytes, verifies an ACK round trip, and prints aggregate
case counts only. It never prints payload bytes, identifiers, digests, keys, or
signatures. Invalid test descriptors and authenticated mutations exit with code
2 and print only `authentication_failed`, `payload_invalid`, or
`payload_oversize`.
