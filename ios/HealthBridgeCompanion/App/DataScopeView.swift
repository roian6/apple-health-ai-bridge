import SwiftUI

struct DataScopeView: View {
    @ObservedObject private var viewModel: HealthBridgeCompanionViewModel

    init(viewModel: HealthBridgeCompanionViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
    }

    var body: some View {
        Form {
            Section {
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
                        message: viewModel.healthPermissionNoticeIsError
                            ? viewModel.healthPermissionNotice
                            : "Access request finished.",
                        systemImage: viewModel.healthPermissionNoticeIsError
                            ? "exclamationmark.triangle.fill"
                            : "info.circle.fill",
                        tint: viewModel.healthPermissionNoticeIsError ? .orange : .blue
                    )
                }

                DisclosureGroup("About Health access") {
                    Group {
                        Text(viewModel.healthPermissionScopeSummary)
                        if !viewModel.healthPermissionNotice.isEmpty
                            && !viewModel.healthPermissionNoticeIsError {
                            Text(viewModel.healthPermissionNotice)
                        } else {
                            Text("Review individual read access in Health > profile picture > Privacy > Apps > Health Bridge.")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Apple Health access")
            } footer: {
                Text("A completed request does not confirm which read permissions you granted.")
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

                VStack(alignment: .leading, spacing: 4) {
                    if let selectedRow = viewModel.healthHistoryDepthRows.first(where: \.isSelected) {
                        Text(selectedRow.detail)
                    }
                    Text("Limits vary by data type.")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } header: {
                Text("History")
            } footer: {
                Text("Changing this range does not reset progress or resend older records.")
            }
        }
        .navigationTitle("Health Data")
    }
}
