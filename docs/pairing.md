# Pairing and receiver setup

Pairing connects the iOS companion to a receiver that you run. The default flow is **QR-first secure invitation pairing**: setup material contains a short-lived, single-use invitation, not the receiver bearer credential used for later health uploads.

Setup pages, QR codes, copied links, and invitation codes are still private. Anyone who obtains an unexpired invitation may redeem it first.

## Pairing v2 lifecycle

```text
receiver creates a 20-minute single-use invitation
→ setup page renders QR / open button / server-and-code fallback
→ iPhone creates a high-entropy device credential and stages the credential,
  pseudonymous installation ID, receiver URLs, and temporary invitation in Keychain
→ iPhone sends the staged credential and invitation to the receiver
→ receiver atomically consumes the invitation, maps the device, and registers/replaces
  the credential hash
→ receiver returns a completion acknowledgement without the credential
→ app promotes the staged credential to active settings and clears pending pairing state
→ the user chooses Health read permissions and starts automatic sync after pairing
```

QR, the `healthbridge://pair` link, and manual server-plus-code entry are delivery methods for the **same invitation**. They are not separate authentication systems.

Pairing is not proof of sync by itself. A release claim needs actual receiver-side observations and redacted CLI/status output after the user grants Health read permission and starts sync. Automatic delivery, OFF preservation and recovery require their own real-device verification.

## Supported pairing methods

Use these in order:

| Method | Best for | Expected reliability | Notes |
| --- | --- | --- | --- |
| Setup page QR | Laptop/desktop/tablet screen plus iPhone Camera | Best default | QR contains the temporary invitation secret, not a long-lived receiver credential. |
| Setup page button | Setup page already open on the iPhone | Good | Uses `healthbridge://pair`; browser/app handoff can vary by iOS/browser state. |
| Paste setup link | QR/button unavailable | Fallback | Paste only inside Health Bridge. The link is private until expiry or redemption. |
| Server address + invitation code | Camera, browser handoff, accessibility, or one-device fallback | Supported fallback | The grouped code is case-insensitive, expires with the invitation, and works once. |
| `devicectl --payload-url` | Local development/QA only | Developer shortcut | Not a public onboarding path and not evidence that normal user pairing is understandable. |

The manual code uses an unambiguous `5-5-5` shape. Its public selector allows the receiver to count failures against the correct invitation; the remaining 10 characters provide 50 bits of secret entropy and are stored with a salted memory-hard hash.

## Open the connection page

Use the [setup guide](setup.md) for installation and receiver readiness. The unreleased onboarding candidate starts the owned supervised receiver and prints a private live connection URL; it no longer asks you to assemble a service or transfer an HTML file. Released `receiver-v1.1.2` users must follow its version-pinned guide instead.

Open the connection page on the receiver computer and scan its QR with iPhone Camera. On the iPhone, open the same page in Safari and tap **Open in Health Bridge**. If the phone cannot reach the private route, resolve that connectivity before trying another invitation. The page reports receiver readiness, pairing and the first received upload separately.

An invitation lasts 20 minutes and works once. Re-run setup to obtain its current connection URL when the invitation expires; do not keep sharing an old page or link. These URLs and codes remain private. In Companion 1.1.1, pairing is followed by **Allow Health Access** or **Review Permissions** and the user's Apple Health read-permission choices. The user separately enables **Automatic Sync** when desired; an existing OFF setting is not overridden by receiver setup or re-pairing.

Expert `receiver create-pairing` and `dev device-session` commands remain available for explicit recovery or isolated QA. Raw secret-output modes are not the normal onboarding path. See [the CLI and contributor references](../CONTRIBUTING.md) rather than duplicating their setup commands here.

## Direct receiver URL requirements

The native iCloud candidate exchanges encrypted pairing files through iCloud Drive and does not require a receiver URL, HTTPS, or a tunnel. It requires companion and helper builds that support native pairing; availability in an already released app is not implied. The URL and manual-code rules below describe retained Direct and URL-based pairing.

Common working shapes:

- same private LAN hostname or IP, with the receiver bound to the LAN interface;
- private VPN/Tailscale hostname or HTTPS Serve URL;
- a hardened private HTTPS endpoint after a separate security review.

Common failure shapes:

- `127.0.0.1` or `localhost` in iPhone setup material — that points at the iPhone itself;
- receiver bound only to loopback while the iPhone uses another host/IP;
- laptop asleep, firewall blocked, VPN disconnected, or captive/corporate network isolation;
- host or port changed after invitation creation;
- public internet exposure without TLS and deployment hardening.

