import SwiftUI

struct AIGuideView: View {
    @ObservedObject var viewModel: HealthBridgeCompanionViewModel

    private static let connectAIURL = URL(string: "https://healthbridge.chanhyo.dev/install/#connect-ai")!
    private static let supportURL = URL(string: "https://healthbridge.chanhyo.dev/support/")!
    private static let privacyURL = URL(string: "https://healthbridge.chanhyo.dev/privacy/")!

    var body: some View {
        Form {
            Section {
                Text("This iPhone syncs the Apple Health records you allow to a receiver on a computer you own or control.")

                if viewModel.setupState == .unpaired {
                    Text("Connect this iPhone to your receiver from the Home screen before syncing.")
                        .foregroundStyle(.secondary)
                } else if viewModel.setupState == .pairedNeedsHealthPermission {
                    Text("Finish the Apple Health access step on the Home screen before syncing.")
                        .foregroundStyle(.secondary)
                }

                Text("After phone-to-receiver sync, configure your chosen AI client separately to query that receiver.")

                Link(destination: Self.connectAIURL) {
                    Label("Connect an AI Client", systemImage: "arrow.up.right.square")
                }
            } header: {
                Text("After phone sync")
            } footer: {
                Text("Health Bridge does not verify that an AI client is installed or connected.")
            }

            Section("Where data goes") {
                Text("Receiver storage stays on your computer. Your AI client and model determine where query data is processed; local storage does not guarantee local AI.")
                Text("If you choose a cloud model, your client may send your questions and retrieved health data to that provider.")

                Link(destination: Self.privacyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }

            Section {
                Text("First verify the available metrics and dates. What patterns appear in my recorded activity over the last seven completed days?")
                    .textSelection(.enabled)
            } header: {
                Text("Try a first question")
            } footer: {
                Text("Answers reflect the records available to your assistant, not necessarily your complete health history.")
            }

            Section("Help") {
                Link(destination: Self.supportURL) {
                    Label("Support", systemImage: "questionmark.circle")
                }
            }
        }
        .navigationTitle("Use with AI")
        .navigationBarTitleDisplayMode(.inline)
    }
}
