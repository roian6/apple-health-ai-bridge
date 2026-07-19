#if os(iOS)
import Foundation
import UIKit

private final class BackgroundCompletionHandlerBox: @unchecked Sendable {
    private let completionHandler: () -> Void

    init(_ completionHandler: @escaping () -> Void) {
        self.completionHandler = completionHandler
    }

    func call() {
        completionHandler()
    }
}

struct BackgroundUploadCancellationResult: Equatable, Sendable {
    let cancelledCount: Int
    let fullyFinalized: Bool
}

final class BackgroundURLSessionOutboxUploader: NSObject, @unchecked Sendable, URLSessionTaskDelegate, URLSessionDataDelegate {
    static let shared = BackgroundURLSessionOutboxUploader()
    static let sessionIdentifier = HealthBridgeAppIdentity.backgroundUploadSessionIdentifier
    static let legacySessionIdentifiers = HealthBridgeAppIdentity.legacyBackgroundUploadSessionIdentifiers
    static let cancellationCompletionTimeout: TimeInterval = 5
    static let maximumResponseBodyBytes = 65_536

    private let stateLock = NSLock()
    private let cancellationBarrier = AsyncCompletionBarrier<Int>()
    private let legacyCancellationBarrier = AsyncCompletionBarrier<Int>()
    private let eventFinalizationCoordinator = BackgroundEventFinalizationCoordinator<Int>()
    private let legacyEventFinalizationCoordinator = BackgroundEventFinalizationCoordinator<Int>()
    private var outboxDirectory: URL?
    private var responseBodiesByTaskID: [Int: Data] = [:]
    private lazy var taskOwnershipStore: FileBackgroundUploadTaskOwnershipStore? = {
        guard let fileURL = Self.defaultTaskOwnershipFileURL() else { return nil }
        return try? FileBackgroundUploadTaskOwnershipStore(fileURL: fileURL)
    }()
    @MainActor private var cancellationFlight: (
        id: UUID,
        task: Task<BackgroundUploadCancellationResult, Never>
    )?
    @MainActor private var pendingCancellationFinalizationTaskIDs: Set<Int> = []
    @MainActor private var legacyCancellationFlight: (
        id: UUID,
        task: Task<BackgroundUploadCancellationResult, Never>
    )?
    @MainActor private var pendingLegacyCancellationFinalizationTaskIDs: Set<Int> = []

