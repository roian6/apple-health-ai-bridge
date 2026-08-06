import SwiftUI

@main
struct HealthBridgeCompanionMailboxQAApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let invocation = MailboxQAInvocation()

    private var launchInvocationURL: URL? {
        let process = ProcessInfo.processInfo
        if let rawURL = process.environment["HEALTH_BRIDGE_QA_INVOCATION_URL"],
           let url = URL(string: rawURL) {
            return url
        }
        guard let marker = process.arguments.firstIndex(
            of: "health-bridge-qa-invocation-url"
        ), process.arguments.indices.contains(marker + 1) else {
            return nil
        }
        return URL(string: process.arguments[marker + 1])
    }

    var body: some Scene {
        WindowGroup {
            MailboxQARunnerView(
                invocation: invocation
            )
            .task {
                guard let url = launchInvocationURL else { return }
                await invocation.handle(url)
            }
            .onOpenURL { url in
                Task {
                    await invocation.handle(url)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active || phase == .background else {
                    return
                }
                Task {
                    await invocation.observeLifecycle(
                        foreground: phase == .active
                    )
                }
            }
        }
    }
}

private struct MailboxQARunnerView: View {
    let invocation: MailboxQAInvocation
    @State private var status = "Ready"
    @State private var cloudProbeStatus = "checking"

    var body: some View {
        VStack(spacing: 20) {
            Text("Mailbox QA")
                .font(.headline)
            Button("Run QA Action") {
                Task { await runStagedInvocation() }
            }
            .buttonStyle(.borderedProminent)
            Text(status)
                .font(.caption)
                .accessibilityIdentifier("MailboxQAStatus")
            Text("Mac marker: \(cloudProbeStatus)")
                .font(.caption.monospaced())
                .accessibilityIdentifier("MailboxQACloudProbeStatus")
            Button("Refresh iCloud Probe") {
                Task { await refreshCloudProbe() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .task {
            await refreshCloudProbe()
        }
    }

    @MainActor
    private func refreshCloudProbe() async {
        defer { persistCloudProbeStatus() }
        do {
            let configuration = try MailboxQAConfiguration.load()
            let containerIdentifier = configuration.containerIdentifier
            cloudProbeStatus = await Task.detached(priority: .utility) {
                do {
                    guard let root = FileManager.default.url(
                        forUbiquityContainerIdentifier: containerIdentifier
                    ) else {
                        return "container unavailable"
                    }
                    let marker = root
                        .appendingPathComponent("Documents", isDirectory: true)
                        .appendingPathComponent("MailboxQAMacRegistrarProbe.txt")
                    guard FileManager.default.fileExists(atPath: marker.path) else {
                        return "missing"
                    }
                    let values = try marker.resourceValues(
                        forKeys: [.isUbiquitousItemKey]
                    )
                    return values.isUbiquitousItem == true
                        ? "visible"
                        : "visible non-ubiquitous"
                } catch {
                    let nsError = error as NSError
                    return "error \(nsError.domain) \(nsError.code)"
                }
            }.value
        } catch {
            let nsError = error as NSError
            cloudProbeStatus = "error \(nsError.domain) \(nsError.code)"
        }
    }

    private func persistCloudProbeStatus() {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        do {
            try FileManager.default.createDirectory(
                at: support,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data((cloudProbeStatus + "\n").utf8).write(
                to: support.appendingPathComponent("MailboxQACloudProbeStatus.txt"),
                options: .atomic
            )
        } catch {
            return
        }
    }

    @MainActor
    private func runStagedInvocation() async {
        do {
            let file = try stagedInvocationURLFile()
            let encoded = try String(contentsOf: file, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: encoded) else {
                status = "No pending action"
                return
            }
            try FileManager.default.removeItem(at: file)
            status = "Running"
            let outcome = await invocation.handle(url)
            if outcome.succeeded {
                status = "Complete · \(outcome.status)"
            } else {
                status = "Failed · \(outcome.stage ?? "unknown") · \(outcome.errorCode ?? -1)"
            }
        } catch {
            status = "No pending action"
        }
    }

    private func stagedInvocationURLFile() throws -> URL {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw MailboxQAInvocationError.identityMismatch
        }
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return support.appendingPathComponent("MailboxQAPendingInvocation.url")
    }
}
