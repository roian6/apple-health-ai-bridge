import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel: HealthBridgeCompanionViewModel
    @State private var showPendingPairingCancellationConfirmation = false

    init(viewModel: HealthBridgeCompanionViewModel = HealthBridgeCompanionViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HealthBridgeSpacing.section) {
                    header
                    statusCard

                    if viewModel.hasPendingPairing {
                        pairingRecoveryCard
                    }

                    if viewModel.setupState == .unpaired {
                        pairingCard
                    } else if !viewModel.healthPermissionsRequested {
                        healthAccessCard
                    } else {
                        syncControlCard
                    }

                    detailsSection
                }
                .padding(.horizontal, HealthBridgeSpacing.screen)
                .padding(.top, 28)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Health Bridge")
                .font(.system(size: 36, weight: .bold, design: .rounded))
            Text("Sync Apple Health data from this iPhone to your own local server.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusCard: some View {
        HStack(alignment: .center, spacing: 16) {
            statusGlyph
            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.title2.weight(.bold))
                Text(statusSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .cardStyle(cornerRadius: 28)
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Connect Health Bridge",
                subtitle: "Scan the private QR with iPhone Camera, open its setup link, or paste it here. After pairing, the secret key stays on this iPhone."
            )

            TextField("Paste private setup link", text: $viewModel.pairingImportText, axis: .vertical)
                .lineLimit(2...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body)
                .padding(14)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            PrimaryButton(
                title: "Connect",
                subtitle: "Redeem this one-time invitation",
                systemImage: "link.badge.plus",
                tint: .accentColor,
                isDisabled: !viewModel.canImportPairingText,
                isLoading: viewModel.isPairing
            ) {
                Task { await viewModel.importPairingText() }
            }

            Divider()

            DisclosureGroup {
                manualPairingFields
                    .padding(.top, 12)
            } label: {
                Text("Use a code instead")
                    .font(.headline)
            }
        }
        .cardStyle()
    }

    private var pairingRecoveryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pairing Recovery Pending", systemImage: "exclamationmark.shield.fill")
                .font(.headline)
            Text("Automatic sync is paused. Retry the saved attempt after fixing the route, or clear it before opening a different setup link.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Retry Pairing") {
                Task {
                    await viewModel.retryPendingPairing()
                }
            }
            .disabled(viewModel.isPairing)
            Button("Clear Pending Pairing and Disconnect", role: .destructive) {
                showPendingPairingCancellationConfirmation = true
            }
            .disabled(viewModel.isPairing)
        }
        .cardStyle()
        .confirmationDialog(
            "Clear pending pairing and disconnect?",
            isPresented: $showPendingPairingCancellationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Pending Pairing and Disconnect", role: .destructive) {
                Task {
                    await viewModel.cancelPendingPairing()
                }
            }
            Button("Keep Pending Pairing", role: .cancel) {}
        } message: {
            Text("This removes the pending invitation and also removes the currently saved connection. Apple Health data is not deleted.")
        }
    }

    private var manualPairingFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Server address", text: $viewModel.manualPairingServer)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            TextField("Invitation code", text: $viewModel.manualPairingCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            PrimaryButton(
                title: "Connect with Code",
                subtitle: "Codes expire and work only once",
                systemImage: "number.square.fill",
                tint: .blue,
                isDisabled: !viewModel.canRedeemManualPairing,
                isLoading: viewModel.isPairing
            ) {
                Task { await viewModel.redeemManualPairing() }
            }
        }
    }

    private var healthAccessCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Apple Health Access",
                subtitle: "Use Apple Health's permission screen to choose what this iPhone can share."
            )

            Text("Health Bridge requests read-only access for every supported type currently available on this iPhone. Choose exactly what to allow in Apple Health.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(viewModel.healthPermissionScopeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PrimaryButton(
                title: viewModel.healthPermissionsRequested ? "Review Permissions" : "Allow Health Access",
                subtitle: "Opens Apple Health permission sheet",
                systemImage: "checkmark.shield.fill",
                tint: .green,
                isDisabled: false,
                isLoading: viewModel.isRequestingHealthPermissions
            ) {
                Task { await viewModel.requestHealthPermissions() }
            }

            if !viewModel.healthPermissionNotice.isEmpty {
                InlineNotice(
                    message: viewModel.healthPermissionNotice,
                    systemImage: viewModel.healthPermissionNoticeIsError ? "exclamationmark.triangle.fill" : "info.circle.fill",
                    tint: viewModel.healthPermissionNoticeIsError ? .orange : .blue
                )
            }
        }
        .cardStyle()
    }

    private var syncControlCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Sync",
                subtitle: "Send allowed Apple Health data to your local server."
            )

            PrimaryButton(
                title: "Sync Now",
                subtitle: syncActionSubtitle,
                systemImage: viewModel.isSyncing ? "arrow.triangle.2.circlepath" : "arrow.up.arrow.down.circle.fill",
                tint: .indigo,
                isDisabled: !viewModel.canRunPrimaryAction,
                isLoading: viewModel.isSyncing
            ) {
                Task { await viewModel.performPrimaryAction() }
            }

            if viewModel.isSyncing {
                PrimaryButton(
                    title: "Cancel",
                    subtitle: "Stop this sync. Already queued uploads are kept.",
                    systemImage: "xmark.circle.fill",
                    tint: .orange,
                    isDisabled: false
                ) {
                    Task { await viewModel.cancelCurrentForegroundAction() }
                }
            }

            Divider()

            CompactSettingRow(
                title: "Sync Range",
                systemImage: "clock.arrow.circlepath",
                tint: .purple
            ) {
                Picker("Sync Range", selection: Binding(
                    get: { viewModel.healthHistoryDepthOptionID },
                    set: { viewModel.setHealthHistoryDepthOption($0) }
                )) {
                    ForEach(viewModel.healthHistoryDepthRows) { row in
                        Text(row.title).tag(row.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            Divider()

            Toggle(isOn: Binding(
                get: { viewModel.automaticSyncToggleIsOn },
                set: { enabled in
                    viewModel.requestBackgroundSyncEnabled(enabled)
                }
            )) {
                SettingRowLabel(
                    title: "Automatic Sync",
                    subtitle: viewModel.automaticSyncScopeSummary,
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: .green
                )
            }
            .disabled(!viewModel.canChangeAutomaticSyncSetting)
        }
        .cardStyle()
    }

    private var detailsSection: some View {
        NavigationLink {
            AppDetailsView(viewModel: viewModel)
        } label: {
            CardRow(
                title: "Settings",
                subtitle: viewModel.pendingOutboxCount > 0 || viewModel.statusIsError ? "Connection and sync status" : "Connection and app details",
                systemImage: "gearshape.fill",
                tint: .orange
            )
        }
        .buttonStyle(.plain)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var statusGlyph: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.16))
                .frame(width: 76, height: 76)
            Circle()
                .fill(statusColor)
                .frame(width: 58, height: 58)
            Image(systemName: statusSymbol)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var statusTitle: String {
        if viewModel.hasPendingPrivateStorageRecovery { return "Recovery Required" }
        if !viewModel.canSendConnectionTest && viewModel.pendingOutboxCount > 0 { return "Queued Uploads Waiting" }
        if viewModel.statusIsError { return syncErrorTitle }
        if !viewModel.canSendConnectionTest { return "Not Connected" }
        if viewModel.isSyncing { return "Syncing" }
        if viewModel.pendingOutboxCount > 0 { return "Waiting to Send" }
        if viewModel.backgroundSyncEnabled { return "Ready to Sync" }
        if viewModel.healthPermissionsRequested { return "Ready to Sync" }
        return "Allow Health Access"
    }

    private var statusSubtitle: String {
        if viewModel.hasPendingPrivateStorageRecovery {
            return "Open Settings, reset private sync state, then pair this iPhone again."
        }
        if !viewModel.canSendConnectionTest && viewModel.pendingOutboxCount > 0 {
            return "Queued uploads remain on this iPhone. Reconnect from setup link to retry them."
        }
        if viewModel.statusIsError { return userFacingStatusMessage }
        if !viewModel.canSendConnectionTest { return "Connect this iPhone before syncing." }
        if viewModel.setupState == .pairedNeedsHealthPermission { return "Open Apple Health and allow the data you want to sync." }
        if viewModel.pendingOutboxCount > 0 { return "\(viewModel.pendingOutboxCount) pending sync item(s) will send when Health Bridge is reachable." }
        if viewModel.backgroundSyncEnabled { return viewModel.automaticSyncScopeSummary }
        return "Use Sync Now to update your allowed Apple Health data."
    }

    private var syncErrorTitle: String {
        let message = viewModel.statusMessage.lowercased()
        if message.contains("sync") || message.contains("queued upload") || message.contains("outbox") {
            return "Sync Failed"
        }
        if message.contains("connection") || message.contains("bridge") || message.contains("receiver") {
            return "Connection Failed"
        }
        return "Needs Attention"
    }

    private var statusColor: Color {
        if !viewModel.canSendConnectionTest && viewModel.pendingOutboxCount > 0 { return .orange }
        if viewModel.statusIsError || !viewModel.canSendConnectionTest { return .red }
        if viewModel.pendingOutboxCount > 0 { return .orange }
        if viewModel.isSyncing || viewModel.backgroundSyncEnabled || viewModel.healthPermissionsRequested { return .green }
        return .orange
    }

    private var statusSymbol: String {
        if !viewModel.canSendConnectionTest && viewModel.pendingOutboxCount > 0 { return "exclamationmark" }
        if !viewModel.canSendConnectionTest { return "xmark" }
        if viewModel.statusIsError || viewModel.pendingOutboxCount > 0 { return "exclamationmark" }
        if viewModel.isSyncing { return "arrow.triangle.2.circlepath" }
        if viewModel.healthPermissionsRequested || viewModel.backgroundSyncEnabled { return "checkmark" }
        return "heart.text.square"
    }

    private var syncActionSubtitle: String {
        if viewModel.setupState == .pairedNeedsHealthPermission {
            return "Choose data in Apple Health first"
        }
        if viewModel.setupState == .degraded {
            return "Run a manual update"
        }
        return "Send allowed Health data to your server"
    }

    private var userFacingStatusMessage: String {
        CompanionPrimaryStatusMessage.sanitized(
            from: viewModel.statusMessage,
            isError: viewModel.statusIsError
        )
    }
}