The redeem URL must have the same scheme, host, and port as the batch receiver URL. The app rejects a completion response that points at a different receiver.

HTTP is retained for localhost and trusted private-development networks. Use HTTPS whenever the invitation exchange crosses an untrusted network because the request contains both the temporary invitation and the staged device credential. The completion response does not return the credential.

## Invitation security properties

The default implementation provides:

- default expiry: 20 minutes;
- accepted internal TTL range: 10–30 minutes;
- one-time atomic redemption;
- same-label invitation rotation (the previous active invitation is revoked);
- a high-entropy QR invitation secret;
- manual code with a public selector plus a 50-bit secret portion;
- salted `scrypt` storage for the manual secret;
- no raw invitation secret, full manual code, installation ID, device bearer credential, or v2 credential-derived raw lookup prefix in SQLite;
- installation IDs use a domain-separated hash, device credentials use the existing one-way receiver-token hash, and v2 lookup prefixes are derived from that hash before persistence;
- device-to-token mapping so a successful re-pair atomically revokes the previous active v2 credential for that installation;
- five failed code attempts per invitation before lockout;
- five redeem requests per direct client address per 60 seconds;
- a 4 KiB redeem request limit;
- generic errors for unknown, invalid, expired, revoked, used, or locked invitations;
- no default HTTP access log or socketserver fallback traceback containing client addresses, request paths, database paths, or storage error details.

Invitation consumption, device upsert, previous-v2-token revocation, staged-token insertion, and device/redemption mapping happen in one SQLite `BEGIN IMMEDIATE` transaction. Any failed insert or mapping rolls the whole redemption back. Concurrent requests from different devices can therefore register only one winner. A retry carrying the exact same installation ID, credential, and invitation is idempotent and returns the same completion acknowledgement without creating another token.

The app stages pending pairing state in a dedicated Keychain item **before** the network call. A network response loss, app termination, or active-Keychain save failure leaves that state available for retry while preserving the previous active receiver URL, token, outbox generation, and automatic-sync configuration. Retapping the same setup link reuses the exact staged tuple; a different invitation cannot silently replace it. On launch, the app resumes the staged request before starting HealthKit observers, outbox scheduling, or catch-up. A cold-launch setup URL waits for bootstrap recovery and then runs unless it exactly matches the invitation bootstrap just recovered; duplicate user callbacks remain deduplicated. It clears pending state only after active settings are saved, or after an exact receiver `400 {"error":"pairing_invitation_invalid"}` response. Ambiguous 4xx responses such as 408, rate limits, 5xx responses, malformed intermediary bodies, and transport failures retain the staged tuple.

While recovery remains pending, automatic and manual sync are paused. Disconnect and every connection replacement, including legacy v1 replacement, use the same local terminal barrier. The app first closes payload admission and advances a non-secret connection generation, then cancels and awaits pairing and foreground payload tasks. It also serializes background outbox scheduling and waits for cancelled background URLSession tasks to finish their generation-checked callbacks before clearing or promoting settings. Foreground outbox loops use an immutable receiver credential snapshot and recheck the captured generation before removing queued items or allowing cursor/proof progress. Bootstrap applies the same cancellation drain to background tasks restored by iOS from a previous process.

Disconnect completes locally only after those joins and the settings clear. After completion, an older generation cannot promote credentials, mutate outbox/cursor/proof state, or admit new payload work. This boundary does not retract a network request that was already sent; that request may still reach the receiver, so server-side device or token revocation remains a separate action when needed.

Each committed connection receives a random opaque binding ID stored atomically with its URL, credential, and generation in one Keychain record. The outbox manifest stores only that opaque ID, never the raw URL, credential, or a reusable credential hash. During upgrade, an older version-2 credential hash is used in memory once to verify the currently saved legacy connection, then matching entries are rebound to the opaque ID and every legacy hash is removed; nonmatching entries become unknown-origin quarantine. A different connection cannot automatically or manually send the old connection's queued health payloads. Receiver replacement and disconnect are refused until the trusted current queue is empty; the user must explicitly delete queued uploads before changing that binding. The oldest mismatched or unknown item stays quarantined on the iPhone and preserves FIFO until the user explicitly deletes queued uploads; re-pairing never adopts it automatically.

