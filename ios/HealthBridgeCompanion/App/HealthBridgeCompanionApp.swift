import SwiftUI
#if os(iOS)
import UIKit
#endif

@MainActor
final class HealthBridgeCompanionApplicationRuntime {
    static let shared = HealthBridgeCompanionApplicationRuntime()

    let viewModel: HealthBridgeCompanionViewModel
    let automaticSyncRuntime: AutomaticSyncRuntime
    private let backgroundLaunchPreparation: @MainActor () -> Void

    init(
        viewModel: HealthBridgeCompanionViewModel = HealthBridgeCompanionViewModel(),
        backgroundLaunchPreparation: (@MainActor () -> Void)? = nil
    ) {
        self.viewModel = viewModel
        let automaticSyncRuntime = AutomaticSyncRuntime(viewModel: viewModel)
        self.automaticSyncRuntime = automaticSyncRuntime
        viewModel.installAutomaticSyncRuntime(automaticSyncRuntime)
        self.backgroundLaunchPreparation = backgroundLaunchPreparation ?? {
            automaticSyncRuntime.prepareForBackgroundLaunch()
        }
    }

    func prepareForBackgroundLaunch() {
        backgroundLaunchPreparation()
    }

    func bootstrap() async {
        await viewModel.bootstrap()
    }

    func runForegroundCatchUpIfNeeded() {
        automaticSyncRuntime.runForegroundCatchUpIfNeeded()
    }

    func noteSceneLeftActive() {
        automaticSyncRuntime.noteSceneLeftActive()
    }

    func handleBackgroundRefresh() async {
        await automaticSyncRuntime.handleBackgroundRefresh()
    }
}

@main
@MainActor
struct HealthBridgeCompanionApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let applicationRuntime = HealthBridgeCompanionApplicationRuntime.shared
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
                    await applicationRuntime.bootstrap()
                    guard !Task.isCancelled, scenePhase == .active else { return }
                    applicationRuntime.runForegroundCatchUpIfNeeded()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { @MainActor in
                            await applicationRuntime.bootstrap()
                            guard !Task.isCancelled, scenePhase == .active else { return }
                            applicationRuntime.runForegroundCatchUpIfNeeded()
                        }
                    } else {
                        applicationRuntime.noteSceneLeftActive()
                        if newPhase == .background {
                            viewModel.schedulePendingBackgroundOutboxUploadsIfAllowed()
                        }
                    }
                }
        }
        .backgroundTask(.appRefresh(HealthBridgeBackgroundSync.appRefreshIdentifier)) {
            await applicationRuntime.handleBackgroundRefresh()
        }
    }
}
