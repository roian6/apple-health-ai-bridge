import SwiftUI

struct ActivityDiagnosticsView: View {
    @ObservedObject var viewModel: HealthBridgeCompanionViewModel
    @State private var showsAdvanced = false

    var body: some View {
        Form {
            Section("Current status") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(viewModel.syncPresentation.title, systemImage: viewModel.syncPresentation.symbol)
                        .font(.headline)
                    Text(viewModel.syncPresentation.phase == .needsAttention
                        ? viewModel.displayStatusMessage : viewModel.syncPresentation.detail)
                        .foregroundStyle(.secondary)
                }
                nextAction
            }

            Section("Recent activity") {
                if viewModel.activityLogMessages.isEmpty {
                    Text("No recent activity yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(viewModel.activityLogMessages.suffix(3).reversed().enumerated()), id: \.offset) { _, message in
                        Text(message)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                }
                if viewModel.activityLogMessages.count > 3 {
                    DisclosureGroup("Earlier activity") {
                        ForEach(Array(viewModel.activityLogMessages.dropLast(3).reversed().enumerated()), id: \.offset) { _, message in
                            Text(message)
                                .font(.subheadline)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    Group {
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
                        if !viewModel.historicalBackfillState.selectedTypeCodes.isEmpty {
                            Text(viewModel.historicalBackfillSummary)
                            LabeledContent(
                                "History range",
                                value: HealthHistoryDepthPresentation.summary(
                                    selected: viewModel.historicalBackfillState.historyDepth
                                )
                            )
                        }
                        if !viewModel.nutritionNotice.isEmpty {
                            Text(viewModel.nutritionNotice)
                        }
                    }
                    .font(.subheadline)
                }
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
            NavigationLink("Open Connection") {
                ConnectionSettingsView(viewModel: viewModel)
            }
        } else {
            switch viewModel.syncPresentation.phase {
            case .recoveryRequired, .connectionRequired, .unpaired, .pendingPairing:
                NavigationLink("Open Connection") {
                    ConnectionSettingsView(viewModel: viewModel)
                }
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