Sleep transitions add a second private journal containing the exact encoded
payload and post-delivery manifest. Queuing alone never advances the committed
HealthKit sleep anchor. The manifest is committed only after the tracked FIFO item
has received a successful response. The destructive **Reset Private Sync State** action first closes
foreground and background upload admission and automatic delivery, stops HealthKit background delivery,
and cancels and awaits active foreground payload work. It then acquires the exclusive direct-transfer
gate, cancels/awaits restored OS-managed uploads, and revalidates the connection generation. Only after
those barriers does it persist the private clear intent. While admission remains closed, it invalidates
the Sleep manifest and transition journal, resets receiver-scoped non-Sleep cursors,
upload proofs, and backfill progress, removes the outbox, and deletes the clear intent last. If the
saved atomic connection record is unreadable, the same explicit user-confirmed action replaces it
with a clean unpaired record. If the app exits at any deletion boundary, launch recovery finishes the
deletion before automatic sync can start. The next connected foreground sync uses fresh receiver-scoped
progress and a newer ordered Sleep reset epoch to reconcile the receiver rather than silently skipping
discarded corrections. A journal-only Sleep transition is also visible in the destructive-clear UI even
before it has obtained an outbox item. If either private store cannot be opened or
decoded, uploads and deletion completion remain fail-closed; the app does not fall
back to direct network upload or remove the clear intent while sleep state may
still survive. Bootstrap validates both Sleep files and migrates incompatible
persisted Sleep payloads before any FIFO or HealthKit upload can start. An
unreadable outbox can be destructively recovered only after a durable clear intent
is written; recovery removes the dedicated private outbox contents while retaining
that intent until a clean outbox has been reopened. After a successful deletion,
bootstrap and automatic HealthKit delivery are reactivated when the saved
preference remains enabled.

The app offers an explicit destructive cancel action backed by a generation-bound Keychain marker and a non-secret durable terminal intent. It first verifies that the caller still owns the expected connection generation, persists the intent and marker, clears the uncertain active connection, removes the pending attempt, and clears both markers last. A stale cancellation cannot delete newer credentials. A legacy marker with no generation remains fail-closed until the user explicitly confirms cancellation again; it is never applied to the current connection automatically. If the app exits or a Keychain operation fails midway, bootstrap finishes a bound cancellation instead of resuming pairing or automatic sync.

The source-address limiter is process-local. It is suitable for the default single receiver process, but it does not coordinate multiple workers or replicas and resets on restart. A public or replicated deployment needs a shared ingress/application limiter.

The receiver uses the direct socket peer as the limiter key and does **not** trust `X-Forwarded-For` by default. Configure trusted-proxy behavior at a reviewed ingress instead of accepting spoofable forwarded headers in the app.

## Redemption API

The public, unauthenticated exchange endpoint is:

```text
POST /v1/pairing/redeem
```

A request supplies the pseudonymous installation ID, the client-staged device credential, the platform, and exactly one invitation grant:

```json
{
  "invitation_secret": "<temporary-QR-secret>",
  "installation_id": "<random-installation-uuid-v4>",
  "device_credential": "<client-generated-high-entropy-credential>",
  "platform": "ios"
}
```

```json
{
  "invitation_code": "<temporary-grouped-code>",
  "installation_id": "<random-installation-uuid-v4>",
  "device_credential": "<client-generated-high-entropy-credential>",
  "platform": "ios"
}
```

A successful response returns only the schema, invitation label, and batch receiver URL. It does **not** return the device credential. The app verifies the receiver origin, promotes its staged credential to active Keychain settings, then removes the pending pairing item. The temporary invitation is present only inside pending Keychain state during an incomplete pairing attempt.

Do not log request/response bodies from this endpoint.

## Device inventory and revocation

List active v2 devices using redacted, hash-derived references:

```bash
uv run health-bridge receiver list-devices --db .tmp/receiver.sqlite
```

To include prior revocations for local audit:

```bash
uv run health-bridge receiver list-devices \
  --db .tmp/receiver.sqlite \
  --include-revoked
```

Revoke one active device and every mapped active v2 credential in the same SQLite transaction:

```bash
uv run health-bridge receiver revoke-device \
  --db .tmp/receiver.sqlite \
  --device-ref <ref-from-list-devices>
```

`revoke-device` fails closed if the reference is malformed, absent, already revoked, or not unique. It never requires or prints the bearer credential, installation ID, installation hash, or token hash. Legacy v1 credentials that have no device mapping continue to use `receiver revoke-token --token-prefix ...`.

