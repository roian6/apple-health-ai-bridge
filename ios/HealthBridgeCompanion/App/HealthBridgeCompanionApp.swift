import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct HealthBridgeCompanionApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = HealthBridgeCompanionViewModel()
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
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { @MainActor in
                            await viewModel.bootstrap()
                            viewModel.runForegroundCatchUpIfNeeded()
                        }
                    } else if newPhase == .background {
                        viewModel.schedulePendingBackgroundOutboxUploadsIfAllowed()
                        BackgroundRefreshScheduler.scheduleNextRefreshIfNeeded(viewModel: viewModel)
                    }
                }
        }
        .backgroundTask(.appRefresh(HealthBridgeBackgroundSync.appRefreshIdentifier)) {
            await viewModel.bootstrap()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                viewModel.noteBackgroundRefreshHandlerStarted(source: "bg_app_refresh")
            }
            await viewModel.runBackgroundRefreshSync(reason: .scheduledRefresh)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                viewModel.schedulePendingBackgroundOutboxUploadsIfAllowed()
                BackgroundRefreshScheduler.scheduleNextRefreshIfNeeded(viewModel: viewModel)
            }
        }
    }
}
