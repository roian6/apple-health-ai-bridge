import SwiftUI

struct ConnectionSettingsView: View {
    @ObservedObject var viewModel: HealthBridgeCompanionViewModel
    @State private var showDisconnectConfirmation = false
    @State private var showDisconnectFailureAlert = false
    @State private var disconnectFailureMessage = ""
    @State private var showPrivateResetConfirmation = false
    @State private var showMailboxKeyResetConfirmation = false
    @State private var showPendingPairingCancellationConfirmation = false
    @FocusState private var inputFocus: InputField?

    private enum InputField: Hashable {
        case link, server, code
    }

    var body: some View {
        Form {
            connectionSection

            if viewModel.hasPendingPairing {
                pendingPairingSection
            }

            setupSection

            if !viewModel.receiverSettingsSaved {
                Section {
                    DisclosureGroup("Advanced connection editing") {
                        Text("Server address")
                        TextField("https://receiver.example", text: $viewModel.manualPairingServer)
                            .accessibilityLabel("Server address")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .privacySensitive()
                            .focused($inputFocus, equals: .server)
                            .submitLabel(.next)
                            .onSubmit { inputFocus = .code }
                        Text("Invitation code")
                        TextField("15-character code", text: $viewModel.manualPairingCode)
                            .accessibilityLabel("Invitation code")
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .privacySensitive()
                            .focused($inputFocus, equals: .code)
                        Button("Connect with Code") {
                            inputFocus = nil
                            Task { await viewModel.redeemManualPairing() }
                        }
                        .disabled(!viewModel.canRedeemManualPairing || viewModel.isPairing)
                    }
                }
            }

            recoverySection
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { inputFocus = nil }
            }
        }
        .confirmationDialog(
            "Disconnect from server?",
            isPresented: $showDisconnectConfirmation,
            titleVisibility: .visible
        ) {
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
        .confirmationDialog(
            "Reset private sync state?",
            isPresented: $showPrivateResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Private Sync State", role: .destructive) {
                Task { await viewModel.clearPendingOutbox() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes unsent local Health payloads, pending pairing and local sync progress so the next connection can rebuild history, and removes any unreadable saved connection. This does not delete Apple Health data or revoke receiver enrollment.")
        }
        .confirmationDialog(
            "Reset lost mailbox connection key?",
            isPresented: $showMailboxKeyResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Lost Mailbox Connection Key", role: .destructive) {
                Task { await viewModel.resetLostMailboxConnectionKey() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This resets unreadable mailbox connection key material and pending/saved pairing state only. It does not delete Apple Health data or permissions. Queued uploads and HealthKit sync cursors are not deleted.")
        }
        .confirmationDialog(
            "Cancel pending pairing?",
            isPresented: $showPendingPairingCancellationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel Pending Pairing", role: .destructive) {
                Task { await viewModel.cancelPendingPairing() }
            }
            Button("Keep Pending Pairing", role: .cancel) {}
        } message: {
            Text("This cancels the saved pairing attempt and may disconnect the saved receiver. Any required receiver confirmation must finish before cleanup. Apple Health data is not deleted.")
        }
    }

    private var connectionSection: some View {
        Section {
            Label(
                viewModel.receiverSettingsSaved ? "Connection saved" : "No saved connection",
                systemImage: viewModel.receiverSettingsSaved ? "link" : "link.badge.plus"
            )
            if viewModel.receiverSettingsSaved {
                LabeledContent("Destination", value: viewModel.savedReceiverDestination)
                LabeledContent(
                    "Route",
                    value: viewModel.usesMailboxTransport ? "Encrypted Mac Mailbox" : "Direct"
                )
            }

            Button {
                Task { await viewModel.checkConnection() }
            } label: {
                if viewModel.isCheckingConnection {
                    ProgressView(
                        viewModel.usesMailboxTransport ? "Checking mailbox folder" : "Checking connection"
                    )
                } else {
                    Label(
                        viewModel.usesMailboxTransport ? "Check Mailbox Folder" : "Check Connection",
                        systemImage: viewModel.usesMailboxTransport ? "lock.icloud" : "network"
                    )
                }
            }
            .disabled(!viewModel.canSendConnectionTest || viewModel.isCheckingConnection)

            if viewModel.receiverSettingsSaved && !viewModel.hasPendingPairing {
                InlineNotice(
                    message: viewModel.displayStatusMessage,
                    systemImage: viewModel.statusIsError ? "exclamationmark.triangle" : "info.circle",
                    tint: viewModel.statusIsError ? .orange : .blue
                )
            }

            if viewModel.canSendConnectionTest {
                Button("Disconnect from Server", role: .destructive) {
                    showDisconnectConfirmation = true
                }
            }
        } header: {
            Text("Saved connection")
        } footer: {
            Text(
                viewModel.receiverSettingsSaved
                    ? (viewModel.usesMailboxTransport
                        ? "A folder check confirms local availability, not receiver delivery."
                        : "This is the saved destination. Use Check Connection to test its current availability.")
                    : "Use a private setup link from your computer to connect."
            )
        }
    }

    private var pendingPairingSection: some View {
        Section("Pending pairing") {
            Text(
                viewModel.mailboxKeyDiagnosticState == .lost
                    ? "Automatic sync is paused because the mailbox connection key is lost. Clear this pending pairing before using the dedicated key recovery action."
                    : "Automatic sync is paused. Retry the saved attempt after fixing the route, or clear it before opening a different setup link."
            )
            .foregroundStyle(.secondary)

            if let pairingFailure = viewModel.pairingFailurePresentation {
                Label(pairingFailure.message, systemImage: "exclamationmark.triangle")
            }

            if viewModel.mailboxKeyDiagnosticState != .lost {
                Button("Retry Pairing") {
                    Task { await viewModel.retryPendingPairing() }
                }
                .disabled(viewModel.isPairing)
            }
            Button("Cancel Pending Pairing", role: .destructive) {
                showPendingPairingCancellationConfirmation = true
            }
            .disabled(viewModel.isPairing)
        }
    }

    private var setupSection: some View {
        Section {
            Text("Private setup link")
                .font(.subheadline)
            TextField("Paste setup link", text: $viewModel.pairingImportText, axis: .vertical)
                .lineLimit(2...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .accessibilityLabel("Private setup link")
                .focused($inputFocus, equals: .link)
            Button(viewModel.canSendConnectionTest ? "Replace Connection" : "Connect from Setup Link") {
                inputFocus = nil
                Task { await viewModel.importPairingText() }
            }
            .disabled(!viewModel.canImportPairingText || viewModel.isPairing)

            if viewModel.isPairing {
                ProgressView("Connecting")
            }
            if let correction = viewModel.pairingInputCorrection {
                InlineNotice(
                    message: correction,
                    systemImage: "exclamationmark.circle.fill",
                    tint: .orange
                )
            }
        } header: {
            Text(viewModel.canSendConnectionTest ? "Replace connection" : "Setup link")
        } footer: {
            Text(
                viewModel.canSendConnectionTest
                    ? "Paste a new setup link only if you want to replace this iPhone's saved connection."
                    : "Setup links contain private connection details. Only paste them here. Do not share them in chat or screenshots."
            )
        }
    }

    @ViewBuilder
    private var recoverySection: some View {
        if viewModel.hasTransientPrivateStorageFailure
            || viewModel.mailboxKeyDiagnosticState == .lost
            || viewModel.pendingOutboxCount > 0
            || viewModel.hasPendingSleepTransition
            || viewModel.hasPendingOutboxDeletion
            || viewModel.hasPendingPrivateStorageRecovery
            || viewModel.hasPendingPairing {
            Section("Recovery") {
                if viewModel.hasTransientPrivateStorageFailure {
                    Button("Retry Private Storage") {
                        Task { await viewModel.retryPrivateStorage() }
                    }
                }

                if viewModel.pendingOutboxCount > 0
                    || viewModel.hasPendingSleepTransition
                    || viewModel.hasPendingOutboxDeletion
                    || viewModel.hasPendingPrivateStorageRecovery
                    || viewModel.hasPendingPairing {
                    Button(role: .destructive) {
                        showPrivateResetConfirmation = true
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
                    }
                }

                if viewModel.mailboxKeyDiagnosticState == .lost {
                    Button("Reset Lost Mailbox Connection Key", role: .destructive) {
                        showMailboxKeyResetConfirmation = true
                    }
                    .disabled(!viewModel.canResetLostMailboxConnectionKey)
                }
            }
        }
    }

}
