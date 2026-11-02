import SwiftUI

struct DataScopeView: View {
    @ObservedObject private var viewModel: HealthBridgeCompanionViewModel

    init(viewModel: HealthBridgeCompanionViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
    }

    var body: some View {
        Form {
            Section {
                Text(viewModel.healthPermissionScopeSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await viewModel.requestHealthPermissions() }
                } label: {
                    Label(
                        viewModel.isRequestingHealthPermissions
                            ? "Requesting Health Access..."
                            : "Request Health Access",
                        systemImage: "heart.text.square"
                    )
                }
                .disabled(viewModel.isRequestingHealthPermissions)

                if !viewModel.healthPermissionNotice.isEmpty {
                    InlineNotice(
                        message: viewModel.healthPermissionNotice,
                        systemImage: viewModel.healthPermissionNoticeIsError
                            ? "exclamationmark.triangle.fill"
                            : "info.circle.fill",
                        tint: viewModel.healthPermissionNoticeIsError ? .orange : .blue
                    )
                }
            } header: {
                Text("Apple Health access")
            } footer: {
                Text("A completed request does not reveal which read permissions you granted. Review Health Bridge access in the Health app.")
            }

            Section {
                Picker("Requested range", selection: Binding(
                    get: { viewModel.healthHistoryDepthOptionID },
                    set: { viewModel.setHealthHistoryDepthOption($0) }
                )) {
                    ForEach(viewModel.healthHistoryDepthRows) { row in
                        Text(row.title).tag(row.id)
                    }
                }

                if let selectedRow = viewModel.healthHistoryDepthRows.first(where: \.isSelected) {
                    Text(selectedRow.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("History")
            } footer: {
                Text("Limits vary by data type. Changing this preference does not reset progress or resend older records.")
            }

            Section {
                Text(viewModel.historicalBackfillSummary)
                    .fixedSize(horizontal: false, vertical: true)

                if !viewModel.historicalBackfillState.selectedTypeCodes.isEmpty {
                    Text("Saved range: \(HealthHistoryDepthPresentation.summary(selected: viewModel.historicalBackfillState.historyDepth))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Additional history")
            } footer: {
                Text("Progress for selected data types; queued records may still be awaiting delivery.")
            }

            Section("Nutrition compatibility") {
                if viewModel.nutritionNotice.isEmpty {
                    Text("No nutrition compatibility details are available.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(viewModel.nutritionNotice)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .navigationTitle("Health Data")
    }
}
