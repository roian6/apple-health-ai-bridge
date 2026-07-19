# Public preview QA

Use this guide to check a public developer-preview build without exposing private health data or receiver credentials.

## Synthetic quickstart

Run this first on a fresh checkout. It uses only synthetic fixture data.

```bash
uv sync --all-extras --dev
uv run health-bridge init --db .tmp/qa-public-preview.sqlite
uv run health-bridge ingest-fixture \
  --db .tmp/qa-public-preview.sqlite \
  --input fixtures/health_bridge_batch_v1.synthetic.json
uv run health-bridge status --db .tmp/qa-public-preview.sqlite --markdown
uv run health-bridge mcp smoke --db .tmp/qa-public-preview.sqlite
```

Pass condition:

- database initialization succeeds;
- synthetic ingest succeeds;
- status Markdown is understandable and redacted;
- MCP smoke returns a compact read-only summary;
- output does not include receiver credentials, pairing links, setup pages, token material, or real HealthKit values.

## Documentation check

A new reader should be able to answer these from `README.md`, `docs/architecture.md`, and `docs/pairing.md`:

- What does the project do?
- What data path does it use?
- Is HealthKit access read-only?
- What can be tested without an iPhone?
- What requires iPhone, Mac/Xcode, and private pairing material?
- Which pairing method is the default user path, which methods are fallbacks, and which method is maintainer-only?
- What receiver URL shapes fail for physical iPhones?
- What is not supported yet?
- What must never be pasted into public issues, PRs, docs, or chat?

The answer should not claim full Apple Health export, HealthKit write support, hosted cloud processing, App Store availability, medical use, or guaranteed background freshness.

## Real-device smoke checklist

Real-device QA should happen privately. Public notes should use aggregate, redacted wording only.

An upgrade install, **Reset Private Sync State**, or a pairing URL delivered with
`devicectl --payload-url` does not count as fresh-user QA. Reset is a recovery
operation and intentionally preserves some installation identity. A release-blocking
fresh-user run must use the following sequence:

1. seal and record the exact candidate version, build, source tree, executable hash,
   receiver PID/executable, and aggregate receiver event baseline;
2. drain or explicitly discard queued uploads, disconnect and revoke the previous
   test device, remove the app, and verify that the bundle is absent;
3. install the sealed candidate and launch it normally, without delivering a URL;
4. verify that the first screen is **Not Connected**, with no saved receiver,
   pending pairing, recovery banner, or queued upload;
5. start a clean receiver database and verify the exact advertised `/health` URL
   from the iPhone's active LAN or VPN route before creating an invitation;
6. display the private setup page on a separate trusted screen and scan its QR with
   the iPhone Camera app;
7. after Camera hands off to Health Bridge, do not relaunch or force-quit the app
   until the app and receiver both confirm one successful redemption;
8. complete the native Local Network and Apple Health permission prompts as a human;
9. run first sync, unchanged-data idempotence, receiver outage, and recovery while
   recording only aggregate counts and statuses.

The first-sync lane must select **All** history. It has no outer operation deadline:
individual uploads use a bounded no-progress timeout and a long per-request resource
budget, while the visible **Cancel** action stops the current run without deleting
already queued uploads. A slow but progressing transfer must be allowed to finish.

Deleting an app may not prove that Keychain installation identity is cryptographically
new. Label this lane `container-clean, keychain freshness unproven`. A claim of a fully
fresh installation identity requires a never-installed/erased QA device; a temporary
bundle identifier or injected local-state purge does not validate the exact release
candidate.

Before claiming a release has a working iPhone path, verify:

1. the receiver is reachable from the iPhone;
2. `/health` works on the same URL used by setup material;
3. pairing material is generated privately;
4. the signed companion opens on a real iPhone;
5. QR-first setup page pairing works without `devicectl --payload-url` shortcut;
6. at least one documented fallback is understandable: setup-page button on iPhone or copy/paste setup link;
7. the native Apple Health permission sheet appears when expected;
8. the primary sync action completes;
9. local status or MCP output confirms new data without exposing sample values;
10. receiver-offline, invalid URL, rejected token, queued upload, disconnect, and automatic-sync copy are understandable;
11. background sync copy remains best-effort.

For the receiver-offline foreground gate, **Sync Now** must end its visible loading
state within eight seconds of the action starting: the bounded five-second
reachability probe plus no more than three seconds of scheduling overhead. It must
not repeat one network timeout per Health lane and must not collect
or enqueue new Health payloads after the failed preflight. **Check Connection** is a
health-only probe and must not create a durable synthetic batch.

Run a separate mid-transfer outage lane after a successful preflight. It must create
at least one durable queued upload, preserve that queue through background and
foreground transitions, retry against the same receiver, drain to zero, and create
no duplicate device, credential, or record identities.

When Linux is the receiver under test, the receiver process and database must remain
on Linux for the whole run. A Mac receiver is not substitute evidence. If a private
relay is required, record it explicitly as network transport and still prove the
Linux receiver PID, request, redemption, and ingest events.

Record the aggregate result in a private JSON file outside the repository, then run:

```bash
EXPECTED_SOURCE_TREE="$(git write-tree)"
EXPECTED_APP_SHA256="<independently computed signed-app executable SHA-256>"
EXPECTED_RECEIVER_SHA256="<independently computed Linux receiver executable SHA-256>"
uv run python scripts/validate-fresh-device-evidence.py \
  /private/path/fresh-device-evidence.json \
  --expected-source-tree "$EXPECTED_SOURCE_TREE" \
  --expected-app-sha256 "$EXPECTED_APP_SHA256" \
  --expected-receiver-sha256 "$EXPECTED_RECEIVER_SHA256"
```

Compute the expected hashes independently from the sealed staged tree, signed app
executable, and verified Linux receiver executable; do not copy them from the evidence
JSON. The strict validator rejects unknown fields and requires: clean-install empty
state, human permission prompts, Linux process/database/request/redemption/ingest
ownership, exactly one QR redemption and final active credential, first-sync and
idempotence deltas, the total eight-second offline budget, durable outage persistence,
Cancel queue preservation, a write-free connection check, same-receiver recovery to
queue zero, and zero duplicate identities. A validator PASS is required; checklist
prose alone is not release evidence.

Do not commit detailed device logs, screenshots, private endpoints, setup pages, pairing links, tokens, cursor values, receiver databases, outbox payloads, or raw HealthKit values.

## Feedback template

Use one item per issue:

```text
[QA]
Flow: README / synthetic quickstart / receiver / pairing / permission / sync / recovery / docs
Severity: blocker / pre-public / post-public / question
What I tried:
What I expected:
What happened:
Exact visible text or command:
Why it was confusing or broken:
Sensitive data included: no
```

Severity guide:

- blocker: prevents setup, sync, query, or risks leaking secrets or health data;
- pre-public: confusing enough to hurt first-release users;
- post-public: acceptable for the stable release but worth improving later;
- question: product decision, not necessarily a bug.
