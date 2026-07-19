import Foundation
#if canImport(HealthKit)
import HealthKit
#endif
#if os(iOS)
import UIKit
#endif
import SwiftUI

private struct RejectedSleepBaselineOutboxItem: Error {
    let itemID: String
    let minimumResetEpoch: UInt64
    let expectedGeneration: String?

    init(
        itemID: String,
        minimumResetEpoch: UInt64,
        expectedGeneration: String? = nil
    ) {
        self.itemID = itemID
        self.minimumResetEpoch = minimumResetEpoch
        self.expectedGeneration = expectedGeneration
    }
}

private enum CompanionPrivateStorageError: LocalizedError {
    case outboxUnavailable
    case cursorStoreUnavailable
    case sleepManifestUnavailable
    case receiverIdentityUnavailable

    var errorDescription: String? {
        switch self {
        case .outboxUnavailable:
            "The private queued-upload store could not be opened. Uploads remain blocked."
        case .cursorStoreUnavailable:
            "The private synchronization cursor store could not be opened. Uploads remain blocked."
        case .sleepManifestUnavailable:
            "The private Sleep synchronization store could not be opened. Deletion remains pending."
        case .receiverIdentityUnavailable:
            "The saved receiver identity could not be read. Uploads remain blocked."
        }
    }
}

private struct ReceiverSyncProgressScope {
    let receiverBindingID: String
    let connectionGeneration: String
}

enum DisconnectReceiverOutcome: Equatable {
    case disconnected(pendingOutboxCount: Int?)
    case rejected(
        message: String,
        pendingOutboxCount: Int?,
        connectionPreserved: Bool
    )
}

@MainActor
final class HealthBridgeCompanionViewModel: ObservableObject {
    @Published var receiverURLString: String
    @Published var bearerToken: String
    @Published private(set) var receiverSettingsSaved: Bool
    @Published private var publishedStatusIsError = false
    var statusIsError: Bool {
        get { publishedStatusIsError }
        set {
            guard !taskUIPublicationIsSuppressed else { return }
            publishedStatusIsError = newValue
        }
    }
    @Published private var publishedStatusMessage = "Not connected" {
        didSet { appendActivityLog(publishedStatusMessage, isError: publishedStatusIsError) }
    }
    var statusMessage: String {
        get { publishedStatusMessage }
        set {
            guard !taskUIPublicationIsSuppressed else { return }
            publishedStatusMessage = newValue
        }
    }
    @Published private var publishedPendingOutboxCount = 0
    var pendingOutboxCount: Int {
        get { publishedPendingOutboxCount }
        set {
            guard !taskUIPublicationIsSuppressed else { return }
            publishedPendingOutboxCount = newValue
        }
    }
    @Published private(set) var hasPendingSleepTransition = false
    @Published private(set) var hasPendingOutboxDeletion = false
    @Published private(set) var hasPendingPrivateStorageRecovery = false
    @Published private(set) var hasTransientPrivateStorageFailure = false
    @Published var pairingImportText = ""
    @Published var manualPairingServer = ""
    @Published var manualPairingCode = ""
    @Published var isPairing = false
    @Published private var publishedHasPendingPairing: Bool
    private(set) var hasPendingPairing: Bool {
        get { publishedHasPendingPairing }
        set {
            guard !taskUIPublicationIsSuppressed else { return }
            publishedHasPendingPairing = newValue
        }
    }
    @Published var backgroundSyncEnabled: Bool
    @Published private var publishedBackgroundSyncStatus: String
    var backgroundSyncStatus: String {
        get { publishedBackgroundSyncStatus }
        set {
            guard !taskUIPublicationIsSuppressed else { return }
            publishedBackgroundSyncStatus = newValue
        }
    }
    @Published var healthPermissionsRequested: Bool

    @Published var healthPermissionNotice = ""
    @Published var healthPermissionNoticeIsError = false
    @Published var isRequestingHealthPermissions = false
    @Published var isCheckingConnection = false
    @Published var isSyncing = false
    @Published var healthHistoryDepth: HealthHistoryDepth
    @Published var historicalBackfillState: HealthHistoricalBackfillState
    @Published private(set) var activityLogMessages: [String]

    private var foregroundCatchUpTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var bootstrapAttemptID: UUID?
    private var bootstrapWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var pairingTask: Task<Void, Never>?
    private var pairingAttemptID: UUID?
    private var pairingOperationKind: PairingOperationCategory?
    private let pairingRequestEpoch = PairingRequestEpoch()
    private var backgroundOutboxSchedulingTask: Task<Void, Never>?
    private var backgroundOutboxSchedulingID: UUID?
    private var backgroundObserverRetryTask: Task<Void, Never>?
    private var trackedSyncTasks: [UUID: Task<Void, Never>] = [:]
    private var directOutboxTransferRequestCount = 0
    private var bootstrapCompleted = false
    private var automaticSyncActivated = false
    private var backgroundSyncPreferenceGeneration: UInt64 = 0
    private var automaticSyncPreferenceTask: Task<Void, Never>?
    private var automaticSyncDisableCleanupTask: Task<Bool, Never>?
    private var terminalTaskUIPublicationSuppressionDepth = 0
    private var taskUIPublicationIsSuppressed: Bool {
        terminalTaskUIPublicationSuppressionDepth > 0
    }
    private var terminalRequestLifecycleSnapshot: TerminalRequestLifecycleSnapshot {
        TerminalRequestLifecycleSnapshot(
            requestIsActive: terminalTransitionRequestIsActive,
            publicationIsSuppressed: taskUIPublicationIsSuppressed,
            payloadAdmissionIsOpen: connectionTerminalBarrier.admissionIsOpen
        )
    }
    private var terminalUserActionAdmissionIsOpen: Bool {
        terminalRequestLifecycleSnapshot.admitsUserAction
    }
    private var terminalPayloadActionAdmissionIsOpen: Bool {
        terminalRequestLifecycleSnapshot.admitsPayloadAction
    }
    @Published private(set) var backgroundSyncRequestedEnabled: Bool
    private var outboxIdentityMigrationReady: Bool
    private var privateStorageAdmissionReady = false
    private let directOutboxTransferGate = AsyncExclusiveAccessGate()
    private let terminalTransitionRequestCoordinator = TerminalRequestCoordinator()
    @Published private(set) var terminalTransitionRequestIsActive = false
    private let connectionTerminalBarrier = ReceiverConnectionTerminalBarrier()
    private let encoder = HealthBridgeBatchEncoder()
    private let receiverClient: ReceiverClient
    private let settingsStore: ReceiverSettingsStore
    private let pairingStateStore: ReceiverPairingStateStore
    private let pairingCoordinator: ReceiverPairingCoordinator
    private let backgroundSyncStore: BackgroundSyncSettingsStore
    private let healthPermissionRequestStore: CompanionHealthPermissionRequestStore
    private let healthHistoryDepthStore: HealthHistoryDepthSelectionStore
    private let historicalBackfillStateStore: HealthHistoricalBackfillStateStore
    private let quantityObservationStore: QuantityObservationStore
    private let coreLaneUploadProofStore: CoreLaneUploadProofStore
    private var outbox: FileOutbox?
    private let outboxDirectoryURL: URL?
    private var cursorStore: FileSyncCursorStore?
    private let cursorStoreFileURL: URL?
    private var cursorStateNeedsRecovery = false
    private var connectionStateNeedsRecovery = false
    private var sleepManifestStore: SleepSyncManifestStoring?
    private let sleepManifestFileURL: URL?
    private let sleepResetEpochStore: SleepResetEpochStore
    private var sleepSourceKey: String?
    private let backgroundRunGate = BackgroundSyncRunGate()
    private var lastOutboxNotice = ""
    #if canImport(HealthKit)
    private var backgroundDeliveryCoordinator: HealthKitBackgroundDeliveryCoordinator?
    private var backgroundDeliveryRegistrationExpectedCount = 0
    private var backgroundDeliveryRegistrationResults: [String: Bool] = [:]
    private var backgroundDeliveryRegistrationErrors: [String: String] = [:]
    #endif

    init(
        receiverClient: ReceiverClient = ReceiverClient(),
        settingsStore: ReceiverSettingsStore = ReceiverSettingsStore(),
        pairingStateStore: ReceiverPairingStateStore = ReceiverPairingStateStore(),
        backgroundSyncStore: BackgroundSyncSettingsStore = BackgroundSyncSettingsStore(),
        healthPermissionRequestStore: CompanionHealthPermissionRequestStore = CompanionHealthPermissionRequestStore(),
        healthHistoryDepthStore: HealthHistoryDepthSelectionStore = HealthHistoryDepthSelectionStore(),
        historicalBackfillStateStore: HealthHistoricalBackfillStateStore = HealthHistoricalBackfillStateStore(),
        quantityObservationStore: QuantityObservationStore = QuantityObservationStore(),
        coreLaneUploadProofStore: CoreLaneUploadProofStore = CoreLaneUploadProofStore(),
        outbox: FileOutbox? = HealthBridgeCompanionViewModel.makeDefaultOutbox(),
        outboxDirectoryURL: URL? = HealthBridgeCompanionViewModel.defaultOutboxDirectoryURL(),
        cursorStore: FileSyncCursorStore? = HealthBridgeCompanionViewModel.makeDefaultCursorStore(),
        cursorStoreFileURL: URL? = HealthBridgeCompanionViewModel.defaultCursorStoreFileURL(),
        sleepManifestStore: SleepSyncManifestStoring? = HealthBridgeCompanionViewModel.makeDefaultSleepManifestStore(),
        sleepManifestFileURL: URL? = HealthBridgeCompanionViewModel.defaultSleepManifestFileURL(),
        sleepResetEpochStore: SleepResetEpochStore = SleepResetEpochStore()
    ) {
        let pendingPairingMayExist: Bool
        do {
            pendingPairingMayExist = try pairingStateStore.loadPending() != nil
        } catch {
            pendingPairingMayExist = true
        }
        self.receiverClient = receiverClient
        self.settingsStore = settingsStore
        self.pairingStateStore = pairingStateStore
        self.pairingCoordinator = ReceiverPairingCoordinator(
            client: receiverClient,
            stateStore: pairingStateStore,
            settingsStore: settingsStore
        )
        self.backgroundSyncStore = backgroundSyncStore
        self.healthPermissionRequestStore = healthPermissionRequestStore
        #if canImport(HealthKit)
        let currentRuntimePermissionTypeCodes = HealthKitReadTypeCatalog.availableTypeCodes(
            forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
        )
        healthPermissionRequestStore.invalidateIfRuntimeCoverageChanged(
            currentRuntimeTypeCodes: currentRuntimePermissionTypeCodes
        )
        #endif
        self.healthHistoryDepthStore = healthHistoryDepthStore
        self.historicalBackfillStateStore = historicalBackfillStateStore
        self.quantityObservationStore = quantityObservationStore
        self.coreLaneUploadProofStore = coreLaneUploadProofStore
        self.outbox = outbox
        self.outboxDirectoryURL = outbox?.directoryURL ?? outboxDirectoryURL
        let resolvedCursorStoreFileURL = cursorStore?.fileURL ?? cursorStoreFileURL
        var resolvedCursorStore = cursorStore
        var initialCursorStateNeedsRecovery = false
        var initialCursorTransientFailure = false
        do {
            if resolvedCursorStore == nil, let resolvedCursorStoreFileURL {
                resolvedCursorStore = try FileSyncCursorStore(fileURL: resolvedCursorStoreFileURL)
            }
            guard let resolvedCursorStore else {
                throw CompanionPrivateStorageError.cursorStoreUnavailable
            }
            try resolvedCursorStore.validateReadableAndWritable()
        } catch FileSyncCursorStoreError.invalidData {
            resolvedCursorStore = nil
            initialCursorStateNeedsRecovery = true
        } catch {
            resolvedCursorStore = nil
            initialCursorTransientFailure = true
        }
        self.cursorStore = resolvedCursorStore
        self.cursorStoreFileURL = resolvedCursorStoreFileURL
        self.sleepManifestStore = sleepManifestStore
        self.sleepManifestFileURL = sleepManifestFileURL
        self.sleepResetEpochStore = sleepResetEpochStore
        self.sleepSourceKey = (try? pairingStateStore.loadOrCreateInstallationID()).map {
            "apple_health.phone.\($0.lowercased())"
        }
        let atomicConnectionRecordReady: Bool
        let initialConnectionStateNeedsRecovery: Bool
        let initialConnectionTransientFailure: Bool
        do {
            try settingsStore.ensureAtomicConnectionRecord()
            atomicConnectionRecordReady = true
            initialConnectionStateNeedsRecovery = false
            initialConnectionTransientFailure = false
        } catch {
            atomicConnectionRecordReady = false
            initialConnectionStateNeedsRecovery = ReceiverConnectionRecordRecoveryPolicy
                .requiresDestructiveRecovery(error)
            initialConnectionTransientFailure = !initialConnectionStateNeedsRecovery
        }
        let savedBearerToken: String
        let bearerTokenReadSucceeded: Bool
        do {
            savedBearerToken = try settingsStore.loadBearerToken()
            bearerTokenReadSucceeded = true
        } catch {
            savedBearerToken = ""
            bearerTokenReadSucceeded = false
        }
        let outboxIdentityMigrationSucceeded: Bool
        if let outbox, atomicConnectionRecordReady, bearerTokenReadSucceeded {
            do {
                let currentBindingID = settingsStore.receiverBindingID
                if let currentBindingID,
                   Self.receiverSettingsAreComplete(
                       urlString: settingsStore.receiverURLString,
                       bearerToken: savedBearerToken
                   ) {
                    _ = try outbox.migrateLegacyHashedReceiverIdentities(
                        currentReceiverURLString: settingsStore.receiverURLString,
                        currentBearerToken: savedBearerToken,
                        currentBindingID: currentBindingID
                    )
                }
                outboxIdentityMigrationSucceeded = ReceiverOutboxAdmissionPolicy.isReady(
                    pendingReceiverIdentities: try outbox.pendingItems().map(\.receiverIdentity),
                    currentBindingID: currentBindingID,
                    hasBearerToken: !savedBearerToken.isEmpty
                )
            } catch {
                outboxIdentityMigrationSucceeded = false
            }
        } else {
            outboxIdentityMigrationSucceeded = false
        }
        self.receiverURLString = settingsStore.receiverURLString
        self.bearerToken = savedBearerToken
        let savedReceiverSettingsAreComplete = Self.receiverSettingsAreComplete(
            urlString: settingsStore.receiverURLString,
            bearerToken: savedBearerToken
        ) && settingsStore.receiverBindingID != nil && outboxIdentityMigrationSucceeded
        self.receiverSettingsSaved = savedReceiverSettingsAreComplete
        self.outboxIdentityMigrationReady = outboxIdentityMigrationSucceeded
        self.backgroundSyncEnabled = backgroundSyncStore.isEnabled
        self.backgroundSyncRequestedEnabled = backgroundSyncStore.isEnabled
        self.publishedHasPendingPairing = pendingPairingMayExist
        self.cursorStateNeedsRecovery = initialCursorStateNeedsRecovery
        self.connectionStateNeedsRecovery = initialConnectionStateNeedsRecovery
        self.hasPendingPrivateStorageRecovery = initialCursorStateNeedsRecovery || initialConnectionStateNeedsRecovery
        self.hasTransientPrivateStorageFailure = initialCursorTransientFailure || initialConnectionTransientFailure
        self.publishedBackgroundSyncStatus = HealthBridgeCompanionViewModel.describeBackgroundSync(backgroundSyncStore)
        self.healthPermissionsRequested = healthPermissionRequestStore.wasRequested
        self.healthHistoryDepth = healthHistoryDepthStore.historyDepth
        self.historicalBackfillState = historicalBackfillStateStore.state
        self.activityLogMessages = []
        self.publishedPendingOutboxCount = (try? outbox?.pendingItems().count) ?? 0
        self.hasPendingSleepTransition = Self.sleepStorageMayNeedRecovery(in: sleepManifestStore)
        self.hasPendingOutboxDeletion = outbox?.clearIntentIsActive ?? true
        if outbox == nil {
            self.statusIsError = true
            self.statusMessage = "The private queued-upload store could not be opened. Automatic and manual uploads remain blocked."
        } else if initialConnectionStateNeedsRecovery {
            self.statusIsError = true
            self.statusMessage = "A saved connection from an older or damaged app state must be reset and paired again before any upload."
        } else if !outboxIdentityMigrationSucceeded {
            self.statusIsError = true
            self.statusMessage = "Queued-upload privacy migration failed. Automatic and manual uploads remain unavailable until the local outbox is cleared or migration succeeds."
        } else if !bearerToken.isEmpty {
            self.statusMessage = "Loaded saved connection from this iPhone."
        }
        appendActivityLog(statusMessage, isError: statusIsError)
    }

    private var committedReceiverSettingsAreComplete: Bool {
        guard let bearerToken = try? settingsStore.loadBearerToken(),
              settingsStore.receiverBindingID != nil else {
            return false
        }
        return Self.receiverSettingsAreComplete(
            urlString: settingsStore.receiverURLString,
            bearerToken: bearerToken
        )
    }

    private var automaticSyncEnablePrerequisitesReady: Bool {
        bootstrapCompleted
            && committedReceiverSettingsAreComplete
            && healthPermissionsRequested
            && outboxIdentityMigrationReady
            && privateStorageAdmissionReady
            && !(outbox?.clearIntentIsActive ?? false)
            && !hasPendingPairing
            && connectionTerminalBarrier.admissionIsOpen
    }

    private var automaticSyncReady: Bool {
        automaticSyncEnablePrerequisitesReady
            && !terminalTransitionRequestIsActive
            && !taskUIPublicationIsSuppressed
            && backgroundSyncRequestedEnabled
    }

    var automaticSyncToggleIsOn: Bool {
        backgroundSyncRequestedEnabled
    }

    var canSaveReceiverSettings: Bool {
        !taskUIPublicationIsSuppressed
            && connectionTerminalBarrier.admissionIsOpen
            && Self.receiverSettingsAreComplete(
                urlString: receiverURLString,
                bearerToken: bearerToken
            )
    }

    var canSendConnectionTest: Bool {
        connectionTerminalBarrier.admissionIsOpen
            && !hasPendingPairing
            && receiverSettingsSaved
            && canSaveReceiverSettings
    }

    var canChangeAutomaticSyncSetting: Bool {
        backgroundSyncRequestedEnabled
            || backgroundSyncEnabled
            || (terminalUserActionAdmissionIsOpen && canSendConnectionTest)
    }

    var backgroundRefreshSchedulingAdmissionIsOpen: Bool {
        terminalPayloadActionAdmissionIsOpen
    }

