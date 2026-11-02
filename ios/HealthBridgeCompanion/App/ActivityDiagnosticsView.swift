import SwiftUI

struct ActivityDiagnosticsView: View {
    @ObservedObject var viewModel: HealthBridgeCompanionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsAdvanced = false

    var body: some View {
        Form {
            Section("Current status") {
                Label(viewModel.syncPresentation.title, systemImage: viewModel.syncPresentation.symbol)
                    .font(.headline)
                Text(viewModel.syncPresentation.phase == .needsAttention
                    ? viewModel.displayStatusMessage : viewModel.syncPresentation.detail)
                    .foregroundStyle(.secondary)
                nextAction
            }

            Section {
                DisclosureGroup("Recent activity") {
                    if viewModel.activityLogMessages.isEmpty {
                        Text("No recent activity yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(viewModel.activityLogMessages.enumerated()), id: \.offset) { _, message in
                            Text(message)
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    Text("Automatic sync is best-effort. These diagnostics do not confirm receiver delivery or Health read access.")
                        .foregroundStyle(.secondary)
                    Text(viewModel.backgroundSyncEnabled ? "Automatic sync is on." : "Automatic sync is off.")
                    Text(viewModel.automaticSyncCoverageDetail)
                    LabeledContent("Registration", value: viewModel.automaticSyncRegistrationLine)
                    LabeledContent("Background request", value: viewModel.automaticSyncScheduleLine)
                    LabeledContent("Last wake", value: viewModel.automaticSyncWakeLine)
                    LabeledContent("Last run", value: viewModel.automaticSyncRunLine)
                    Text(viewModel.automaticSyncLaneDiagnosticLine)
                        .textSelection(.enabled)
                }
                .font(.footnote)
            }
        }
        .navigationTitle("Activity")
    }

    @ViewBuilder
    private var nextAction: some View {
        if viewModel.hasTransientPrivateStorageFailure {
            Button("Retry Private Storage") {
                Task { await viewModel.retryPrivateStorage() }
            }
        } else if viewModel.hasPendingSleepTransition
            || viewModel.hasPendingOutboxDeletion
            || viewModel.mailboxKeyDiagnosticState == .lost {
            Text("Review recovery options in Settings > Connection.")
                .foregroundStyle(.secondary)
            Button("Back to Settings") { dismiss() }
        } else {
            switch viewModel.syncPresentation.phase {
            case .recoveryRequired, .connectionRequired, .unpaired:
                Text("Open Connection in Settings to continue.")
                    .foregroundStyle(.secondary)
                Button("Back to Settings") { dismiss() }
            case .pendingPairing:
                Text("Return to the main screen to retry or cancel pending pairing.")
                    .foregroundStyle(.secondary)
                Button("Back to Settings") { dismiss() }
            case .pairing, .syncing:
                Text("Wait for the current action to finish.")
                    .foregroundStyle(.secondary)
            case .permissionRequestNeeded:
                Button("Review Health Access") {
                    Task { await viewModel.performPrimaryAction() }
                }
                .disabled(!viewModel.canRunPrimaryAction || viewModel.isRequestingHealthPermissions)
            case .directQueued, .mailboxConfirmationWaiting, .needsAttention, .ready:
                Button("Sync Now") {
                    Task { await viewModel.performPrimaryAction() }
                }
                .disabled(!viewModel.canRunPrimaryAction || viewModel.syncPresentationIsActive)
            }
        }
    }
}