    private let sessionDelegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.example.HealthBridgeCompanion.background-upload-delegate"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: sessionDelegateQueue
        )
    }()

    private lazy var legacyCancellationSession: URLSession = {
        guard let identifier = Self.legacySessionIdentifiers.first else {
            preconditionFailure("A legacy background upload identifier is required")
        }
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: sessionDelegateQueue
        )
    }()

    @MainActor
    func schedulePendingUploads(
        outbox: FileOutbox,
        receiverURL: URL,
        bearerToken: String,
        receiverGeneration: String,
        receiverBindingID: String,
        isUploadAllowed: @MainActor () -> Bool = { true }
    ) async throws -> Int {
        rememberOutboxDirectory(outbox.directoryURL)
        await recoverPersistedTaskCompletions()
        guard let taskOwnershipStore,
              (try? taskOwnershipStore.records().isEmpty) == true else {
            return 0
        }
        guard cancellationFlight == nil,
              legacyCancellationFlight == nil,
              pendingCancellationFinalizationTaskIDs.isEmpty,
              pendingLegacyCancellationFinalizationTaskIDs.isEmpty,
              eventFinalizationCoordinator.pendingIDsSnapshot().isEmpty,
              legacyEventFinalizationCoordinator.pendingIDsSnapshot().isEmpty,
              await currentLegacyTaskIDs().isEmpty else {
            return 0
        }
        guard cancellationFlight == nil,
              legacyCancellationFlight == nil,
              pendingCancellationFinalizationTaskIDs.isEmpty,
              pendingLegacyCancellationFinalizationTaskIDs.isEmpty,
              eventFinalizationCoordinator.stateSnapshot().isIdle,
              legacyEventFinalizationCoordinator.stateSnapshot().isIdle else {
            return 0
        }
        let pendingItems = try outbox.uploadablePendingItems(for: receiverBindingID)
        guard !pendingItems.isEmpty else { return 0 }
        guard let scheduledItemIDs = await currentScheduledItemIDs() else {
            return 0
        }
        guard cancellationFlight == nil,
              legacyCancellationFlight == nil,
              pendingCancellationFinalizationTaskIDs.isEmpty,
              pendingLegacyCancellationFinalizationTaskIDs.isEmpty,
              eventFinalizationCoordinator.stateSnapshot().isIdle,
              legacyEventFinalizationCoordinator.stateSnapshot().isIdle else {
            return 0
        }
        guard isUploadAllowed() else { return 0 }
        let plans = try BackgroundOutboxUploadPlanner.plan(
            pendingItems: pendingItems,
            receiverURL: receiverURL,
            bearerToken: bearerToken,
            receiverGeneration: receiverGeneration,
            receiverBindingID: receiverBindingID,
            alreadyScheduledItemIDs: scheduledItemIDs
        )

        for plan in plans {
            let task = session.uploadTask(with: plan.request, fromFile: plan.fileURL)
            task.taskDescription = plan.taskDescription
            do {
                try taskOwnershipStore.begin(
                    BackgroundUploadTaskOwnership(
                        taskID: task.taskIdentifier,
                        itemID: plan.itemID,
                        receiverGeneration: plan.receiverGeneration,
                        receiverBindingID: plan.receiverBindingID
                    )
                )
            } catch {
                task.cancel()
                throw error
            }
            eventFinalizationCoordinator.begin(task.taskIdentifier)
            task.resume()
        }
        return plans.count
    }

    @MainActor
    func cancelPendingUploads() async -> BackgroundUploadCancellationResult {
        if let cancellationFlight {
            return await cancellationFlight.task.value
        }
        let flightID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return BackgroundUploadCancellationResult(
                    cancelledCount: 0,
                    fullyFinalized: false
                )
            }
            return await self.performPendingUploadCancellation()
        }
        cancellationFlight = (flightID, task)
        let result = await task.value
        if cancellationFlight?.id == flightID {
            cancellationFlight = nil
        }
        return result
    }

    @MainActor
    private func performPendingUploadCancellation() async -> BackgroundUploadCancellationResult {
        await recoverPersistedTaskCompletions()
        guard let ownedTaskIDs = currentOwnedTaskIDs() else {
            return BackgroundUploadCancellationResult(
                cancelledCount: 0,
                fullyFinalized: false
            )
        }
        pendingCancellationFinalizationTaskIDs.formUnion(ownedTaskIDs)
        let sessionTasks = await tasks(
            in: session,
            coordinator: eventFinalizationCoordinator
        )
        let enumeratedTaskIDs = Set(sessionTasks.map(\.taskIdentifier))
        pendingCancellationFinalizationTaskIDs.formUnion(enumeratedTaskIDs)
        pendingCancellationFinalizationTaskIDs.formUnion(
            eventFinalizationCoordinator.stateSnapshot().pendingIDs
        )
        await cancellationBarrier.retainCompletions(
            for: pendingCancellationFinalizationTaskIDs
        )
        sessionTasks.forEach { $0.cancel() }
        await drainSessionDelegateQueue()

        let reconciledTasks = await tasks(
            in: session,
            coordinator: eventFinalizationCoordinator
        )
        let reconciledTaskIDs = Set(reconciledTasks.map(\.taskIdentifier))
        pendingCancellationFinalizationTaskIDs.formUnion(reconciledTaskIDs)
        pendingCancellationFinalizationTaskIDs.formUnion(
            eventFinalizationCoordinator.stateSnapshot().pendingIDs
        )
        await cancellationBarrier.retainCompletions(
            for: pendingCancellationFinalizationTaskIDs
        )
        reconciledTasks.forEach { $0.cancel() }
        await drainSessionDelegateQueue()

        let taskIDsRequiringFinalization = pendingCancellationFinalizationTaskIDs
        let barrierFinalized: Bool
        if taskIDsRequiringFinalization.isEmpty {
            barrierFinalized = true
        } else {
            barrierFinalized = await cancellationBarrier.wait(
                for: taskIDsRequiringFinalization,
                timeout: Self.cancellationCompletionTimeout
            )
        }
        let eventCycleFinalized = await waitForEventFinalizationIdle(
            eventFinalizationCoordinator,
            timeout: Self.cancellationCompletionTimeout
        )
        let preFinalState = eventFinalizationCoordinator.stateSnapshot()
        await drainSessionDelegateQueue()
        let finalTasks = await tasks(
            in: session,
            coordinator: eventFinalizationCoordinator
        )
        finalTasks.forEach { $0.cancel() }
        await drainSessionDelegateQueue()
        let finalTaskIDs = Set(finalTasks.map(\.taskIdentifier))
        let finalState = eventFinalizationCoordinator.stateSnapshot()
        let finalPendingIDs = finalState.pendingIDs
            .union(finalTaskIDs)
            .union(pendingCancellationFinalizationTaskIDs)
        await cancellationBarrier.retainCompletions(for: finalPendingIDs)

        let postRetentionTasks = await tasks(
            in: session,
            coordinator: eventFinalizationCoordinator
        )
        postRetentionTasks.forEach { $0.cancel() }
        await drainSessionDelegateQueue()
        let postRetentionTaskIDs = Set(postRetentionTasks.map(\.taskIdentifier))
        let postRetentionState = eventFinalizationCoordinator.stateSnapshot()
        let finalOwnedTaskIDs = currentOwnedTaskIDs()
        let ownershipLedgerIsEmpty = finalOwnedTaskIDs?.isEmpty == true
        let settledPendingIDs = postRetentionState.pendingIDs
            .union(postRetentionTaskIDs)
            .union(finalPendingIDs)
            .union(finalOwnedTaskIDs ?? taskIDsRequiringFinalization)
        let introducedAfterWait = !settledPendingIDs.isSubset(
            of: taskIDsRequiringFinalization
        )
        let fullyFinalized = BackgroundUploadCancellationCertificationPolicy
            .canCertifyFullyFinalized(
                barrierFinalized: barrierFinalized,
                eventCycleFinalized: eventCycleFinalized,
                finalTaskSetIsEmpty: finalTasks.isEmpty
                    && postRetentionTasks.isEmpty
                    && ownershipLedgerIsEmpty,
                finalCoordinatorIsIdle: postRetentionState.isIdle,
                coordinatorGenerationIsStable:
                    preFinalState.generation == finalState.generation
                    && finalState.generation == postRetentionState.generation,
                introducedTaskAfterWait: introducedAfterWait
            )
        if fullyFinalized {
            pendingCancellationFinalizationTaskIDs.removeAll()
        } else {
            pendingCancellationFinalizationTaskIDs.formUnion(settledPendingIDs)
        }
        return BackgroundUploadCancellationResult(
            cancelledCount: enumeratedTaskIDs
                .union(reconciledTaskIDs)
                .union(finalTaskIDs)
                .union(postRetentionTaskIDs)
                .union(ownedTaskIDs)
                .count,
            fullyFinalized: fullyFinalized
        )
    }

    @MainActor
    func cancelInheritedLegacyUploads() async -> BackgroundUploadCancellationResult {
        if let legacyCancellationFlight {
            return await legacyCancellationFlight.task.value
        }
        let flightID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return BackgroundUploadCancellationResult(
                    cancelledCount: 0,
                    fullyFinalized: false
                )
            }
            return await self.performInheritedLegacyUploadCancellation()
        }
        legacyCancellationFlight = (flightID, task)
        let result = await task.value
        if legacyCancellationFlight?.id == flightID {
            legacyCancellationFlight = nil
        }
        return result
    }

    @MainActor
    private func performInheritedLegacyUploadCancellation() async
        -> BackgroundUploadCancellationResult
    {
        let inheritedTasks = await tasks(
            in: legacyCancellationSession,
            coordinator: legacyEventFinalizationCoordinator
        )
        let enumeratedTaskIDs = Set(inheritedTasks.map(\.taskIdentifier))
        pendingLegacyCancellationFinalizationTaskIDs.formUnion(enumeratedTaskIDs)
        pendingLegacyCancellationFinalizationTaskIDs.formUnion(
            legacyEventFinalizationCoordinator.stateSnapshot().pendingIDs
        )
        await legacyCancellationBarrier.retainCompletions(
            for: pendingLegacyCancellationFinalizationTaskIDs
        )
        inheritedTasks.forEach { $0.cancel() }
        await drainSessionDelegateQueue()

        let reconciledTasks = await tasks(
            in: legacyCancellationSession,
            coordinator: legacyEventFinalizationCoordinator
        )
        let reconciledTaskIDs = Set(reconciledTasks.map(\.taskIdentifier))
        pendingLegacyCancellationFinalizationTaskIDs.formUnion(reconciledTaskIDs)
        pendingLegacyCancellationFinalizationTaskIDs.formUnion(
            legacyEventFinalizationCoordinator.stateSnapshot().pendingIDs
        )
        await legacyCancellationBarrier.retainCompletions(
            for: pendingLegacyCancellationFinalizationTaskIDs
        )
        reconciledTasks.forEach { $0.cancel() }
        await drainSessionDelegateQueue()

        let taskIDsRequiringFinalization = pendingLegacyCancellationFinalizationTaskIDs
        let barrierFinalized: Bool
        if taskIDsRequiringFinalization.isEmpty {
            barrierFinalized = true
        } else {
            barrierFinalized = await legacyCancellationBarrier.wait(
                for: taskIDsRequiringFinalization,
                timeout: Self.cancellationCompletionTimeout
            )
        }
        let eventCycleFinalized = await waitForEventFinalizationIdle(
            legacyEventFinalizationCoordinator,
            timeout: Self.cancellationCompletionTimeout
        )
        let preFinalState = legacyEventFinalizationCoordinator.stateSnapshot()
        await drainSessionDelegateQueue()
        let finalTasks = await tasks(
            in: legacyCancellationSession,
            coordinator: legacyEventFinalizationCoordinator
        )
        finalTasks.forEach { $0.cancel() }
        await drainSessionDelegateQueue()
        let finalTaskIDs = Set(finalTasks.map(\.taskIdentifier))
        let finalState = legacyEventFinalizationCoordinator.stateSnapshot()
        let finalPendingIDs = finalState.pendingIDs
            .union(finalTaskIDs)
            .union(pendingLegacyCancellationFinalizationTaskIDs)
        await legacyCancellationBarrier.retainCompletions(for: finalPendingIDs)

        let postRetentionTasks = await tasks(
            in: legacyCancellationSession,
            coordinator: legacyEventFinalizationCoordinator
        )
        postRetentionTasks.forEach { $0.cancel() }
        await drainSessionDelegateQueue()
        let postRetentionTaskIDs = Set(postRetentionTasks.map(\.taskIdentifier))
        let postRetentionState = legacyEventFinalizationCoordinator.stateSnapshot()
        let settledPendingIDs = postRetentionState.pendingIDs
            .union(postRetentionTaskIDs)
            .union(finalPendingIDs)
        let introducedAfterWait = !settledPendingIDs.isSubset(
            of: taskIDsRequiringFinalization
        )
        let fullyFinalized = BackgroundUploadCancellationCertificationPolicy
            .canCertifyFullyFinalized(
                barrierFinalized: barrierFinalized,
                eventCycleFinalized: eventCycleFinalized,
                finalTaskSetIsEmpty: finalTasks.isEmpty && postRetentionTasks.isEmpty,
                finalCoordinatorIsIdle: postRetentionState.isIdle,
                coordinatorGenerationIsStable:
                    preFinalState.generation == finalState.generation
                    && finalState.generation == postRetentionState.generation,
                introducedTaskAfterWait: introducedAfterWait
            )
        if fullyFinalized {
            pendingLegacyCancellationFinalizationTaskIDs.removeAll()
        } else {
            pendingLegacyCancellationFinalizationTaskIDs.formUnion(settledPendingIDs)
        }
        return BackgroundUploadCancellationResult(
            cancelledCount: enumeratedTaskIDs
                .union(reconciledTaskIDs)
                .union(finalTaskIDs)
                .union(postRetentionTaskIDs)
                .count,
            fullyFinalized: fullyFinalized
        )
    }

    func setBackgroundCompletionHandler(
        forSessionIdentifier identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == Self.sessionIdentifier {
            Self.dispatchCompletionHandler(
                eventFinalizationCoordinator.setCompletionHandler(completionHandler)
            )
            _ = session
            return
        }
        if Self.legacySessionIdentifiers.contains(identifier) {
            Self.dispatchCompletionHandler(
                legacyEventFinalizationCoordinator.setCompletionHandler(completionHandler)
            )
            _ = legacyCancellationSession
            Task { @MainActor [weak self] in
                _ = await self?.cancelInheritedLegacyUploads()
            }
            return
        }
        completionHandler()
    }

    private func currentScheduledItemIDs() async -> Set<String>? {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                tasks.forEach { task in
                    self.eventFinalizationCoordinator.begin(task.taskIdentifier)
                }
                let parsedItemIDs = tasks.compactMap { task in
                    BackgroundOutboxTaskDescriptor.itemID(fromTaskDescription: task.taskDescription)
                }
                guard parsedItemIDs.count == tasks.count else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Set(parsedItemIDs))
            }
        }
    }

    private func currentLegacyTaskIDs() async -> Set<Int> {
        await withCheckedContinuation { continuation in
            legacyCancellationSession.getAllTasks { tasks in
                tasks.forEach { task in
                    self.legacyEventFinalizationCoordinator.begin(task.taskIdentifier)
                }
                continuation.resume(returning: Set(tasks.map(\.taskIdentifier)))
            }
        }
    }

    @MainActor
    func hasPendingUploadTasks() async -> Bool {
        await recoverPersistedTaskCompletions()
        guard let ownedTaskIDs = currentOwnedTaskIDs() else { return true }
        if !ownedTaskIDs.isEmpty { return true }
        for _ in 0 ..< 3 {
            let currentStateBefore = eventFinalizationCoordinator.stateSnapshot()
            let legacyStateBefore = legacyEventFinalizationCoordinator.stateSnapshot()
            guard let currentItemIDs = await currentScheduledItemIDs() else {
                return true
            }
            let legacyTaskIDs = await currentLegacyTaskIDs()
            let currentStateAfter = eventFinalizationCoordinator.stateSnapshot()
            let legacyStateAfter = legacyEventFinalizationCoordinator.stateSnapshot()
            if !pendingCancellationFinalizationTaskIDs.isEmpty
                || !pendingLegacyCancellationFinalizationTaskIDs.isEmpty
                || !currentItemIDs.isEmpty
                || !legacyTaskIDs.isEmpty
                || !currentStateAfter.isIdle
                || !legacyStateAfter.isIdle
            {
                return true
            }
            if currentStateBefore.generation == currentStateAfter.generation,
               legacyStateBefore.generation == legacyStateAfter.generation {
                return false
            }
        }
        return true
    }

    private func tasks(
        in session: URLSession,
        coordinator: BackgroundEventFinalizationCoordinator<Int>
    ) async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                tasks.forEach { task in
                    coordinator.begin(task.taskIdentifier)
                }
                continuation.resume(returning: tasks)
            }
        }
    }

    private func waitForEventFinalizationIdle(
        _ coordinator: BackgroundEventFinalizationCoordinator<Int>,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !coordinator.stateSnapshot().isIdle {
            if Task.isCancelled || Date() >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return true
    }

    private func drainSessionDelegateQueue() async {
        await withCheckedContinuation { continuation in
            sessionDelegateQueue.addOperation {
                continuation.resume()
            }
        }
    }

    private func rememberOutboxDirectory(_ directory: URL) {
        stateLock.lock()
        outboxDirectory = directory
        stateLock.unlock()
    }

    private func currentOutboxDirectory() -> URL? {
        stateLock.lock()
        let directory = outboxDirectory
        stateLock.unlock()
        return directory ?? Self.defaultOutboxDirectory()
    }

    private func currentOwnedTaskRecord(
        for taskID: Int
    ) -> BackgroundUploadTaskOwnership? {
        guard let taskOwnershipStore else { return nil }
        return try? taskOwnershipStore.record(forTaskID: taskID)
    }

    private func currentOwnedTaskIDs() -> Set<Int>? {
        guard let taskOwnershipStore,
              let records = try? taskOwnershipStore.records() else {
            return nil
        }
        return Set(records.map(\.taskID))
    }

    @MainActor
    private func recoverPersistedTaskCompletions() async {
        guard let taskOwnershipStore,
              let records = try? taskOwnershipStore.records() else {
            return
        }
        for record in records {
            guard let completion = record.completion else { continue }
            let descriptor = (
                receiverGeneration: record.receiverGeneration,
                receiverBindingID: record.receiverBindingID,
                itemID: record.itemID
            )
            guard finishCompletedUpload(
                descriptor: descriptor,
                completion: completion
            ) else {
                continue
            }
            await cancellationBarrier.complete(record.taskID)
            do {
                try taskOwnershipStore.remove(taskID: record.taskID)
            } catch {
                continue
            }
            Self.dispatchCompletionHandler(
                eventFinalizationCoordinator.complete(record.taskID)
            )
        }
    }

    private static func dispatchCompletionHandler(_ completionHandler: (() -> Void)?) {
        guard let completionHandler else { return }
        let box = BackgroundCompletionHandlerBox(completionHandler)
        DispatchQueue.main.async {
            box.call()
        }
    }

    private static func defaultOutboxDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HealthBridgeCompanion", isDirectory: true)
            .appendingPathComponent("Outbox", isDirectory: true)
    }

    private static func defaultTaskOwnershipFileURL() -> URL? {
        defaultOutboxDirectory()?
            .deletingLastPathComponent()
            .appendingPathComponent("background-upload-task-ownership-v1.json")
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = response.url ?? task.originalRequest?.url,
              let redirectedURL = request.url,
              ReceiverRedirectPolicy.allowsRedirect(
                  from: originalURL,
                  to: redirectedURL
              )
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        appendResponseData(data, for: dataTask.taskIdentifier)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskID = task.taskIdentifier
        let responseBody = takeResponseBody(for: taskID)
        if let identifier = session.configuration.identifier,
           Self.legacySessionIdentifiers.contains(identifier) {
            legacyEventFinalizationCoordinator.begin(taskID)
            let completionBarrier = legacyCancellationBarrier
            let finalizationCoordinator = legacyEventFinalizationCoordinator
            Task {
                await completionBarrier.complete(taskID)
                Self.dispatchCompletionHandler(finalizationCoordinator.complete(taskID))
            }
            return
        }

        eventFinalizationCoordinator.begin(taskID)
        let completionBarrier = cancellationBarrier
        let finalizationCoordinator = eventFinalizationCoordinator
        let ownershipRecord = currentOwnedTaskRecord(for: taskID)
        let descriptor: (
            receiverGeneration: String,
            receiverBindingID: String,
            itemID: String
        )?
        if let parsed = BackgroundOutboxTaskDescriptor.descriptor(
            fromTaskDescription: task.taskDescription
        ) {
            descriptor = parsed
        } else if let ownershipRecord {
            descriptor = (
                ownershipRecord.receiverGeneration,
                ownershipRecord.receiverBindingID,
                ownershipRecord.itemID
            )
        } else {
            descriptor = nil
        }
        guard let descriptor else { return }
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        let minimumResetEpoch = BackgroundOutboxUploadCompletionPolicy
            .sleepBaselineConflictMinimumResetEpoch(
                error: error,
                httpStatusCode: statusCode,
                responseBody: responseBody
            )
        let completion = BackgroundUploadTaskCompletion(
            statusCode: statusCode,
            hadTransportError: error != nil,
            sleepMinimumResetEpoch: minimumResetEpoch
        )
        let completionMetadataPersisted: Bool
        if ownershipRecord == nil {
            completionMetadataPersisted = true
        } else if let taskOwnershipStore {
            do {
                try taskOwnershipStore.recordCompletion(completion, forTaskID: taskID)
                completionMetadataPersisted = true
            } catch {
                completionMetadataPersisted = false
            }
        } else {
            completionMetadataPersisted = false
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let durablyReconciled = self.finishCompletedUpload(
                descriptor: descriptor,
                completion: completion
            )
            guard durablyReconciled, completionMetadataPersisted else { return }
            await completionBarrier.complete(taskID)
            var ownershipFinalized = ownershipRecord == nil
            if ownershipRecord != nil,
               let taskOwnershipStore = self.taskOwnershipStore {
                do {
                    try taskOwnershipStore.remove(taskID: taskID)
                    ownershipFinalized = true
                } catch {
                    ownershipFinalized = false
                }
            }
            guard ownershipFinalized else { return }
            Self.dispatchCompletionHandler(finalizationCoordinator.complete(taskID))
        }
    }

    @MainActor
    private func finishCompletedUpload(
        descriptor: (receiverGeneration: String, receiverBindingID: String, itemID: String),
        completion: BackgroundUploadTaskCompletion
    ) -> Bool {
        guard let outboxDirectory = currentOutboxDirectory() else {
            return false
        }
        do {
            let outbox = try FileOutbox(directory: outboxDirectory)
            let settingsStore = ReceiverSettingsStore()
            guard descriptor.receiverGeneration == settingsStore.receiverSettingsGenerationToken,
                  descriptor.receiverBindingID == settingsStore.receiverBindingID else {
                return true
            }

            if let minimumResetEpoch = completion.sleepMinimumResetEpoch,
               !completion.hadTransportError,
               completion.statusCode == 409 {
                let manifestStore = try FileSleepSyncManifestStore(
                    fileURL: outboxDirectory
                        .deletingLastPathComponent()
                        .appendingPathComponent("sleep-sync-manifest-v1.json")
                )
                try SleepBaselineRejectionRecovery.recover(
                    itemID: descriptor.itemID,
                    minimumResetEpoch: minimumResetEpoch,
                    outbox: outbox,
                    manifestStore: manifestStore,
                    epochStore: SleepResetEpochStore()
                )
                return true
            }

            guard !completion.hadTransportError,
                  let statusCode = completion.statusCode,
                  (200 ..< 300).contains(statusCode) else {
                return true
            }
            if let item = try outbox.pendingItem(id: descriptor.itemID),
               item.receiverIdentity == descriptor.receiverBindingID {
                try outbox.markUploaded(item)
            }
            return true
        } catch {
            // Keep ownership durable until a later launch can replay reconciliation.
            return false
        }
    }

    private func appendResponseData(_ data: Data, for taskID: Int) {
        stateLock.lock()
        var body = responseBodiesByTaskID[taskID] ?? Data()
        let remainingCapacity = max(0, Self.maximumResponseBodyBytes - body.count)
        if remainingCapacity > 0 {
            body.append(data.prefix(remainingCapacity))
            responseBodiesByTaskID[taskID] = body
        }
        stateLock.unlock()
    }

    private func takeResponseBody(for taskID: Int) -> Data? {
        stateLock.lock()
        let body = responseBodiesByTaskID.removeValue(forKey: taskID)
        stateLock.unlock()
        return body
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let identifier = session.configuration.identifier,
           Self.legacySessionIdentifiers.contains(identifier) {
            Self.dispatchCompletionHandler(
                legacyEventFinalizationCoordinator.markEventsFinished()
            )
            return
        }
        Self.dispatchCompletionHandler(
            eventFinalizationCoordinator.markEventsFinished()
        )
    }
}

final class HealthBridgeBackgroundURLSessionAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundURLSessionOutboxUploader.shared.setBackgroundCompletionHandler(
            forSessionIdentifier: identifier,
            completionHandler: completionHandler
        )
    }
}
#endif
