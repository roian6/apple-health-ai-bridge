<div align="center">
  <img src="assets/brand/health-bridge-mark-512.png" alt="" width="80">
  <h1>Apple Health AI Bridge</h1>
  <p>
    <a href="https://apps.apple.com/us/app/health-bridge-for-ai/id6786152806">Download on the App Store</a> ·
    <a href="docs/setup.md">Set up your bridge</a> ·
    <a href="docs/supported-health-data.md">Supported health data</a> ·
    <a href="https://healthbridge.chanhyo.dev/">Website</a>
  </p>
</div>

---

Apple Health AI Bridge connects your Apple Health history to the AI you already use. Ask how your sleep has changed over the past month or compare this week's workouts with last week's. Automatic sync brings in new records, so you can keep asking without exporting another file each time.

The iPhone app syncs the records you allow to a macOS or Linux computer you control. From there, a read-only MCP server gives your chosen AI access to your history.

## Set up the bridge

> **Unreleased onboarding preview.** Until the immutable `receiver-v1.1.3` release and its assets are published and verified, this is an unreleased preview; use the [published Receiver/CLI 1.1.2 guide](https://github.com/roian6/apple-health-ai-bridge/blob/receiver-v1.1.2/docs/setup.md). Direct/Tailscale retains Companion 1.1.1 compatibility. iCloud-native first pairing requires the updated companion and matching signed helper; those updates are not published yet. There is no published npm/PyPI install target yet for this preview; the versioned guide uses exact GitHub release assets rather than assuming registry availability.

You need an iPhone running iOS 18 or later and an awake macOS or Linux receiver computer; native Windows is not currently supported. Use an existing Tailscale connection on both devices, keep your own working private route, or choose iCloud on a compatible Mac once its updated app and helper are available. The [setup guide](docs/setup.md) is the single installation reference for those options.

Enable Automatic Sync once you have paired the app. iOS controls background scheduling, so delivery timing is best-effort rather than real-time or guaranteed at a specific moment.

### 1. Run setup once

After installing the candidate command on PATH, run:

```bash
health-bridge setup
```

In a human terminal, setup detects your environment and offers recommended setup or an existing private URL. It prepares or resumes the supervised receiver, opens the **private connection page** when a desktop browser is available, and follows the iPhone through connection and stored records. Use arrows and Enter, or numbered choices in a plain terminal. You can leave and rerun setup without resetting your receiver or data.

`--no-input` and `--json` prepare without prompts, waiting, browser actions or client configuration. Captured output omits the private invitation; return to a human terminal for phone connection. Client configuration is an explicit choice after a real read-only coverage query; CLI/Skill access needs no client changes.

If you used the one-shot npm command in the setup guide, keep that exact runner prefix for later commands; it does not install a command on PATH.

### 2. Connect the iPhone and start automatic sync

Download [the iPhone app from the App Store](https://apps.apple.com/us/app/health-bridge-for-ai/id6786152806), or keep your compatible installed companion. TestFlight remains available for beta builds.

Scan the connection page's QR with iPhone Camera, or open the page in Safari and tap **Open in Health Bridge**. If you install the app first, return to the same page to connect. In the app, tap **Allow Health Access**, choose Apple Health read permissions, then turn on **Automatic Sync**, which starts OFF. **Sync Now** can test delivery immediately.

The same page shows the connection, then confirms a health-data upload with records still stored. It remains available until the invitation's original expiry. This does not prove every type or future background delivery; iOS controls background timing.

### 3. Ask your AI about the stored data

On the receiver computer, your AI can use the packaged [Health Bridge Skill](skills/health-bridge/SKILL.md) and CLI:

```bash
health-bridge status --json
health-bridge query synced-metrics
```

Setup remembers the database, so normal reads do not repeat `--db`. An AI elsewhere can use an existing approved SSH connection. It should check coverage and observation dates, then run the smallest query needed for your question. MCP remains an optional read-only interface, not an additional onboarding requirement.

For example: “Summarize the sleep records stored for the last seven days and tell me about gaps.”

### Delivery transports

Direct remains available for private HTTPS and trusted-LAN setups; a Direct failure never switches transports automatically. The unreleased native iCloud option uses the user's iCloud container and a compatible Mac receiver without inbound HTTPS or a relay. It requires the updated companion and matching signed helper described in the [mailbox service guide](docs/icloud-mailbox-service.md).

Mailbox envelopes are encrypted and signed before publication. The receiver decrypts and commits accepted batches, then returns an encrypted, signed ACK. The app advances committed local progress only after validating a committed ACK.

## What is supported

The companion requests every HealthKit type that is both implemented by the app and available on the current iOS runtime. Unsupported or unavailable types remain absent rather than being fabricated.

See the versioned [supported health data reference](docs/supported-health-data.md).

## Agent surface

The MCP server is read-only and exposes bounded, source-grounded tools:

- bridge and sync status;
- supported and currently synced metric catalogs;
- time-series observations;
- workouts;
- sleep summaries;
- daily summaries;
- source provenance.

It does not expose raw SQL, token material, cursor values, or clinical recommendations.

## Privacy and security

- HealthKit access is read-only.
- The receiver and SQLite database are user-owned.
- The project has no hosted health-data backend.
- Pairing invitations are temporary and single-use.
- Device credentials are stored in the iOS Keychain and hashed at rest by the receiver.
- Logs and agent status omit health values and credentials by default.
- The receiver is designed for one trusted user, not mutually untrusted tenants.
- The developer does not operate or have access to the user's receiver or iCloud container. A “Data Not Collected” App Privacy answer remains valid only while that developer-no-access boundary remains true.

Do not expose the receiver's loopback port or pairing page to the public internet. For continuous sync away from home, use an existing private-network HTTPS route such as Tailscale Serve or an agent-assisted private HTTPS ingress reviewed for the receiver paths. LAN-only access is a limited fallback.

Report vulnerabilities through GitHub’s private vulnerability reporting flow described in [SECURITY.md](SECURITY.md).

Public policies and help: [Privacy](https://healthbridge.chanhyo.dev/privacy) · [Support](https://healthbridge.chanhyo.dev/support)

### Remove local bridge data

Stop the receiver, then inspect the exact deletion scope with the default dry-run:

```bash
health-bridge receiver purge --db ~/.local/share/health-bridge/health.sqlite
```

Run the same command with `--confirm` only after reviewing the listed database and SQLite sidecars. Confirmation is refused while the receiver is still using the database. This removes the local bridge copy and does not delete Apple Health data. Empty private `.lifecycle.lock` and `.access.lock` coordination files and a private `.purge-*` directory containing zero-byte tomb files may remain; they contain no health records.

If the command returns `recovery-required`, do not restart the receiver. Review the structured source, quarantine, and truncated path lists; the command deliberately keeps the private quarantine instead of claiming a rollback after an irreversible partial purge.

## Component versions and releases

The repository contains independently released components. Always include the component label rather than referring to an unlabeled “repo version.”

| Surface | Source candidate | Identifier |
| --- | --- | --- |
| Receiver/CLI | `1.1.3` | planned signed tag `receiver-v1.1.3` |
| iOS Companion | `1.1.2` | source candidate build `62`, not yet published |
| Batch Protocol | `1.0.0` | `health_bridge.batch.v1` |

This source candidate is a coordinated Receiver/CLI 1.1.3 and Companion 1.1.2/build 62 release; the published companion remains 1.1.1 until Apple distribution is verified. These numbers do not need to match. Receiver-only fixes must not force an unchanged iOS Companion update, and compatible product patches must not bump the Batch Protocol. The canonical machine-readable mapping is [`component-versions.json`](component-versions.json); see the complete [versioning and compatibility policy](docs/versioning.md).

User installs are pinned to a signed Receiver/CLI release tag instead of the moving `main` branch. Each GitHub Release publishes the exact-tag wheel and source archive together with the signed mailbox helper and its public manifest, SHA-256 checksums, build provenance, and metadata that ties the Receiver/CLI, compatible iOS Companion, helper source tree, Git tree, and Batch Protocol together. Existing `v1.0.0`, `v1.0.1`, and `receiver-v1.1.0` releases remain immutable; current and future receiver releases use component-scoped tags such as `receiver-v1.1.2`.

## Build from source

The App Store is the normal iPhone installation path. TestFlight is reserved for beta builds. Contributors and advanced users can build with Xcode 16 or later by following [docs/self-build.md](docs/self-build.md).

## Documentation

- [Setup](docs/setup.md)
- [Supported health data](docs/supported-health-data.md)
- [Architecture and trust boundaries](docs/architecture.md)
- [Brand guide](docs/brand.md)
- [Batch contract](docs/reference/batch-v1.md)
- [SQLite schema](docs/reference/sqlite-v1.md)
- [Build the iOS app](docs/self-build.md)
- [Contribution ideas](docs/contribution-ideas.md)
- [Support routes](SUPPORT.md)
- [Maintainer workflow](docs/maintainer-guide.md)

## Development

```bash
uv sync --all-extras --dev --locked
uv run pytest -q
uv run ruff check .
uv run basedpyright
```

Synthetic fixtures and smoke commands are contributor tools, not part of user onboarding. See [CONTRIBUTING.md](CONTRIBUTING.md).

Apple Health AI Bridge is an independent open-source project and is not affiliated with, endorsed by, or sponsored by Apple Inc.

## License

Apache-2.0. See [LICENSE](LICENSE).
