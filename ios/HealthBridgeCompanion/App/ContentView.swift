import SwiftUI

struct ContentView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var viewModel: HealthBridgeCompanionViewModel
    @State private var showPendingPairingCancellationConfirmation = false
    @State private var usesManualPairing = false
    @FocusState private var pairingFocus: PairingField?

    private enum PairingField: Hashable {
        case link, server, code
    }

    init(viewModel: HealthBridgeCompanionViewModel = HealthBridgeCompanionViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HealthBridgeSpacing.section) {
                    header
                    if viewModel.syncPresentation.phase != .unpaired
                        && viewModel.syncPresentation.phase != .permissionRequestNeeded
                        && (viewModel.setupState != .unpaired || viewModel.pairingInputError == nil) {
                        statusCard
                    }

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

                    if viewModel.syncPresentation.phase == .ready
                        && viewModel.lastAcceptedTransferObservation != nil {
                        NavigationLink {
                            AIGuideView(viewModel: viewModel)
                        } label: {
                            CardRow(
                                title: "Connect an AI client",
                                subtitle: "Set up your assistant separately",
                                systemImage: "desktopcomputer",
                                tint: .blue
                            )
                        }
                        .buttonStyle(.plain)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }

                    detailsSection
                }
                .padding(.horizontal, HealthBridgeSpacing.screen)
                .padding(.top, 28)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(NotificationCenter.default.publisher(for: LastAcceptedTransferObservationStore.didChange)) { _ in
                viewModel.objectWillChange.send()
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { pairingFocus = nil }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Health Bridge")
                .font(.system(size: 36, weight: .bold, design: .rounded))
            Text("Send Apple Health data to a receiver you control.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusCard: some View {
        HStack(alignment: .center, spacing: 16) {
            if !dynamicTypeSize.isAccessibilitySize {
                statusGlyph
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.syncPresentation.title)
                    .font(.title2.weight(.bold))
                Text(viewModel.syncPresentation.phase == .needsAttention
                    ? (viewModel.pairingInputCorrection ?? viewModel.displayStatusMessage)
                    : viewModel.syncPresentation.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let observation = viewModel.lastAcceptedTransferObservation {
                    Text(observation.evidenceKind == .directResponse
                        ? "Direct response observed" : "Receiver confirmation observed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Text(observation.observedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if viewModel.healthPermissionsRequested && viewModel.canSendConnectionTest {
                    Text("No transfer response recorded for this connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .cardStyle(cornerRadius: 28)
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Connect your receiver",
                subtitle: usesManualPairing
                    ? "Enter the address and code shown by your receiver."
                    : "Open the private setup link from your receiver, or paste it below."
            )

            if usesManualPairing {
                manualPairingFields
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Private setup link")
                        .font(.subheadline.weight(.medium))
                    TextField("Paste setup link", text: $viewModel.pairingImportText, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Private setup link")
                        .focused($pairingFocus, equals: .link)
                        .padding(14)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }

            if let correction = viewModel.pairingInputCorrection {
                InlineNotice(
                    message: correction,
                    systemImage: "exclamationmark.circle.fill",
                    tint: .orange
                )
            }

            PrimaryButton(
                title: "Connect",
                subtitle: "Use your receiver invitation",
                systemImage: "link.badge.plus",
                tint: .accentColor,
                isDisabled: usesManualPairing
                    ? !viewModel.canRedeemManualPairing : !viewModel.canImportPairingText,
                isLoading: viewModel.isPairing
            ) { connectReceiver() }

            Button {
                pairingFocus = nil
                viewModel.dismissPairingInputError()
                usesManualPairing.toggle()
            } label: {
                Text(usesManualPairing ? "Use a setup link" : "Use a code instead")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(viewModel.isPairing)

            Divider()

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Direct connects to a Mac or Linux receiver, including over Tailscale or HTTPS.")
                    Text("Encrypted iCloud Mailbox (Beta) connects to a Mac without a VPN. Delivery is eventual, not immediate.")
                    Text("The setup invitation selects the route. Same-network-only Direct setups have limited reach.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } label: {
                Text("Connection options")
                    .font(.subheadline)
                    .frame(minHeight: 44)
            }
        }
        .cardStyle()
    }

    private var pairingRecoveryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pairing Recovery Pending", systemImage: "exclamationmark.shield.fill")
                .font(.headline)
            Text(
                viewModel.mailboxKeyDiagnosticState == .lost
                    ? "Automatic sync is paused because the mailbox connection key is lost. Clear this pending pairing before using the dedicated key recovery action."
                    : "Automatic sync is paused. Retry the saved attempt after fixing the route, or clear it before opening a different setup link."
            )
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let pairingFailure = viewModel.pairingFailurePresentation {
                InlineNotice(
                    message: pairingFailure.message,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }
            if viewModel.mailboxKeyDiagnosticState != .lost {
                Button("Retry Pairing") {
                    Task {
                        await viewModel.retryPendingPairing()
                    }
                }
                .disabled(viewModel.isPairing)
            }
            Button("Cancel Pending Pairing", role: .destructive) {
                showPendingPairingCancellationConfirmation = true
            }
            .disabled(viewModel.isPairing)
        }
        .cardStyle()
        .confirmationDialog(
            "Cancel pending pairing?",
            isPresented: $showPendingPairingCancellationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel Pending Pairing", role: .destructive) {
                Task {
                    await viewModel.cancelPendingPairing()
                }
            }
            Button("Keep Pending Pairing", role: .cancel) {}
        } message: {
            Text("This cancels the saved pairing attempt and may disconnect the saved receiver. Any required receiver confirmation must finish before cleanup. Apple Health data is not deleted.")
        }
    }

    private var manualPairingFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Server address")
                .font(.subheadline.weight(.medium))
            TextField("https://receiver.example", text: $viewModel.manualPairingServer)
                .accessibilityLabel("Server address")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($pairingFocus, equals: .server)
                .submitLabel(.next)
                .onSubmit { pairingFocus = .code }
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("Invitation code")
                .font(.subheadline.weight(.medium))
            TextField("15-character code", text: $viewModel.manualPairingCode)
                .accessibilityLabel("Invitation code")
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .focused($pairingFocus, equals: .code)
                .submitLabel(.go)
                .onSubmit { connectReceiver() }
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

        }
    }

    private func connectReceiver() {
        guard usesManualPairing ? viewModel.canRedeemManualPairing : viewModel.canImportPairingText else { return }
        let manualPairing = usesManualPairing
        pairingFocus = nil
        Task {
            if manualPairing {
                await viewModel.redeemManualPairing()
            } else {
                await viewModel.importPairingText()
            }
        }
    }

    private var healthAccessCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Choose Health data",
                subtitle: "Choose what this iPhone may share. Health Bridge only reads your data."
            )

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
                subtitle: "Send allowed Apple Health data to your receiver."
            )

            if !viewModel.healthPermissionNotice.isEmpty {
                InlineNotice(
                    message: viewModel.healthPermissionNotice,
                    systemImage: viewModel.healthPermissionNoticeIsError
                        ? "exclamationmark.circle.fill" : "info.circle.fill",
                    tint: viewModel.healthPermissionNoticeIsError ? .orange : .blue
                )
            }

            PrimaryButton(
                title: "Sync Now",
                subtitle: syncActionSubtitle,
                systemImage: viewModel.syncPresentationIsActive ? "arrow.triangle.2.circlepath" : "arrow.up.arrow.down.circle.fill",
                tint: .indigo,
                isDisabled: !viewModel.canRunPrimaryAction,
                isLoading: viewModel.syncPresentationIsActive
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
                subtitle: "Connection, Health data, and help",
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
            Image(systemName: viewModel.syncPresentation.symbol)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var statusColor: Color {
        switch viewModel.syncPresentation.tone {
        case .neutral: return .secondary
        case .active: return .accentColor
        case .attention: return .orange
        case .error: return .red
        }
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

}


private struct AppDetailsView: View {
    @ObservedObject var viewModel: HealthBridgeCompanionViewModel

    private static let privacyPolicyURL = URL(string: "https://healthbridge.chanhyo.dev/privacy/")!
    private static let supportURL = URL(string: "https://healthbridge.chanhyo.dev/support/")!

    var body: some View {
        List {
            Section("Preferences") {
                NavigationLink {
                    ConnectionSettingsView(viewModel: viewModel)
                } label: {
                    Label("Connection", systemImage: "network")
                }
                NavigationLink {
                    DataScopeView(viewModel: viewModel)
                } label: {
                    Label("Health Data", systemImage: "heart.text.square")
                }
            }
            Section("Help") {
                NavigationLink {
                    ActivityDiagnosticsView(viewModel: viewModel)
                } label: {
                    Label("Activity & Diagnostics", systemImage: "list.bullet.rectangle")
                }
                NavigationLink {
                    AIGuideView(viewModel: viewModel)
                } label: {
                    Label("Use with AI", systemImage: "desktopcomputer")
                }
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "51"
        return "\(version) (\(build))"
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
                        .controlSize(.regular)
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

struct InlineNotice: View {
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(message)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .font(.footnote)
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
