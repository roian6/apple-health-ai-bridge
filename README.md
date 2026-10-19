<div align="center">
  <img src="assets/brand/health-bridge-mark-512.png" alt="" width="80">
  <h1>Apple Health AI Bridge</h1>
  <p>Put your Apple Health history to work in your own AI assistant.</p>
  <p>
    <a href="https://apps.apple.com/us/app/health-bridge-for-ai/id6786152806"><img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" height="40"></a>
  </p>
  <p>
    <a href="#get-started">Get started</a> ·
    <a href="docs/supported-health-data.md">Supported data</a> ·
    <a href="https://healthbridge.chanhyo.dev/">Website</a>
  </p>
  <p>
    <a href="https://github.com/roian6/apple-health-ai-bridge/releases"><img src="https://img.shields.io/github/v/release/roian6/apple-health-ai-bridge?filter=receiver-v%2A&amp;label=release&amp;style=flat-square" alt="Receiver release" height="20"></a>
    <a href="https://github.com/roian6/apple-health-ai-bridge/actions/workflows/python.yml"><img src="https://img.shields.io/github/actions/workflow/status/roian6/apple-health-ai-bridge/python.yml?branch=main&amp;label=Python%20CI&amp;style=flat-square" alt="Python CI" height="20"></a>
    <a href="https://github.com/roian6/apple-health-ai-bridge/actions/workflows/ios.yml"><img src="https://img.shields.io/github/actions/workflow/status/roian6/apple-health-ai-bridge/ios.yml?branch=main&amp;label=iOS%20CI&amp;style=flat-square" alt="iOS CI" height="20"></a>
    <a href="LICENSE"><img src="https://img.shields.io/github/license/roian6/apple-health-ai-bridge?style=flat-square" alt="License: Apache-2.0" height="20"></a>
    <a href="https://glama.ai/mcp/servers/roian6/apple-health-ai-bridge"><img src="https://glama.ai/mcp/servers/roian6/apple-health-ai-bridge/badges/score.svg" alt="Glama tool quality and maintenance" width="110" height="20"></a>
    <a href="https://scorecard.dev/viewer/?uri=github.com/roian6/apple-health-ai-bridge"><img src="https://api.scorecard.dev/projects/github.com/roian6/apple-health-ai-bridge/badge" alt="OpenSSF Scorecard" height="20"></a>
  </p>
</div>

---

Your iPhone already has a record of how you've been sleeping, moving, and training. Bring that history into the AI conversations where you review your week and plan what comes next.

Apple Health AI Bridge is an open-source connector for MCP-enabled assistants. The iPhone app sends the records you allow to a macOS or Linux computer you control. Automatic sync brings in new records, so you can keep the conversation going without preparing another export.

## Review your week with the records in view

Pull sleep, activity, and workouts into the same conversation. Compare weeks, look at a change, and ask follow-up questions instead of piecing together separate charts and screenshots.

> I'm planning next week's routine. How did my sleep and workouts change over the last two weeks?

| Recorded history | June 1–7 | June 8–14 |
| --- | --- | --- |
| Average sleep per night | 7h 24m | 6h 42m |
| Workouts | 4 · 160 minutes | 2 · 80 minutes |

The second week's workouts both fell on the weekend, while average sleep was 42 minutes shorter. Bring that pattern into the next question: which weekdays have room for the routine you want to keep?

*Example using [synthetic records and reproducible queries](docs/examples/weekly-review.md).*

## Start your next goals with what you actually did

When you discuss a new routine with your assistant, give it your recent history to work with. Use the records alongside the goals and constraints you bring to the conversation.

> Before we discuss next week's training goals, look at what I actually did over the last four weeks.

## Why run your own bridge?

Use your health history in the personal AI workflows you're already building. Connect an assistant that also helps with your routines and plans, and keep a store of the records on your own computer.

- Choose which MCP clients can read your history, rather than committing the bridge to one AI provider.
- Store the data on your Mac or Linux computer, with read-only tools for sleep, workouts, daily summaries, and individual measurements.
- Build your own reviews and agent workflows on the same history as new records arrive.

## Get started

You need an iPhone running iOS 18 or later, a macOS or Linux computer that can stay awake and connected, and an MCP client on that computer. The computer runs the receiver and stores your health history.

### 1. Install the iPhone app

Download [the iPhone app from the App Store](https://apps.apple.com/us/app/health-bridge-for-ai/id6786152806).

### 2. Set up your receiver

Install the Receiver/CLI with [`uv`](https://docs.astral.sh/uv/):

```bash
uv tool install "git+https://github.com/roian6/apple-health-ai-bridge.git@receiver-v1.1.2"
```

Follow the [setup guide](docs/setup.md) to prepare a private HTTPS route, start the receiver, and verify the connection from your iPhone. This keeps the receiver reachable when you're away from home. The guide also covers a deliberate same-LAN installation and the separate [macOS iCloud delivery Beta](docs/icloud-mailbox-service.md).

### 3. Pair and sync

[Pair the iPhone](docs/setup.md#pair-the-iphone), review Apple's Health permissions, and enable **Automatic Sync**.

### 4. Connect your AI and ask

[Add the bridge to your MCP client](docs/setup.md#connect-an-mcp-client-intentionally), then [check your records and ask your first question](docs/setup.md#ask-your-first-question). If your phone is already paired, you can add the client using your existing database.

## Supported data

The catalog includes sleep, workouts, activity such as steps and energy, heart-rate measurements, weight, and body composition. See the [complete supported data list](docs/supported-health-data.md) for the types available to the app and the permissions you control in Apple Health.

The MCP tools let your assistant retrieve time-series observations, workouts, sleep and daily summaries, and the sources behind those records. See the [architecture reference](docs/architecture.md#agent-boundary) for the tool surface.

## Privacy

Apple Health access and the MCP query tools are read-only. You run the receiver and choose which AI clients can read the stored history. When a client uses a cloud model, its provider receives the query results it sends; that client's settings and policies apply.

Read the [privacy policy](https://healthbridge.chanhyo.dev/privacy) and [security model](SECURITY.md) for the full data-handling boundaries. For help removing your local copy, see [Remove local bridge data](docs/setup.md#remove-local-bridge-data).

## Documentation

- **Install and use:** [Setup and troubleshooting](docs/setup.md) · [Supported data](docs/supported-health-data.md) · [Support](https://healthbridge.chanhyo.dev/support)
- **Understand and build:** [Architecture](docs/architecture.md) · [Batch protocol](docs/reference/batch-v1.md) · [SQLite schema](docs/reference/sqlite-v1.md) · [Brand guide](docs/brand.md)
- **Contribute:** [Development setup](CONTRIBUTING.md) · [Contribution ideas](docs/contribution-ideas.md) · [Build the iPhone app with Xcode 16 or later](docs/self-build.md)

Current components: **Receiver/CLI** `1.1.2` · **iOS Companion** `1.1.1` (build `50`) · **Batch Protocol** `1.0.0`. See [release downloads](https://github.com/roian6/apple-health-ai-bridge/releases/tag/receiver-v1.1.2), [`component-versions.json`](component-versions.json), and the [compatibility policy](docs/versioning.md).

## License

[Apache-2.0](LICENSE).

Apple Health AI Bridge is an independent open-source project and is not affiliated with, endorsed by, or sponsored by Apple Inc.
