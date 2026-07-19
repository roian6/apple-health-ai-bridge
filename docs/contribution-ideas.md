# Contribution ideas

This page lists safe starter issues and launch-feedback lanes for the public `1.0.0` release. Keep contributions synthetic, local-first, and privacy-safe.

## Good first issues

These are intentionally documentation, examples, or fixture-focused. They should not require real HealthKit data, private receiver setup, App Store Connect access, or changes to HealthKit authorization/cursor/outbox behavior.

| Candidate | Why it helps | Privacy notes |
| --- | --- | --- |
| Add a Claude Desktop MCP config example | Helps users connect the local MCP server | Use `.tmp/quickstart.sqlite` and synthetic data only |
| Add a Cursor MCP config example | Helps agent users try the project from their editor | No screenshots with personal paths or health data |
| Implement and test Windows database locking | Enables a safe native Windows receiver path | Match POSIX lifecycle/access lock semantics before documenting support |
| Add a Linux systemd example for a local receiver | Helps self-hosted users keep the receiver running | Keep it local/private-network oriented; no public internet hardening claim |
| Expand sample MCP prompts | Shows how agents can query status, daily summaries, workouts, sleep, and sources | Prompts must avoid diagnosis/medical advice claims |
| Add troubleshooting for Local Network permission | Helps TestFlight/self-build users understand iPhone receiver reachability | Do not include real IPs or screenshots with health values |
| Improve no-data/denied-permission documentation | Explains why denied HealthKit reads can look empty | Keep wording general; no personal examples |
| Add synthetic sleep edge-case fixture | Improves tests without private data | Synthetic fixture only |
| Add a docs glossary | Clarifies receiver, setup page, pairing, source provenance, cursor, MCP | No implementation diary or private notes |

## Not good first issues

Avoid using these as starter tasks because mistakes can leak data, break sync correctness, or change App Review posture:

- HealthKit permission expansion;
- cursor/anchor semantics;
- local outbox retry ordering;
- receiver token/pairing/setup-page handling;
- background delivery scheduling;
- App Store Connect/reviewer/demo material;
- hosted relay, public internet receiver deployment, or remote MCP;
- clinical/medical, diagnosis, coaching, score, or emergency features.

## Feedback lanes

Use GitHub issues with one report per issue:

- **Synthetic quickstart**: fresh checkout, `uv sync`, fixture ingest, status, MCP smoke.
- **MCP/client integration**: Claude Desktop, Cursor, Hermes, or other MCP client config.
- **Receiver setup**: local/private-network reachability, `/health`, pairing setup material.
- **TestFlight/self-build iPhone path**: install, pairing, Health permission, foreground sync, recovery states.
- **Docs/positioning**: unclear privacy boundary, misleading wording, missing caveats.

## Feedback template

```text
Flow: README / synthetic quickstart / MCP config / receiver / pairing / permission / sync / recovery / docs
Environment: OS, Python version, uv version, MCP client, iOS/Xcode/TestFlight if relevant
What I tried:
Expected:
Actual visible text or command output:
Sensitive data included: no
```

Do not include real HealthKit values, exports, receiver DBs, setup pages, pairing links, bearer tokens, token hashes, cursor values, outbox payloads, private receiver endpoints, or screenshots with health values.
