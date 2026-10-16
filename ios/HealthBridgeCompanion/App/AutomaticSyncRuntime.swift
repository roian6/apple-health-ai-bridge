import Foundation
#if canImport(HealthKit)
import HealthKit
#endif
#if os(iOS)
import UIKit
#endif

@MainActor
protocol MailboxChangeObserving: AnyObject {
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
final class NativeMailboxChangeObserver: NSObject, MailboxChangeObserving {
    private(set) var query: NSMetadataQuery?
    private var onChange: (@MainActor () -> Void)?

    func start(onChange: @escaping @MainActor () -> Void) {
        stop()
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(
            format: "%K LIKE %@ OR %K LIKE %@",
            NSMetadataItemFSNameKey, "*.hba", NSMetadataItemFSNameKey, "*.hbd"
        )
        query.operationQueue = .main
        self.query = query
        self.onChange = onChange
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(metadataChanged(_:)), name: name, object: query
            )
        }
        query.start()
    }

    func stop() {
        onChange = nil
        if let query {
            NotificationCenter.default.removeObserver(self, name: nil, object: query)
            query.stop()
        }
        query = nil
    }

    @objc private func metadataChanged(_ notification: Notification) {
        guard let query, notification.object as? NSMetadataQuery === query else { return }
        onChange?()
    }
}

@MainActor
final class AutomaticSyncRuntime {
    unowned let viewModel: HealthBridgeCompanionViewModel

