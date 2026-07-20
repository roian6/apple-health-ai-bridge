# Apple Health AI Bridge v1.0.1

**Receiver-only release.** Compatible iOS companion: `1.0.0 (15)`. No TestFlight update is required.

Apple Health AI Bridge 1.0.1 is a receiver-side onboarding and safety patch. The HealthKit companion, pairing protocol, batch schema, and background-sync behavior are unchanged.

## Highlights

- Replaces placeholder-host onboarding with explicit Route A/B/C selection and a complete route → setup → supervised receiver → local health → physical-iPhone health → pairing → first upload ACK lifecycle.
- Rejects reserved documentation/test hostnames and canonical or legacy loopback URL spellings before creating the private database, key, invitation, or pairing page.
- Makes the setup manifest and human-readable CLI output require service supervision, both health checks, and the first receiver upload ACK before MCP handoff.
- Adds safe local health-check URLs for loopback, wildcard, specific IPv4, hostname, and IPv6 receiver binds.
- Strengthens agent-assisted ingress boundaries: no unapproved provider account, paid plan, trial, charges, provider terms, DNS, firewall, proxy, tunnel, or service changes.
- Keeps Route C explicitly limited to trusted same-LAN evaluation with no router port forwarding or public `8765` exposure.

## Install or upgrade the receiver

```bash
uv tool install --force "git+https://github.com/roian6/apple-health-ai-bridge.git@v1.0.1"
```

Then follow the [versioned setup guide](https://github.com/roian6/apple-health-ai-bridge/blob/v1.0.1/docs/setup.md). The existing iOS companion `1.0.0 (15)` remains compatible.

## Verify the release

The GitHub Release assets include:

- `apple_health_ai_bridge-1.0.1-py3-none-any.whl`
- `apple_health_ai_bridge-1.0.1.tar.gz`
- `SHA256SUMS`
- `release-metadata.json`

`release-metadata.json` identifies this as a receiver-only release and independently records receiver version `1.0.1`, compatible iOS source version/build `1.0.0 (15)`, the exact Git commit/tree, and batch schema `1.0.0`. Verify `SHA256SUMS` before using downloaded artifacts.

## Boundaries

- HealthKit access remains read-only.
- The project still does not operate a hosted health-data relay.
- The receiver remains intended for trusted local or private-network deployment, not direct public exposure.
- Automatic sync remains eventual and controlled by iOS scheduling; it is not guaranteed real-time delivery.
- Receiver same-host stdio MCP and direct CLI access remain read-only.
