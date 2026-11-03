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

                    detailsSection
                }
                .padding(.horizontal, HealthBridgeSpacing.screen)
                .padding(.top, 28)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .clipped()
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
                .font(.largeTitle.weight(.bold))
                .fontDesign(.rounded)
            if !dynamicTypeSize.isAccessibilitySize {
                Text("Send Apple Health data to a receiver you control.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                }
                Spacer(minLength: 0)
            }
            if let observation = viewModel.lastAcceptedTransferObservation {
                Divider()
                let dateFormat = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
                let confirmationDate = Text(
                    observation.observedAt,
                    format: Calendar.current.isDate(observation.observedAt, equalTo: Date(), toGranularity: .year)
                        ? dateFormat : dateFormat.year()
                )
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Last transfer confirmed")
                        confirmationDate
                    }
                    .fixedSize()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last transfer confirmed")
                        confirmationDate
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
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
                    .font(.body)
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

            Text("Completing the request does not confirm which read permissions you granted.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            DisclosureGroup {
                Text(viewModel.healthPermissionScopeSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Text("About Health access")
                    .frame(minHeight: 44)
            }
        }
        .cardStyle()
    }

    private var syncControlCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sync")
                .font(.title3.weight(.bold))

            if !viewModel.healthPermissionNotice.isEmpty {
                InlineNotice(
                    message: viewModel.healthPermissionNoticeIsError
                        ? viewModel.healthPermissionNotice
                        : "Access request finished. Only data you allow in Apple Health can sync.",
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


            let automaticSyncLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            automaticSyncLayout {
                SettingRowLabel(
                    title: "Automatic Sync",
                    subtitle: dynamicTypeSize.isAccessibilitySize
                        ? "iOS decides background timing."
                        : viewModel.automaticSyncScopeSummary,
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: .green
                )
                Toggle("Automatic Sync", isOn: Binding(
                    get: { viewModel.automaticSyncToggleIsOn },
                    set: { enabled in
                        viewModel.requestBackgroundSyncEnabled(enabled)
                    }
                ))
                .labelsHidden()
                .fixedSize()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityHint(viewModel.automaticSyncScopeSummary)
                .disabled(!viewModel.canChangeAutomaticSyncSetting)
            }
        }
        .cardStyle()
    }

    private var detailsSection: some View {
        NavigationLink {
            AppDetailsView(viewModel: viewModel)
        } label: {
            CardRow(
                title: "Settings",
                systemImage: "gearshape.fill",
                tint: .orange
            )
        }
        .buttonStyle(.plain)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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
    private static let setupGuideURL = URL(string: "https://healthbridge.chanhyo.dev/install/")!

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
                NavigationLink {
                    ActivityDiagnosticsView(viewModel: viewModel)
                } label: {
                    Label("Activity", systemImage: "list.bullet.rectangle")
                }
            }
            Section("Help") {
                Link("Setup Guide", destination: Self.setupGuideURL)
                Link("Support", destination: Self.supportURL)
            }
            Section("About") {
                LabeledContent("Version", value: appVersion)
                Link("Privacy Policy", destination: Self.privacyPolicyURL)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                } else if !dynamicTypeSize.isAccessibilitySize {
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let systemImage: String
    let tint: Color
    var accessory: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
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
            if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(HealthBridgeSpacing.screen)
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
