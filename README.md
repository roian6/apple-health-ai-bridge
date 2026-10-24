<div align="center">
  <img src="assets/brand/health-bridge-mark-512.png" alt="" width="80">
  <h1>Apple Health AI Bridge</h1>
  <p>Bring Apple Health into your AI workflow.</p>
  <p>
    <a href="https://github.com/roian6/apple-health-ai-bridge/releases"><img src="https://img.shields.io/github/v/release/roian6/apple-health-ai-bridge?filter=receiver-v%2A&amp;label=Receiver&amp;style=flat-square" alt="Receiver release" height="20"></a>
    <a href="https://scorecard.dev/viewer/?uri=github.com/roian6/apple-health-ai-bridge"><img src="https://api.scorecard.dev/projects/github.com/roian6/apple-health-ai-bridge/badge" alt="OpenSSF Scorecard" height="20"></a>
    <a href="https://www.bestpractices.dev/en/projects/15671"><img src="https://www.bestpractices.dev/projects/15671/badge" alt="OpenSSF Best Practices" height="20"></a>
    <a href="https://glama.ai/mcp/servers/roian6/apple-health-ai-bridge"><img src="https://glama.ai/mcp/servers/roian6/apple-health-ai-bridge/badges/score.svg" alt="Glama tool quality and maintenance" width="110" height="20"></a>
  </p>
  <p>
    <a href="#get-started"><strong>Quickstart</strong></a> ·
    <a href="#documentation">Documentation</a> ·
    <a href="docs/examples/weekly-review.md">Examples</a> ·
    <a href="https://healthbridge.chanhyo.dev/">Website</a>
  </p>
  <p>
    <a href="https://apps.apple.com/us/app/health-bridge-for-ai/id6786152806"><img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" height="40"></a>
  </p>
</div>

---

Apple Health AI Bridge connects Apple Health to MCP-compatible assistants. The iPhone app syncs the records you allow to your own computer, where your AI can query sleep, workouts, activity, and more.

> Before we plan next week, what did my sleep and workouts actually look like?

Automatic sync brings new records into the same local history, without another export. Use it in the assistant you prefer or in your own agent workflows; your data isn't tied to a single AI provider.

## Get started

You'll need an **iPhone running iOS 18 or later**, a **macOS or Linux computer** that can stay awake to receive records, and an AI assistant.

1. **Install the app.** Download [the iPhone app from the App Store](https://apps.apple.com/us/app/health-bridge-for-ai/id6786152806).
2. **Set up the receiver.** Follow the [setup guide](docs/setup.md), including a private HTTPS route for sync away from home.
3. **Pair your iPhone.** [Scan the pairing QR](docs/setup.md#pair-the-iphone), review Apple's Health permissions, and enable **Automatic Sync**.
4. **Connect your AI.** [Choose your client](#choose-your-ai), then [ask your first question](docs/setup.md#ask-your-first-question).

## Choose your AI

Find your assistant's setup guide below.

<table width="100%">
<tr>
<td width="50%" align="center"><a href="docs/clients.md#antigravity-cli"><img src="assets/clients/antigravity.svg" alt="" width="24" height="24"><br>Antigravity CLI</a></td>
<td width="50%" align="center"><a href="docs/clients.md#claude-code"><img src="assets/clients/claude-code-mark.svg" alt="" width="24" height="24"><br>Claude Code</a></td>
</tr>
<tr>
<td width="50%" align="center"><a href="docs/clients.md#claude-desktop"><img src="assets/clients/claude-desktop-mark.svg" alt="" width="24" height="24"><br>Claude Desktop</a></td>
<td width="50%" align="center"><a href="docs/clients.md#codex-cli"><img src="assets/clients/codex-openai-mark.svg" alt="" width="24" height="24"><br>Codex CLI</a></td>
</tr>
<tr>
<td width="50%" align="center"><a href="docs/clients.md#cursor"><picture><source media="(prefers-color-scheme: dark)" srcset="assets/clients/cursor-cube-2d-dark.svg"><img src="assets/clients/cursor-cube-2d-light.svg" alt="" width="21" height="24"></picture><br>Cursor</a></td>
<td width="50%" align="center"><a href="docs/clients.md#hermes-agent"><img src="assets/clients/hermes-agent.svg" alt="" width="24" height="24"><br>Hermes Agent</a></td>
</tr>
<tr>
<td width="50%" align="center"><a href="docs/clients.md#openclaw-manual-configuration"><img src="assets/clients/openclaw.svg" alt="" width="24" height="24"><br>OpenClaw</a></td>
<td width="50%" align="center"><a href="docs/clients.md#opencode"><picture><source media="(prefers-color-scheme: dark)" srcset="assets/clients/opencode-logo-dark.svg"><img src="assets/clients/opencode-logo-light.svg" alt="" width="19" height="24"></picture><br>OpenCode</a></td>
</tr>
<tr>
<td width="50%" align="center"><a href="docs/clients.md#vs-code-local-format"><img src="assets/clients/vscode.svg" alt="" width="24" height="24"><br>Visual Studio Code</a></td>
<td width="50%" align="center"><a href="docs/setup.md#connect-an-mcp-client-intentionally">And more</a></td>
</tr>
</table>

## Supported data

Sleep, workouts, steps and energy, heart-rate measurements, weight, and body composition are supported. The [full data catalog](docs/supported-health-data.md) lists individual record types and their availability.

## Privacy

Health access and MCP queries are **read-only**. The receiver stores your records on your computer, and you decide which clients can query them.

When you use a cloud model, the query results your client sends go to that model provider. Its privacy settings and policies apply.

[Privacy policy](https://healthbridge.chanhyo.dev/privacy) · [Security model](SECURITY.md) · [Remove local data](docs/setup.md#remove-local-bridge-data)

## Documentation

- **Install and use:** [Setup and troubleshooting](docs/setup.md) · [Supported data](docs/supported-health-data.md) · [Support](https://healthbridge.chanhyo.dev/support)
- **Understand and build:** [Architecture](docs/architecture.md) · [Compatibility](docs/versioning.md) · [Batch protocol](docs/reference/batch-v1.md) · [SQLite schema](docs/reference/sqlite-v1.md) · [Brand guide](docs/brand.md)
- **Contribute:** [Development setup](CONTRIBUTING.md) · [Contribution ideas](docs/contribution-ideas.md) · [Build the iPhone app](docs/self-build.md)

## License

<a href="LICENSE"><img src="https://img.shields.io/github/license/roian6/apple-health-ai-bridge?label=&amp;style=flat-square" alt="License: Apache-2.0" height="20"></a>

Apple Health AI Bridge is an independent open-source project and is not affiliated with, endorsed by, or sponsored by Apple Inc.
