import BackgroundTasks
import Foundation

@MainActor
enum BackgroundRefreshScheduler {
    private static let requests = BackgroundRefreshRequestCoalescer()

    static func noteRequestConsumed() {
        requests.requestWasConsumed()
    }

    static func cancelPendingRefresh() {
        requests.invalidate()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: HealthBridgeBackgroundSync.appRefreshIdentifier)
    }

    static func scheduleNextRefreshIfNeeded(
        viewModel: HealthBridgeCompanionViewModel,
        now: Date = Date()
    ) {
        guard viewModel.backgroundRefreshSchedulingAdmissionIsOpen else {
            return
        }
        guard viewModel.backgroundSyncEnabled else {
            return
        }
        guard viewModel.canSendConnectionTest else {
            viewModel.noteBackgroundRefreshSchedulingSkipped()
            return
        }
        guard let earliestBeginDate = HealthBridgeBackgroundSync.nextEarliestBeginDate(
            enabled: true,
            now: now
        ) else {
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: HealthBridgeBackgroundSync.appRefreshIdentifier)
        request.earliestBeginDate = earliestBeginDate
        do {
            try requests.submitIfNeeded(generation: viewModel.backgroundRefreshConnectionGeneration) {
                try BGTaskScheduler.shared.submit(request)
                viewModel.noteBackgroundRefreshScheduled(earliestBeginDate: earliestBeginDate)
            }
        } catch {
            viewModel.noteBackgroundRefreshScheduleFailed(error)
        }
    }
}
