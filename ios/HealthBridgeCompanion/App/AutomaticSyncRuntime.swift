import Foundation
#if canImport(HealthKit)
import HealthKit
#endif
#if os(iOS)
import UIKit
#endif

@MainActor
final class AutomaticSyncRuntime {
    unowned let viewModel: HealthBridgeCompanionViewModel

    @MainActor
    struct Platform {
        var scheduleRefresh: (HealthBridgeCompanionViewModel) -> Void = {
            BackgroundRefreshScheduler.scheduleNextRefreshIfNeeded(viewModel: $0)
        }
        var cancelRefresh: () -> Void = { BackgroundRefreshScheduler.cancelPendingRefresh() }
        var consumeRefresh: () -> Void = { BackgroundRefreshScheduler.noteRequestConsumed() }
        var setUploadAdmission: (Bool) -> Void = {
            #if os(iOS)
            BackgroundURLSessionOutboxUploader.shared.setAutomaticContinuationAdmissionOpen($0)
            #endif
        }
        var beginBackgroundOwner: AutomaticSyncEngine.StartOwner = { cancelOwner in
            #if os(iOS)
            let identifier = UIApplication.shared.beginBackgroundTask(
                withName: "HealthBridge automatic sync",
                expirationHandler: cancelOwner
            )
            return {
                guard identifier != .invalid else { return }
                UIApplication.shared.endBackgroundTask(identifier)
            }
            #else
            return {}
            #endif
        }
        #if canImport(HealthKit)
        var healthDataAvailable: () -> Bool = { HKHealthStore.isHealthDataAvailable() }
        var backgroundDeliveryCoordinator = HealthKitBackgroundDeliveryCoordinator()
        #endif
    }

    private let platform: Platform

    private var isActivated = false
    private var hasActivatedReadyWork = false
    private var foregroundOpportunityConsumed = false
    private var foregroundCatchUpTask: Task<Void, Never>?
    #if canImport(HealthKit)
    private var backgroundDeliveryCoordinator: HealthKitBackgroundDeliveryCoordinator {
        platform.backgroundDeliveryCoordinator
    }
    #endif

    private lazy var engine = AutomaticSyncEngine(
        pendingStore: viewModel.automaticSyncSettingsStore,
        processType: { @MainActor [weak viewModel] typeCode, pendingGenerations in
            guard let viewModel else { return .blocked }
            return await viewModel.processAutomaticSyncType(
                typeCode,
                pendingGenerations: pendingGenerations
            )
        },
        performOpportunity: { @MainActor [weak viewModel] opportunity, processPendingTypes in
            guard let viewModel else { return }
            if opportunity.reason == .manualSync {
                await viewModel.performManualSyncOpportunity(
                    processPendingTypes: processPendingTypes
                )
                return
            }
            _ = await viewModel.performAutomaticSyncOpportunity(
                opportunity: opportunity,
                processPendingTypes: processPendingTypes
            )
        },
        startOwner: { @MainActor [weak self] cancelOwner in
            self?.beginOwner(cancelOwner: cancelOwner) ?? {}
        }
    )

    init(viewModel: HealthBridgeCompanionViewModel, platform: Platform? = nil) {
        self.viewModel = viewModel
        self.platform = platform ?? Platform()
    }

    func prepareForBackgroundLaunch() {
        guard viewModel.automaticSyncLaunchPreparationIsAllowed else { return }
        platform.setUploadAdmission(true)
        isActivated = true
        startObservers(allowBeforeBootstrap: true)
        platform.scheduleRefresh(viewModel)
    }

    func activateIfReady(scheduleOutbox: Bool = true) {
        guard viewModel.automaticSyncRuntimeIsReady else { return }
        platform.setUploadAdmission(true)
        guard !hasActivatedReadyWork else { return }
        hasActivatedReadyWork = true
        if !isActivated {
            isActivated = true
            startObservers(allowBeforeBootstrap: false)
        }
        if scheduleOutbox {
            viewModel.schedulePendingBackgroundOutboxUploadsIfAllowed()
        }
        platform.scheduleRefresh(viewModel)
        runForegroundCatchUpIfNeeded()
    }

    func stopAdmission() {
        platform.setUploadAdmission(false)
        isActivated = false
        hasActivatedReadyWork = false
        foregroundOpportunityConsumed = false
        foregroundCatchUpTask?.cancel()
        foregroundCatchUpTask = nil
        engine.cancelActiveOwner()
        platform.cancelRefresh()
        #if canImport(HealthKit)
        backgroundDeliveryCoordinator.stop(
            healthTypes: HealthBridgeBackgroundSync.allKnownBackgroundDeliveryHealthTypes
        )
        #endif
        viewModel.setAutomaticSyncActiveObserverCount(0)
    }