    var canImportPairingText: Bool {
        !taskUIPublicationIsSuppressed
            && connectionTerminalBarrier.admissionIsOpen
            && privateStorageAdmissionReady
            && !hasPendingPrivateStorageRecovery
            && !isPairing
            && !pairingImportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canRedeemManualPairing: Bool {
        !taskUIPublicationIsSuppressed
            && connectionTerminalBarrier.admissionIsOpen
            && privateStorageAdmissionReady
            && !hasPendingPrivateStorageRecovery
            && !isPairing
            && !manualPairingServer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !manualPairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSyncStepCounts: Bool {
        canSendConnectionTest
    }

    var canSyncWorkouts: Bool {
        canSendConnectionTest
    }

    var canSyncSleep: Bool {
        canSendConnectionTest
    }

    var setupSnapshot: CompanionSetupSnapshot {
        CompanionSetupSnapshot(
            receiverURLString: receiverSettingsSaved ? receiverURLString : "",
            hasBearerToken: receiverSettingsSaved,
            healthPermissionsRequested: healthPermissionsRequested,
            isSyncing: isSyncing,
            statusIsError: statusIsError,
            pendingOutboxCount: pendingOutboxCount
        )
    }

    var setupState: CompanionSetupState {
        CompanionSetupState.evaluate(setupSnapshot)
    }

    var setupStateDetail: String {
        switch setupState {
        case .unpaired:
            return "Connect this iPhone before syncing Apple Health data."
        case .pairedNeedsHealthPermission:
            return "Open Apple Health and allow the data you want to sync."
        case .ready:
            return "Use Sync Now when you want to update your data."
        case .syncing:
            return "Sync is running. Keep the connection reachable until it finishes."
        case .degraded:
            return "Something needs attention. Run Sync Now again, then open Details if it still fails."
        }
    }

    var canRunPrimaryAction: Bool {
        guard terminalPayloadActionAdmissionIsOpen else { return false }
        switch setupState {
        case .unpaired, .syncing:
            return false
        case .pairedNeedsHealthPermission, .ready, .degraded:
            return true
        }
    }

    var statusLaneSummaries: [CompanionStatusLane] {
        CompanionStatusLaneBuilder.lanes(
            snapshot: setupSnapshot,
            backgroundSyncEnabled: backgroundSyncEnabled
        )
    }

    var automaticSyncScopeSummary: String {
        "All supported Apple Health data you allow. iOS decides background timing."
    }

    var healthPermissionScopeSummary: String {
        #if canImport(HealthKit)
        let runtimeAvailableTypeCount = HealthKitReadTypeCatalog.availableTypeCodes(
            forTypeCodes: HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
        ).count
        return "Requests read-only access to all \(runtimeAvailableTypeCount) supported types currently available on this iPhone; Apple Health still lets you deny each item."
        #else
        return "Apple Health read access is unavailable on this platform."
        #endif
    }

    var automaticSyncCoverageDetail: String {
        #if canImport(HealthKit)
        let runtimeAvailableQuantityTypeCount = HealthKitReadTypeCatalog.availableTypeCodes(
            forTypeCodes: enabledBroadQuantityTypeCodes
        ).count
        let activeObserverQueryCount = backgroundDeliveryCoordinator?.activeObserverCount ?? 0
        let backgroundDeliveryEnabledCount = backgroundDeliveryRegistrationResults.values.filter { $0 }.count
        let backgroundDeliveryFailureCount = backgroundDeliveryRegistrationErrors.count
        #else
        let runtimeAvailableQuantityTypeCount = 0
        let activeObserverQueryCount = 0
        let backgroundDeliveryEnabledCount = 0
        let backgroundDeliveryFailureCount = 0
        #endif
        return CompanionAutomaticSyncCoveragePresentation.detail(
            runtimeAvailableQuantityTypeCount: runtimeAvailableQuantityTypeCount,
            activeObserverQueryCount: activeObserverQueryCount,
            backgroundDeliveryEnabledCount: backgroundDeliveryEnabledCount,
            backgroundDeliveryFailureCount: backgroundDeliveryFailureCount
        )
    }

    var healthHistoryDepthRows: [HealthHistoryDepthOptionRow] {
        HealthHistoryDepthPresentation.optionRows(selected: healthHistoryDepth)
    }

    var healthHistoryDepthOptionID: String {
        HealthHistoryDepthPresentation.optionID(for: healthHistoryDepth)
    }

    var healthHistoryDepthSummary: String {
        HealthHistoryDepthPresentation.summary(selected: healthHistoryDepth)
    }

    var historicalBackfillSummary: String {
        HealthHistoricalBackfillPresentation.summary(state: historicalBackfillState)
    }

    func setHealthHistoryDepthOption(_ optionID: String) {
        guard terminalUserActionAdmissionIsOpen else { return }
        let selected = HealthHistoryDepthPresentation.historyDepth(forOptionID: optionID)
        healthHistoryDepthStore.saveHistoryDepth(selected)
        healthHistoryDepth = healthHistoryDepthStore.historyDepth
        statusIsError = false
        statusMessage = "Saved Apple Health history window: \(HealthHistoryDepthPresentation.summary(selected: healthHistoryDepth))"
    }

    func saveReceiverSettings() async {
        guard terminalUserActionAdmissionIsOpen else { return }
        defer { activateAutomaticSyncIfReady() }
        do {
            try await withTerminalTransitionRequestGate { [self] in
                pairingRequestEpoch.invalidate()
                let previousGeneration = settingsStore.receiverSettingsGenerationToken
                let newReceiverURLString = receiverURLString
                let newBearerToken = bearerToken
                let transition: (
                    result: Void,
                    committedGeneration: String,
                    postCommitRecoveryRequired: Bool
                )
                do {
                    transition = try await performTerminalConnectionTransitionWhileHoldingRequestGate(
                        cancelPairingOperation: true
                    ) { expectedGeneration in
                        try self.settingsStore.save(
                            receiverURLString: newReceiverURLString,
                            bearerToken: newBearerToken,
                            expectedGeneration: expectedGeneration
                        )
                    }
                } catch {
                    statusIsError = true
                    statusMessage = "Saving connection settings failed: \(describe(error))"
                    return
                }

                do {
                    try requireCommittedConnectionGenerationWhileHoldingRequestGate(
                        transition.committedGeneration
                    )
                    receiverSettingsSaved = Self.receiverSettingsAreComplete(
                        urlString: settingsStore.receiverURLString,
                        bearerToken: try settingsStore.loadBearerToken()
                    ) && settingsStore.receiverBindingID != nil && outboxIdentityMigrationReady
                    if settingsStore.receiverSettingsGenerationToken != previousGeneration {
                        reschedulePendingBackgroundOutboxUploadsAfterReceiverChange()
                    }
                    if transition.postCommitRecoveryRequired || !outboxIdentityMigrationReady {
                        statusIsError = true
                        statusMessage = "Connection saved, but private sync storage must recover before uploads can resume."
                    } else {
                        statusIsError = false
                        statusMessage = "Saved connection on this iPhone."
                    }
                } catch {
                    reloadCommittedReceiverSettings()
                    statusIsError = true
                    statusMessage = "Connection change was saved, but secure local verification failed. Reopen Settings before syncing."
                }
            }
        } catch {
            statusIsError = true
            statusMessage = "Saving connection settings was cancelled before it could start."
        }
    }

    func disconnectReceiver() async -> DisconnectReceiverOutcome {
        guard terminalUserActionAdmissionIsOpen else {
            return .rejected(
                message: "Another connection change is already in progress. Your saved server connection was not changed.",
                pendingOutboxCount: trustedPendingOutboxCount(),
                connectionPreserved: receiverSettingsSaved
            )
        }
        defer { activateAutomaticSyncIfReady() }
        do {
            return try await withTerminalTransitionRequestGate { [self] in
                await self.performDisconnectReceiverWhileHoldingRequestGate()
            }
        } catch {
            return .rejected(
                message: "The disconnect request was cancelled before it could start. Your saved server connection was not changed.",
                pendingOutboxCount: trustedPendingOutboxCount(),
                connectionPreserved: receiverSettingsSaved
            )
        }
    }

    private func performDisconnectReceiverWhileHoldingRequestGate() async -> DisconnectReceiverOutcome {
        do {
            try requireTrustedEmptyOutboxForConnectionTransition(
                outboxIdentityAdmissionWasReady: outboxIdentityMigrationReady
            )
            pairingRequestEpoch.invalidate()
            let transition = try await performTerminalConnectionTransitionWhileHoldingRequestGate(
                cancelPairingOperation: true
            ) { expectedGeneration in
                let expectedBindingID = self.settingsStore.receiverBindingID
                let backgroundSyncWasEnabled = self.backgroundSyncRequestedEnabled
                let expectedBackgroundSyncPreferenceGeneration =
                    self.backgroundSyncPreferenceGeneration
                let cancellationOutcome: ReceiverPairingCancellationOutcome
                do {
                    try self.backgroundSyncStore.setEnabledDurably(false)
                    cancellationOutcome = try self.pairingCoordinator.cancelPendingPairing(
                        expectedGeneration: expectedGeneration
                    )
                } catch {
                    let cancellationRecoveryIsPending =
                        (try? self.pairingCoordinator.hasPendingCancellationRecovery()) ?? true
                    let connectionIsUnchanged =
                        self.settingsStore.receiverSettingsGenerationToken == expectedGeneration
                        && self.settingsStore.receiverBindingID == expectedBindingID
                    let backgroundSyncPreferenceIsUnchanged =
                        self.backgroundSyncPreferenceGeneration
                        == expectedBackgroundSyncPreferenceGeneration
                    if self.committedReceiverSettingsAreComplete,
                       connectionIsUnchanged,
                       backgroundSyncPreferenceIsUnchanged,
                       !cancellationRecoveryIsPending {
                        do {
                            try self.backgroundSyncStore.setEnabledDurably(
                                backgroundSyncWasEnabled
                            )
                        } catch {
                            self.backgroundSyncRequestedEnabled = false
                            self.backgroundSyncEnabled = false
                        }
                    } else {
                        self.backgroundSyncRequestedEnabled = false
                        self.backgroundSyncEnabled = false
                    }
                    throw error
                }
                self.backgroundSyncPreferenceGeneration &+= 1
                self.backgroundSyncRequestedEnabled = false
                self.automaticSyncActivated = false
                self.backgroundSyncEnabled = false
                self.stopHealthKitBackgroundDelivery()
                return cancellationOutcome == .committedCleanupPending
            }
            let trustedPendingOutboxCount = self.trustedPendingOutboxCount()
            let cancellationCleanupRecoveryRequired = transition.result
            if cancellationCleanupRecoveryRequired {
                privateStorageAdmissionReady = false
                outboxIdentityMigrationReady = false
                hasPendingPrivateStorageRecovery = true
                automaticSyncActivated = false
                stopHealthKitBackgroundDelivery()
            }
            receiverURLString = settingsStore.receiverURLString
            bearerToken = ""
            receiverSettingsSaved = false
            hasPendingPairing = ((try? pairingCoordinator.hasPendingPairing()) ?? false)
                || cancellationCleanupRecoveryRequired
            backgroundSyncStatus = "Automatic sync is off. Sync Now still works."
            refreshPendingOutboxCount()
            if cancellationCleanupRecoveryRequired || transition.postCommitRecoveryRequired {
                statusIsError = true
                statusMessage = "Disconnected and turned automatic sync off. Private sync storage must recover before uploads can resume."
            } else {
                statusIsError = false
                if let trustedPendingOutboxCount {
                    statusMessage = "Disconnected and turned automatic sync off. Queued uploads: \(trustedPendingOutboxCount)."
                } else {
                    statusMessage = "Disconnected and turned automatic sync off. Queued-upload status is unavailable."
                }
            }
            return .disconnected(pendingOutboxCount: trustedPendingOutboxCount)
        } catch {
            reloadCommittedReceiverSettings()
            hasPendingPairing = (try? pairingCoordinator.hasPendingPairing()) ?? true
            let trustedPendingOutboxCount = self.trustedPendingOutboxCount()
            refreshPendingOutboxCount()
            let connectionPreserved = receiverSettingsSaved
            let failureMessage = "Disconnect failed: \(describe(error))"
            statusIsError = true
            statusMessage = failureMessage
            return .rejected(
                message: failureMessage,
                pendingOutboxCount: trustedPendingOutboxCount,
                connectionPreserved: connectionPreserved
            )
        }
    }

    private func checkReceiverHealth() async {
        guard let url = URL(string: receiverURLString) else {
            statusIsError = true
            statusMessage = "Bridge URL is invalid."
            return
        }

        do {
            statusIsError = false
            statusMessage = "Checking connection..."
            let result = try await receiverClient.healthCheck(forBatchURL: url)
            statusIsError = false
            statusMessage = "Connection check passed with HTTP \(result.statusCode)."
        } catch {
            statusIsError = true
            statusMessage = "Local bridge check failed: \(describe(error))"
        }
    }

    func checkConnection() async {
        guard terminalPayloadActionAdmissionIsOpen else { return }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCheckConnection()
        }
        trackedSyncTasks[taskID] = task
        await task.value
        trackedSyncTasks.removeValue(forKey: taskID)
    }

    func cancelCurrentForegroundAction() async {
        let activeTasks = Array(trackedSyncTasks.values)
        guard !activeTasks.isEmpty else { return }
        activeTasks.forEach { $0.cancel() }
        for task in activeTasks {
            await task.value
        }
        isSyncing = false
        isCheckingConnection = false
        statusIsError = false
        statusMessage = "Cancelled. Any already queued uploads remain available for retry."
    }

    private func performCheckConnection() async {
        guard !isCheckingConnection else { return }
        guard canSendConnectionTest, !Task.isCancelled else {
            statusIsError = true
            statusMessage = "Connection test is paused while pairing recovery is in progress."
            return
        }
        isCheckingConnection = true
        statusIsError = false
        statusMessage = "Checking connection..."
        defer {
            if !taskUIPublicationIsSuppressed {
                isCheckingConnection = false
            }
        }

        await checkReceiverHealth()
    }

    func performPrimaryAction() async {
        guard terminalPayloadActionAdmissionIsOpen else { return }
        switch setupState {
        case .unpaired:
            statusIsError = false
            statusMessage = "Connect this iPhone first using the setup link or manual settings."
        case .pairedNeedsHealthPermission:
            await requestHealthPermissions()
        case .ready, .degraded:
            await syncAllNow()
        case .syncing:
            break
        }
    }

    func syncAllNow() async {
        guard terminalPayloadActionAdmissionIsOpen else { return }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.runWithExclusiveDirectOutboxTransfer {
                    await self.performSyncAllNow()
                }
            } catch is CancellationError {
                return
            } catch {
                self.statusIsError = true
                self.statusMessage = "Sync could not acquire private storage access: \(self.describe(error))"
            }
        }
        trackedSyncTasks[taskID] = task
        await task.value
        trackedSyncTasks.removeValue(forKey: taskID)
        if !bootstrapCompleted {
            await bootstrap()
        }
    }

    private func runWithExclusiveDirectOutboxTransfer<Result>(
        _ operation: @escaping @MainActor () async -> Result
    ) async throws -> Result {
        directOutboxTransferRequestCount += 1
        do {
            try await directOutboxTransferGate.acquire()
        } catch {
            directOutboxTransferRequestCount -= 1
            if directOutboxTransferRequestCount == 0 {
                schedulePendingBackgroundOutboxUploadsIfAllowed()
            }
            throw error
        }
        do {
            #if os(iOS)
            await cancelBackgroundOutboxSchedulingIfNeeded()
            let cancellationResult = await BackgroundURLSessionOutboxUploader.shared
                .cancelPendingUploads()
            let legacyCancellationResult = await BackgroundURLSessionOutboxUploader.shared
                .cancelInheritedLegacyUploads()
            let hasPendingUploadTasks = await BackgroundURLSessionOutboxUploader.shared
                .hasPendingUploadTasks()
            guard BackgroundUploadCancellationPolicy.canBeginDirectTransfer(
                cancellationWasFullyFinalized: cancellationResult.fullyFinalized
                    && legacyCancellationResult.fullyFinalized,
                hasPendingUploadTasks: hasPendingUploadTasks
            ) else {
                throw CancellationError()
            }
            #endif
            let result = await operation()
            await finishExclusiveDirectOutboxTransfer()
            return result
        } catch {
            await finishExclusiveDirectOutboxTransfer()
            throw error
        }
    }

    private func finishExclusiveDirectOutboxTransfer() async {
        await directOutboxTransferGate.release()
        directOutboxTransferRequestCount -= 1
        if directOutboxTransferRequestCount == 0 {
            schedulePendingBackgroundOutboxUploadsIfAllowed()
        }
    }

    private func performSyncAllNow() async {
        guard canSendConnectionTest else {
            statusIsError = true
            statusMessage = "Local bridge settings are incomplete. Connect or save settings before syncing."
            return
        }

        do {
            try preparePrivateStorageForUploadAdmission()
        } catch {
            refreshPendingOutboxCount()
            statusIsError = true
            statusMessage = "Sync is blocked until private storage is recovered: \(describe(error))"
            return
        }

        isSyncing = true
        statusIsError = false
        statusMessage = "Starting sync for allowed Apple Health data."
        defer {
            if !taskUIPublicationIsSuppressed {
                isSyncing = false
            }
        }
        for step in CompanionSyncNowPlan.defaultSteps {
            guard !hasPendingPairing, !Task.isCancelled else {
                statusIsError = true
                statusMessage = "Sync stopped because pairing recovery is in progress."
                return
            }
            switch step {
            case .checkReceiverReachability:
                await checkReceiverHealth()
            case .flushPendingOutboxBeforeSync:
                if pendingOutboxCount > 0 {
                    guard await flushPendingOutbox() else {
                        statusMessage = "Sync stopped: \(statusMessage)"
                        return
                    }
                }
                continue
            case .syncAnchoredSteps:
                _ = await syncRecentStepCounts()
            case .syncDailyActivityAggregates:
                _ = await syncDailyActivityAggregates()
            case .syncAnchoredWorkouts:
                _ = await syncAnchoredWorkoutChanges()
            case .syncSleep:
                _ = await syncRecentSleepSessions()
            case .syncSupportedQuantityMetrics:
                await syncSupportedQuantityMetrics()
            }

            if statusIsError {
                statusMessage = "Sync stopped: \(statusMessage)"
                return
            }
        }

        let completion = CompanionSyncNowCompletion.summary(
            pendingOutboxCount: pendingOutboxCount
        )
        statusIsError = completion.isError
        statusMessage = completion.message
    }

    private func flushPendingOutbox() async -> Bool {
        guard !hasPendingPairing, !Task.isCancelled else {
            statusIsError = true
            statusMessage = "Queued upload retry is paused while pairing recovery is in progress."
            return false
        }
        do {
            try preparePrivateStorageForUploadAdmission()
        } catch {
            refreshPendingOutboxCount()
            statusIsError = true
            statusMessage = "Queued upload retry is blocked until private storage is recovered: \(describe(error))"
            return false
        }
        guard let outbox else {
            refreshPendingOutboxCount()
            statusIsError = true
            statusMessage = CompanionPrivateStorageError.outboxUnavailable.localizedDescription
            return false
        }
        guard let url = URL(string: receiverURLString) else {
            statusIsError = true
            statusMessage = "Bridge URL is invalid."
            return false
        }

        do {
            let expectedGeneration = settingsStore.receiverSettingsGenerationToken
            try requireCurrentConnectionGeneration(expectedGeneration)
            let uploadBearerToken = try settingsStore.loadBearerToken()
            guard settingsStore.receiverURLString == url.absoluteString else {
                throw CancellationError()
            }
            let summary = try await uploadPendingOutbox(
                outbox,
                to: url,
                bearerToken: uploadBearerToken,
                expectedGeneration: expectedGeneration
            )
            try requireCurrentConnectionGeneration(expectedGeneration)
            refreshPendingOutboxCount()
            if summary.failedCount > 0 {
                statusIsError = true
                statusMessage = "Some queued uploads did not finish: attempted \(summary.attemptedCount), uploaded \(summary.uploadedCount), failed \(summary.failedCount). \(Self.firstFailureSentence(summary)) Queued uploads: \(pendingOutboxCount)."
            } else {
                statusIsError = false
                statusMessage = "Queued uploads sent: \(summary.uploadedCount). Remaining: \(pendingOutboxCount)."
            }
            return true
        } catch let conflict as RejectedSleepBaselineOutboxItem {
            do {
                try recoverRejectedSleepBaseline(conflict)
                statusIsError = false
                statusMessage = "Receiver rejected an older Sleep reset epoch. The rejected FIFO item was retired durably; a newer authoritative baseline will be generated."
                return true
            } catch {
                refreshPendingOutboxCount()
                statusIsError = true
                statusMessage = "Queued Sleep epoch recovery failed: \(describe(error))"
                return false
            }
        } catch {
            refreshPendingOutboxCount()
            statusIsError = true
            statusMessage = "Queued upload retry failed: \(describe(error))"
            return false
        }
    }

    func clearPendingOutbox() async {
        guard terminalUserActionAdmissionIsOpen else { return }
        defer { activateAutomaticSyncIfReady() }
        let needsBootstrap: Bool
        do {
            needsBootstrap = try await withTerminalTransitionRequestGate { [self] in
                pairingRequestEpoch.invalidate()
                return await self.performClearPendingOutboxWhileHoldingRequestGate()
            }
        } catch {
            statusIsError = true
            statusMessage = "Private sync-state reset was cancelled before it could start."
            return
        }
        if needsBootstrap {
            await retryBootstrapAfterRecoveryIfNeeded()
        }
    }

    private func performClearPendingOutboxWhileHoldingRequestGate() async -> Bool {
        let expectedConnectionGeneration = settingsStore.receiverSettingsGenerationToken
        let cleared: Bool
        do {
            cleared = try await connectionTerminalBarrier.performRecovery(
                closeAdmission: {
                    self.privateStorageAdmissionReady = false
                    self.automaticSyncActivated = false
                    self.stopHealthKitBackgroundDelivery()
                },
                cancelAndAwaitPairing: {
                    await self.cancelPairingOperationIfNeeded()
                },
                cancelAndAwaitForegroundPayloads: {
                    await self.cancelAndAwaitForegroundPayloadTasks()
                },
                drainBackgroundPayloads: {
                    await self.drainBackgroundPayloadCancellation()
                },
                commit: {
                    try await self.runWithExclusiveDirectOutboxTransfer {
                        do {
                            do {
                                try self.retryPrivateStoreInitialization()
                            } catch {
                                self.outbox = nil
                            }
                            try self.requireUnchangedConnectionGenerationDuringRecovery(
                                expectedConnectionGeneration
                            )
                            if let outbox = self.outbox {
                                try outbox.beginClearIntent()
                            } else {
                                guard let outboxDirectoryURL = self.outboxDirectoryURL else {
                                    throw CompanionPrivateStorageError.outboxUnavailable
                                }
                                try FileOutbox.beginDestructiveRecovery(directory: outboxDirectoryURL)
                            }
                            self.refreshPendingOutboxCount()
                        } catch {
                            self.refreshPendingOutboxCount()
                            self.statusIsError = true
                            self.statusMessage = "Starting queued-upload deletion failed: \(self.describe(error))"
                            return false
                        }
                        return await self.performClearPendingOutbox(outbox: self.outbox)
                    }
                }
            )
        } catch {
            statusIsError = true
            statusMessage = "Private sync-state reset failed: \(describe(error))"
            return false
        }
        guard cleared else { return false }
        if bootstrapCompleted {
            do {
                try preparePrivateStorageForUploadAdmission()
            } catch {
                statusIsError = true
                statusMessage = "Private storage recovery failed: \(describe(error))"
            }
            return false
        }
        return true
    }

    private func resetPrivateSyncProgressForClear() throws {
        if connectionStateNeedsRecovery {
            try settingsStore.resetInvalidConnectionRecord()
            connectionStateNeedsRecovery = false
        } else {
            try settingsStore.resolveTerminalCancellationForPrivateReset()
        }
        try pairingStateStore.resetPrivatePairingState()
        hasPendingPairing = false
        if sleepManifestStore == nil,
           let sleepManifestFileURL {
            sleepManifestStore = try FileSleepSyncManifestStore(
                fileURL: sleepManifestFileURL
            )
        }
        guard let sleepManifestStore else {
            throw CompanionPrivateStorageError.sleepManifestUnavailable
        }
        try sleepManifestStore.resetSynchronizationState()
        if cursorStateNeedsRecovery {
            guard let cursorStoreFileURL else {
                throw CompanionPrivateStorageError.cursorStoreUnavailable
            }
            cursorStore = try FileSyncCursorStore.replaceWithEmptyStore(
                fileURL: cursorStoreFileURL
            )
        } else if cursorStore == nil {
            guard let cursorStoreFileURL else {
                throw CompanionPrivateStorageError.cursorStoreUnavailable
            }
            cursorStore = try FileSyncCursorStore(fileURL: cursorStoreFileURL)
        }
        guard let cursorStore else {
            throw CompanionPrivateStorageError.cursorStoreUnavailable
        }
        try cursorStore.resetAll()
        try backgroundSyncStore.resetPendingObserverDirtiness()
        coreLaneUploadProofStore.resetAll()
        historicalBackfillStateStore.reset()
        refreshHistoricalBackfillPublishedStateIfAllowed()
        cursorStateNeedsRecovery = false
    }

    private func performClearPendingOutbox(outbox: FileOutbox?) async -> Bool {
        do {
            try resetPrivateSyncProgressForClear()
            let removedCount: Int
            if let outbox {
                removedCount = try outbox.clearPendingWhileIntentIsActive()
                try outbox.finishClearIntent()
            } else {
                guard let outboxDirectoryURL else {
                    throw CompanionPrivateStorageError.outboxUnavailable
                }
                let recovery = try FileOutbox.completeDestructiveRecovery(
                    directory: outboxDirectoryURL
                )
                self.outbox = recovery.outbox
                removedCount = recovery.removedPayloadCount
            }
            outboxIdentityMigrationReady = true
            hasPendingPrivateStorageRecovery = false
            hasTransientPrivateStorageFailure = false
            reloadCommittedReceiverSettings()
            refreshPendingOutboxCount()
            statusIsError = false
            statusMessage = "Cleared \(removedCount) queued upload(s) and reset local sync progress. The next connected sync will rebuild receiver history."
            return true
        } catch {
            refreshPendingOutboxCount()
            statusIsError = true
            statusMessage = "Clearing queued uploads failed: \(describe(error))"
            return false
        }
    }

    func retryPrivateStorage() async {
        guard terminalUserActionAdmissionIsOpen else { return }
        bootstrapCompleted = false
        await bootstrap()
    }

    func retryPendingPairing() async {
        guard terminalUserActionAdmissionIsOpen, hasPendingPairing else { return }
        bootstrapCompleted = false
        statusIsError = false
        statusMessage = "Retrying the pending pairing attempt..."
        await bootstrap()
    }

    func bootstrap() async {
        guard !terminalTransitionRequestIsActive else { return }
        let attemptID: UUID
        let attemptTask: Task<Void, Never>
        if let existingAttemptID = bootstrapAttemptID,
           let existingTask = bootstrapTask {
            attemptID = existingAttemptID
            attemptTask = existingTask
        } else {
            attemptID = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performBootstrap()
                self.finishBootstrapAttempt(attemptID)
            }
            bootstrapTask = task
            bootstrapAttemptID = attemptID
            attemptTask = task
        }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else if bootstrapAttemptID == attemptID, bootstrapTask != nil {
                    bootstrapWaiters[waiterID] = continuation
                } else {
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelBootstrapWaiter(waiterID, attemptID: attemptID)
            }
        }
        if attemptTask.isCancelled, !Task.isCancelled {
            await attemptTask.value
            await bootstrap()
        }
    }

    private func finishBootstrapAttempt(_ attemptID: UUID) {
        guard bootstrapAttemptID == attemptID else { return }
        bootstrapTask = nil
        bootstrapAttemptID = nil
        let waiters = Array(bootstrapWaiters.values)
        bootstrapWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func cancelBootstrapWaiter(_ waiterID: UUID, attemptID: UUID) {
        guard let waiter = bootstrapWaiters.removeValue(forKey: waiterID) else { return }
        waiter.resume()
        if bootstrapWaiters.isEmpty, bootstrapAttemptID == attemptID {
            bootstrapTask?.cancel()
        }
    }

    private func retryBootstrapAfterRecoveryIfNeeded() async {
        if bootstrapTask != nil { await bootstrap() }
        guard !bootstrapCompleted else { return }
        await bootstrap()
    }

    private func performBootstrap() async {
        #if os(iOS)
        let inheritedUploadCancellation = await BackgroundURLSessionOutboxUploader.shared
            .cancelInheritedLegacyUploads()
        if !inheritedUploadCancellation.fullyFinalized {
            backgroundSyncStatus = "Inherited background upload cleanup is still finalizing; automatic transfers remain blocked."
            return
        } else if inheritedUploadCancellation.cancelledCount > 0 {
            backgroundSyncStatus = "Cancelled \(inheritedUploadCancellation.cancelledCount) inherited background upload task(s) before private-state migration."
        }
        #endif
        guard await recoverPendingOutboxClearIfNeeded() else { return }
        guard !Task.isCancelled else { return }
        if !backgroundSyncEnabled {
            guard await drainBackgroundPayloadCancellation() else {
                backgroundSyncStatus = "Background transfer cleanup is still finalizing; bootstrap remains fail-closed."
                return
            }
        }
        guard !Task.isCancelled else { return }
        await resumePendingPairingIfNeeded()
        guard !Task.isCancelled else { return }
        reloadCommittedReceiverSettings()
        refreshPendingPairingState()
        let preparationFailure: String?
        do {
            preparationFailure = try await runWithExclusiveDirectOutboxTransfer {
                do {
                    try self.preparePrivateStorageForUploadAdmission()
                    return Optional<String>.none
                } catch {
                    return self.describe(error)
                }
            }
        } catch {
            preparationFailure = describe(error)
        }
        if let preparationFailure {
            refreshPendingOutboxCount()
            statusIsError = true
            statusMessage = "Private upload storage needs recovery before sync can start: \(preparationFailure)"
            return
        }
        guard !Task.isCancelled else { return }
        bootstrapCompleted = true
        activateAutomaticSyncIfReady()
        if hasPendingPairing {
            statusIsError = true
            statusMessage = "Pairing recovery is still pending. Automatic sync remains paused until recovery succeeds or you cancel it."
        }
    }

    private func recoverPendingOutboxClearIfNeeded() async -> Bool {
        try? retryPrivateStoreInitialization()
        let rawIntentExists = outboxDirectoryURL.map {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent(".clear-intent").path
            )
        } ?? false
        guard outbox?.clearIntentIsActive == true || rawIntentExists else { return true }
        privateStorageAdmissionReady = false
        hasPendingOutboxDeletion = true
        automaticSyncActivated = false
        stopHealthKitBackgroundDelivery()
        guard await drainBackgroundPayloadCancellation() else {
            statusIsError = true
            statusMessage = "Queued-upload deletion recovery is waiting for background transfer cleanup to finish. Uploads remain blocked."
            backgroundSyncStatus = "Background transfer cleanup is still finalizing; queued-upload deletion remains fail-closed."
            return false
        }
        do {
            try resetPrivateSyncProgressForClear()
            let removedCount: Int
            if let outbox {
                removedCount = try outbox.clearPendingWhileIntentIsActive()
                try outbox.finishClearIntent()
            } else {
                guard let outboxDirectoryURL else {
                    throw CompanionPrivateStorageError.outboxUnavailable
                }
                let recovery = try FileOutbox.completeDestructiveRecovery(
                    directory: outboxDirectoryURL
                )
                self.outbox = recovery.outbox
                removedCount = recovery.removedPayloadCount
            }
            outboxIdentityMigrationReady = true
            hasPendingPrivateStorageRecovery = false
            hasTransientPrivateStorageFailure = false
            refreshPendingOutboxCount()
            statusIsError = false
            statusMessage = "Finished the interrupted deletion of \(removedCount) queued upload(s)."
            return true
        } catch {
            refreshPendingOutboxCount()
            statusIsError = true
            statusMessage = "Queued-upload deletion recovery failed. Uploads remain blocked: \(describe(error))"
            return false
        }
    }

    func resumePendingPairingIfNeeded() async {
        await runTrackedPairingOperation(kind: .bootstrapRecovery) { [weak self] in
            await self?.performResumePendingPairingIfNeeded()
        }
    }

    private func performResumePendingPairingIfNeeded() async {
        guard !taskUIPublicationIsSuppressed,
              connectionTerminalBarrier.admissionIsOpen else {
            return
        }
        guard !hasPendingPrivateStorageRecovery, outboxIdentityMigrationReady else { return }
        guard !isPairing else { return }
        guard (try? pairingCoordinator.hasPendingPairing()) != false else { return }
        isPairing = true
        defer {
            if !taskUIPublicationIsSuppressed {
                isPairing = false
                finishPairingAttempt()
            }
        }
        do {
            hasPendingPairing = true
            if try pairingCoordinator.hasPendingCancellationRecovery() {
                _ = try await performTerminalConnectionTransitionWhileHoldingRequestGate(
                    cancelPairingOperation: false,
                    advanceGeneration: false
                ) { expectedGeneration in
                    try self.pairingCoordinator.finishPendingCancellationIfNeeded(
                        expectedGeneration: expectedGeneration
                    )
                }
                reloadCommittedReceiverSettings()
                return
            }
            let previousGeneration = settingsStore.receiverSettingsGenerationToken
            let transition = try await performTerminalConnectionTransitionWhileHoldingRequestGate(
                cancelPairingOperation: false
            ) { expectedGeneration in
                try await self.pairingCoordinator.resumePendingPairing(
                    expectedGeneration: expectedGeneration
                )
            }
            guard let credential = transition.result else {
                reloadCommittedReceiverSettings()
                return
            }
            try requireCommittedConnectionGenerationWhileHoldingRequestGate(transition.committedGeneration)
            applyCommittedPairingCredential(
                credential,
                previousGeneration: previousGeneration
            )
        } catch {
            reloadCommittedReceiverSettings()
            statusIsError = true
            statusMessage = "Finishing the previous pairing attempt failed: \(describe(error))"
        }
    }

    func cancelPendingPairing() async {
        guard terminalUserActionAdmissionIsOpen else { return }
        do {
            try await withTerminalTransitionRequestGate { [self] in
                await self.performCancelPendingPairingWhileHoldingRequestGate()
            }
        } catch {
            statusIsError = true
            statusMessage = "Pending pairing cancellation was cancelled before it could start."
        }
    }

    private func performCancelPendingPairingWhileHoldingRequestGate() async {
        pairingRequestEpoch.invalidate()
        hasPendingPairing = true
        automaticSyncActivated = false
        stopHealthKitBackgroundDelivery()
        do {
            let transition = try await performTerminalConnectionTransitionWhileHoldingRequestGate(
                cancelPairingOperation: true
            ) { expectedGeneration in
                try self.pairingCoordinator.cancelPendingPairing(
                    expectedGeneration: expectedGeneration
                )
            }
            try requireCommittedConnectionGenerationWhileHoldingRequestGate(transition.committedGeneration)
            receiverURLString = ReceiverSettingsStore.defaultReceiverURLString
            bearerToken = ""
            receiverSettingsSaved = false
            let cancellationCleanupRecoveryRequired =
                transition.result == .committedCleanupPending
            let cleanupRecoveryRequired =
                cancellationCleanupRecoveryRequired
                || transition.postCommitRecoveryRequired
            if cancellationCleanupRecoveryRequired {
                privateStorageAdmissionReady = false
                outboxIdentityMigrationReady = false
                hasPendingPrivateStorageRecovery = true
                automaticSyncActivated = false
                stopHealthKitBackgroundDelivery()
            }
            hasPendingPairing = ((try? pairingCoordinator.hasPendingPairing()) ?? false)
                || cancellationCleanupRecoveryRequired
            if cleanupRecoveryRequired {
                statusIsError = true
                statusMessage = "Cancelled pending pairing and cleared the uncertain connection. Private cleanup will finish during recovery."
            } else {
                statusIsError = false
                statusMessage = "Cancelled pending pairing and cleared the uncertain active connection. Start a fresh pairing invitation."
            }
        } catch {
            reloadCommittedReceiverSettings()
            hasPendingPairing = true
            receiverSettingsSaved = false
            statusIsError = true
            statusMessage = "Cancelling pending pairing failed: \(describe(error))"
        }
    }

    private func runTrackedPairingOperation(
        kind: PairingOperationCategory = .userInitiated,
        skipAfterBootstrapRecovery: Bool = false,
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        let allowsClosedPayloadAdmission = kind == .bootstrapRecovery
        guard terminalUserActionAdmissionIsOpen,
              allowsClosedPayloadAdmission || connectionTerminalBarrier.admissionIsOpen else {
            return
        }
        let capturedPairingRequestEpoch = pairingRequestEpoch.capture()
        if let existingTask = pairingTask {
            let existingAttemptID = pairingAttemptID
            let existingKind = pairingOperationKind
            await existingTask.value
            if pairingAttemptID == existingAttemptID {
                pairingTask = nil
                pairingAttemptID = nil
                pairingOperationKind = nil
            }
            guard pairingRequestEpoch.isCurrent(capturedPairingRequestEpoch) else {
                return
            }
            guard PairingOperationSequencingPolicy.shouldRunAfterWaiting(
                existing: existingKind,
                requested: kind,
                matchesPendingBootstrapInvitation: skipAfterBootstrapRecovery
            ) else {
                return
            }
            if let queuedUserTask = pairingTask {
                await queuedUserTask.value
                return
            }
        }
        guard terminalUserActionAdmissionIsOpen,
              allowsClosedPayloadAdmission || connectionTerminalBarrier.admissionIsOpen,
              pairingRequestEpoch.isCurrent(capturedPairingRequestEpoch) else {
            return
        }
        let attemptID = UUID()
        let task = Task { @MainActor in
            do {
                try await withTerminalTransitionRequestGate(
                    allowDuringActiveBootstrap: kind == .bootstrapRecovery
                ) {
                    await operation()
                }
            } catch {
                return
            }
        }
        pairingAttemptID = attemptID
        pairingOperationKind = kind
        pairingTask = task
        await task.value
        if pairingAttemptID == attemptID {
            pairingTask = nil
            pairingAttemptID = nil
            pairingOperationKind = nil
        }
        guard !Task.isCancelled else { return }
        activateAutomaticSyncIfReady()
    }

    private func cancelPairingOperationIfNeeded() async {
        guard let task = pairingTask else { return }
        pairingTask = nil
        pairingAttemptID = nil
        pairingOperationKind = nil
        task.cancel()
        await task.value
    }

    private func finishPairingAttempt() {
        refreshPendingPairingState()
        guard !Task.isCancelled else {
            automaticSyncActivated = false
            stopHealthKitBackgroundDelivery()
            return
        }
        activateAutomaticSyncIfReady()
    }

    private func refreshPendingPairingState() {
        do {
            hasPendingPairing = try pairingCoordinator.hasPendingPairing()
        } catch {
            hasPendingPairing = true
        }
    }

    private func reloadCommittedReceiverSettings() {
        guard !taskUIPublicationIsSuppressed else { return }
        let savedBearerToken = (try? settingsStore.loadBearerToken()) ?? ""
        receiverURLString = settingsStore.receiverURLString
        bearerToken = savedBearerToken
        receiverSettingsSaved = Self.receiverSettingsAreComplete(
            urlString: receiverURLString,
            bearerToken: bearerToken
        ) && settingsStore.receiverBindingID != nil
            && outboxIdentityMigrationReady
    }

    private func requireTrustedEmptyOutboxForConnectionTransition(
        outboxIdentityAdmissionWasReady: Bool
    ) throws {
        guard let outbox else {
            throw CompanionPrivateStorageError.outboxUnavailable
        }
        let pendingItemCount = try outbox.pendingItems().count
        guard ReceiverConnectionTransitionPolicy.canBegin(
            outboxIdentityAdmissionReady: outboxIdentityAdmissionWasReady,
            pendingItemCount: pendingItemCount,
            clearIntentIsActive: outbox.clearIntentIsActive
        ) else {
            throw ReceiverOutboxIdentityError.receiverTransitionRequiresEmptyOutbox
        }
    }

    private func refreshHistoricalBackfillPublishedStateIfAllowed() {
        guard !taskUIPublicationIsSuppressed else { return }
        historicalBackfillState = historicalBackfillStateStore.state
    }

    private func beginTerminalTaskUIPublicationSuppression() {
        terminalTaskUIPublicationSuppressionDepth += 1
    }

    private func endTerminalTaskUIPublicationSuppression() {
        precondition(terminalTaskUIPublicationSuppressionDepth > 0)
        terminalTaskUIPublicationSuppressionDepth -= 1
        guard terminalTaskUIPublicationSuppressionDepth == 0 else { return }
        refreshPendingOutboxCount()
        refreshPendingPairingState()
        refreshHistoricalBackfillPublishedStateIfAllowed()
        isSyncing = false
        isCheckingConnection = false
        if pairingTask == nil {
            isPairing = false
        }
    }

    private func withTerminalTransitionRequestGate<Result>(
        allowDuringActiveBootstrap: Bool = false,
        afterSuccessfulRelease: (@MainActor () -> Void)? = nil,
        _ operation: @escaping @MainActor () async throws -> Result
    ) async throws -> Result {
        guard !terminalTransitionRequestIsActive else {
            throw CancellationError()
        }
        terminalTransitionRequestIsActive = true
        do {
            let result = try await terminalTransitionRequestCoordinator.perform(
                canStartAfterAcquire: { [self] in
                    allowDuringActiveBootstrap || bootstrapTask == nil
                },
                operation: operation
            )
            terminalTransitionRequestIsActive = false
            afterSuccessfulRelease?()
            return result
        } catch {
            terminalTransitionRequestIsActive = false
            throw error
        }
    }

    private func performTerminalConnectionTransitionWhileHoldingRequestGate<Result>(
        cancelPairingOperation: Bool,
        advanceGeneration: Bool = true,
        commit: @escaping @MainActor (String) async throws -> Result
    ) async throws -> (
        result: Result,
        committedGeneration: String,
        postCommitRecoveryRequired: Bool
    ) {
        beginTerminalTaskUIPublicationSuppression()
        if cancelPairingOperation {
            await cancelPairingOperationIfNeeded()
        }
        let outboxIdentityAdmissionWasReady = outboxIdentityMigrationReady
        var previousBindingID: String?
        let transition: (result: Result, committedGeneration: String)
        do {
            transition = try await connectionTerminalBarrier.perform(
            closeAdmission: {
                previousBindingID = self.settingsStore.receiverBindingID
                self.privateStorageAdmissionReady = false
                self.outboxIdentityMigrationReady = false
                self.automaticSyncActivated = false
                self.stopHealthKitBackgroundDelivery()
            },
            invalidateGeneration: {
                if advanceGeneration {
                    return try self.settingsStore.invalidateReceiverSettingsGeneration()
                }
                return self.settingsStore.receiverSettingsGenerationToken
            },
            cancelAndAwaitPairing: {
                if cancelPairingOperation {
                    await self.cancelPairingOperationIfNeeded()
                }
            },
            cancelAndAwaitForegroundPayloads: {
                await self.cancelAndAwaitForegroundPayloadTasks()
            },
            drainBackgroundPayloads: {
                await self.drainBackgroundPayloadCancellation()
            },
            commit: { expectedGeneration in
                try self.requireTrustedEmptyOutboxForConnectionTransition(
                    outboxIdentityAdmissionWasReady: outboxIdentityAdmissionWasReady
                )
                let result = try await commit(expectedGeneration)
                let committedBindingID = self.settingsStore.receiverBindingID
                if committedBindingID != previousBindingID {
                    do {
                        try self.cursorStore?.resetAll()
                        self.cursorStateNeedsRecovery = false
                    } catch {
                        self.cursorStore = nil
                        self.cursorStateNeedsRecovery = false
                        self.hasTransientPrivateStorageFailure = true
                        self.privateStorageAdmissionReady = false
                    }
                    self.coreLaneUploadProofStore.resetAll()
                    self.historicalBackfillStateStore.reset()
                    self.refreshHistoricalBackfillPublishedStateIfAllowed()
                }
                return (
                    result: result,
                    committedGeneration: self.settingsStore.receiverSettingsGenerationToken
                )
            }
            )
        } catch {
            endTerminalTaskUIPublicationSuppression()
            restorePrivateStorageAdmissionAfterFailedConnectionTransition()
            throw error
        }
        endTerminalTaskUIPublicationSuppression()
        do {
            try preparePrivateStorageForUploadAdmission()
        } catch {
            privateStorageAdmissionReady = false
            outboxIdentityMigrationReady = false
            return (
                result: transition.result,
                committedGeneration: transition.committedGeneration,
                postCommitRecoveryRequired: true
            )
        }
        return (
            result: transition.result,
            committedGeneration: transition.committedGeneration,
            postCommitRecoveryRequired: false
        )
    }

    private func restorePrivateStorageAdmissionAfterFailedConnectionTransition() {
        do {
            if try pairingCoordinator.hasPendingCancellationRecovery() {
                privateStorageAdmissionReady = false
                outboxIdentityMigrationReady = false
                return
            }
            try preparePrivateStorageForUploadAdmission()
        } catch {
            privateStorageAdmissionReady = false
            outboxIdentityMigrationReady = false
        }
    }

    private func cancelAndAwaitForegroundPayloadTasks() async {
        let catchUpTask = foregroundCatchUpTask
        foregroundCatchUpTask = nil
        catchUpTask?.cancel()
        let observerRetryTask = backgroundObserverRetryTask
        backgroundObserverRetryTask = nil
        observerRetryTask?.cancel()
        let activeSyncTasks = Array(trackedSyncTasks.values)
        trackedSyncTasks.removeAll()
        activeSyncTasks.forEach { $0.cancel() }
        for task in activeSyncTasks {
            await task.value
        }
        await catchUpTask?.value
        await observerRetryTask?.value
    }

    private func drainBackgroundPayloadCancellation() async -> Bool {
        #if os(iOS)
        await cancelBackgroundOutboxSchedulingIfNeeded()
        let cancellationResult = await BackgroundURLSessionOutboxUploader.shared
            .cancelPendingUploads()
        let legacyCancellationResult = await BackgroundURLSessionOutboxUploader.shared
            .cancelInheritedLegacyUploads()
        let hasPendingUploadTasks = await BackgroundURLSessionOutboxUploader.shared
            .hasPendingUploadTasks()
        return BackgroundUploadCancellationPolicy.canBeginDirectTransfer(
            cancellationWasFullyFinalized: cancellationResult.fullyFinalized
                && legacyCancellationResult.fullyFinalized,
            hasPendingUploadTasks: hasPendingUploadTasks
        )
        #else
        return true
        #endif
    }

    private func requireUnchangedConnectionGenerationDuringRecovery(
        _ expectedGeneration: String
    ) throws {
        try Task.checkCancellation()
        guard settingsStore.receiverSettingsGenerationToken == expectedGeneration else {
            throw CancellationError()
        }
    }

    private func requireCommittedConnectionGenerationWhileHoldingRequestGate(
        _ expectedGeneration: String
    ) throws {
        guard settingsStore.receiverSettingsGenerationToken == expectedGeneration else {
            throw CancellationError()
        }
    }

    private func requireCurrentConnectionGeneration(_ expectedGeneration: String) throws {
        try Task.checkCancellation()
        guard connectionTerminalBarrier.allowsPostResponseMutation(
            capturedGeneration: expectedGeneration,
            currentGeneration: settingsStore.receiverSettingsGenerationToken
        ) else {
            throw CancellationError()
        }
    }

    private func captureReceiverSyncProgressScope() throws -> (FileSyncCursorStore, ReceiverSyncProgressScope) {
        try Task.checkCancellation()
        guard let cursorStore else {
            throw CompanionPrivateStorageError.cursorStoreUnavailable
        }
        guard let receiverBindingID = settingsStore.receiverBindingID else {
            throw CompanionPrivateStorageError.receiverIdentityUnavailable
        }
        let scope = ReceiverSyncProgressScope(
            receiverBindingID: receiverBindingID,
            connectionGeneration: settingsStore.receiverSettingsGenerationToken
        )
        try requireCurrentReceiverSyncProgressScope(scope)
        return (cursorStore, scope)
    }

    private func requireCurrentReceiverSyncProgressScope(
        _ scope: ReceiverSyncProgressScope,
        deliveryGeneration: String? = nil
    ) throws {
        try requireCurrentConnectionGeneration(scope.connectionGeneration)
        guard settingsStore.receiverBindingID == scope.receiverBindingID,
              deliveryGeneration == nil || deliveryGeneration == scope.connectionGeneration else {
            throw CancellationError()
        }
    }

    private func pauseAutomaticSyncForPendingPairing() {
        hasPendingPairing = true
        automaticSyncActivated = false
        stopHealthKitBackgroundDelivery()
    }

    private func activateAutomaticSyncIfReady(scheduleOutbox: Bool = true) {
        guard automaticSyncReady, backgroundSyncEnabled, !automaticSyncActivated else {
            return
        }
        automaticSyncActivated = true
        startHealthKitBackgroundDeliveryIfNeeded()
        if scheduleOutbox {
            schedulePendingBackgroundOutboxUploadsIfAllowed()
        }
        BackgroundRefreshScheduler.scheduleNextRefreshIfNeeded(viewModel: self)
        runForegroundCatchUpIfNeeded()
    }

    func importPairingText() async {
        await runTrackedPairingOperation { [weak self] in
            await self?.performImportPairingText()
        }
    }

    private func performImportPairingText() async {
        guard !taskUIPublicationIsSuppressed,
              connectionTerminalBarrier.admissionIsOpen else {
            return
        }
        guard privateStorageAdmissionReady, !hasPendingPrivateStorageRecovery else {
            statusIsError = true
            statusMessage = "Reset unreadable private sync state before importing a new setup link."
            return
        }
        guard !isPairing else { return }
        let trimmed = pairingImportText.trimmingCharacters(in: .whitespacesAndNewlines)
        isPairing = true
        defer {
            if !taskUIPublicationIsSuppressed {
                isPairing = false
                finishPairingAttempt()
            }
        }
        do {
            let material = try ReceiverPairingMaterial.decode(trimmed)
            try await applyPairingMaterial(material)
            pairingImportText = ""
        } catch {
            statusIsError = true
            statusMessage = "Setup link import failed: \(describe(error))"
        }
    }

    func importPairingURL(_ url: URL) async {
        guard !taskUIPublicationIsSuppressed else { return }
        let pendingPairingExists: Bool
        do {
            pendingPairingExists = try pairingCoordinator.hasPendingPairing()
        } catch {
            hasPendingPairing = true
            statusIsError = true
            statusMessage = "Could not read the saved pending pairing. Recover private storage before opening another setup link."
            return
        }
        let matchesPendingBootstrapInvitation: Bool
        do {
            let material = try ReceiverPairingMaterial(deepLink: url)
            if case .invitation(let invitation) = material {
                matchesPendingBootstrapInvitation = (
                    try pairingCoordinator.pendingPairingMatches(invitation)
                )
            } else {
                matchesPendingBootstrapInvitation = false
            }
        } catch {
            matchesPendingBootstrapInvitation = false
        }
        let decision = ReceiverIncomingPairingPolicy.decision(
            hasPendingPairing: pendingPairingExists,
            matchesPendingInvitation: matchesPendingBootstrapInvitation
        )
        switch decision {
        case .rejectDifferentPending:
            hasPendingPairing = true
            automaticSyncActivated = false
            stopHealthKitBackgroundDelivery()
            statusIsError = true
            statusMessage = "A different pairing is already pending. Retry it, or clear the pending pairing and saved connection before opening this setup link again."
            return
        case .resumeMatchingPending:
            await bootstrap()
            return
        case .importIncoming:
            await bootstrap()
        }
        await runTrackedPairingOperation { [weak self] in
            await self?.performImportPairingURL(url)
        }
    }

    private func performImportPairingURL(_ url: URL) async {
        guard !taskUIPublicationIsSuppressed,
              connectionTerminalBarrier.admissionIsOpen else {
            return
        }
        guard privateStorageAdmissionReady, !hasPendingPrivateStorageRecovery else {
            statusIsError = true
            statusMessage = "Reset unreadable private sync state before opening a new setup link."
            return
        }
        guard !isPairing else { return }
        isPairing = true
        defer {
            if !taskUIPublicationIsSuppressed {
                isPairing = false
                finishPairingAttempt()
            }
        }
        do {
            let material = try ReceiverPairingMaterial(deepLink: url)
            try await applyPairingMaterial(material)
        } catch {
            statusIsError = true
            statusMessage = "Setup link failed: \(describe(error))"
        }
    }

    func redeemManualPairing() async {
        await runTrackedPairingOperation { [weak self] in
            await self?.performRedeemManualPairing()
        }
    }

    private func performRedeemManualPairing() async {
        guard !taskUIPublicationIsSuppressed,
              connectionTerminalBarrier.admissionIsOpen else {
            return
        }
        guard privateStorageAdmissionReady, !hasPendingPrivateStorageRecovery else {
            statusIsError = true
            statusMessage = "Reset unreadable private sync state before entering a new setup code."
            return
        }
        guard !isPairing else { return }
        isPairing = true
        defer {
            if !taskUIPublicationIsSuppressed {
                isPairing = false
                finishPairingAttempt()
            }
        }
        do {
            let manualPairing = try ReceiverManualPairing(
                serverURLString: manualPairingServer,
                invitationCode: manualPairingCode
            )
            statusIsError = false
            statusMessage = "Redeeming temporary pairing invitation..."
            pauseAutomaticSyncForPendingPairing()
            let previousGeneration = settingsStore.receiverSettingsGenerationToken
            let transition = try await performTerminalConnectionTransitionWhileHoldingRequestGate(
                cancelPairingOperation: false
            ) { expectedGeneration in
                try await self.pairingCoordinator.pair(
                    manualPairing: manualPairing,
                    expectedGeneration: expectedGeneration
                )
            }
            let credential = transition.result
            try requireCommittedConnectionGenerationWhileHoldingRequestGate(transition.committedGeneration)
            applyCommittedPairingCredential(
                credential,
                previousGeneration: previousGeneration
            )
            manualPairingServer = ""
            manualPairingCode = ""
        } catch {
            statusIsError = true
            statusMessage = "Manual pairing failed: \(describe(error))"
        }
    }

    private func applyPairingMaterial(_ material: ReceiverPairingMaterial) async throws {
        switch material {
        case .legacy(let bundle):
            if hasPendingPairing {
                throw ReceiverPairingStateError.pendingPairingConflict
            }
            let previousGeneration = settingsStore.receiverSettingsGenerationToken
            let transition = try await performTerminalConnectionTransitionWhileHoldingRequestGate(
                cancelPairingOperation: false
            ) { expectedGeneration in
                try self.settingsStore.save(
                    receiverURLString: bundle.receiverURLString,
                    bearerToken: bundle.bearerToken,
                    expectedGeneration: expectedGeneration,
                    rotateBindingID: true
                )
            }
            let committedGeneration = transition.committedGeneration
            try requireCommittedConnectionGenerationWhileHoldingRequestGate(committedGeneration)
            applyCommittedPairingConnection(
                receiverURL: bundle.receiverURLString,
                token: bundle.bearerToken,
                label: bundle.label,
                previousGeneration: previousGeneration
            )
        case .invitation(let invitation):
            statusIsError = false
            statusMessage = "Redeeming temporary pairing invitation..."
            pauseAutomaticSyncForPendingPairing()
            let previousGeneration = settingsStore.receiverSettingsGenerationToken
            let transition = try await performTerminalConnectionTransitionWhileHoldingRequestGate(
                cancelPairingOperation: false
            ) { expectedGeneration in
                try await self.pairingCoordinator.pair(
                    invitation: invitation,
                    expectedGeneration: expectedGeneration
                )
            }
            let credential = transition.result
            let committedGeneration = transition.committedGeneration
            try requireCommittedConnectionGenerationWhileHoldingRequestGate(committedGeneration)
            applyCommittedPairingCredential(
                credential,
                previousGeneration: previousGeneration
            )
        }
    }

    private func applyCommittedPairingCredential(
        _ credential: ReceiverPairingCredential,
        previousGeneration: String
    ) {
        applyCommittedPairingConnection(
            receiverURL: credential.receiverURLString,
            token: credential.bearerToken,
            label: credential.label,
            previousGeneration: previousGeneration
        )
        refreshPendingPairingState()
    }

    private func applyCommittedPairingConnection(
        receiverURL: String,
        token: String,
        label: String,
        previousGeneration: String
    ) {
        receiverURLString = receiverURL
        bearerToken = token
        receiverSettingsSaved = canSaveReceiverSettings
            && settingsStore.receiverBindingID != nil
            && outboxIdentityMigrationReady
        let connectionChanged =
            settingsStore.receiverSettingsGenerationToken != previousGeneration
        activateAutomaticSyncIfReady(scheduleOutbox: !connectionChanged)
        if connectionChanged {
            reschedulePendingBackgroundOutboxUploadsAfterReceiverChange()
        }
        if outboxIdentityMigrationReady {
            statusIsError = false
            statusMessage = "Connected: \(label). The device credential is stored securely on this iPhone."
        } else {
            statusIsError = true
            statusMessage = "Connected: \(label), but uploads remain blocked until you delete the quarantined queued uploads."
        }
    }

    func requestBackgroundSyncEnabled(_ enabled: Bool) {
        if enabled, !terminalUserActionAdmissionIsOpen {
            backgroundSyncRequestedEnabled = backgroundSyncEnabled
            statusIsError = true
            statusMessage = "Automatic sync was not enabled because a connection or recovery action is still finishing. Try again after it completes."
            return
        }
        backgroundSyncPreferenceGeneration &+= 1
        let preferenceGeneration = backgroundSyncPreferenceGeneration
        backgroundSyncRequestedEnabled = enabled

        if !enabled {
            beginAutomaticSyncDisable(preferenceGeneration: preferenceGeneration)
            return
        }
        let expectedReceiverGeneration = settingsStore.receiverSettingsGenerationToken
        let expectedReceiverBindingID = settingsStore.receiverBindingID
        scheduleAutomaticSyncEnable(
            preferenceGeneration: preferenceGeneration,
            expectedReceiverGeneration: expectedReceiverGeneration,
            expectedReceiverBindingID: expectedReceiverBindingID
        )
    }

    private func receiverIdentityMatches(
        expectedGeneration: String,
        expectedBindingID: String?
    ) -> Bool {
        guard let expectedBindingID else { return false }
        return settingsStore.receiverSettingsGenerationToken == expectedGeneration
            && settingsStore.receiverBindingID == expectedBindingID
    }

    private func beginAutomaticSyncDisable(preferenceGeneration: UInt64) {
        automaticSyncActivated = false
        backgroundSyncEnabled = false
        backgroundSyncStatus = "Automatic sync is turning off…"
        statusIsError = false
        statusMessage = "Automatic sync is turning off."
        stopHealthKitBackgroundDelivery()

        let disableWasDurablyPersisted: Bool
        do {
            try backgroundSyncStore.setEnabledDurably(false)
            disableWasDurablyPersisted = true
        } catch {
            disableWasDurablyPersisted = false
        }

        let previousCleanupTask = automaticSyncDisableCleanupTask
        let cleanupTask = Task { @MainActor [weak self] in
            _ = await previousCleanupTask?.value
            guard let self else { return false }
            await self.cancelAndAwaitForegroundPayloadTasks()
            let cleanupWasFullyFinalized = await self.drainBackgroundPayloadCancellation()

            guard self.backgroundSyncPreferenceGeneration == preferenceGeneration,
                  !self.backgroundSyncRequestedEnabled else {
                return cleanupWasFullyFinalized
            }
            if !disableWasDurablyPersisted {
                self.statusIsError = true
                self.statusMessage = "Automatic sync is off for this app session, but its durable disable intent could not be saved."
                self.backgroundSyncStatus = "Automatic sync is off, but saving the disable intent failed."
                return cleanupWasFullyFinalized
            }
            if !cleanupWasFullyFinalized {
                self.statusIsError = true
                self.statusMessage = "Automatic sync is off. Background transfer cleanup is still pending."
                self.backgroundSyncStatus = "Automatic sync is off; background transfer cleanup remains fail-closed."
                return false
            }
            self.statusIsError = false
            self.statusMessage = "Automatic sync is off. Sync Now still works."
            self.backgroundSyncStatus = "Automatic sync is off. Sync Now still works."
            return true
        }
        automaticSyncDisableCleanupTask = cleanupTask
    }

    private func scheduleAutomaticSyncEnable(
        preferenceGeneration: UInt64,
        expectedReceiverGeneration: String,
        expectedReceiverBindingID: String?
    ) {
        let pendingCleanupTask = automaticSyncDisableCleanupTask
        let enableTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let cleanupWasFullyFinalized: Bool
            if let pendingCleanupTask {
                if await pendingCleanupTask.value {
                    cleanupWasFullyFinalized = true
                } else {
                    await self.cancelAndAwaitForegroundPayloadTasks()
                    cleanupWasFullyFinalized = await self.drainBackgroundPayloadCancellation()
                }
            } else {
                await self.cancelAndAwaitForegroundPayloadTasks()
                cleanupWasFullyFinalized = await self.drainBackgroundPayloadCancellation()
            }
            guard cleanupWasFullyFinalized else {
                guard self.backgroundSyncPreferenceGeneration == preferenceGeneration,
                      self.backgroundSyncRequestedEnabled else {
                    return
                }
                self.automaticSyncActivated = false
                self.backgroundSyncEnabled = false
                self.backgroundSyncRequestedEnabled = false
                self.statusIsError = true
                self.statusMessage = "Automatic sync stayed off because background transfer cleanup did not fully finish."
                self.backgroundSyncStatus = "Automatic sync is off; retry after background transfer cleanup finishes."
                return
            }

            if let bootstrapTask = self.bootstrapTask {
                await bootstrapTask.value
            }
            while self.terminalTransitionRequestIsActive {
                guard self.backgroundSyncPreferenceGeneration == preferenceGeneration,
                      self.backgroundSyncRequestedEnabled else {
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard self.backgroundSyncPreferenceGeneration == preferenceGeneration,
                  self.backgroundSyncRequestedEnabled else {
                return
            }
            do {
                try await self.withTerminalTransitionRequestGate(
                    allowDuringActiveBootstrap: true,
                    afterSuccessfulRelease: { [weak self] in
                        guard let self,
                              self.backgroundSyncPreferenceGeneration == preferenceGeneration,
                              self.backgroundSyncRequestedEnabled,
                              self.backgroundSyncEnabled,
                              self.receiverIdentityMatches(
                                  expectedGeneration: expectedReceiverGeneration,
                                  expectedBindingID: expectedReceiverBindingID
                              ) else {
                            return
                        }
                        self.activateAutomaticSyncIfReady()
                    }
                ) { [self] in
                    guard backgroundSyncPreferenceGeneration == preferenceGeneration,
                          backgroundSyncRequestedEnabled else {
                        return
                    }
                    guard receiverIdentityMatches(
                        expectedGeneration: expectedReceiverGeneration,
                        expectedBindingID: expectedReceiverBindingID
                    ) else {
                        automaticSyncActivated = false
                        backgroundSyncEnabled = false
                        backgroundSyncRequestedEnabled = false
                        statusIsError = true
                        statusMessage = "Automatic sync stayed off because the connected receiver changed while the request was pending."
                        backgroundSyncStatus = "Automatic sync is off; turn it on again for the current receiver."
                        return
                    }
                    guard !taskUIPublicationIsSuppressed,
                          connectionTerminalBarrier.admissionIsOpen,
                          automaticSyncEnablePrerequisitesReady else {
                        automaticSyncActivated = false
                        backgroundSyncEnabled = false
                        backgroundSyncRequestedEnabled = false
                        statusIsError = true
                        statusMessage = "Automatic sync stayed off because the connected receiver, Health access, or private storage is not ready."
                        backgroundSyncStatus = "Automatic sync is off until setup and private storage are ready."
                        return
                    }
                    do {
                        try backgroundSyncStore.setEnabledDurably(true)
                    } catch {
                        automaticSyncActivated = false
                        backgroundSyncEnabled = false
                        backgroundSyncRequestedEnabled = false
                        statusIsError = true
                        statusMessage = "Automatic sync stayed off because the enabled preference could not be saved."
                        backgroundSyncStatus = "Automatic sync is off; saving the enabled preference failed."
                        return
                    }
                    guard backgroundSyncPreferenceGeneration == preferenceGeneration,
                          backgroundSyncRequestedEnabled,
                          receiverIdentityMatches(
                              expectedGeneration: expectedReceiverGeneration,
                              expectedBindingID: expectedReceiverBindingID
                          ) else {
                        return
                    }
                    backgroundSyncEnabled = true
                    statusIsError = false
                    statusMessage = "Automatic sync is on. iOS decides when it can run."
                    backgroundSyncStatus = "Automatic sync is on. iOS decides when it can run."
                }
            } catch {
                guard self.backgroundSyncPreferenceGeneration == preferenceGeneration,
                      self.backgroundSyncRequestedEnabled else {
                    return
                }
                self.automaticSyncActivated = false
                self.backgroundSyncEnabled = false
                self.backgroundSyncRequestedEnabled = false
                self.statusIsError = true
                self.statusMessage = "Automatic sync stayed off because another private-state transition did not finish."
                self.backgroundSyncStatus = "Automatic sync is off; retry after the current transition finishes."
            }
        }
        automaticSyncPreferenceTask = enableTask
    }

    private func recordBackgroundSyncRegistrationIfAllowed(
        at date: Date,
        succeeded: Bool,
        summary: String
    ) {
        guard terminalPayloadActionAdmissionIsOpen else { return }
        backgroundSyncStore.recordRegistration(
            at: date,
            succeeded: succeeded,
            summary: summary
        )
    }

    private func startHealthKitBackgroundDeliveryIfNeeded() {
        #if canImport(HealthKit)
        guard automaticSyncReady, backgroundSyncEnabled else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            backgroundSyncStatus = "Automatic sync is on, but Apple Health data is not available on this device/build."
            return
        }
        let availableAutomaticQuantityTypeCodes = HealthKitReadTypeCatalog.availableTypeCodes(
            forTypeCodes: enabledBroadQuantityTypeCodes
        )
        let registrationPlan = HealthBridgeBackgroundSync.backgroundDeliveryRegistrationPlan(
            automaticQuantityTypeCodes: availableAutomaticQuantityTypeCodes
        )
        let expectedTypeIdentifiers = HealthKitReadTypeCatalog.sampleTypes(for: registrationPlan.observedHealthTypes)
            .map(\.identifier)
        backgroundDeliveryRegistrationExpectedCount = expectedTypeIdentifiers.count
        backgroundDeliveryRegistrationResults = [:]
        backgroundDeliveryRegistrationErrors = [:]
        let coordinator = backgroundDeliveryCoordinator ?? HealthKitBackgroundDeliveryCoordinator()
        backgroundDeliveryCoordinator = coordinator
        coordinator.start(
            healthTypes: registrationPlan.observedHealthTypes,
            registrationHandler: { [weak self] typeIdentifier, succeeded, errorDescription in
                self?.noteHealthKitBackgroundDeliveryRegistration(
                    typeIdentifier: typeIdentifier,
                    succeeded: succeeded,
                    errorDescription: errorDescription
                )
            }
        ) { [weak self] typeCode in
            guard let self else { return }
            do {
                try self.backgroundSyncStore.markPendingObserverTypeCodes([typeCode])
            } catch {
                await self.backgroundRunGate.retainObserverTypeCodes([typeCode])
                self.hasTransientPrivateStorageFailure = true
                self.statusIsError = true
                self.statusMessage = "Apple Health change tracking could not be persisted; automatic retry remains pending: \(self.describe(error))"
                self.backgroundSyncStatus = self.statusMessage
                self.scheduleDebouncedObserverCatchUp()
                BackgroundRefreshScheduler.scheduleNextRefreshIfNeeded(viewModel: self)
                return
            }
            guard self.terminalPayloadActionAdmissionIsOpen else { return }
            self.noteBackgroundRefreshHandlerStarted(source: "healthkit_observer")
            self.backgroundSyncStatus = "Apple Health reported a change; running read-only sync."
            await self.runBackgroundRefreshSync(reason: .observer(typeCode: typeCode))
            BackgroundRefreshScheduler.scheduleNextRefreshIfNeeded(viewModel: self)
        }
        recordBackgroundSyncRegistrationIfAllowed(
            at: Date(),
            succeeded: false,
            summary: "HealthKit background delivery registration requested for \(expectedTypeIdentifiers.count) type(s); active_observers=\(coordinator.activeObserverCount)."
        )
        backgroundSyncStatus = "Automatic sync scope includes steps, workouts, sleep, and \(availableAutomaticQuantityTypeCodes.count) runtime-available supported quantity types. Background delivery registration is in progress; iOS still decides timing."
        #endif
    }

    #if canImport(HealthKit)
    private func noteHealthKitBackgroundDeliveryRegistration(
        typeIdentifier: String,
        succeeded: Bool,
        errorDescription: String?
    ) {
        guard terminalPayloadActionAdmissionIsOpen else { return }
        backgroundDeliveryRegistrationResults[typeIdentifier] = succeeded
        if succeeded {
            backgroundDeliveryRegistrationErrors.removeValue(forKey: typeIdentifier)
        } else {
            backgroundDeliveryRegistrationErrors[typeIdentifier] = errorDescription ?? "unknown error"
        }

        let completedCount = backgroundDeliveryRegistrationResults.count
        let expectedCount = max(backgroundDeliveryRegistrationExpectedCount, completedCount)
        let successCount = backgroundDeliveryRegistrationResults.values.filter { $0 }.count
        let failureCount = backgroundDeliveryRegistrationErrors.count
        let observerCount = backgroundDeliveryCoordinator?.activeObserverCount ?? 0
        let failureSummary = backgroundDeliveryRegistrationErrors
            .sorted { $0.key < $1.key }
            .prefix(3)
            .map { key, value in "\(key): \(value)" }
            .joined(separator: "; ")
        let suffix = failureSummary.isEmpty ? "" : "; failures=\(failureSummary)"
        let summary = "HealthKit background delivery registration \(successCount)/\(expectedCount) enabled, \(failureCount) failed; active_observers=\(observerCount)\(suffix)."
        let allResponsesReceived = completedCount >= expectedCount
        let allSucceeded = allResponsesReceived && failureCount == 0
        recordBackgroundSyncRegistrationIfAllowed(
            at: Date(),
            succeeded: allSucceeded,
            summary: summary
        )
        if failureCount > 0 {
            backgroundSyncStatus = "HealthKit background delivery registration has \(failureCount) failure(s). Sync Now still works."
        } else if allSucceeded {
            backgroundSyncStatus = "HealthKit background delivery registered for \(successCount) type(s). iOS still decides timing."
        }
    }
    #endif

    private func stopHealthKitBackgroundDelivery() {
        #if canImport(HealthKit)
        backgroundDeliveryCoordinator?.stop(healthTypes: HealthBridgeBackgroundSync.allKnownBackgroundDeliveryHealthTypes)
        backgroundDeliveryCoordinator = nil
        #endif
    }

    func schedulePendingBackgroundOutboxUploadsIfAllowed() {
        guard terminalPayloadActionAdmissionIsOpen,
              automaticSyncReady,
              directOutboxTransferRequestCount == 0 else { return }
        #if os(iOS)
        startBackgroundOutboxScheduling(cancelExistingUploads: false)
        #endif
    }

    func cancelPendingBackgroundOutboxUploads() {
        guard terminalUserActionAdmissionIsOpen else { return }
        #if os(iOS)
        Task { @MainActor in
            await cancelBackgroundOutboxSchedulingIfNeeded()
            let cancellationResult = await BackgroundURLSessionOutboxUploader.shared.cancelPendingUploads()
            let legacyCancellationResult = await BackgroundURLSessionOutboxUploader.shared
                .cancelInheritedLegacyUploads()
            if !cancellationResult.fullyFinalized
                || !legacyCancellationResult.fullyFinalized
            {
                backgroundSyncStatus = "Background upload cancellation is still finalizing; direct retry remains blocked."
            } else {
                let cancelledCount = cancellationResult.cancelledCount
                    + legacyCancellationResult.cancelledCount
                if cancelledCount > 0 {
                    backgroundSyncStatus = "Cancelled \(cancelledCount) queued background upload(s)."
                }
            }
        }
        #endif
    }

    private func reschedulePendingBackgroundOutboxUploadsAfterReceiverChange() {
        guard terminalPayloadActionAdmissionIsOpen,
              automaticSyncReady,
              directOutboxTransferRequestCount == 0 else { return }
        #if os(iOS)
        startBackgroundOutboxScheduling(cancelExistingUploads: true)
        #endif
    }

    #if os(iOS)
    private func startBackgroundOutboxScheduling(cancelExistingUploads: Bool) {
        guard terminalPayloadActionAdmissionIsOpen,
              directOutboxTransferRequestCount == 0 else { return }
        if !cancelExistingUploads, backgroundOutboxSchedulingTask != nil {
            return
        }
        let previousTask = backgroundOutboxSchedulingTask
        previousTask?.cancel()
        let schedulingID = UUID()
        let expectedGeneration = settingsStore.receiverSettingsGenerationToken
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishBackgroundOutboxScheduling(id: schedulingID) }
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled,
                  self.terminalPayloadActionAdmissionIsOpen else { return }
            var cancellationResult = BackgroundUploadCancellationResult(
                cancelledCount: 0,
                fullyFinalized: true
            )
            var legacyCancellationResult = BackgroundUploadCancellationResult(
                cancelledCount: 0,
                fullyFinalized: true
            )
            if cancelExistingUploads {
                cancellationResult = await BackgroundURLSessionOutboxUploader.shared.cancelPendingUploads()
                legacyCancellationResult = await BackgroundURLSessionOutboxUploader.shared
                    .cancelInheritedLegacyUploads()
            }
            guard !Task.isCancelled,
                  cancellationResult.fullyFinalized,
                  legacyCancellationResult.fullyFinalized else {
                self.backgroundSyncStatus = "Previous background upload cancellation is still finalizing; reschedule remains blocked."
                return
            }
            await self.schedulePendingBackgroundOutboxUploadsNow(
                expectedGeneration: expectedGeneration
            )
            let cancelledCount = cancellationResult.cancelledCount
                + legacyCancellationResult.cancelledCount
            if cancelledCount > 0 {
                self.backgroundSyncStatus += " Cancelled \(cancelledCount) previous background upload task(s) tied to older connection settings."
            }
        }
        backgroundOutboxSchedulingID = schedulingID
        backgroundOutboxSchedulingTask = task
    }

    private func finishBackgroundOutboxScheduling(id: UUID) {
        guard backgroundOutboxSchedulingID == id else { return }
        backgroundOutboxSchedulingTask = nil
        backgroundOutboxSchedulingID = nil
    }

    private func cancelBackgroundOutboxSchedulingIfNeeded() async {
        guard let task = backgroundOutboxSchedulingTask else { return }
        backgroundOutboxSchedulingTask = nil
        backgroundOutboxSchedulingID = nil
        task.cancel()
        await task.value
    }

    private func schedulePendingBackgroundOutboxUploadsNow(
        expectedGeneration: String
    ) async {
        guard terminalPayloadActionAdmissionIsOpen,
              automaticSyncReady,
              directOutboxTransferRequestCount == 0,
              settingsStore.receiverSettingsGenerationToken == expectedGeneration,
              !Task.isCancelled else {
            return
        }
        let committedReceiverURLString = settingsStore.receiverURLString
        let committedBearerToken: String
        do {
            committedBearerToken = try settingsStore.loadBearerToken()
        } catch {
            backgroundSyncStatus = "Background outbox upload scheduling failed: \(describe(error))"
            return
        }
        guard
            backgroundSyncEnabled,
            let outbox,
            let url = URL(string: committedReceiverURLString),
            let receiverBindingID = settingsStore.receiverBindingID,
            !committedBearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }
        do {
            try Task.checkCancellation()
            let scheduledCount = try await BackgroundURLSessionOutboxUploader.shared.schedulePendingUploads(
                outbox: outbox,
                receiverURL: url,
                bearerToken: committedBearerToken,
                receiverGeneration: expectedGeneration,
                receiverBindingID: receiverBindingID,
                isUploadAllowed: {
                    self.automaticSyncReady
                        && self.directOutboxTransferRequestCount == 0
                        && self.backgroundSyncEnabled
                        && self.settingsStore.receiverSettingsGenerationToken == expectedGeneration
                        && self.settingsStore.receiverBindingID == receiverBindingID
                        && !Task.isCancelled
                }
            )
            refreshPendingOutboxCount()
            if scheduledCount > 0 {
                backgroundSyncStatus = "Scheduled \(scheduledCount) pending outbox upload(s) with background URLSession."
            }
        } catch is CancellationError {
            return
        } catch {
            backgroundSyncStatus = "Background outbox upload scheduling failed: \(describe(error))"
        }
    }
    #endif

    func noteBackgroundRefreshScheduled(earliestBeginDate: Date) {
        guard terminalPayloadActionAdmissionIsOpen else { return }
        let earliest = Self.backgroundDateFormatter.string(from: earliestBeginDate)
        let runtime = Self.backgroundRuntimeSummary()
        backgroundSyncStore.recordTaskSchedule(
            at: Date(),
            status: "submitted",
            summary: "BGAppRefreshTask submitted, earliestBeginDate=\(earliest); \(runtime)."
        )
        backgroundSyncStatus = "Next background refresh request submitted for no earlier than \(earliest)."
    }

    func noteBackgroundRefreshSchedulingSkipped() {
        guard terminalPayloadActionAdmissionIsOpen else { return }
        if backgroundSyncEnabled {
            let runtime = Self.backgroundRuntimeSummary()
            backgroundSyncStore.recordTaskSchedule(
                at: Date(),
                status: "skipped",
                summary: "BGAppRefreshTask scheduling skipped because receiver settings are incomplete; \(runtime)."
            )
            backgroundSyncStatus = "Background refresh scheduling skipped until receiver settings are complete."
        }
    }

    func noteBackgroundRefreshScheduleFailed(_ error: Error) {
        guard terminalPayloadActionAdmissionIsOpen else { return }
        let runtime = Self.backgroundRuntimeSummary()
        backgroundSyncStore.recordTaskSchedule(
            at: Date(),
            status: "failed",
            summary: "BGAppRefreshTask submit failed: \(describe(error)); \(runtime)."
        )
        backgroundSyncStatus = "Background refresh scheduling failed: \(describe(error))"
    }

    func noteBackgroundRefreshHandlerStarted(source: String) {
        guard terminalPayloadActionAdmissionIsOpen else { return }
        backgroundSyncStore.recordWakeEvent(
            at: Date(),
            source: source,
            summary: "Background handler entered from \(source); \(Self.backgroundRuntimeSummary())."
        )
    }

    func runForegroundCatchUpIfNeeded() {
        guard
            terminalPayloadActionAdmissionIsOpen,
            automaticSyncReady,
            backgroundSyncEnabled,
            canSendConnectionTest,
            backgroundSyncStore.shouldRunForegroundCatchUp()
        else {
            return
        }
        guard foregroundCatchUpTask == nil else {
            return
        }
        foregroundCatchUpTask = Task { @MainActor in
            backgroundSyncStatus = "Catching up after Health Bridge opened..."
            await runBackgroundRefreshSync(reason: .launchCatchUp)
            BackgroundRefreshScheduler.scheduleNextRefreshIfNeeded(viewModel: self)
            foregroundCatchUpTask = nil
        }
    }

    func runBackgroundRefreshSync(reason: AutomaticSyncReason) async {
        guard terminalPayloadActionAdmissionIsOpen else { return }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performBackgroundRefreshSync(reason: reason)
        }
        trackedSyncTasks[taskID] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        trackedSyncTasks.removeValue(forKey: taskID)
    }

    private func recordBackgroundSyncRunIfAllowed(
        startedAt: Date,
        finishedAt: Date,
        succeeded: Bool,
        summary: String
    ) {
        guard terminalPayloadActionAdmissionIsOpen else { return }
        backgroundSyncStore.recordRun(
            startedAt: startedAt,
            finishedAt: finishedAt,
            succeeded: succeeded,
            summary: summary
        )
    }

    private func performBackgroundRefreshSync(reason: AutomaticSyncReason) async {
        let startedAt = Date()
        guard automaticSyncReady else {
            recordBackgroundSyncRunIfAllowed(
                startedAt: startedAt,
                finishedAt: Date(),
                succeeded: false,
                summary: "Background refresh skipped until pairing recovery is complete."
            )
            backgroundSyncStatus = "Background refresh skipped until pairing recovery is complete."
            return
        }
        guard backgroundSyncEnabled else {
            recordBackgroundSyncRunIfAllowed(
                startedAt: startedAt,
                finishedAt: Date(),
                succeeded: false,
                summary: "Background refresh skipped because eventual sync is disabled."
            )
            backgroundSyncStatus = "Background refresh skipped because eventual sync is disabled."
            return
        }

        guard canSendConnectionTest else {
            recordBackgroundSyncRunIfAllowed(
                startedAt: startedAt,
                finishedAt: Date(),
                succeeded: false,
                summary: "Background refresh skipped because receiver settings are incomplete."
            )
            backgroundSyncStatus = "Background refresh skipped because receiver settings are incomplete."
            return
        }

        let observerGenerationSnapshot: [String: Int]
        do {
            observerGenerationSnapshot = try backgroundSyncStore
                .loadPendingObserverTypeCodeGenerations()
        } catch {
            await backgroundRunGate.retainObserverTypeCodes(reason.observerTypeCodes)
            hasTransientPrivateStorageFailure = true
            statusIsError = true
            statusMessage = "Background refresh deferred because durable Apple Health change tracking is unreadable: \(describe(error))"
            backgroundSyncStatus = statusMessage
            scheduleDebouncedObserverCatchUp()
            BackgroundRefreshScheduler.scheduleNextRefreshIfNeeded(viewModel: self)
            return
        }
        let admission = await backgroundRunGate.beginRun(reason: reason, now: startedAt)
        guard admission.shouldRun else {
            if admission.skipReason == .debounced,
               !reason.observerTypeCodes.isEmpty {
                scheduleDebouncedObserverCatchUp()
            }
            let reason = admission.skipReason?.userDescription ?? "background refresh gate rejected this run"
            backgroundSyncStatus = "Background refresh skipped because \(reason)."
            return
        }
        if await deferAutomaticSyncForPendingOutboxIfNeeded(startedAt: startedAt) {
            return
        }
        do {
            try await runWithExclusiveDirectOutboxTransfer {
                if await self.deferAutomaticSyncForPendingOutboxIfNeeded(startedAt: startedAt) {
                    return
                }
                await self.performAdmittedBackgroundRefreshSync(
                    reason: reason,
                    startedAt: startedAt,
                    observerGenerationSnapshot: observerGenerationSnapshot
                )
            }
        } catch is CancellationError {
            _ = await finishBackgroundRunPreservingObserverDirtiness(
                scheduleRetry: false
            )
            return
        } catch {
            _ = await finishBackgroundRunPreservingObserverDirtiness(
                scheduleRetry: true
            )
            backgroundSyncStatus = "Background refresh stopped before private storage access: \(describe(error))"
        }
    }

    private func finishBackgroundRunPreservingObserverDirtiness(
        scheduleRetry: Bool
    ) async -> [String] {
        let pendingTypeCodes = await backgroundRunGate.finishRun(.interrupted)
        if !pendingTypeCodes.isEmpty {
            do {
                try backgroundSyncStore.markPendingObserverTypeCodes(pendingTypeCodes)
            } catch {
                hasTransientPrivateStorageFailure = true
                statusIsError = true
                statusMessage = "Apple Health change tracking remains in memory because durable persistence failed; automatic retry remains pending: \(describe(error))"
                backgroundSyncStatus = statusMessage
            }
            if scheduleRetry,
               automaticSyncReady,
               backgroundSyncEnabled,
               terminalPayloadActionAdmissionIsOpen {
                scheduleDebouncedObserverCatchUp()
            }
        }
        return pendingTypeCodes
    }

    private func deferAutomaticSyncForPendingOutboxIfNeeded(
        startedAt: Date
    ) async -> Bool {
        let trustedPendingOutboxCount = trustedPendingOutboxCount()
        guard AutomaticSyncPayloadGenerationPolicy.shouldGenerateNewPayloads(
            trustedPendingOutboxCount: trustedPendingOutboxCount
        ) else {
            let summary: String
            if let trustedPendingOutboxCount {
                refreshPendingOutboxCount()
                statusIsError = false
                statusMessage = "Queued uploads are waiting for the saved server before automatic sync reads more data."
                summary = "Background refresh deferred while \(trustedPendingOutboxCount) queued upload(s) await delivery."
                schedulePendingBackgroundOutboxUploadsIfAllowed()
            } else {
                privateStorageAdmissionReady = false
                statusIsError = true
                statusMessage = "Automatic sync stopped because queued-upload status is unavailable."
                summary = "Background refresh stopped because queued-upload status is unavailable."
            }
            recordBackgroundSyncRunIfAllowed(
                startedAt: startedAt,
                finishedAt: Date(),
                succeeded: false,
                summary: summary
            )
            _ = await finishBackgroundRunPreservingObserverDirtiness(
                scheduleRetry: true
            )
            backgroundSyncStatus = summary
            return true
        }
        return false
    }

    private struct BackgroundCoreLaneResult {
        let uploadedRecords: Bool
        let succeeded: Bool
        let failureDetail: String?
        let durablyQueuedPayload: Bool
    }

    private func captureBackgroundCoreLaneResult(
        _ operation: @escaping @MainActor () async -> Bool
    ) async -> BackgroundCoreLaneResult {
        let pendingBefore = trustedPendingOutboxCount()
        let uploadedRecords = await operation()
        let pendingAfter = trustedPendingOutboxCount()
        let laneFailed = statusIsError
        return BackgroundCoreLaneResult(
            uploadedRecords: uploadedRecords,
            succeeded: !laneFailed,
            failureDetail: laneFailed
                ? Self.backgroundLaneFailureDetail(statusMessage)
                : nil,
            durablyQueuedPayload: pendingBefore.flatMap { before in
                pendingAfter.map { after in after > before }
            } ?? false
        )
    }

    private func performAdmittedBackgroundRefreshSync(
        reason: AutomaticSyncReason,
        startedAt: Date,
        observerGenerationSnapshot: [String: Int]
    ) async {
        if await stopBackgroundRunIfUnavailable(startedAt: startedAt) {
            return
        }
        do {
            try preparePrivateStorageForUploadAdmission()
        } catch {
            privateStorageAdmissionReady = false
            let summary = "Background refresh stopped because private upload storage needs recovery: \(describe(error))"
            recordBackgroundSyncRunIfAllowed(
                startedAt: startedAt,
                finishedAt: Date(),
                succeeded: false,
                summary: summary
            )
            _ = await finishBackgroundRunPreservingObserverDirtiness(
                scheduleRetry: true
            )
            backgroundSyncStatus = summary
            statusIsError = true
            statusMessage = summary
            refreshPendingOutboxCount()
            return
        }
        statusIsError = false
        statusMessage = "Running best-effort background refresh..."
        let stepResult = await captureBackgroundCoreLaneResult {
            await self.syncRecentStepCounts(executionMode: .automatic)
        }
        let stepRecordsUploaded = stepResult.uploadedRecords
        let stepSucceeded = stepResult.succeeded && !stepResult.durablyQueuedPayload
        let stepFailure = stepResult.failureDetail
            ?? (stepResult.durablyQueuedPayload ? "payload queued for retry" : nil)
        if await deferAutomaticSyncForPendingOutboxIfNeeded(startedAt: startedAt) {
            return
        }
        if await stopBackgroundRunIfUnavailable(startedAt: startedAt) {
            return
        }
        let dailyActivityResult = await captureBackgroundCoreLaneResult {
            await self.syncDailyActivityAggregates(executionMode: .automatic)
        }
        let dailyActivityRecordsUploaded = dailyActivityResult.uploadedRecords
        let dailyActivitySucceeded = dailyActivityResult.succeeded
            && !dailyActivityResult.durablyQueuedPayload
        let dailyActivityFailure = dailyActivityResult.failureDetail
            ?? (dailyActivityResult.durablyQueuedPayload ? "payload queued for retry" : nil)
        if await deferAutomaticSyncForPendingOutboxIfNeeded(startedAt: startedAt) {
            return
        }
        if await stopBackgroundRunIfUnavailable(startedAt: startedAt) {
            return
        }
        let workoutResult = await captureBackgroundCoreLaneResult {
            await self.syncAnchoredWorkoutChanges(executionMode: .automatic)
        }
        let workoutRecordsUploaded = workoutResult.uploadedRecords
        let workoutSucceeded = workoutResult.succeeded
            && !workoutResult.durablyQueuedPayload
        let workoutFailure = workoutResult.failureDetail
            ?? (workoutResult.durablyQueuedPayload ? "payload queued for retry" : nil)
        if await deferAutomaticSyncForPendingOutboxIfNeeded(startedAt: startedAt) {
            return
        }
        if await stopBackgroundRunIfUnavailable(startedAt: startedAt) {
            return
        }
        let sleepResult = await captureBackgroundCoreLaneResult {
            await self.syncRecentSleepSessions(executionMode: .automatic)
        }
        let sleepRecordsUploaded = sleepResult.uploadedRecords
        let sleepSucceeded = sleepResult.succeeded
            && !sleepResult.durablyQueuedPayload
        let sleepFailure = sleepResult.failureDetail
            ?? (sleepResult.durablyQueuedPayload ? "payload queued for retry" : nil)
        if await deferAutomaticSyncForPendingOutboxIfNeeded(startedAt: startedAt) {
            return
        }
        if await stopBackgroundRunIfUnavailable(startedAt: startedAt) {
            return
        }
        let availableAutomaticQuantityTypeCodes = HealthKitReadTypeCatalog.availableTypeCodes(
            forTypeCodes: enabledBroadQuantityTypeCodes
        )
        let quantityPlan = HealthBridgeBackgroundSync.automaticQuantitySyncPlan(
            availableTypeCodes: availableAutomaticQuantityTypeCodes,
            observedTypeCodes: quantityObservationStore.observedTypeCodes,
            reason: reason
        )
        let quantityStatus: BackgroundQuantitySyncStatus
        if quantityPlan.typeCodes.isEmpty {
            quantityStatus = .noWork
        } else {
            await syncBackgroundAutomaticQuantityMetrics(
                typeCodes: quantityPlan.typeCodes,
                historyDepth: quantityPlan.fallbackHistoryDepth
            )
            quantityStatus = statusIsError
                ? .failed(typeCodes: quantityPlan.typeCodes)
                : .succeeded(typeCodes: quantityPlan.typeCodes)
        }
        if await deferAutomaticSyncForPendingOutboxIfNeeded(startedAt: startedAt) {
            return
        }
        if await stopBackgroundRunIfUnavailable(startedAt: startedAt) {
            return
        }
        let quantitySucceeded = !quantityStatus.isFailure
        let succeeded = stepSucceeded && dailyActivitySucceeded && workoutSucceeded && sleepSucceeded && quantitySucceeded
        var summary = HealthBridgeBackgroundSync.refreshSummary(
            succeeded: succeeded,
            stepsSucceeded: stepSucceeded,
            dailyActivitySucceeded: dailyActivitySucceeded,
            workoutsSucceeded: workoutSucceeded,
            sleepSucceeded: sleepSucceeded,
            pendingOutboxCount: pendingOutboxCount,
            quantityStatus: quantityStatus
        )
        summary = Self.backgroundRefreshDiagnosticSummary(
            baseSummary: summary,
            uploadedRecordFlags: [
                "steps": stepRecordsUploaded,
                "daily_activity": dailyActivityRecordsUploaded,
                "workouts": workoutRecordsUploaded,
                "sleep": sleepRecordsUploaded,
            ],
            failures: [
                "steps": stepFailure,
                "daily_activity": dailyActivityFailure,
                "workouts": workoutFailure,
                "sleep": sleepFailure,
            ]
        )
        recordBackgroundSyncRunIfAllowed(
            startedAt: startedAt,
            finishedAt: Date(),
            succeeded: succeeded,
            summary: summary
        )
        var pendingObserverTypeCodes: [String]
        if succeeded {
            pendingObserverTypeCodes = await backgroundRunGate.finishRun(.succeeded)
            let pendingTypeCodeSet = Set(pendingObserverTypeCodes)
            let attemptedObserverTypeCodes: [String]
            switch reason {
            case .observer, .observerBatch:
                attemptedObserverTypeCodes = reason.observerTypeCodes
            case .scheduledRefresh, .launchCatchUp:
                attemptedObserverTypeCodes = Array(observerGenerationSnapshot.keys)
            }
            let clearableTypeCodes = attemptedObserverTypeCodes.filter {
                !pendingTypeCodeSet.contains($0)
            }
            do {
                try backgroundSyncStore.clearPendingObserverTypeCodes(
                    matching: observerGenerationSnapshot,
                    typeCodes: clearableTypeCodes
                )
            } catch {
                await backgroundRunGate.retainObserverTypeCodes(clearableTypeCodes)
                pendingObserverTypeCodes = Array(
                    Set(pendingObserverTypeCodes).union(clearableTypeCodes)
                ).sorted()
                hasTransientPrivateStorageFailure = true
                statusIsError = true
                statusMessage = "Sync data was delivered, but durable Apple Health change cleanup failed; automatic retry remains pending: \(describe(error))"
                summary += " Observer change cleanup remains pending."
            }
        } else {
            pendingObserverTypeCodes =
                await finishBackgroundRunPreservingObserverDirtiness(
                    scheduleRetry: true
                )
        }
        backgroundSyncStatus = summary
        guard !hasPendingPairing, !Task.isCancelled else {
            backgroundSyncStatus = "Background refresh stopped because pairing recovery is in progress."
            return
        }
        if !pendingObserverTypeCodes.isEmpty {
            let followUpReason = AutomaticSyncReason.observerBatch(
                typeCodes: pendingObserverTypeCodes
            )
            let followUpStartedAt = Date()
            let followUpAdmission = await backgroundRunGate.beginRun(
                reason: followUpReason,
                now: followUpStartedAt
            )
            if followUpAdmission.shouldRun {
                if await deferAutomaticSyncForPendingOutboxIfNeeded(startedAt: followUpStartedAt) {
                    return
                }
                let followUpObserverGenerationSnapshot: [String: Int]
                do {
                    followUpObserverGenerationSnapshot = try backgroundSyncStore
                        .loadPendingObserverTypeCodeGenerations()
                } catch {
                    await backgroundRunGate.retainObserverTypeCodes(
                        followUpReason.observerTypeCodes
                    )
                    hasTransientPrivateStorageFailure = true
                    statusIsError = true
                    statusMessage = "Observer catch-up remains pending because durable change tracking is unreadable: \(describe(error))"
                    backgroundSyncStatus = statusMessage
                    scheduleDebouncedObserverCatchUp()
                    return
                }
                await performAdmittedBackgroundRefreshSync(
                    reason: followUpReason,
                    startedAt: followUpStartedAt,
                    observerGenerationSnapshot: followUpObserverGenerationSnapshot
                )
            } else if followUpAdmission.skipReason == .debounced {
                scheduleDebouncedObserverCatchUp()
            }
        }
    }

    private func scheduleDebouncedObserverCatchUp() {
        backgroundObserverRetryTask?.cancel()
        backgroundObserverRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let remainingSpacing = await self.backgroundRunGate.remainingSpacing()
            do {
                let delayNanoseconds = UInt64(
                    max(0, remainingSpacing + 0.05) * 1_000_000_000
                )
                try await Task.sleep(nanoseconds: delayNanoseconds)
                try Task.checkCancellation()
            } catch {
                return
            }
            self.backgroundObserverRetryTask = nil
            guard self.automaticSyncReady,
                  self.backgroundSyncEnabled,
                  self.terminalPayloadActionAdmissionIsOpen else {
                return
            }
            let pendingTypeCodes = await self.backgroundRunGate
                .pendingObserverTypeCodesSnapshot()
            guard !pendingTypeCodes.isEmpty else { return }
            await self.performBackgroundRefreshSync(
                reason: .observerBatch(typeCodes: pendingTypeCodes)
            )
        }
    }

    private func stopBackgroundRunIfUnavailable(startedAt: Date) async -> Bool {
        let summary: String
        if hasPendingPairing {
            summary = "Background refresh stopped because pairing recovery is in progress."
        } else if Task.isCancelled {
            summary = "Background refresh stopped because the task was cancelled."
        } else if !automaticSyncReady {
            summary = "Background refresh stopped because automatic sync is not ready."
        } else if !backgroundSyncEnabled {
            summary = "Background refresh stopped because automatic sync was turned off."
        } else if !canSendConnectionTest {
            summary = "Background refresh stopped because receiver settings are incomplete."
        } else {
            return false
        }
        recordBackgroundSyncRunIfAllowed(
            startedAt: startedAt,
            finishedAt: Date(),
            succeeded: false,
            summary: summary
        )
        _ = await finishBackgroundRunPreservingObserverDirtiness(
            scheduleRetry: false
        )
        backgroundSyncStatus = summary
        return true
    }

    func requestHealthPermissions() async {
        guard terminalUserActionAdmissionIsOpen else { return }
        defer { activateAutomaticSyncIfReady() }
        do {
            try await withTerminalTransitionRequestGate { [self] in
                await self.performRequestHealthPermissionsWhileHoldingRequestGate()
            }
        } catch {
            return
        }
    }

    private func performRequestHealthPermissionsWhileHoldingRequestGate() async {
        guard !taskUIPublicationIsSuppressed,
              connectionTerminalBarrier.admissionIsOpen else {
            return
        }
        guard !isRequestingHealthPermissions else { return }
        isRequestingHealthPermissions = true
        statusIsError = false
        healthPermissionNoticeIsError = false
        healthPermissionNotice = "Opening Apple Health permissions..."
        defer { isRequestingHealthPermissions = false }

        #if canImport(HealthKit)
        do {
            let requestedTypeCodes = HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: enabledHealthPermissionTypeCodes
            )
            let authorizer = HealthStoreAuthorizer()
            try await authorizer.requestReadAuthorization(typeCodes: requestedTypeCodes)
            healthPermissionNotice = "Apple Health permission request completed for \(requestedTypeCodes.count) supported types currently available on this iPhone. Only data you allow in Apple Health can sync. Change individual access in Health > profile picture > Privacy > Apps > Health Bridge."
            healthPermissionRequestStore.recordCompletedRequest(
                runtimeTypeCodes: requestedTypeCodes
            )
            healthPermissionsRequested = true
            statusIsError = false
            if backgroundSyncEnabled {
                activateAutomaticSyncIfReady()
            }
        } catch {
            statusIsError = true
            statusMessage = "Apple Health permission failed."
            healthPermissionNoticeIsError = true
            healthPermissionNotice = "Apple Health permission failed: \(Self.userFriendlyErrorMessage(from: describe(error), context: .healthPermission))"
        }
        #else
        statusIsError = true
        statusMessage = "Apple Health is not available on this platform."
        healthPermissionNoticeIsError = true
        healthPermissionNotice = "Apple Health is not available on this platform."
        #endif
    }

    func sendConnectionTestBatch() async {
        do {
            try await runWithExclusiveDirectOutboxTransfer {
                await self.performSendConnectionTestBatch()
            }
        } catch is CancellationError {
            return
        } catch {
            statusIsError = true
            statusMessage = "Connection test could not acquire private storage access: \(describe(error))"
        }
    }

    private func performSendConnectionTestBatch() async {
        guard canSendConnectionTest, !Task.isCancelled else {
            statusIsError = true
            statusMessage = "Connection test stopped because receiver settings are no longer ready."
            return
        }
        guard let url = URL(string: receiverURLString) else {
            statusIsError = true
            statusMessage = "Bridge URL is invalid."
            return
        }

        do {
            statusIsError = false
            statusMessage = "Sending receiver test to \(url.absoluteString)..."
            let batch = ConnectionTestBatchFactory.make()
            let data = try encoder.encode(batch)
            let deliveryResult = try await uploadPayloadsWithOutbox([data], to: url)
            try requireCurrentConnectionGeneration(deliveryResult.connectionGeneration)
            let outboxNotice = lastOutboxNotice
            switch deliveryResult {
            case .uploaded:
                statusIsError = false
            case .queuedPendingRetry:
                statusIsError = true
            }
            statusMessage = deliveryStatusMessage(
                deliveryResult,
                uploadedDescription: "Receiver accepted test batch via \(url.host() ?? url.absoluteString)",
                queuedDescription: "Receiver test batch queued behind earlier pending upload(s)",
                outboxNotice: outboxNotice
            )
        } catch {
            statusIsError = true
            statusMessage = "Receiver test failed: \(describe(error))"
        }
    }

    @discardableResult
    func syncRecentStepCounts(executionMode: HealthBridgeSyncExecutionMode = .foreground) async -> Bool {
        guard let url = URL(string: receiverURLString) else {
            statusIsError = true
            statusMessage = "Bridge URL is invalid."
            return false
        }

        #if canImport(HealthKit)
        do {
            statusIsError = false
            statusMessage = "Reading anchored Step Count changes from HealthKit..."
            if executionMode.shouldRequestReadAuthorization {
                try await HealthStoreAuthorizer().requestReadAuthorization(healthTypes: [.steps])
            }
            let now = Date()
            let calendar = utcCalendar()
            let sourceKey = HealthBridgeAppleHealthSource.phone.sourceKey
            let (cursorStore, progressScope) = try captureReceiverSyncProgressScope()
            let receiverBindingID = progressScope.receiverBindingID
            let hasUploadedStepRecords = coreLaneUploadProofStore.hasUploadedRecords(
                lane: .steps,
                receiverBindingID: receiverBindingID
            )
            let storedAnchorCursorValue = try cursorStore.cursorValue(
                receiverBindingID: receiverBindingID,
                sourceKey: sourceKey,
                cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
            )
            let anchorCursorValue = CoreLaneSyncCursorPolicy.effectiveCursorValue(
                storedCursorValue: storedAnchorCursorValue,
                hasUploadedRecords: hasUploadedStepRecords
            )
            let shouldPersistSharedProgress = executionMode.shouldPersistSharedProgress(
                hadUsableCursor: HealthKitAnchoredCursorPolicy.hasUsableCursorValue(
                    anchorCursorValue
                )
            )
            let storedBootstrapStartValue = try cursorStore.cursorValue(
                receiverBindingID: receiverBindingID,
                sourceKey: sourceKey,
                cursorKind: AnchoredStepSyncPolicy.bootstrapStartCursorKind
            )
            let queryPlan = AnchoredStepSyncPolicy.queryPlan(
                anchorCursorValue: anchorCursorValue,
                storedBootstrapStartValue: storedBootstrapStartValue,
                bootstrapLookbackDays: executionMode.cursorlessFallbackDays ?? AnchoredStepSyncPolicy.bootstrapLookbackDays,
                clampStoredBootstrapToLookback: executionMode == .automatic,
                now: now,
                calendar: calendar
            )
            if shouldPersistSharedProgress, let bootstrapStart = queryPlan.bootstrapStartToPersist {
                try cursorStore.saveCursorValue(
                    HealthBridgeUTCFormatter.string(from: bootstrapStart),
                    receiverBindingID: receiverBindingID,
                    sourceKey: sourceKey,
                    cursorKind: AnchoredStepSyncPolicy.bootstrapStartCursorKind
                )
            }
            let changes = try await HealthKitStepCountReader(calendar: calendar).readAnchoredStepChanges(
                anchorCursorValue: anchorCursorValue,
                predicateStart: queryPlan.queryStart,
                receivedAt: now
            )
            try requireCurrentReceiverSyncProgressScope(progressScope)
            let batch = StepCountSyncBatchFactory.makeAnchoredStepBatch(
                changes: changes,
                generatedAt: now
            )
            let uploadedRecords = !batch.samples.isEmpty

            guard ForegroundSyncUploadPolicy.shouldUpload(batch) else {
                statusIsError = false
                statusMessage = "HealthKit returned no anchored step-count payload. Nothing sent."
                return false
            }
            guard uploadedRecords || hasUploadedStepRecords || !changes.deletedStepSamples.isEmpty else {
                statusIsError = false
                statusMessage = "HealthKit returned no readable Step Count records. Step cursor was not advanced so future Health permission changes can backfill history."
                return false
            }

            let uploadDescription = batch.samples.isEmpty && changes.deletedStepSamples.isEmpty
                ? "step anchor cursor-only sync"
                : "\(batch.samples.count) step add/update(s), \(changes.deletedStepSamples.count) step deletion(s)"
            statusMessage = "Uploading \(uploadDescription) to \(url.host() ?? url.absoluteString)..."
            let data = try encoder.encode(batch)
            let shouldPersistAnchorCursor = shouldPersistSharedProgress
                && CoreLaneSyncCursorPolicy.shouldPersistCursor(
                    uploadedRecords: uploadedRecords,
                    hasUploadedRecords: hasUploadedStepRecords
                )
            let cursorCheckpoint = shouldPersistAnchorCursor
                ? FileOutboxCursorCheckpoint(
                    receiverIdentity: receiverBindingID,
                    sourceKey: sourceKey,
                    cursorKind: StepCountSyncBatchFactory.anchoredCursorKind,
                    cursorValue: changes.anchorCursorValue,
                    coreLaneUploadProof: uploadedRecords ? .steps : nil
                )
                : nil
            try requireCurrentReceiverSyncProgressScope(progressScope)
            let deliveryResult = try await uploadPayloadsWithOutbox(
                [data],
                to: url,
                cursorCheckpoint: cursorCheckpoint
            )
            try requireCurrentReceiverSyncProgressScope(
                progressScope,
                deliveryGeneration: deliveryResult.connectionGeneration
            )
            let outboxNotice = lastOutboxNotice
            if shouldPersistAnchorCursor {
                try cursorStore.saveCursorValue(
                    changes.anchorCursorValue,
                    receiverBindingID: receiverBindingID,
                    sourceKey: sourceKey,
                    cursorKind: StepCountSyncBatchFactory.anchoredCursorKind
                )
                if cursorCheckpoint?.coreLaneUploadProof == .steps {
                    coreLaneUploadProofStore.markUploadedRecords(
                        lane: .steps,
                        receiverBindingID: receiverBindingID
                    )
                }
                if case .queuedPendingRetry = deliveryResult,
                   let cursorCheckpoint,
                   let outbox {
                    try outbox.acknowledgeCursorCheckpoint(cursorCheckpoint)
                    schedulePendingBackgroundOutboxUploadsIfAllowed()
                }
            }
            statusIsError = false
            let resultDescription = batch.samples.isEmpty && changes.deletedStepSamples.isEmpty
                ? "Recorded step anchor cursor"
                : "Synced step changes: added/updated \(batch.samples.count), deleted \(changes.deletedStepSamples.count)"
            statusMessage = deliveryStatusMessage(
                deliveryResult,
                uploadedDescription: resultDescription,
                queuedDescription: "Queued \(uploadDescription) behind earlier pending upload(s)",
                outboxNotice: outboxNotice
            )
            return uploadedRecords
        } catch {
            statusIsError = true
            statusMessage = "Step sync failed: \(describe(error))"
            return false
        }
        #else
        statusIsError = true
        statusMessage = "HealthKit is not available on this platform."
        return false
        #endif
    }

    @discardableResult
    func syncDailyActivityAggregates(executionMode: HealthBridgeSyncExecutionMode = .foreground) async -> Bool {
        guard let url = URL(string: receiverURLString) else {
            statusIsError = true
            statusMessage = "Bridge URL is invalid."
            return false
        }

        #if canImport(HealthKit)
        do {
            statusIsError = false
            statusMessage = "Reading HealthKit daily activity totals..."
            let typeCodes = DailyActivityAggregateSyncPolicy.defaultTypeCodes
            if executionMode.shouldRequestReadAuthorization {
                try await HealthStoreAuthorizer().requestReadAuthorization(typeCodes: typeCodes)
            }
            let now = Date()
            let calendar = Calendar.current
            let end = now
            let startOfToday = calendar.startOfDay(for: now)
            let fallbackDays = executionMode.cursorlessFallbackDays ?? 14
            let fallbackStart = calendar.date(byAdding: .day, value: -fallbackDays, to: startOfToday)
                ?? now.addingTimeInterval(TimeInterval(-fallbackDays * 24 * 60 * 60))
            let sourceKey = HealthBridgeAppleHealthSource.phone.sourceKey
            let (cursorStore, progressScope) = try captureReceiverSyncProgressScope()
            let receiverBindingID = progressScope.receiverBindingID
            let cursorValue = try cursorStore.cursorValue(
                receiverBindingID: receiverBindingID,
                sourceKey: sourceKey,
                cursorKind: DailyActivityAggregateSyncPolicy.cursorKind
            )
            let shouldPersistSharedProgress = executionMode.shouldPersistSharedProgress(
                hadUsableCursor: ForegroundSyncWindowPolicy.hasUsableCursorValue(
                    cursorValue,
                    before: end
                )
            )
            let start = ForegroundSyncWindowPolicy.windowStart(
                fallbackStart: fallbackStart,
                end: end,
                cursorValue: cursorValue,
                replayOverlapDays: 3,
                alignToStartOfDay: true,
                calendar: calendar
            )
            let aggregates = try await HealthKitGenericQuantityReader().readDailyActivityAggregates(
                typeCodes: typeCodes,
                start: start,
                end: end,
                calendar: calendar
            )
            guard let batch = DailyActivityAggregateSyncBatchFactory.makeDailyActivityAggregateBatch(
                aggregates: aggregates,
                typeCodes: typeCodes,
                windowStart: start,
                windowEnd: end,
                generatedAt: now
            ) else {
                statusIsError = false
                statusMessage = "No readable daily activity aggregate types are available. Nothing sent."
                return false
            }
            guard !batch.samples.isEmpty else {
                statusIsError = false
                statusMessage = "HealthKit returned no daily activity totals for the selected sync window. Nothing sent."
                return false
            }

            statusMessage = "Uploading \(batch.samples.count) daily activity total(s) to \(url.host() ?? url.absoluteString)..."
            let data = try encoder.encode(batch)
            let cursor = shouldPersistSharedProgress
                ? batch.sync.cursors.first(where: {
                    $0.sourceKey == sourceKey
                        && $0.cursorKind == DailyActivityAggregateSyncPolicy.cursorKind
                })
                : nil
            let cursorCheckpoint = cursor.map {
                FileOutboxCursorCheckpoint(
                    receiverIdentity: receiverBindingID,
                    sourceKey: $0.sourceKey,
                    cursorKind: $0.cursorKind,
                    cursorValue: $0.cursorValue
                )
            }
            try requireCurrentReceiverSyncProgressScope(progressScope)
            let deliveryResult = try await uploadPayloadsWithOutbox(
                [data],
                to: url,
                cursorCheckpoint: cursorCheckpoint
            )
            try requireCurrentReceiverSyncProgressScope(
                progressScope,
                deliveryGeneration: deliveryResult.connectionGeneration
            )
            let outboxNotice = lastOutboxNotice
            if let cursor {
                try cursorStore.saveCursorValue(
                    cursor.cursorValue,
                    receiverBindingID: receiverBindingID,
                    sourceKey: cursor.sourceKey,
                    cursorKind: cursor.cursorKind
                )
                if case .queuedPendingRetry = deliveryResult,
                   let cursorCheckpoint,
                   let outbox {
                    try outbox.acknowledgeCursorCheckpoint(cursorCheckpoint)
                    schedulePendingBackgroundOutboxUploadsIfAllowed()
                }
            }
            statusIsError = false
            statusMessage = deliveryStatusMessage(
                deliveryResult,
                uploadedDescription: "Synced \(batch.samples.count) daily activity total(s)",
                queuedDescription: "Queued \(batch.samples.count) daily activity total(s) behind earlier pending upload(s)",
                outboxNotice: outboxNotice
            )
            return true
        } catch {
            statusIsError = true
            statusMessage = "Daily activity total sync failed: \(describe(error))"
            return false
        }
        #else
        statusIsError = true
        statusMessage = "HealthKit is not available on this platform."
        return false
        #endif
    }

    func syncRecentWorkouts() async {
        guard let url = URL(string: receiverURLString) else {
            statusIsError = true
            statusMessage = "Bridge URL is invalid."
            return
        }

        #if canImport(HealthKit)
        do {
            statusIsError = false
            statusMessage = "Reading workouts from HealthKit..."
            try await HealthStoreAuthorizer().requestReadAuthorization(healthTypes: [.workouts])
            let now = Date()
            let calendar = utcCalendar()
            let end = now
            let startOfToday = calendar.startOfDay(for: now)
            let fallbackStart = calendar.date(byAdding: .day, value: -14, to: startOfToday)
                ?? now.addingTimeInterval(-14 * 24 * 60 * 60)
            let (cursorStore, progressScope) = try captureReceiverSyncProgressScope()
            let receiverBindingID = progressScope.receiverBindingID
            let cursorValue = try cursorStore.cursorValue(
                receiverBindingID: receiverBindingID,
                sourceKey: "apple_health.phone",
                cursorKind: "foreground_workout_sync"
            )
            let start = ForegroundSyncWindowPolicy.windowStart(
                fallbackStart: fallbackStart,
                end: end,
                cursorValue: cursorValue,
                replayOverlapDays: 3,
                alignToStartOfDay: false,
                calendar: calendar
            )
            let workouts = try await HealthKitWorkoutReader().readWorkouts(start: start, end: end)
            let batch = WorkoutSyncBatchFactory.makeWorkoutBatch(
                workouts: workouts,
                windowStart: start,
                windowEnd: end,
                generatedAt: now
            )

            guard ForegroundSyncUploadPolicy.shouldUpload(batch) else {
                statusIsError = false
                statusMessage = "HealthKit returned no workout sync payload for the selected sync window. Nothing sent."
                return
            }

            let uploadDescription = batch.workouts.isEmpty
                ? "workout cursor-only sync"
                : "\(batch.workouts.count) workouts"
            statusMessage = "Uploading \(uploadDescription) to \(url.host() ?? url.absoluteString)..."
            let data = try encoder.encode(batch)
            let cursor = batch.sync.cursors.first(where: {
                $0.sourceKey == "apple_health.phone"
                    && $0.cursorKind == "foreground_workout_sync"
            })
            let cursorCheckpoint = cursor.map {
                FileOutboxCursorCheckpoint(
                    receiverIdentity: receiverBindingID,
                    sourceKey: $0.sourceKey,
                    cursorKind: $0.cursorKind,
                    cursorValue: $0.cursorValue
                )
            }
            try requireCurrentReceiverSyncProgressScope(progressScope)
            let deliveryResult = try await uploadPayloadsWithOutbox(
                [data],
                to: url,
                cursorCheckpoint: cursorCheckpoint
            )
            try requireCurrentReceiverSyncProgressScope(
                progressScope,
                deliveryGeneration: deliveryResult.connectionGeneration
            )
            let outboxNotice = lastOutboxNotice
            if let cursor {
                try cursorStore.saveCursorValue(
                    cursor.cursorValue,
                    receiverBindingID: receiverBindingID,
                    sourceKey: cursor.sourceKey,
                    cursorKind: cursor.cursorKind
                )
                if case .queuedPendingRetry = deliveryResult,
                   let cursorCheckpoint,
                   let outbox {
                    try outbox.acknowledgeCursorCheckpoint(cursorCheckpoint)
                    schedulePendingBackgroundOutboxUploadsIfAllowed()
                }
            }
            let totalMinutes = batch.workouts.reduce(0) { $0 + $1.durationSeconds } / 60
            statusIsError = false
            let resultDescription = batch.workouts.isEmpty
                ? "Recorded workout sync cursor"
                : "Synced \(batch.workouts.count) workouts (\(totalMinutes) min)"
            statusMessage = deliveryStatusMessage(
                deliveryResult,
                uploadedDescription: resultDescription,
                queuedDescription: "Queued \(uploadDescription) behind earlier pending upload(s)",
                outboxNotice: outboxNotice
            )
        } catch {
            statusIsError = true
            statusMessage = "Workout sync failed: \(describe(error))"
        }
        #else
        statusIsError = true
        statusMessage = "HealthKit is not available on this platform."
        #endif
    }

    @discardableResult
    func syncAnchoredWorkoutChanges(executionMode: HealthBridgeSyncExecutionMode = .foreground) async -> Bool {
        guard let url = URL(string: receiverURLString) else {
            statusIsError = true
            statusMessage = "Bridge URL is invalid."
            return false
        }

        #if canImport(HealthKit)
        do {
            statusIsError = false
            statusMessage = "Reading anchored workout changes from HealthKit..."
            if executionMode.shouldRequestReadAuthorization {
                try await HealthStoreAuthorizer().requestReadAuthorization(healthTypes: [.workouts])
            }
            let now = Date()
            let calendar = utcCalendar()
            let sourceKey = HealthBridgeAppleHealthSource.phone.sourceKey
            let (cursorStore, progressScope) = try captureReceiverSyncProgressScope()
            let receiverBindingID = progressScope.receiverBindingID
            let hasUploadedWorkoutRecords = coreLaneUploadProofStore.hasUploadedRecords(
                lane: .workouts,
                receiverBindingID: receiverBindingID
            )
            let storedAnchorCursorValue = try cursorStore.cursorValue(
                receiverBindingID: receiverBindingID,
                sourceKey: sourceKey,
                cursorKind: WorkoutSyncBatchFactory.anchoredCursorKind
            )
            let anchorCursorValue = CoreLaneSyncCursorPolicy.effectiveCursorValue(
                storedCursorValue: storedAnchorCursorValue,
                hasUploadedRecords: hasUploadedWorkoutRecords
            )
            let shouldPersistSharedProgress = executionMode.shouldPersistSharedProgress(
                hadUsableCursor: HealthKitAnchoredCursorPolicy.hasUsableCursorValue(
                    anchorCursorValue
                )
            )
            let storedBootstrapStartValue = try cursorStore.cursorValue(
                receiverBindingID: receiverBindingID,
                sourceKey: sourceKey,
                cursorKind: AnchoredWorkoutSyncPolicy.bootstrapStartCursorKind
            )
            let queryPlan = AnchoredWorkoutSyncPolicy.queryPlan(
                anchorCursorValue: anchorCursorValue,
                storedBootstrapStartValue: storedBootstrapStartValue,
                bootstrapLookbackDays: executionMode.cursorlessFallbackDays ?? AnchoredWorkoutSyncPolicy.bootstrapLookbackDays,
                clampStoredBootstrapToLookback: executionMode == .automatic,
                now: now,
                calendar: calendar
            )
            if shouldPersistSharedProgress, let bootstrapStart = queryPlan.bootstrapStartToPersist {
                try cursorStore.saveCursorValue(
                    HealthBridgeUTCFormatter.string(from: bootstrapStart),
                    receiverBindingID: receiverBindingID,
                    sourceKey: sourceKey,
                    cursorKind: AnchoredWorkoutSyncPolicy.bootstrapStartCursorKind
                )
            }
            let changes = try await HealthKitWorkoutReader().readAnchoredWorkoutChanges(
                anchorCursorValue: anchorCursorValue,
                predicateStart: queryPlan.queryStart,
                receivedAt: now
            )
            let batch = WorkoutSyncBatchFactory.makeAnchoredWorkoutBatch(
                changes: changes,
                generatedAt: now
            )
            let uploadedRecords = !batch.workouts.isEmpty

            guard ForegroundSyncUploadPolicy.shouldUpload(batch) else {
                statusIsError = false
                statusMessage = "HealthKit returned no anchored workout payload. Nothing sent."
                return false
            }
            guard uploadedRecords || hasUploadedWorkoutRecords || !batch.deletedRecords.isEmpty else {
                statusIsError = false
                statusMessage = "HealthKit returned no readable Workout records. Workout cursor was not advanced so future Health permission changes can backfill history."
                return false
            }

            let uploadDescription = batch.workouts.isEmpty && batch.deletedRecords.isEmpty
                ? "workout anchor cursor-only sync"
                : "\(batch.workouts.count) workout add/update(s), \(batch.deletedRecords.count) workout deletion(s)"
            statusMessage = "Uploading \(uploadDescription) to \(url.host() ?? url.absoluteString)..."
            let data = try encoder.encode(batch)
            let shouldPersistAnchorCursor = shouldPersistSharedProgress
                && CoreLaneSyncCursorPolicy.shouldPersistCursor(
                    uploadedRecords: uploadedRecords,
                    hasUploadedRecords: hasUploadedWorkoutRecords
                )
            let cursorCheckpoint = shouldPersistAnchorCursor
                ? FileOutboxCursorCheckpoint(
                    receiverIdentity: receiverBindingID,
                    sourceKey: sourceKey,
                    cursorKind: WorkoutSyncBatchFactory.anchoredCursorKind,
                    cursorValue: changes.anchorCursorValue,
                    coreLaneUploadProof: uploadedRecords ? .workouts : nil
                )
                : nil
            try requireCurrentReceiverSyncProgressScope(progressScope)
            let deliveryResult = try await uploadPayloadsWithOutbox(
                [data],
                to: url,
                cursorCheckpoint: cursorCheckpoint
            )
            try requireCurrentReceiverSyncProgressScope(
                progressScope,
                deliveryGeneration: deliveryResult.connectionGeneration
            )
            let outboxNotice = lastOutboxNotice
            if shouldPersistAnchorCursor {
                try cursorStore.saveCursorValue(
                    changes.anchorCursorValue,
                    receiverBindingID: receiverBindingID,
                    sourceKey: sourceKey,
                    cursorKind: WorkoutSyncBatchFactory.anchoredCursorKind
                )
                if cursorCheckpoint?.coreLaneUploadProof == .workouts {
                    coreLaneUploadProofStore.markUploadedRecords(
                        lane: .workouts,
                        receiverBindingID: receiverBindingID
                    )
                }
                if case .queuedPendingRetry = deliveryResult,
                   let cursorCheckpoint,
                   let outbox {
                    try outbox.acknowledgeCursorCheckpoint(cursorCheckpoint)
                    schedulePendingBackgroundOutboxUploadsIfAllowed()
                }
            }

            statusIsError = false
            let resultDescription = batch.workouts.isEmpty && batch.deletedRecords.isEmpty
                ? "Recorded workout anchor cursor"
                : "Synced workout changes: added/updated \(batch.workouts.count), deleted \(batch.deletedRecords.count)"
            statusMessage = deliveryStatusMessage(
                deliveryResult,
                uploadedDescription: resultDescription,
                queuedDescription: "Queued \(uploadDescription) behind earlier pending upload(s)",
                outboxNotice: outboxNotice
            )
            return uploadedRecords
        } catch {
            statusIsError = true
            statusMessage = "Anchored workout sync failed: \(describe(error))"
            return false
        }
        #else
        statusIsError = true
        statusMessage = "HealthKit is not available on this platform."
        return false
        #endif
    }

    @discardableResult
    func syncRecentSleepSessions(executionMode: HealthBridgeSyncExecutionMode = .foreground) async -> Bool {
        guard let url = URL(string: receiverURLString) else {
            statusIsError = true
            statusMessage = "Bridge URL is invalid."
            return false
        }

        #if canImport(HealthKit)
        do {
            if !privateStorageAdmissionReady {
                try preparePrivateStorageForUploadAdmission()
            }
            guard let sleepManifestStore else {
                statusIsError = true
                statusMessage = "Sleep sync is unavailable because its private manifest store could not be opened."
                return false
            }
            guard let outbox else {
                throw CompanionPrivateStorageError.outboxUnavailable
            }
            guard let sleepSourceKey else {
                throw KeychainReceiverTokenStoreError.unavailable
            }
            try outbox.requireUploadAdmission()
            if let pendingTransition = try sleepManifestStore.loadPendingTransition() {
                let pendingBatch = try JSONDecoder().decode(
                    HealthBridgeBatchV1.self,
                    from: pendingTransition.payload
                )
                if SleepSyncBatchFactory.requiresInstallationSourceMigration(
                    manifest: pendingTransition.manifest,
                    pendingBatch: pendingBatch,
                    expectedSourceKey: sleepSourceKey
                ) {
                    if let itemID = pendingTransition.outboxItemID,
                       let obsoleteItem = try outbox.pendingItem(id: itemID) {
                        try outbox.markUploaded(obsoleteItem)
                    }
                    try sleepManifestStore.resetSynchronizationState()
                    _ = try sleepResetEpochStore.reserveEpoch(
                        after: pendingTransition.manifest.baselineResetEpoch ?? 0
                    )
                    refreshPendingOutboxCount()
                } else {
                    let matchesCurrentConnection =
                        settingsStore.receiverSettingsGenerationToken
                            == pendingTransition.connectionGeneration
                        && settingsStore.receiverBindingID == pendingTransition.receiverBindingID
                        && settingsStore.receiverURLString == url.absoluteString
                    if matchesCurrentConnection {
                        return try await deliverPendingSleepTransition(
                            pendingTransition,
                            store: sleepManifestStore,
                            to: url
                        )
                    }
                    let trackedItemStillExists = try pendingTransition.outboxItemID.map { itemID in
                        try outbox.pendingItem(id: itemID) != nil
                    } ?? false
                    if trackedItemStillExists {
                        refreshPendingOutboxCount()
                        statusIsError = true
                        statusMessage = "A pending Sleep upload belongs to an earlier connection. It is quarantined and must be deleted before Sleep sync can continue."
                        return false
                    }
                    try sleepManifestStore.resetSynchronizationState()
                    refreshPendingOutboxCount()
                }
            }
            statusIsError = false
            statusMessage = "Reading anchored Sleep Analysis changes from HealthKit..."
            if executionMode.shouldRequestReadAuthorization {
                try await HealthStoreAuthorizer().requestReadAuthorization(healthTypes: [.sleepAnalysis])
            }
            let now = Date()
            let currentReceiverGeneration = settingsStore.receiverSettingsGenerationToken
            guard let currentReceiverBindingID = settingsStore.receiverBindingID else {
                throw CancellationError()
            }
            let currentHistoryDepth = healthHistoryDepth.sanitized
            let requestedHistoryStartDate = currentHistoryDepth.lowerBoundDate(
                now: now,
                calendar: utcCalendar()
            )
            var storedManifest = try sleepManifestStore.loadManifest()
            let sourceMigrationRequired = storedManifest.map {
                SleepSyncBatchFactory.requiresInstallationSourceMigration(
                    manifest: $0,
                    pendingBatch: nil,
                    expectedSourceKey: sleepSourceKey
                )
            } ?? false
            let baselineReservationRequired = storedManifest == nil
                || storedManifest?.receiverSettingsGeneration != currentReceiverGeneration
                || storedManifest?.historyDepth != currentHistoryDepth
                || storedManifest?.sourceKey != sleepSourceKey
                || storedManifest?.baselineResetEpoch == nil
                || sourceMigrationRequired
            if baselineReservationRequired {
                let resetEpoch = try sleepResetEpochStore.reserveEpoch(
                    after: storedManifest?.baselineResetEpoch ?? 0
                )
                let canRetainIdentity = !sourceMigrationRequired
                    && storedManifest?.sourceKey == sleepSourceKey
                let reservation = SleepSyncBatchFactory.makeManifestReservation(
                    receiverSettingsGeneration: currentReceiverGeneration,
                    historyDepth: currentHistoryDepth,
                    historyStartDate: requestedHistoryStartDate,
                    sourceKey: sleepSourceKey,
                    baselineResetEpoch: resetEpoch,
                    identityNamespace: canRetainIdentity
                        ? (storedManifest?.identityNamespace ?? UUID())
                        : UUID(),
                    nextRevisionSequence: canRetainIdentity
                        ? (storedManifest?.nextRevisionSequence ?? 1)
                        : 1
                )
                guard terminalPayloadActionAdmissionIsOpen, !Task.isCancelled else {
                    throw CancellationError()
                }
                try sleepManifestStore.saveManifest(reservation)
                storedManifest = reservation
            }
            let manifestPlan = SleepSyncBatchFactory.manifestPlan(
                storedManifest,
                receiverSettingsGeneration: currentReceiverGeneration,
                historyDepth: currentHistoryDepth,
                requestedHistoryStartDate: requestedHistoryStartDate
            )
            guard executionMode == .foreground || manifestPlan.anchorCursorValue != nil else {
                statusIsError = false
                statusMessage = "Open the app and run Sync Now once before automatic Sleep sync begins."
                return false
            }
            let changes = try await HealthKitSleepReader().readAnchoredSleepChanges(
                anchorCursorValue: manifestPlan.anchorCursorValue,
                historyStartDate: manifestPlan.historyStartDate,
                receivedAt: now
            )
            try Task.checkCancellation()
            try requireCurrentConnectionGeneration(currentReceiverGeneration)
            guard settingsStore.receiverBindingID == currentReceiverBindingID,
                  settingsStore.receiverURLString == url.absoluteString else {
                throw CancellationError()
            }
            guard let transition = SleepSyncBatchFactory.makeAnchoredSleepTransition(
                previousManifest: manifestPlan.previousManifest,
                changes: changes,
                receiverSettingsGeneration: currentReceiverGeneration,
                historyDepth: currentHistoryDepth,
                historyStartDate: manifestPlan.historyStartDate,
                forceRepublishAll: manifestPlan.forceRepublishAll,
                generatedAt: now
            ) else {
                statusIsError = false
                statusMessage = "HealthKit returned no readable Sleep records. No deletion was inferred and no sleep anchor was advanced."
                return false
            }
            let batch = transition.batch
            let uploadedRecords = !batch.sleepSessions.isEmpty
            let hasRecordChanges = uploadedRecords || !batch.deletedRecords.isEmpty
            let uploadDescription = hasRecordChanges
                ? "\(batch.sleepSessions.count) sleep revision(s), \(batch.deletedRecords.count) sleep deletion(s)"
                : "sleep anchor cursor-only sync"
            statusMessage = "Uploading \(uploadDescription) to \(url.host() ?? url.absoluteString)..."
            let data = try encoder.encode(batch)
            try Task.checkCancellation()
            try requireCurrentConnectionGeneration(currentReceiverGeneration)
            guard settingsStore.receiverBindingID == currentReceiverBindingID,
                  settingsStore.receiverURLString == url.absoluteString else {
                throw CancellationError()
            }
            let pendingTransition = SleepSyncPendingTransition(
                payload: data,
                manifest: transition.manifest,
                receiverBindingID: currentReceiverBindingID,
                connectionGeneration: currentReceiverGeneration
            )
            guard terminalPayloadActionAdmissionIsOpen, !Task.isCancelled else {
                throw CancellationError()
            }
            try sleepManifestStore.savePendingTransition(pendingTransition)
            refreshPendingOutboxCount()
            return try await deliverPendingSleepTransition(
                pendingTransition,
                store: sleepManifestStore,
                to: url
            )
        } catch {
            statusIsError = true
            statusMessage = "Anchored sleep sync failed: \(describe(error))"
            return false
        }
        #else
        statusIsError = true
        statusMessage = "HealthKit is not available on this platform."
        return false
        #endif
    }

    private func deliverPendingSleepTransition(
        _ pendingTransition: SleepSyncPendingTransition,
        store: SleepSyncManifestStoring,
        to url: URL
    ) async throws -> Bool {
        guard terminalPayloadActionAdmissionIsOpen, !Task.isCancelled else {
            throw CancellationError()
        }
        guard settingsStore.receiverSettingsGenerationToken == pendingTransition.connectionGeneration,
              settingsStore.receiverBindingID == pendingTransition.receiverBindingID,
              settingsStore.receiverURLString == url.absoluteString else {
            throw CancellationError()
        }
        try requireCurrentConnectionGeneration(pendingTransition.connectionGeneration)

        let decodedBatch = try? JSONDecoder().decode(
            HealthBridgeBatchV1.self,
            from: pendingTransition.payload
        )
        let uploadedRecords = !(decodedBatch?.sleepSessions.isEmpty ?? true)
        let hasRecordChanges = uploadedRecords || !(decodedBatch?.deletedRecords.isEmpty ?? true)

        guard let outbox else {
            throw CompanionPrivateStorageError.outboxUnavailable
        }
        var trackedTransition = pendingTransition
        if trackedTransition.outboxItemID == nil {
            let enqueueResult = try outbox.enqueueIfAbsent(
                trackedTransition.payload,
                receiverIdentity: trackedTransition.receiverBindingID
            )
            trackedTransition = trackedTransition.assigningOutboxItemID(
                enqueueResult.item.id
            )
            try store.savePendingTransition(trackedTransition)
            refreshPendingOutboxCount()
            if enqueueResult.wasInserted {
                schedulePendingBackgroundOutboxUploadsIfAllowed()
            }
        }

        guard let outboxItemID = trackedTransition.outboxItemID else {
                throw CocoaError(.fileWriteUnknown)
            }
            let pendingItems = try outbox.pendingItems()
            var itemRemains = pendingItems.contains { $0.id == outboxItemID }
            var summary: FileOutboxFlushSummary?
            let isFIFOHead = pendingItems.first?.id == outboxItemID
            if itemRemains,
               !CompanionPayloadNetworkAttemptPolicy.shouldAttemptNetworkForQueuedPayload(
                   isFIFOHead: isFIFOHead
               ) {
                schedulePendingBackgroundOutboxUploadsIfAllowed()
                statusIsError = false
                statusMessage = "Sleep transition is durably journaled behind an earlier queued upload. Pending outbox: \(pendingOutboxCount)."
                return false
            }
            if itemRemains {
                do {
                    summary = try await uploadPendingOutbox(
                        outbox,
                        to: url,
                        bearerToken: try settingsStore.loadBearerToken(),
                        expectedGeneration: trackedTransition.connectionGeneration
                    )
                } catch let conflict as RejectedSleepBaselineOutboxItem {
                    try recoverRejectedSleepBaseline(conflict)
                    statusIsError = false
                    statusMessage = "Receiver required a newer Sleep reset epoch. The rejected transition was retired crash-safely and a receiver-safe epoch was reserved."
                    return false
                }
                try requireCurrentConnectionGeneration(trackedTransition.connectionGeneration)
                refreshPendingOutboxCount()
                itemRemains = try outbox.pendingItems().contains { $0.id == outboxItemID }
            }
        if itemRemains {
            statusIsError = false
            let failure = summary.map { Self.firstFailureSentence($0) } ?? ""
            statusMessage = "Sleep transition is durably journaled and queued for FIFO retry. Pending outbox: \(pendingOutboxCount). \(failure)"
            return false
        }

        try store.saveManifest(pendingTransition.manifest)
        try store.clearPendingTransition(id: pendingTransition.id)
        refreshPendingOutboxCount()
        statusIsError = false
        statusMessage = hasRecordChanges
            ? "Synced the durable authoritative sleep transition. Pending outbox: \(pendingOutboxCount)."
            : "Recorded the durable sleep anchor transition. Pending outbox: \(pendingOutboxCount)."
        return uploadedRecords
    }

    func syncSupportedQuantityMetrics() async {
        await syncQuantityMetrics(
            typeCodes: supportedForegroundQuantityTypeCodes,
            mode: .foreground
        )
    }

    private var supportedForegroundQuantityTypeCodes: [String] {
        enabledBroadQuantityTypeCodes
    }

    private var enabledBroadQuantityTypeCodes: [String] {
        HealthBridgeBackgroundSync.supportedAutomaticQuantityTypeCodes
    }

    private var enabledHealthPermissionTypeCodes: [String] {
        HealthBridgeBackgroundSync.supportedUnifiedReadTypeCodes
    }

    private func syncBackgroundAutomaticQuantityMetrics(
        typeCodes: [String],
        historyDepth: HealthHistoryDepth
    ) async {
        await syncQuantityMetrics(
            typeCodes: typeCodes,
            mode: .background,
            historyDepth: historyDepth
        )
    }

    private enum QuantitySyncMode: Equatable {
        case foreground
        case background

        var executionMode: HealthBridgeSyncExecutionMode {
            switch self {
            case .foreground:
                return .foreground
            case .background:
                return .automatic
            }
        }

        var emptySelectionMessage: String {
            switch self {
            case .foreground:
                return "No supported quantity types are available on this device. Nothing sent."
            case .background:
                return "No supported quantity work was planned for this background run. Nothing sent."
            }
        }

        var noSamplesMessage: String {
            switch self {
            case .foreground:
                return "HealthKit returned no supported quantity samples. Cursors were not advanced so future permission changes can still backfill history."
            case .background:
                return "HealthKit returned no supported quantity samples during bounded background catch-up. Cursors were not advanced."
            }
        }

        var failurePrefix: String {
            switch self {
            case .foreground:
                return "Supported quantity sync failed"
            case .background:
                return "Background quantity sync failed"
            }
        }

        func readingStatus(metricCount: Int) -> String {
            switch self {
            case .foreground:
                return "Requesting read access and reading \(metricCount) supported quantity type(s) from HealthKit..."
            case .background:
                return "Reading new data and bounded catch-up for \(metricCount) supported quantity type(s) from HealthKit..."
            }
        }
    }

    private func syncQuantityMetrics(
        typeCodes rawTypeCodes: [String],
        mode: QuantitySyncMode,
        historyDepth: HealthHistoryDepth? = nil
    ) async {
        guard let url = URL(string: receiverURLString) else {
            statusIsError = true
            statusMessage = "Bridge URL is invalid."
            return
        }

        #if canImport(HealthKit)
            let availableRawTypeCodes = HealthKitReadTypeCatalog.availableTypeCodes(
                forTypeCodes: rawTypeCodes
            )
            let selectedTypeCodes = GenericQuantityCoveragePolicy
                .coveragePlan(availableTypeCodes: availableRawTypeCodes)
                .availableEntries
                .map(\.typeCode)
            guard !selectedTypeCodes.isEmpty else {
                statusIsError = false
                statusMessage = mode.emptySelectionMessage
                return
            }

            let sourceKey = HealthBridgeAppleHealthSource.phone.sourceKey
            let progressStorage: (FileSyncCursorStore, ReceiverSyncProgressScope)
            do {
                progressStorage = try captureReceiverSyncProgressScope()
            } catch {
                statusIsError = true
                statusMessage = describe(error)
                return
            }
            let (cursorStore, progressScope) = progressStorage
            let receiverBindingID = progressScope.receiverBindingID
            let now = Date()
            let calendar = utcCalendar()
            let selectedHistoryDepth = historyDepth ?? healthHistoryDepthStore.historyDepth
            let selectedEntries = GenericQuantityCoveragePolicy
                .coveragePlan(availableTypeCodes: selectedTypeCodes)
                .availableEntries
            let displayNamesByTypeCode = Dictionary(
                uniqueKeysWithValues: selectedEntries.map { ($0.typeCode, $0.displayName) }
            )
            let historicalBackfillTypeCodes: [String]
            switch mode {
            case .foreground:
                historicalBackfillTypeCodes = HealthHistoricalBackfillPolicy.sparseAllAvailableTypeCodes(
                    selectedTypeCodes: selectedTypeCodes,
                    historyDepth: selectedHistoryDepth
                )
            case .background:
                historicalBackfillTypeCodes = []
            }
            if !historicalBackfillTypeCodes.isEmpty {
                historicalBackfillStateStore.start(
                    typeCodes: historicalBackfillTypeCodes,
                    historyDepth: selectedHistoryDepth
                )
                refreshHistoricalBackfillPublishedStateIfAllowed()
            }

            statusIsError = false
            statusMessage = mode.readingStatus(metricCount: selectedTypeCodes.count)
            let reader = HealthKitGenericQuantityReader()
            var completedTypeCodes: [String] = []
            var skippedMetricDescriptions: [String] = []
            var totalSampleCount = 0
            var totalDeletedCount = 0
            var totalBatchCount = 0
            var queuedAnyPayload = false

            for typeCode in selectedTypeCodes {
                do {
                    try requireCurrentReceiverSyncProgressScope(progressScope)
                    let anchorCursorKind = GenericQuantitySyncBatchFactory.anchoredCursorKind(for: typeCode)
                    let anchorCursorValue = try cursorStore.cursorValue(
                        receiverBindingID: receiverBindingID,
                        sourceKey: sourceKey,
                        cursorKind: anchorCursorKind
                    )
                    let legacyTimestampCursorValues = try GenericQuantityAnchoredSyncPolicy
                        .legacyTimestampCursorKinds(for: typeCode)
                        .compactMap { cursorKind in
                            try cursorStore.cursorValue(
                                receiverBindingID: receiverBindingID,
                                sourceKey: sourceKey,
                                cursorKind: cursorKind
                            )
                        }
                    let legacyTimestampCursorValue = GenericQuantityAnchoredSyncPolicy
                        .earliestUsableTimestampCursorValue(legacyTimestampCursorValues)
                    guard let queryPlan = GenericQuantityAnchoredSyncPolicy.queryPlan(
                        typeCode: typeCode,
                        anchorCursorValue: anchorCursorValue,
                        legacyTimestampCursorValue: legacyTimestampCursorValue,
                        historyDepth: selectedHistoryDepth,
                        now: now,
                        calendar: calendar
                    ) else {
                        continue
                    }
                    let hadUsableAnchor = HealthKitAnchoredCursorPolicy.hasUsableCursorValue(
                        anchorCursorValue
                    )
                    let canPersistSharedProgress = mode.executionMode.shouldPersistSharedProgress(
                        hadUsableCursor: hadUsableAnchor
                    )

                    let changes = try await reader.readAnchoredQuantityChanges(
                        typeCode: queryPlan.canonicalTypeCode,
                        anchorCursorValue: anchorCursorValue,
                        predicateStart: queryPlan.predicateStart,
                        receivedAt: now
                    )
                    try requireCurrentReceiverSyncProgressScope(progressScope)
                    let shouldIncludeAnchor = GenericQuantityAnchoredProgressPolicy
                        .shouldIncludeAnchor(
                            canPersistSharedProgress: canPersistSharedProgress,
                            hadUsableAnchor: hadUsableAnchor,
                            activeSampleCount: changes.samples.count,
                            deletedSampleCount: changes.deletedSamples.count
                        )
                    let batches = GenericQuantitySyncBatchFactory.makeAnchoredQuantityBatches(
                        changes: changes,
                        generatedAt: now,
                        includeAnchorCursor: shouldIncludeAnchor
                    ).filter(ForegroundSyncUploadPolicy.shouldUpload)
                    guard !batches.isEmpty else {
                        continue
                    }

                    let payloads = try batches.map { try encoder.encode($0) }
                    let cursorCheckpoint = shouldIncludeAnchor
                        ? FileOutboxCursorCheckpoint(
                            receiverIdentity: receiverBindingID,
                            sourceKey: sourceKey,
                            cursorKind: queryPlan.anchorCursorKind,
                            cursorValue: changes.anchorCursorValue
                        )
                        : nil
                    try requireCurrentReceiverSyncProgressScope(progressScope)
                    let deliveryResult = try await uploadPayloadsWithOutbox(
                        payloads,
                        to: url,
                        cursorCheckpoint: cursorCheckpoint
                    )
                    try requireCurrentReceiverSyncProgressScope(
                        progressScope,
                        deliveryGeneration: deliveryResult.connectionGeneration
                    )
                    let deliveryDisposition: GenericQuantityAnchoredDeliveryDisposition
                    switch deliveryResult {
                    case .uploaded:
                        deliveryDisposition = .uploaded
                    case .queuedPendingRetry:
                        deliveryDisposition = .durablyQueued
                        queuedAnyPayload = true
                    }
                    if shouldIncludeAnchor,
                       GenericQuantityAnchoredProgressPolicy.shouldPersistAnchor(
                        readSucceeded: true,
                        delivery: deliveryDisposition
                       ) {
                        try cursorStore.saveCursorValue(
                            changes.anchorCursorValue,
                            receiverBindingID: receiverBindingID,
                            sourceKey: sourceKey,
                            cursorKind: queryPlan.anchorCursorKind
                        )
                        if case .queuedPendingRetry = deliveryResult,
                           let cursorCheckpoint,
                           let outbox {
                            try outbox.acknowledgeCursorCheckpoint(cursorCheckpoint)
                            schedulePendingBackgroundOutboxUploadsIfAllowed()
                        }
                    }
                    quantityObservationStore.markObserved(typeCodes: [queryPlan.canonicalTypeCode])
                    if historicalBackfillTypeCodes.contains(queryPlan.canonicalTypeCode),
                       shouldIncludeAnchor {
                        historicalBackfillStateStore.markCompleted(queryPlan.canonicalTypeCode)
                        refreshHistoricalBackfillPublishedStateIfAllowed()
                    }
                    completedTypeCodes.append(queryPlan.canonicalTypeCode)
                    totalSampleCount += batches.reduce(0) { $0 + $1.samples.count }
                    totalDeletedCount += batches.reduce(0) { $0 + $1.deletedRecords.count }
                    totalBatchCount += batches.count
                    if AutomaticSyncPayloadGenerationPolicy.shouldStopQuantityLoop(
                        isAutomaticSync: mode == .background,
                        hasDurablyQueuedPayload: queuedAnyPayload
                    ) {
                        break
                    }
                } catch let enqueueFailure as DurablePayloadEnqueueFailure {
                    if enqueueFailure.durableItemCount > 0 {
                        queuedAnyPayload = true
                    }
                    if enqueueFailure.underlyingError is CancellationError {
                        return
                    }
                    let name = displayNamesByTypeCode[typeCode] ?? typeCode
                    skippedMetricDescriptions.append(
                        "\(name) — \(supportedMetricSkipReason(enqueueFailure.underlyingError))"
                    )
                    if AutomaticSyncPayloadGenerationPolicy.shouldStopQuantityLoop(
                        isAutomaticSync: mode == .background,
                        hasDurablyQueuedPayload: queuedAnyPayload
                    ) {
                        break
                    }
                } catch is CancellationError {
                    return
                } catch {
                    let name = displayNamesByTypeCode[typeCode] ?? typeCode
                    skippedMetricDescriptions.append("\(name) — \(supportedMetricSkipReason(error))")
                    if AutomaticSyncPayloadGenerationPolicy.shouldStopQuantityLoop(
                        isAutomaticSync: mode == .background,
                        hasDurablyQueuedPayload: queuedAnyPayload
                    ) {
                        break
                    }
                }
            }

            guard !completedTypeCodes.isEmpty else {
                if skippedMetricDescriptions.count == selectedTypeCodes.count {
                    statusIsError = true
                    statusMessage = "\(mode.failurePrefix): \(skippedAdditionalMetricsMessage(skippedMetricDescriptions))"
                } else {
                    statusIsError = false
                    statusMessage = mode.noSamplesMessage
                }
                return
            }

            statusIsError = false
            let metricList = Array(Set(completedTypeCodes)).sorted().joined(separator: ", ")
            let chunkDescription = totalBatchCount > completedTypeCodes.count
                ? " in \(totalBatchCount) ordered batches"
                : ""
            let resultDescription: String
            if totalSampleCount == 0 && totalDeletedCount == 0 {
                resultDescription = "Recorded anchored quantity cursor(s) for \(metricList)"
            } else {
                resultDescription = "Synced anchored quantity changes for \(metricList): added/updated \(totalSampleCount), deleted \(totalDeletedCount)\(chunkDescription)"
            }
            let skipNotice = skippedMetricDescriptions.isEmpty
                ? ""
                : " \(skippedAdditionalMetricsMessage(skippedMetricDescriptions))"
            let queueNotice = queuedAnyPayload
                ? " Exact ordered payload sequence(s) are durably queued for FIFO retry."
                : ""
            statusMessage = "\(resultDescription).\(queueNotice) Pending outbox: \(pendingOutboxCount).\(lastOutboxNotice)\(skipNotice)"
        #else
        statusIsError = true
        statusMessage = "HealthKit is not available on this platform."
        #endif
    }

    private enum PayloadDeliveryResult {
        case uploaded(ReceiverUploadResult, generation: String)
        case queuedPendingRetry(generation: String)

        var connectionGeneration: String {
            switch self {
            case .uploaded(_, let generation), .queuedPendingRetry(let generation):
                return generation
            }
        }
    }

    private func deliveryStatusMessage(
        _ result: PayloadDeliveryResult,
        uploadedDescription: String,
        queuedDescription: String,
        outboxNotice: String
    ) -> String {
        switch result {
        case .uploaded(let uploadResult, _):
            return "\(uploadedDescription) with HTTP \(uploadResult.statusCode). Pending outbox: \(pendingOutboxCount).\(outboxNotice)"
        case .queuedPendingRetry:
            return "\(queuedDescription) in local outbox for FIFO retry. Local cursor may advance only because the exact payload is durably queued. Pending outbox: \(pendingOutboxCount).\(outboxNotice)"
        }
    }

    private func uploadPayloadsWithOutbox(
        _ payloads: [Data],
        to url: URL,
        cursorCheckpoint: FileOutboxCursorCheckpoint? = nil
    ) async throws -> PayloadDeliveryResult {
        guard !hasPendingPairing, !Task.isCancelled else {
            throw CancellationError()
        }
        let expectedGeneration = settingsStore.receiverSettingsGenerationToken
        try requireCurrentConnectionGeneration(expectedGeneration)
        guard settingsStore.receiverURLString == url.absoluteString else {
            throw CancellationError()
        }
        let uploadBearerToken = try settingsStore.loadBearerToken()
        lastOutboxNotice = ""
        guard !payloads.isEmpty else {
            throw ReceiverClientError.nonHTTPResponse
        }
        guard privateStorageAdmissionReady else {
            throw CompanionPrivateStorageError.sleepManifestUnavailable
        }
        guard let outbox else {
            throw CompanionPrivateStorageError.outboxUnavailable
        }
            let hasPendingOutbox = !(try outbox.pendingItems()).isEmpty
            if !CompanionPayloadNetworkAttemptPolicy.shouldAttemptNetworkForNewPayload(
                hasPendingOutbox: hasPendingOutbox
            ) {
                try enqueuePayloads(
                    payloads,
                    into: outbox,
                    expectedGeneration: expectedGeneration,
                    cursorCheckpoint: cursorCheckpoint
                )
                refreshPendingOutboxCount()
                lastOutboxNotice = " Queued payload sequence behind existing pending outbox item(s) without repeating a foreground network attempt."
                return .queuedPendingRetry(generation: expectedGeneration)
            }

            var lastResult: ReceiverUploadResult?
            for (index, payload) in payloads.enumerated() {
                try requireCurrentConnectionGeneration(expectedGeneration)
                try outbox.requireUploadAdmission()
                do {
                    lastResult = try await receiverClient.upload(
                        payload,
                        to: url,
                        bearerToken: uploadBearerToken
                    )
                    try requireCurrentConnectionGeneration(expectedGeneration)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try requireCurrentConnectionGeneration(expectedGeneration)
                    try enqueuePayloads(
                        Array(payloads[index...]),
                        into: outbox,
                        expectedGeneration: expectedGeneration,
                        cursorCheckpoint: cursorCheckpoint
                    )
                    lastOutboxNotice = " Queued remaining payload sequence after upload failure: \(describe(error))"
                    return .queuedPendingRetry(generation: expectedGeneration)
                }
            }

            try requireCurrentConnectionGeneration(expectedGeneration)
            refreshPendingOutboxCount()
            guard let lastResult else {
                throw ReceiverClientError.nonHTTPResponse
            }
            return .uploaded(lastResult, generation: expectedGeneration)
    }

    private func enqueuePayloads(
        _ payloads: [Data],
        into outbox: FileOutbox,
        expectedGeneration: String,
        cursorCheckpoint: FileOutboxCursorCheckpoint?
    ) throws {
        guard terminalPayloadActionAdmissionIsOpen, !Task.isCancelled else {
            throw CancellationError()
        }
        try requireCurrentConnectionGeneration(expectedGeneration)
        guard let receiverIdentity = settingsStore.receiverBindingID else {
            throw CancellationError()
        }
        let initialItemIDs = Set(try outbox.pendingItems().map(\.id))
        var successfulEnqueueCount = 0
        var enqueueWasAttempted = false
        do {
            guard terminalPayloadActionAdmissionIsOpen, !Task.isCancelled else {
                throw CancellationError()
            }
            try requireCurrentConnectionGeneration(expectedGeneration)
            enqueueWasAttempted = true
            successfulEnqueueCount = try outbox.enqueueSequence(
                payloads,
                receiverIdentity: receiverIdentity,
                cursorCheckpoint: cursorCheckpoint
            ).count
        } catch {
            let finalItemIDs = try? Set(outbox.pendingItems().map(\.id))
            let durableItemCount = DurablePayloadEnqueueAccounting.durableItemCount(
                initialItemIDs: initialItemIDs,
                finalItemIDs: finalItemIDs,
                successfulEnqueueCount: successfulEnqueueCount,
                enqueueWasAttempted: enqueueWasAttempted
            )
            if cursorCheckpoint == nil, durableItemCount == payloads.count {
                refreshPendingOutboxCount()
                if cursorCheckpoint == nil {
                    schedulePendingBackgroundOutboxUploadsIfAllowed()
                }
                return
            }
            if durableItemCount > 0 {
                refreshPendingOutboxCount()
                schedulePendingBackgroundOutboxUploadsIfAllowed()
            }
            throw DurablePayloadEnqueueFailure(
                durableItemCount: durableItemCount,
                underlyingError: error
            )
        }
        refreshPendingOutboxCount()
        if cursorCheckpoint == nil {
            schedulePendingBackgroundOutboxUploadsIfAllowed()
        }
    }

    private func retryPrivateStoreInitialization() throws {
        do {
            try settingsStore.ensureAtomicConnectionRecord()
            connectionStateNeedsRecovery = false
        } catch {
            if ReceiverConnectionRecordRecoveryPolicy.requiresDestructiveRecovery(error) {
                connectionStateNeedsRecovery = true
                hasPendingPrivateStorageRecovery = true
                hasTransientPrivateStorageFailure = false
            } else {
                connectionStateNeedsRecovery = false
                hasTransientPrivateStorageFailure = true
            }
            throw error
        }
        if cursorStore == nil {
            guard let cursorStoreFileURL else {
                cursorStateNeedsRecovery = false
                hasTransientPrivateStorageFailure = true
                throw CompanionPrivateStorageError.cursorStoreUnavailable
            }
            do {
                cursorStore = try FileSyncCursorStore(fileURL: cursorStoreFileURL)
            } catch FileSyncCursorStoreError.invalidData {
                cursorStateNeedsRecovery = true
                hasPendingPrivateStorageRecovery = true
                hasTransientPrivateStorageFailure = false
                throw FileSyncCursorStoreError.invalidData
            } catch {
                cursorStateNeedsRecovery = false
                hasTransientPrivateStorageFailure = true
                throw error
            }
        }
        do {
            guard let cursorStore else {
                throw CompanionPrivateStorageError.cursorStoreUnavailable
            }
            try cursorStore.validateReadableAndWritable()
            cursorStateNeedsRecovery = false
        } catch FileSyncCursorStoreError.invalidData {
            cursorStore = nil
            cursorStateNeedsRecovery = true
            hasPendingPrivateStorageRecovery = true
            hasTransientPrivateStorageFailure = false
            throw FileSyncCursorStoreError.invalidData
        } catch {
            cursorStore = nil
            cursorStateNeedsRecovery = false
            hasTransientPrivateStorageFailure = true
            throw error
        }
        do {
            if sleepManifestStore == nil {
                guard let sleepManifestFileURL else {
                    throw CompanionPrivateStorageError.sleepManifestUnavailable
                }
                sleepManifestStore = try FileSleepSyncManifestStore(
                    fileURL: sleepManifestFileURL
                )
            }
            if outbox == nil {
                guard let outboxDirectoryURL else {
                    throw CompanionPrivateStorageError.outboxUnavailable
                }
                outbox = try FileOutbox(directory: outboxDirectoryURL)
            }
            guard let outbox else {
                throw CompanionPrivateStorageError.outboxUnavailable
            }
            let currentBearerToken = try settingsStore.loadBearerToken()
            let currentBindingID = settingsStore.receiverBindingID
            if let currentBindingID {
                guard Self.receiverSettingsAreComplete(
                    urlString: settingsStore.receiverURLString,
                    bearerToken: currentBearerToken
                ) else {
                    throw KeychainReceiverTokenStoreError.invalidData
                }
                _ = try outbox.migrateLegacyHashedReceiverIdentities(
                    currentReceiverURLString: settingsStore.receiverURLString,
                    currentBearerToken: currentBearerToken,
                    currentBindingID: currentBindingID
                )
            }
            guard ReceiverOutboxAdmissionPolicy.isReady(
                pendingReceiverIdentities: try outbox.pendingItems().map(\.receiverIdentity),
                currentBindingID: currentBindingID,
                hasBearerToken: !currentBearerToken.isEmpty
            ) else {
                throw ReceiverOutboxIdentityError.unknownReceiverIdentity
            }
        } catch {
            outboxIdentityMigrationReady = false
            if ReceiverConnectionRecordRecoveryPolicy.requiresDestructiveRecovery(error) {
                connectionStateNeedsRecovery = true
                hasPendingPrivateStorageRecovery = true
                hasTransientPrivateStorageFailure = false
            } else if error is ReceiverOutboxIdentityError {
                hasPendingPrivateStorageRecovery = true
                hasTransientPrivateStorageFailure = false
            } else {
                hasTransientPrivateStorageFailure = true
            }
            throw error
        }
        outboxIdentityMigrationReady = true
        hasPendingPrivateStorageRecovery = cursorStateNeedsRecovery || connectionStateNeedsRecovery
        hasTransientPrivateStorageFailure = false
    }

    private func matchingPendingSleepOutboxItems(
        _ pendingTransition: SleepSyncPendingTransition,
        in outbox: FileOutbox
    ) throws -> [FileOutboxItem] {
        let items = try outbox.pendingItems()
        return try items.filter { item in
            if item.id == pendingTransition.outboxItemID {
                return true
            }
            guard item.receiverIdentity == pendingTransition.receiverBindingID else {
                return false
            }
            return try Data(contentsOf: item.fileURL) == pendingTransition.payload
        }
    }

    private func reconcilePendingSleepOutboxItem(
        _ pendingTransition: SleepSyncPendingTransition,
        store: SleepSyncManifestStoring,
        outbox: FileOutbox
    ) throws -> SleepSyncPendingTransition {
        guard pendingTransition.outboxItemID == nil else { return pendingTransition }
        guard let item = try matchingPendingSleepOutboxItems(
            pendingTransition,
            in: outbox
        ).first else {
            return pendingTransition
        }
        let reconciled = pendingTransition.assigningOutboxItemID(item.id)
        try store.savePendingTransition(reconciled)
        return reconciled
    }

    private func preparePrivateStorageForUploadAdmission() throws {
        privateStorageAdmissionReady = false
        try retryPrivateStoreInitialization()
        guard let outbox else {
            throw CompanionPrivateStorageError.outboxUnavailable
        }
        guard let sleepManifestStore else {
            throw CompanionPrivateStorageError.sleepManifestUnavailable
        }
        guard let cursorStore else {
            throw CompanionPrivateStorageError.cursorStoreUnavailable
        }
        if sleepSourceKey == nil {
            let installationID = try pairingStateStore.loadOrCreateInstallationID()
            sleepSourceKey = "apple_health.phone.\(installationID.lowercased())"
        }
        guard let sleepSourceKey else {
            throw KeychainReceiverTokenStoreError.unavailable
        }
        try outbox.requireUploadAdmission()
        if let cursorCheckpoint = try outbox.pendingCursorCheckpoint() {
            guard settingsStore.receiverBindingID == cursorCheckpoint.receiverIdentity else {
                throw ReceiverOutboxIdentityError.unknownReceiverIdentity
            }
            try cursorStore.saveCursorValue(
                cursorCheckpoint.cursorValue,
                receiverBindingID: cursorCheckpoint.receiverIdentity,
                sourceKey: cursorCheckpoint.sourceKey,
                cursorKind: cursorCheckpoint.cursorKind
            )
            switch cursorCheckpoint.coreLaneUploadProof {
            case .steps:
                coreLaneUploadProofStore.markUploadedRecords(
                    lane: .steps,
                    receiverBindingID: cursorCheckpoint.receiverIdentity
                )
            case .workouts:
                coreLaneUploadProofStore.markUploadedRecords(
                    lane: .workouts,
                    receiverBindingID: cursorCheckpoint.receiverIdentity
                )
            case nil:
                break
            }
            try outbox.acknowledgeCursorCheckpoint(cursorCheckpoint)
        }

        _ = try sleepManifestStore.loadManifest()
        if let loadedTransition = try sleepManifestStore.loadPendingTransition() {
            let pendingTransition = try reconcilePendingSleepOutboxItem(
                loadedTransition,
                store: sleepManifestStore,
                outbox: outbox
            )
            if let rejectedFloor = pendingTransition.rejectedMinimumResetEpoch {
                try recoverRejectedSleepBaseline(
                    RejectedSleepBaselineOutboxItem(
                        itemID: pendingTransition.outboxItemID ?? "",
                        minimumResetEpoch: rejectedFloor
                    )
                )
                privateStorageAdmissionReady = true
                return
            }
            let pendingBatch = try JSONDecoder().decode(
                HealthBridgeBatchV1.self,
                from: pendingTransition.payload
            )
            if SleepSyncBatchFactory.requiresInstallationSourceMigration(
                manifest: pendingTransition.manifest,
                pendingBatch: pendingBatch,
                expectedSourceKey: sleepSourceKey
            ) {
                _ = try sleepResetEpochStore.reserveEpoch(
                    after: pendingTransition.manifest.baselineResetEpoch ?? 0
                )
                for item in try matchingPendingSleepOutboxItems(
                    pendingTransition,
                    in: outbox
                ) {
                    try outbox.markUploaded(item)
                }
                try sleepManifestStore.resetSynchronizationState()
            }
        }

        if let manifest = try sleepManifestStore.loadManifest(),
           SleepSyncBatchFactory.requiresInstallationSourceMigration(
               manifest: manifest,
               pendingBatch: nil,
               expectedSourceKey: sleepSourceKey
           ) {
            _ = try sleepResetEpochStore.reserveEpoch(
                after: manifest.baselineResetEpoch ?? 0
            )
            try sleepManifestStore.resetSynchronizationState()
        }
        privateStorageAdmissionReady = true
        refreshPendingOutboxCount()
    }

    private func recoverRejectedSleepBaseline(
        _ rejection: RejectedSleepBaselineOutboxItem
    ) throws {
        privateStorageAdmissionReady = false
        if let expectedGeneration = rejection.expectedGeneration {
            try requireCurrentConnectionGeneration(expectedGeneration)
        }
        guard let outbox else {
            throw CompanionPrivateStorageError.outboxUnavailable
        }
        guard let sleepManifestStore else {
            throw CompanionPrivateStorageError.sleepManifestUnavailable
        }
        try SleepBaselineRejectionRecovery.recover(
            itemID: rejection.itemID,
            minimumResetEpoch: rejection.minimumResetEpoch,
            outbox: outbox,
            manifestStore: sleepManifestStore,
            epochStore: sleepResetEpochStore
        )
        privateStorageAdmissionReady = true
        refreshPendingOutboxCount()
    }

    private func uploadPendingOutbox(
        _ outbox: FileOutbox,
        to url: URL,
        bearerToken uploadBearerToken: String,
        expectedGeneration: String
    ) async throws -> FileOutboxFlushSummary {
        try requireCurrentConnectionGeneration(expectedGeneration)
        guard let receiverIdentity = settingsStore.receiverBindingID else {
            throw CancellationError()
        }
        let pendingItems = try outbox.uploadablePendingItems(for: receiverIdentity)
        var attemptedCount = 0
        var uploadedCount = 0
        var failedItemIDs: [String] = []
        var failedDescriptions: [String] = []
        for item in pendingItems {
            try requireCurrentConnectionGeneration(expectedGeneration)
            try outbox.requireUploadAdmission()
            attemptedCount += 1
            do {
                let payload = try Data(contentsOf: item.fileURL)
                _ = try await receiverClient.upload(
                    payload,
                    to: url,
                    bearerToken: uploadBearerToken
                )
                try requireCurrentConnectionGeneration(expectedGeneration)
                try outbox.markUploaded(item)
                uploadedCount += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch ReceiverClientError.sleepBaselineResetEpochConflict(let minimumResetEpoch) {
                try requireCurrentConnectionGeneration(expectedGeneration)
                throw RejectedSleepBaselineOutboxItem(
                    itemID: item.id,
                    minimumResetEpoch: minimumResetEpoch,
                    expectedGeneration: expectedGeneration
                )
            } catch {
                failedItemIDs.append(item.id)
                failedDescriptions.append(describe(error))
                break
            }
        }
        try requireCurrentConnectionGeneration(expectedGeneration)
        return FileOutboxFlushSummary(
            attemptedCount: attemptedCount,
            uploadedCount: uploadedCount,
            failedItemIDs: failedItemIDs,
            failedDescriptions: failedDescriptions
        )
    }

    private static func sleepStorageMayNeedRecovery(
        in store: SleepSyncManifestStoring?
    ) -> Bool {
        guard let store else { return true }
        do {
            _ = try store.loadManifest()
            return try store.loadPendingTransition() != nil
        } catch {
            return true
        }
    }

    private func sleepStorageMayNeedRecovery() -> Bool {
        Self.sleepStorageMayNeedRecovery(in: sleepManifestStore)
    }

    private func trustedPendingOutboxCount() -> Int? {
        guard let outbox else { return nil }
        return try? outbox.pendingItems().count
    }

    private func refreshPendingOutboxCount() {
        guard !taskUIPublicationIsSuppressed else { return }
        do {
            pendingOutboxCount = try outbox?.pendingItems().count ?? 0
        } catch {
            outbox = nil
            privateStorageAdmissionReady = false
            pendingOutboxCount = 0
            hasPendingSleepTransition = sleepStorageMayNeedRecovery()
            hasPendingOutboxDeletion = true
            return
        }
        hasPendingSleepTransition = sleepStorageMayNeedRecovery()
        hasPendingOutboxDeletion = outbox?.clearIntentIsActive ?? true
    }

    private static func receiverSettingsAreComplete(
        urlString: String,
        bearerToken: String
    ) -> Bool {
        URL(string: urlString) != nil
            && !bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func makeDefaultOutbox() -> FileOutbox? {
        guard let directory = defaultOutboxDirectoryURL() else { return nil }
        return try? FileOutbox(directory: directory)
    }

    private static func defaultOutboxDirectoryURL() -> URL? {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return baseURL
            .appendingPathComponent("HealthBridgeCompanion", isDirectory: true)
            .appendingPathComponent("Outbox", isDirectory: true)
    }

    private static func makeDefaultCursorStore() -> FileSyncCursorStore? {
        guard let fileURL = defaultCursorStoreFileURL() else { return nil }
        return try? FileSyncCursorStore(fileURL: fileURL)
    }

    private static func defaultCursorStoreFileURL() -> URL? {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return baseURL
            .appendingPathComponent("HealthBridgeCompanion", isDirectory: true)
            .appendingPathComponent("sync-cursors.json")
    }

    private static func makeDefaultSleepManifestStore() -> FileSleepSyncManifestStore? {
        guard let fileURL = defaultSleepManifestFileURL() else { return nil }
        return try? FileSleepSyncManifestStore(fileURL: fileURL)
    }

    private static func defaultSleepManifestFileURL() -> URL? {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return baseURL
            .appendingPathComponent("HealthBridgeCompanion", isDirectory: true)
            .appendingPathComponent("sleep-sync-manifest-v1.json")
    }

    private static var backgroundDateFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static func backgroundRuntimeSummary() -> String {
        #if os(iOS)
        let refreshStatus: String
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            refreshStatus = "available"
        case .denied:
            refreshStatus = "denied"
        case .restricted:
            refreshStatus = "restricted"
        @unknown default:
            refreshStatus = "unknown"
        }
        return "backgroundRefreshStatus=\(refreshStatus), lowPowerMode=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
        #else
        return "backgroundRefreshStatus=unavailable, lowPowerMode=unavailable"
        #endif
    }

    private static func describeBackgroundSync(_ store: BackgroundSyncSettingsStore) -> String {
        guard store.isEnabled else {
            return "Eventual background sync is off. Foreground sync still works."
        }
        if let lastRun = store.lastRun {
            return "Eventual background sync enabled. \(lastRun.userVisibleSummary)"
        }
        return "Eventual background sync enabled. iOS will decide when the first refresh window runs."
    }

    private static func firstFailureSentence(_ summary: FileOutboxFlushSummary) -> String {
        guard let firstFailure = summary.failedDescriptions.first, !firstFailure.isEmpty else {
            return ""
        }
        return "First failure: \(firstFailure)."
    }

    private func appendActivityLog(_ rawMessage: String, isError: Bool) {
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let sanitized = CompanionPrimaryStatusMessage.sanitized(from: trimmed, isError: isError)
        guard activityLogMessages.last?.hasSuffix(sanitized) != true else { return }
        let entry = "\(Self.activityLogTimeFormatter.string(from: Date())) — \(sanitized)"
        activityLogMessages.append(entry)
        if activityLogMessages.count > 30 {
            activityLogMessages.removeFirst(activityLogMessages.count - 30)
        }
    }

    private static let activityLogTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func backgroundRefreshDiagnosticSummary(
        baseSummary: String,
        uploadedRecordFlags: [String: Bool],
        failures: [String: String?]
    ) -> String {
        let orderedLanes = ["steps", "daily_activity", "workouts", "sleep"]
        let uploadParts = orderedLanes.compactMap { lane -> String? in
            guard let uploadedRecords = uploadedRecordFlags[lane] else { return nil }
            return "\(lane)=\(uploadedRecords ? "records" : "no_records")"
        }
        let failureParts = orderedLanes.compactMap { lane -> String? in
            guard let detail = failures[lane] ?? nil, !detail.isEmpty else { return nil }
            return "\(lane): \(detail)"
        }
        var parts: [String] = []
        if !uploadParts.isEmpty {
            parts.append("uploads: \(uploadParts.joined(separator: ", "))")
        }
        if !failureParts.isEmpty {
            parts.append("failures: \(failureParts.joined(separator: "; "))")
        }
        guard !parts.isEmpty else { return baseSummary }
        return baseSummary + " Diagnostics: " + parts.joined(separator: ". ") + "."
    }

    private static func backgroundLaneFailureDetail(_ message: String) -> String {
        let collapsed = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "unknown error" }
        let redacted = collapsed.replacingOccurrences(of: "Bearer ", with: "Bearer [REDACTED] ")
        if redacted.count <= 180 {
            return redacted
        }
        let end = redacted.index(redacted.startIndex, offsetBy: 180)
        return String(redacted[..<end]) + "..."
    }

    private enum ErrorContext {
        case healthPermission
    }

    private static func userFriendlyErrorMessage(from diagnostic: String, context: ErrorContext) -> String {
        let message = diagnostic.lowercased()
        switch context {
        case .healthPermission:
            if message.contains("healthkit") || message.contains("apple health") {
                return "Apple Health permission could not be opened. Try again."
            }
            return "Permission request failed. Try again."
        }
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private func skippedAdditionalMetricsMessage(_ descriptions: [String]) -> String {
        let visibleDescriptions = Array(descriptions.prefix(3))
        let suffix = descriptions.count > visibleDescriptions.count
            ? " +\(descriptions.count - visibleDescriptions.count) more"
            : ""
        let detail = visibleDescriptions.isEmpty ? "not readable on this iPhone" : visibleDescriptions.joined(separator: ", ")
        return "Some supported metrics were skipped: \(detail)\(suffix). Sync continued."
    }

    private func supportedMetricSkipReason(_ error: Error) -> String {
        let nsError = error as NSError
        let message = error.localizedDescription.lowercased()
        if message.contains("not authorized") || message.contains("denied") || message.contains("authorization") {
            return "not allowed in Apple Health"
        }
        if message.contains("protected") || message.contains("locked") {
            return "iPhone locked"
        }
        if nsError.domain.lowercased().contains("healthkit") {
            return "not readable on this iPhone"
        }
        return "not readable on this iPhone"
    }

    private func describe(_ error: Error) -> String {
        if let receiverError = error as? ReceiverClientError {
            switch receiverError {
            case .emptyBearerToken:
                return "Connection key is missing. | domain=ReceiverClientError | code=missing_key"
            case .nonHTTPResponse:
                return "Health Bridge returned a non-HTTP response. | domain=ReceiverClientError | code=non_http_response"
            case .sleepBaselineResetEpochConflict(let minimumResetEpoch):
                return "Health Bridge requires a Sleep reset epoch above \(minimumResetEpoch). | domain=ReceiverClientError | code=sleep_epoch_conflict"
            case .unsuccessfulStatusCode(let statusCode, _):
                if statusCode == 401 {
                    return "Health Bridge rejected the saved connection key. Reconnect from a fresh setup link. | domain=ReceiverClientError | code=http_401"
                }
                if statusCode == 403 {
                    return "Health Bridge refused this saved connection. Reconnect from setup link or check server access. | domain=ReceiverClientError | code=http_403"
                }
                return "Health Bridge returned HTTP \(statusCode). | domain=ReceiverClientError | code=http_\(statusCode)"
            }
        }
        if let outboxError = error as? ReceiverOutboxIdentityError {
            switch outboxError {
            case .missingReceiverIdentity:
                return "Reconnect before sending queued uploads. | domain=ReceiverOutboxIdentityError | code=missing_receiver_identity"
            case .unknownReceiverIdentity:
                return "Queued uploads cannot be verified for this server. Reset private sync state before reconnecting. | domain=ReceiverOutboxIdentityError | code=unknown_receiver_identity"
            case .oldestItemBelongsToDifferentReceiver:
                return "Queued uploads belong to a different server. Reset private sync state before reconnecting. | domain=ReceiverOutboxIdentityError | code=different_receiver_identity"
            case .receiverTransitionRequiresEmptyOutbox:
                return "Send queued uploads or reset private sync state before disconnecting or changing the server. | domain=ReceiverOutboxIdentityError | code=transition_requires_empty_outbox"
            }
        }
        if let authorizationError = error as? HealthKitAuthorizationError {
            switch authorizationError {
            case .healthDataUnavailable:
                return "Apple Health data is not available on this device. | domain=HealthKitAuthorizationError | code=health_data_unavailable"
            case .emptyReadTypeSet:
                return "No supported Apple Health data types are available to request on this device. | domain=HealthKitAuthorizationError | code=empty_read_type_set"
            }
        }
        if let stepError = error as? HealthKitStepCountReaderError {
            switch stepError {
            case .healthDataUnavailable:
                return "Apple Health Step Count data is not available on this device. | domain=HealthKitStepCountReaderError | code=health_data_unavailable"
            case .stepCountTypeUnavailable:
                return "Apple Health Step Count is not available on this device. | domain=HealthKitStepCountReaderError | code=step_count_type_unavailable"
            case .invalidWindow:
                return "Step Count sync range was invalid. | domain=HealthKitStepCountReaderError | code=invalid_window"
            case .anchorUnavailable:
                return "Step Count sync cursor could not be read. | domain=HealthKitStepCountReaderError | code=anchor_unavailable"
            }
        }
        if let workoutError = error as? HealthKitWorkoutReaderError {
            switch workoutError {
            case .healthDataUnavailable:
                return "Apple Health Workout data is not available on this device. | domain=HealthKitWorkoutReaderError | code=health_data_unavailable"
            case .invalidWindow:
                return "Workout sync range was invalid. | domain=HealthKitWorkoutReaderError | code=invalid_window"
            case .anchorUnavailable:
                return "Workout sync cursor could not be read. | domain=HealthKitWorkoutReaderError | code=anchor_unavailable"
            }
        }
        if let sleepError = error as? HealthKitSleepReaderError {
            switch sleepError {
            case .healthDataUnavailable:
                return "Apple Health Sleep data is not available on this device. | domain=HealthKitSleepReaderError | code=health_data_unavailable"
            case .sleepAnalysisTypeUnavailable:
                return "Apple Health Sleep Analysis is not available on this device. | domain=HealthKitSleepReaderError | code=sleep_type_unavailable"
            case .invalidWindow:
                return "Sleep sync range was invalid. | domain=HealthKitSleepReaderError | code=invalid_window"
            case .anchorUnavailable:
                return "Sleep sync cursor could not be read. | domain=HealthKitSleepReaderError | code=anchor_unavailable"
            }
        }
        if let quantityError = error as? HealthKitGenericQuantityReaderError {
            switch quantityError {
            case .healthDataUnavailable:
                return "Apple Health data is not available on this device. | domain=HealthKitGenericQuantityReaderError | code=health_data_unavailable"
            case .invalidWindow:
                return "Health data sync range was invalid. | domain=HealthKitGenericQuantityReaderError | code=invalid_window"
            case .emptyReadableTypeSet:
                return "No supported Apple Health data types are available for this sync. | domain=HealthKitGenericQuantityReaderError | code=empty_read_type_set"
            case .anchorUnavailable:
                return "Apple Health did not return an anchored quantity cursor. | domain=HealthKitGenericQuantityReaderError | code=anchor_unavailable"
            }
        }
        let nsError = error as NSError
        var details = [error.localizedDescription]
        details.append("domain=\(nsError.domain)")
        details.append("code=\(nsError.code)")
        if let failureReason = nsError.localizedFailureReason, !failureReason.isEmpty {
            details.append("reason=\(failureReason)")
        }
        if let recoverySuggestion = nsError.localizedRecoverySuggestion, !recoverySuggestion.isEmpty {
            details.append("suggestion=\(recoverySuggestion)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            details.append("underlying=\(underlying.domain)/\(underlying.code): \(underlying.localizedDescription)")
        }
        return details.joined(separator: " | ")
    }
}
