# Agent-assisted Health Bridge setup

Use the [setup guide](setup.md) as the single receiver installation and phone-handoff reference. The supervised receiver setup described there is an unreleased candidate whose Direct/Tailscale path retains Companion 1.1.1 compatibility; iCloud-native first pairing needs the updated companion and matching signed helper; public `receiver-v1.1.2` users must use its linked version-pinned guide instead. Do not invent a working npm/PyPI install command for an unpublished package.

## Start with the requested outcome

If the user asks to **read existing data**, use the installed [Health Bridge Skill](../skills/health-bridge/SKILL.md) and read-only CLI on the receiver computer. Start with `health-bridge status --json` and `health-bridge query synced-metrics`. Setup remembers the database. An existing approved SSH connection can be used when the agent runs elsewhere; missing access is not permission to move or recreate the receiver.

If the user asks to **install or connect the bridge**, inspect the host, existing receiver and private route first. Prefer the working setup already present. Preview the bounded installation/service/network changes once and obtain approval before executing them; do not turn that into a second configuration wizard.

## Run the shared setup path

After the chosen candidate installation, `health-bridge setup` explicitly creates or reuses the supervised per-user receiver and remembers its database. The default discovers an existing logged-in Tailscale installation and prepares private Serve. An explicitly supplied working `--receiver-url` preserves that ingress; the CLI does not select or install a tunnel provider for the user.

Tailscale is the connection app on both the computer and iPhone: use the same account and keep it enabled on the iPhone. On a Mac, the iCloud choice reuses a matching helper and its known Documents folder. Missing helpers can be installed only from user-selected matching signed release files with explicit approval; the 1.1.3 helper assets are not publicly available yet. Return to connection choices or pause when those files are unavailable. The candidate uses iCloud for first pairing as well as data delivery, without a phone-facing receiver URL. This path requires the updated companion; the currently published app does not implement it. Do not ask users to reconstruct flags for information guided setup already discovers.

Follow the printed private connection URL. The same page handles QR or same-iPhone opening, app installation and return, pairing and a confirmed health-data upload with observations still stored. Progress is available only until the original invitation expiry and while the redeemed device/token remain active. For later checks, rerun the same setup invocation or read the remembered database. Do not report localhost reachability or an accepted empty batch as successful iPhone delivery.

The user installs or keeps the compatible companion, opens/scans the connection page and chooses Apple Health read permissions through **Allow Health Access**, then turns on **Automatic Sync** for ongoing delivery. It starts OFF; **Sync Now** is only an optional immediate test. Those phone actions cannot be replaced by a synthetic upload. Existing paired-device identity and stored health data remain intact.

## Boundaries

- Treat actual package installation, persistent services, client registration, pairing changes, network exposure and data removal as scoped mutations, not read-only discovery. Ask only for approval needed by the next actual change.
- The agent must not create a provider account, activate a paid plan, accept terms, start a trial or incur charges without previewing the effect and obtaining explicit approval for each account/billing action. Existing login is not approval.
- Never install, re-sign or access a personal iPhone merely to make a QA gate pass. Signing, trust and Health permission prompts remain user-owned.
- Keep private connection links, QR codes, credentials, database paths and raw health values out of public reports. Summarize stored coverage and actual observation dates.
- Do not reset data, replace a connection, modify queues/cursors or turn Automatic Sync on to repair a read request. Missing observations are not zero activity.

Synthetic contributor checks live in [CONTRIBUTING.md](../CONTRIBUTING.md); app builds and signed-device handoff live in [self-build.md](self-build.md). Reuse those references instead of adding an agent-specific installation stack. MCP remains optional and read-only.
