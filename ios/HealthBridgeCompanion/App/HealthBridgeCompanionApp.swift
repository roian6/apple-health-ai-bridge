import SwiftUI
#if os(iOS)
import UIKit
#endif

@MainActor
final class HealthBridgeCompanionApplicationRuntime {
    static let shared = HealthBridgeCompanionApplicationRuntime()

    let viewModel: HealthBridgeCompanionViewModel

    init(viewModel: HealthBridgeCompanionViewModel = HealthBridgeCompanionViewModel()) {
        self.viewModel = viewModel
    }

    func bootstrap() async {
        await viewModel.bootstrap()
    }
}

@main
@MainActor
struct HealthBridgeCompanionApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = HealthBridgeCompanionApplicationRuntime.shared.viewModel
    #if os(iOS)
    @UIApplicationDelegateAdaptor(HealthBridgeBackgroundURLSessionAppDelegate.self) private var backgroundURLSessionAppDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onOpenURL { url in
                    Task { await viewModel.importPairingURL(url) }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    Task { await viewModel.importPairingURL(url) }
                }
                .task {
                    await viewModel.bootstrap()
                    guard !Task.isCancelled, scenePhase == .active else { return }
                    viewModel.runForegroundMailboxReconciliationIfNeeded()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { @MainActor in
                            await viewModel.bootstrap()
                            guard !Task.isCancelled, scenePhase == .active else { return }
                            viewModel.runForegroundCatchUpIfNeeded()
                        }
                    } else {
                        viewModel.noteSceneLeftActive()
                        if newPhase == .background {
                            viewModel.schedulePendingBackgroundOutboxUploadsIfAllowed()
                            BackgroundRefreshScheduler.scheduleNextRefreshIfNeeded(viewModel: viewModel)
                        }
                    }
                }
        }
        .backgroundTask(.appRefresh(HealthBridgeBackgroundSync.appRefreshIdentifier)) {
            await viewModel.handleBackgroundRefresh()
        }
    }
}