    private var isActivated = false
    private var hasActivatedReadyWork = false
    private var foregroundOpportunityConsumed = false
    private var foregroundCatchUpTask: Task<Void, Never>?
    private let mailboxChangeObserver: any MailboxChangeObserving
    private let backgroundRefreshScheduler: any BackgroundRefreshScheduling
    private var mailboxObservationID: UUID?
    private var mailboxObservationGeneration: String?
    #if canImport(HealthKit)
    private let backgroundDeliveryCoordinator: HealthKitBackgroundDeliveryCoordinator
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
        performOpportunity: { @MainActor [weak self, weak viewModel] opportunity, processPendingTypes in
            guard let viewModel else { return }
            if let observationID = opportunity.deliveryObservationID {
                guard let self, self.mailboxObservationID == observationID,
                      let generation = self.mailboxObservationGeneration else { return }
                await viewModel.performMailboxDeliveryOpportunity(expectedGeneration: generation)
                return
            }
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

    init(
        viewModel: HealthBridgeCompanionViewModel,
        backgroundDeliveryCoordinator: HealthKitBackgroundDeliveryCoordinator? = nil,
        mailboxChangeObserver: (any MailboxChangeObserving)? = nil,
        backgroundRefreshScheduler: (any BackgroundRefreshScheduling)? = nil
    ) {
        self.viewModel = viewModel
        self.mailboxChangeObserver = mailboxChangeObserver ?? NativeMailboxChangeObserver()
        self.backgroundRefreshScheduler = backgroundRefreshScheduler ?? NativeBackgroundRefreshScheduler()
        self.backgroundDeliveryCoordinator = backgroundDeliveryCoordinator
            ?? HealthKitBackgroundDeliveryCoordinator()
    }

    func prepareForBackgroundLaunch() {
        guard viewModel.automaticSyncLaunchPreparationIsAllowed else { return }
        #if os(iOS)
        BackgroundURLSessionOutboxUploader.shared
            .setAutomaticContinuationAdmissionOpen(true)
        #endif
        isActivated = true
        startObservers(allowBeforeBootstrap: true)
        backgroundRefreshScheduler.scheduleNextRefreshIfNeeded(viewModel: viewModel)
    }

    func activateIfReady(scheduleOutbox: Bool = true) {
        guard viewModel.automaticSyncRuntimeIsReady else { return }
        #if os(iOS)
        BackgroundURLSessionOutboxUploader.shared
            .setAutomaticContinuationAdmissionOpen(true)
        #endif
        startMailboxObservationIfNeeded()
        guard !hasActivatedReadyWork else { return }
        hasActivatedReadyWork = true
        if !isActivated {
            isActivated = true
            startObservers(allowBeforeBootstrap: false)
        }
        if scheduleOutbox {
            viewModel.schedulePendingBackgroundOutboxUploadsIfAllowed()
        }
        backgroundRefreshScheduler.scheduleNextRefreshIfNeeded(viewModel: viewModel)
        runForegroundCatchUpIfNeeded()
    }

    func stopAdmission() {
        stopMailboxObservation()
        #if os(iOS)
        BackgroundURLSessionOutboxUploader.shared
            .setAutomaticContinuationAdmissionOpen(false)
        #endif
        isActivated = false
        hasActivatedReadyWork = false
        foregroundOpportunityConsumed = false
        foregroundCatchUpTask?.cancel()
        foregroundCatchUpTask = nil
        engine.cancelActiveOwner()
        backgroundRefreshScheduler.cancelPendingRefresh()
        #if canImport(HealthKit)
        backgroundDeliveryCoordinator.stop(
            healthTypes: HealthBridgeBackgroundSync.allKnownBackgroundDeliveryHealthTypes
        )
        #endif
        viewModel.setAutomaticSyncActiveObserverCount(0)
    }

    func cancelAndWait() async {
        stopMailboxObservation()
        await engine.cancelAndWait()
    }

    private func stopMailboxObservation() {
        mailboxObservationID = nil
        mailboxObservationGeneration = nil
        mailboxChangeObserver.stop()
    }

    private func startMailboxObservationIfNeeded() {
        guard mailboxObservationID == nil, viewModel.usesMailboxTransport else { return }
        let observationID = UUID()
        let generation = viewModel.automaticSyncConnectionGeneration
        mailboxObservationID = observationID
        mailboxObservationGeneration = generation
        mailboxChangeObserver.start { [weak self] in
            guard let self, self.mailboxObservationID == observationID,
                  self.viewModel.usesMailboxTransport,
                  self.viewModel.automaticSyncObserverIsCurrent(
                    expectedConnectionGeneration: generation, allowBeforeBootstrap: false
                  ) else { return }
            self.engine.requestDeliveryReconciliation(observationID: observationID)
        }
    }

    func runForegroundCatchUpIfNeeded() {
        let opportunityWasConsumed = foregroundOpportunityConsumed
        guard !opportunityWasConsumed else { return }
        foregroundOpportunityConsumed = true
        reconcileRegistrations()
        guard viewModel.automaticSyncShouldRunForegroundCatchUp(
            opportunityWasConsumed: opportunityWasConsumed
        ),
              foregroundCatchUpTask == nil else {
            return
        }
        foregroundCatchUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.viewModel.publishAutomaticSyncForegroundCatchUpStarted()
            try? await self.engine.requestRun(reason: .launchCatchUp)
            self.foregroundCatchUpTask = nil
        }
    }

    func noteSceneLeftActive() {
        foregroundOpportunityConsumed = false
    }

    func handleBackgroundRefresh() async {
        backgroundRefreshScheduler.noteRequestConsumed()
        reconcileRegistrations()
        try? await engine.requestRun(
            reason: .scheduledRefresh,
            bootstrapBeforeRun: true
        )
        backgroundRefreshScheduler.scheduleNextRefreshIfNeeded(viewModel: viewModel)
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
        #if os(iOS)
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: "HealthBridge automatic sync",
            expirationHandler: cancelOwner
        )
        return { @MainActor [weak self] in
            self?.viewModel.setAutomaticSyncOwnerActive(false)
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
        }
        #else
        return { @MainActor [weak self] in
            self?.viewModel.setAutomaticSyncOwnerActive(false)
        }
        #endif
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
        guard HKHealthStore.isHealthDataAvailable() else {
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