Receiver upgrades keep existing device records, keys, and health data. An older mailbox connection may need its original pairing exchange replayed to confirm the exact peer. Until then, new deliveries stay pending rather than being accepted from a trust file alone. Native pairing retries the retained request automatically. Keep the original pairing material for a legacy URL-based mailbox retry; do not delete keys, the database, or queued uploads to force recovery. A revoked device still cannot enroll or deliver using its old credential.


## Legacy v1 compatibility

Already paired devices and existing `/v1/batches` bearer credentials continue to work. The iOS parser accepts v1 pairing material during the migration window.

New CLI pairing defaults to invitation v2. Creating a v1 QR bundle that directly contains a long-lived bearer requires explicit expert opt-in:

```bash
uv run health-bridge receiver create-pairing \
  --db .tmp/receiver.sqlite \
  --label legacy-device \
  --receiver-url "$PHONE_REACHABLE_BATCH_URL" \
  --format json \
  --print-secret \
  --legacy-v1
```

Do not use legacy v1 for normal onboarding. Removal of v1 generation/parsing should be considered after one release window; existing device tokens require a separate revocation decision.

## Universal Link boundary

Core parsing accepts a future HTTPS `/pair?payload=...` route in addition to `healthbridge://pair`, and the app has a browsing-activity routing boundary. This does **not** mean Universal Links are currently deployed.

A production Universal Link still requires:

- a stable project-controlled HTTPS domain;
- a final bundle ID and Apple Team ID;
- an AASA file served without redirects;
- an `applinks:` Associated Domains entitlement.

Arbitrary self-hosted receiver domains cannot all become app Universal Link domains. Until an official pairing domain is selected, the custom scheme plus manual code fallback remains the supported path.

## User handoff checklist

For Encrypted iCloud Mailbox, first run the explicit mailbox setup command and
signed-helper lifecycle in
[`icloud-mailbox-service.md`](icloud-mailbox-service.md). The public pairing
command remains `health-bridge setup --transport icloud-mailbox`; there is no
separate hidden mailbox pairing command. Direct remains the default and never
falls back to mailbox delivery.

1. Run setup for the selected transport and keep its owned receiver running.
2. Open the private connection page printed by setup on a trusted screen, then scan its QR or use its Open button on the iPhone.
3. For Direct, verify the phone-facing receiver URL and use the displayed server address and code if link handoff is unavailable. Native iCloud needs neither that URL nor a tunnel.
4. Confirm the connection is saved, choose Apple Health read permissions, and separately enable **Automatic Sync** when wanted. Existing OFF consent remains unchanged.
5. Keep the live page open until it reports stored records; confirm local CLI/MCP access from the setup terminal. Re-run setup to resume the same paired receiver without issuing another invitation.

An expired unused invitation needs a new setup link. A delayed native completion can be retried with the same pending request; do not delete pairing state or provider files as a recovery step. Manually exported Direct invitation files are private capabilities and can be removed after handoff or expiry.

## Security rules

- Do not paste setup links, deep links, invitation secrets/codes, bearer tokens, token hashes, setup-page contents, receiver DBs, cursor values, or raw HealthKit values into public issues, PRs, docs, or chat.
- Do not put real pairing material in screenshots or test snapshots.
- Delete generated setup pages after pairing or expiry.
- Generate a new invitation if temporary setup material may have leaked.
- Run `receiver list-devices` and `receiver revoke-device` if compromise is discovered after successful v2 redemption; use `revoke-token` only for legacy unmapped credentials.
- Use synthetic fixtures for public examples.

## QA interpretation

A complete pairing test proves:

- QR/link and manual-code paths redeem the same invitation protocol;
- different-device races register at most one winner while exact staged retries are idempotent;
- raw invitation, installation ID, and device credential are absent from receiver SQLite;
- an incomplete v2 pairing keeps temporary pending material only in its dedicated Keychain item;
- network loss, termination, and active-Keychain failure preserve retry state and the previous active connection;
- successful promotion stores the final credential and clears pending pairing state;
- re-pairing the same installation revokes its previous active v2 token in the redemption transaction;
- v1 material still imports during the compatibility window;
- the app moves to Health permission or ready-to-sync state;
- foreground sync creates new receiver-side sync runs after Health permission.

A `devicectl --payload-url` shortcut remains useful for maintainer QA, but public release QA must also exercise normal QR and manual-code onboarding.