private struct ReceiverSettingsView: View {
    @ObservedObject var viewModel: HealthBridgeCompanionViewModel
    @State private var showDisconnectConfirmation = false
    @State private var showDisconnectFailureAlert = false
    @State private var disconnectFailureMessage = ""
    @State private var showClearQueuedUploadsConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HealthBridgeSpacing.section) {
                SectionHeader(
                    title: "Connection",
                    subtitle: "Use the private setup link from your computer. Manual setup is only a fallback."
                )
                .padding(.horizontal, HealthBridgeSpacing.screen)

                connectionStatusCard
                    .padding(.horizontal, HealthBridgeSpacing.screen)

                setupLinkCard
                    .padding(.horizontal, HealthBridgeSpacing.screen)

                if !viewModel.receiverSettingsSaved {
                    manualSettingsCard
                        .padding(.horizontal, HealthBridgeSpacing.screen)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Disconnect from server?", isPresented: $showDisconnectConfirmation, titleVisibility: .visible) {
            Button("Disconnect from Server", role: .destructive) {
                Task {
                    let outcome = await viewModel.disconnectReceiver()
                    switch outcome {
                    case .disconnected:
                        break
                    case .rejected(let message, let pendingOutboxCount, let connectionPreserved):
                        if connectionPreserved, let pendingOutboxCount, pendingOutboxCount > 0 {
                            disconnectFailureMessage = "Queued uploads are waiting on this iPhone. Bring the server back and tap Sync Now to send them, or use Reset Private Sync State in Settings to discard them and rebuild local sync history before disconnecting."
                        } else if connectionPreserved, pendingOutboxCount == nil {
                            disconnectFailureMessage = "Health Bridge couldn’t verify whether queued uploads remain. Your saved server connection was not removed. Reopen Settings and try again after private storage is available."
                        } else {
                            disconnectFailureMessage = CompanionPrimaryStatusMessage.sanitized(
                                from: message,
                                isError: true
                            )
                        }
                        showDisconnectFailureAlert = true
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved server connection from this iPhone. It does not delete Apple Health data.")
        }
        .alert("Can’t Disconnect Yet", isPresented: $showDisconnectFailureAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(disconnectFailureMessage)
        }
        .confirmationDialog("Reset private sync state?", isPresented: $showClearQueuedUploadsConfirmation, titleVisibility: .visible) {
            Button("Reset Private Sync State", role: .destructive) {
                Task { await viewModel.clearPendingOutbox() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes unsent local Health payloads and resets local sync cursors so the next connection rebuilds receiver history. If the saved connection is unreadable, it is also removed. Apple Health data itself is not deleted.")
        }
    }

    private var connectionIsReachable: Bool {
        let message = viewModel.statusMessage.lowercased()
        return !viewModel.statusIsError
            && (message.contains("connection check passed")
                || message.contains("health bridge connected")
                || message.contains("local bridge verified")
                || message.contains("connected to local bridge"))
    }

    private var connectionNotice: String {
        let rawMessage = viewModel.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = rawMessage.lowercased()
        guard !rawMessage.isEmpty else { return "" }
        guard !message.contains("permission"), !message.contains("apple health") else { return "" }
        guard message.contains("connection")
            || message.contains("receiver")
            || message.contains("bridge url")
            || message.contains("local bridge")
            || message.contains("setup link")
            || message.contains("disconnect")
            || message.contains("queued upload")
            || message.contains("private sync")
        else {
            return "" }
        return CompanionPrimaryStatusMessage.sanitized(
            from: rawMessage,
            isError: viewModel.statusIsError
        )
    }

    private var connectionStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.canSendConnectionTest ? (connectionIsReachable ? "Server Reachable" : "Connection Saved") : "Not Connected")
                        .font(.headline)
                    Text(viewModel.canSendConnectionTest ? (connectionIsReachable ? "Ready to sync." : "Saved on this iPhone.") : "Use a setup link to connect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: viewModel.canSendConnectionTest ? (connectionIsReachable ? "checkmark.circle.fill" : "link.circle.fill") : "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(viewModel.canSendConnectionTest ? (connectionIsReachable ? .green : .blue) : .red)
            }

            PrimaryButton(
                title: "Check Connection",
                subtitle: "Verify Health Bridge is reachable",
                systemImage: "wifi",
                tint: .blue,
                isDisabled: !viewModel.canSendConnectionTest,
                isLoading: viewModel.isCheckingConnection
            ) {
                Task { await viewModel.checkConnection() }
            }

            if !connectionNotice.isEmpty {
                Label(connectionNotice, systemImage: viewModel.statusIsError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(viewModel.statusIsError ? .orange : .secondary)
                    .padding(.top, 2)
            }

            if viewModel.canSendConnectionTest {
                Button(role: .destructive) {
                    showDisconnectConfirmation = true
                } label: {
                    Label("Disconnect from Server", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if viewModel.hasTransientPrivateStorageFailure {
                Button {
                    Task { await viewModel.retryPrivateStorage() }
                } label: {
                    Label("Retry Private Storage", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if viewModel.pendingOutboxCount > 0
                || viewModel.hasPendingSleepTransition
                || viewModel.hasPendingOutboxDeletion
                || viewModel.hasPendingPrivateStorageRecovery {
                Button(role: .destructive) {
                    showClearQueuedUploadsConfirmation = true
                } label: {
                    Label(
                        viewModel.hasPendingPrivateStorageRecovery
                            ? "Reset Unreadable Private Sync State"
                            : viewModel.hasPendingOutboxDeletion
                            ? "Finish Resetting Private Sync State"
                            : viewModel.pendingOutboxCount > 0
                                ? "Reset Private Sync State (\(viewModel.pendingOutboxCount) queued)"
                                : "Reset Private Sync State",
                        systemImage: "trash"
                    )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .cardStyle()
    }

    private var setupLinkCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: viewModel.canSendConnectionTest ? "Replace Connection" : "Setup Link",
                subtitle: viewModel.canSendConnectionTest ? "Paste a new setup link only if you want to replace this iPhone's saved connection." : "Setup links contain private connection details. Only paste them here. Do not share them in chat or screenshots."
            )
            TextField("Paste private setup link", text: $viewModel.pairingImportText, axis: .vertical)
                .lineLimit(2...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body)
                .padding(14)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            PrimaryButton(
                title: viewModel.canSendConnectionTest ? "Replace Connection" : "Connect from Setup Link",
                subtitle: "Save connection details securely on this iPhone",
                systemImage: "link.badge.plus",
                tint: .accentColor,
                isDisabled: !viewModel.canImportPairingText,
                isLoading: viewModel.isPairing
            ) {
                Task { await viewModel.importPairingText() }
            }
        }
        .cardStyle()
    }

    private var manualSettingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: "Invitation Code",
                subtitle: "If you cannot open the setup link, enter the server address and one-time code shown on the setup page."
            )

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Server address", text: $viewModel.manualPairingServer)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(12)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    TextField("Invitation code", text: $viewModel.manualPairingCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .padding(12)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    PrimaryButton(
                        title: "Connect with Code",
                        subtitle: "Codes expire and work only once",
                        systemImage: "number.square.fill",
                        tint: .blue,
                        isDisabled: !viewModel.canRedeemManualPairing,
                        isLoading: viewModel.isPairing
                    ) {
                        Task { await viewModel.redeemManualPairing() }
                    }
                }
                .padding(.top, 12)
            } label: {
                Text("Use a code instead")
                    .font(.headline)
            }
        }
        .cardStyle()
    }
}

private struct AppDetailsView: View {
    @ObservedObject var viewModel: HealthBridgeCompanionViewModel

    private static let privacyPolicyURL = URL(string: "https://healthbridge.chanhyo.dev/privacy/")!
    private static let supportURL = URL(string: "https://healthbridge.chanhyo.dev/support/")!

    var body: some View {
        List {
            Section("Connection") {
                NavigationLink {
                    ReceiverSettingsView(viewModel: viewModel)
                } label: {
                    Label(viewModel.canSendConnectionTest ? "Connection Saved" : "Set Up Connection", systemImage: "network")
                }
            }

            Section("Health Permissions") {
                Text("Apple Health can ask again when supported types become newly available on this iPhone. To review or change what Health Bridge can read, open the Health app > profile picture > Privacy > Apps > Health Bridge.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Request Health Access Again") {
                    Task { await viewModel.requestHealthPermissions() }
                }
                .disabled(viewModel.isRequestingHealthPermissions)
            }

            Section("Automatic Sync") {
                Text(viewModel.automaticSyncCoverageDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(viewModel.backgroundSyncStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Activity Log") {
                NavigationLink {
                    ActivityLogView(viewModel: viewModel)
                } label: {
                    Label("View Logs", systemImage: "list.bullet.rectangle")
                }
                .disabled(viewModel.activityLogMessages.isEmpty)
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                Link("Privacy Policy", destination: Self.privacyPolicyURL)
                Link("Support", destination: Self.supportURL)
            }
        }
        .navigationTitle("Settings")
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "15"
        return "\(version) (\(build))"
    }
}

private struct ActivityLogView: View {
    @ObservedObject var viewModel: HealthBridgeCompanionViewModel

    var body: some View {
        List {
            if viewModel.activityLogMessages.isEmpty {
                Text("No recent activity yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(viewModel.activityLogMessages.enumerated()), id: \.offset) { _, message in
                    Text(message)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Activity Log")
    }
}

private struct SettingRow<Accessory: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingRowLabel(title: title, subtitle: subtitle, systemImage: systemImage, tint: tint)
            Spacer(minLength: 8)
            accessory()
        }
    }
}

private struct CompactSettingRow<Accessory: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
            Text(title)
                .font(.headline)
            Spacer(minLength: 8)
            accessory()
        }
    }
}

private struct SettingRowLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.bold))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PrimaryButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let isDisabled: Bool
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
                    .font(.headline)
            } icon: {
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: systemImage)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(tint)
        .disabled(isDisabled || isLoading)
        .opacity(isDisabled ? 0.65 : 1)
        .accessibilityHint(subtitle)
    }
}

private struct InlineNotice: View {
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CardRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    var accessory: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let accessory {
                Text(accessory)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(tint.opacity(0.10))
                    .clipShape(Capsule())
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .contentShape(Rectangle())
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 66)
    }
}

private enum HealthBridgeSpacing {
    static let screen: CGFloat = 20
    static let section: CGFloat = 22
}

private extension View {
    func cardStyle(cornerRadius: CGFloat = 24) -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

#Preview {
    ContentView()
}