    func cancelAndWait() async {
        await engine.cancelAndWait()
    }

    func waitForForegroundCatchUp() async {
        await foregroundCatchUpTask?.value
    }

    func foregroundCatchUpCompletion() -> (@MainActor () async -> Void)? {
        guard let task = foregroundCatchUpTask else { return nil }
        return { await task.value }
    }

    func runForegroundCatchUpIfNeeded() {
        let opportunityWasConsumed = foregroundOpportunityConsumed
        guard !opportunityWasConsumed else { return }
        reconcileRegistrations()
        guard viewModel.automaticSyncShouldRunForegroundCatchUp(
            opportunityWasConsumed: opportunityWasConsumed
        ),
              foregroundCatchUpTask == nil else {
            return
        }
        foregroundOpportunityConsumed = true
        foregroundCatchUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.viewModel.publishAutomaticSyncForegroundCatchUpStarted()
            try? await self.engine.requestRun(reason: .launchCatchUp)
            self.foregroundCatchUpTask = nil
        }
    }

    func noteSceneLeftActive() {
        foregroundOpportunityConsumed = false
        viewModel.noteSceneLeftActive()
    }

    func handleBackgroundRefresh() async {
        platform.consumeRefresh()
        reconcileRegistrations()
        try? await engine.requestRun(
            reason: .scheduledRefresh,
            bootstrapBeforeRun: true
        )
        platform.scheduleRefresh(viewModel)
    }

    func runAutomaticSync(
        reason: AutomaticSyncReason,
        diagnosticRunID: UUID = UUID()
    ) async {
        try? await engine.requestRun(
            reason: reason,
            diagnosticRunID: diagnosticRunID
        )
    }

    func runManualSync() async {
        await engine.cancelAndWait()
        guard !Task.isCancelled else { return }
        try? await engine.requestRun(reason: .manualSync)
    }

    private func beginOwner(
        cancelOwner: @escaping AutomaticSyncEngine.CancelOwner
    ) -> AutomaticSyncEngine.FinishOwner {
        viewModel.setAutomaticSyncOwnerActive(true)
        let finishBackgroundOwner = platform.beginBackgroundOwner(cancelOwner)
        return { @MainActor [weak self] in
            self?.viewModel.setAutomaticSyncOwnerActive(false)
            finishBackgroundOwner()
        }
    }

    private func reconcileRegistrations() {
        guard isActivated else { return }
        #if canImport(HealthKit)
        viewModel.prepareAutomaticSyncRegistrationReconciliation(
            expectedTypeCount: backgroundDeliveryCoordinator.activeObserverCount
        )
        backgroundDeliveryCoordinator.reconcileRegistrations()
        #endif
    }

    private func startObservers(allowBeforeBootstrap: Bool) {
        #if canImport(HealthKit)
        guard platform.healthDataAvailable() else {
            viewModel.publishHealthKitUnavailableForAutomaticSync()
            return
        }
        let healthTypes = viewModel.automaticSyncObserverHealthTypes()
        let expectedConnectionGeneration = viewModel.automaticSyncConnectionGeneration
        backgroundDeliveryCoordinator.start(
            healthTypes: healthTypes,
            registrationHandler: { [weak viewModel] typeCode, succeeded in
                viewModel?.noteHealthKitBackgroundDeliveryRegistration(
                    typeCode: typeCode,
                    succeeded: succeeded
                )
            },
            observerEntryHandler: viewModel.automaticSyncObserverEntryHandler(),
            isCurrent: { [weak self, weak viewModel] in
                guard let self, let viewModel, self.isActivated else { return false }
                return viewModel.automaticSyncObserverIsCurrent(
                    expectedConnectionGeneration: expectedConnectionGeneration,
                    allowBeforeBootstrap: allowBeforeBootstrap
                )
            },
            observerAdmissionHandler: { [weak viewModel] typeCode, diagnosticRunID in
                guard let viewModel else { return .complete(nil) }
                return viewModel.admitAutomaticSyncObserver(
                    typeCode: typeCode,
                    diagnosticRunID: diagnosticRunID
                )
            },
            observerCompletionHandler: { [weak viewModel] completedDraft, latency in
                viewModel?.persistCompletedObserverAutomaticSyncDiagnostic(
                    completedDraft,
                    latency: latency
                )
            }
        ) { [weak self] typeCode, diagnosticRunID in
            self?.engine.requestRunWithoutWaiting(
                reason: .observer(typeCode: typeCode),
                diagnosticRunID: diagnosticRunID
            )
            return nil
        }
        let observerCount = backgroundDeliveryCoordinator.activeObserverCount
        viewModel.setAutomaticSyncActiveObserverCount(observerCount)
        viewModel.recordAutomaticSyncRegistrationStarted(
            expectedTypeCount: observerCount
        )
        #endif
    }
}
