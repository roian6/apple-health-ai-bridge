import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

public actor AsyncExclusiveAccessGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isHeld = false
    private var waiters: [Waiter] = []

    public init() {}

    public func acquire() async throws {
        try Task.checkCancellation()
        if !isHeld {
            isHeld = true
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    public func release() {
        precondition(isHeld, "Cannot release an exclusive access gate that is not held.")
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        let next = waiters.removeFirst()
        next.continuation.resume()
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

@MainActor
public final class PairingRequestEpoch {
    private var value: UInt64 = 0

    public init() {}

    public func capture() -> UInt64 {
        value
    }

    public func invalidate() {
        value &+= 1
    }

    public func isCurrent(_ capturedValue: UInt64) -> Bool {
        capturedValue == value
    }
}

@MainActor
public final class TerminalRequestCoordinator {
    private let gate: AsyncExclusiveAccessGate
    public private(set) var isActive = false

    public init(gate: AsyncExclusiveAccessGate = AsyncExclusiveAccessGate()) {
        self.gate = gate
    }

    public func perform<Result>(
        canStartAfterAcquire: @MainActor () -> Bool = { true },
        operation: @MainActor () async throws -> Result
    ) async throws -> Result {
        guard !isActive else {
            throw CancellationError()
        }
        isActive = true
        do {
            try await gate.acquire()
        } catch {
            isActive = false
            throw error
        }
        guard canStartAfterAcquire() else {
            await gate.release()
            isActive = false
            throw CancellationError()
        }
        let result: Result
        do {
            result = try await operation()
        } catch {
            await gate.release()
            isActive = false
            throw error
        }
        await gate.release()
        isActive = false
        return result
    }
}

public actor AsyncCompletionBarrier<ID: Hashable & Sendable> {
    private struct Waiter {
        var remainingIDs: Set<ID>
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var completedIDs: Set<ID> = []
    private var waiters: [UUID: Waiter] = [:]

    public init() {}

    public func wait(for ids: Set<ID>) async {
        _ = await waitUntilCompleted(for: ids, timeout: nil)
    }

    public func wait(for ids: Set<ID>, timeout: TimeInterval) async -> Bool {
        await waitUntilCompleted(for: ids, timeout: timeout)
    }

    private func waitUntilCompleted(
        for ids: Set<ID>,
        timeout: TimeInterval?
    ) async -> Bool {
        guard !ids.isEmpty else { return true }
        let remainingIDs = ids.subtracting(completedIDs)
        if remainingIDs.isEmpty {
            return true
        }
        if let timeout, timeout <= 0 {
            return false
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[waiterID] = Waiter(
                    remainingIDs: remainingIDs,
                    continuation: continuation
                )
                if let timeout {
                    let nanoseconds = UInt64(min(timeout, 86_400) * 1_000_000_000)
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: nanoseconds)
                        await self?.expireWaiter(waiterID)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func expireWaiter(_ waiterID: UUID) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(returning: false)
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(returning: false)
    }

    func retainedWaiterBookkeepingCountForTesting() -> Int {
        waiters.count
    }

    public func complete(_ id: ID) {
        complete(Set([id]))
    }

    public func complete(_ ids: Set<ID>) {
        guard !ids.isEmpty else { return }
        completedIDs.formUnion(ids)
        var completedContinuations: [CheckedContinuation<Bool, Never>] = []
        for waiterID in Array(waiters.keys) {
            guard var waiter = waiters[waiterID] else { continue }
            waiter.remainingIDs.subtract(ids)
            if waiter.remainingIDs.isEmpty {
                waiters.removeValue(forKey: waiterID)
                completedContinuations.append(waiter.continuation)
            } else {
                waiters[waiterID] = waiter
            }
        }
        completedContinuations.forEach { $0.resume(returning: true) }
    }

    public func retainCompletions(for ids: Set<ID>) {
        completedIDs.formIntersection(ids)
    }

    func retainedCompletionCountForTesting() -> Int {
        completedIDs.count
    }
}

enum PairingOperationCategory: Sendable {
    case bootstrapRecovery
    case userInitiated
}

enum PairingOperationSequencingPolicy {
    static func shouldRunAfterWaiting(
        existing: PairingOperationCategory?,
        requested: PairingOperationCategory,
        matchesPendingBootstrapInvitation: Bool
    ) -> Bool {
        existing == .bootstrapRecovery
            && requested == .userInitiated
            && !matchesPendingBootstrapInvitation
    }
}

public enum ReceiverOutboxIdentityError: LocalizedError, Equatable {
    case missingReceiverIdentity
    case unknownReceiverIdentity
    case oldestItemBelongsToDifferentReceiver
    case receiverTransitionRequiresEmptyOutbox

    public var errorDescription: String? {
        switch self {
        case .missingReceiverIdentity:
            return "A current receiver binding is required before queued uploads can be sent."
        case .unknownReceiverIdentity:
            return "The oldest queued upload has no verifiable receiver origin. It is quarantined on this device and can only be deleted."
        case .oldestItemBelongsToDifferentReceiver:
            return "The oldest queued upload belongs to a different receiver binding. It is quarantined on this device and can only be deleted."
        case .receiverTransitionRequiresEmptyOutbox:
            return "Delete all queued uploads before changing or disconnecting the receiver."
        }
    }
}

public enum FileOutboxClearIntentError: LocalizedError, Equatable {
    case clearInProgress
    case clearIntentRequired

    public var errorDescription: String? {
        switch self {
        case .clearInProgress:
            return "Queued-upload deletion is in progress. New uploads remain blocked."
        case .clearIntentRequired:
            return "A durable queued-upload deletion intent is required before clearing payloads."
        }
    }
}

public struct FileOutboxItem: Equatable, Identifiable, Sendable {
    public let id: String
    public let fileURL: URL
    public let receiverIdentity: String?
    public let mailboxBinding: FileOutboxMailboxBindingV1?
    public let deliveryState: FileOutboxDeliveryStateV1?

    public init(
        id: String,
        fileURL: URL,
        receiverIdentity: String? = nil,
        mailboxBinding: FileOutboxMailboxBindingV1? = nil,
        deliveryState: FileOutboxDeliveryStateV1? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.receiverIdentity = receiverIdentity
        self.mailboxBinding = mailboxBinding
        self.deliveryState = deliveryState
    }
}

public struct FileOutboxMailboxBindingV1: Codable, Equatable, Sendable {
    public let payloadSHA256: String
    public let envelopeSHA256: String
    public let envelopeFilename: String

    public init(
        payloadSHA256: String,
        envelopeSHA256: String,
        envelopeFilename: String
    ) {
        self.payloadSHA256 = payloadSHA256
        self.envelopeSHA256 = envelopeSHA256
        self.envelopeFilename = envelopeFilename
    }
}

public enum FileOutboxMailboxError: Error, Equatable, Sendable {
    case itemNotFound
    case invalidDigest
    case payloadDigestMismatch
    case finalizationConflict
    case invalidFinalizationIntent
    case mailboxArtifactsRequireHold
    case legacyReaderCannotOpen
    case invalidDeliveryState
    case deliveryOwnershipMismatch
    case deliveryTransitionConflict
}

public enum FileOutboxDowngradeHoldReason: String, Codable, Equatable, Sendable {
    case v4Manifest
    case finalizationIntent
    case envelopeArtifact
}

public enum FileOutboxDowngradeReadiness: Equatable, Sendable {
    case ready
    case hold(FileOutboxDowngradeHoldReason)
}

enum FileOutboxEnvelopeFinalizationBoundary: CaseIterable, Equatable {
    case intentPersisted
    case stagedEnvelopePersisted
    case envelopeFinalized
    case manifestBound
}

enum FileOutboxCommittedFinalizationBoundary: CaseIterable, Equatable {
    case statePersisted
    case payloadRetired
    case envelopeRetired
}

public enum FileOutboxCoreLaneUploadProof: String, Codable, Equatable, Sendable {
    case steps
    case workouts
}

public struct FileOutboxCursorCheckpoint: Codable, Equatable, Sendable {
    public let receiverIdentity: String
    public let sourceKey: String
    public let cursorKind: String
    public let cursorValue: String
    public let coreLaneUploadProof: FileOutboxCoreLaneUploadProof?

    public init(
        receiverIdentity: String,
        sourceKey: String,
        cursorKind: String,
        cursorValue: String,
        coreLaneUploadProof: FileOutboxCoreLaneUploadProof? = nil
    ) {
        self.receiverIdentity = receiverIdentity
        self.sourceKey = sourceKey
        self.cursorKind = cursorKind
        self.cursorValue = cursorValue
        self.coreLaneUploadProof = coreLaneUploadProof
    }
}

public enum FileOutboxCursorCheckpointError: Error, Equatable {
    case pendingCommit
    case checkpointMismatch
}

public struct FileOutboxEnqueueResult: Equatable, Sendable {
    public let item: FileOutboxItem
    public let wasInserted: Bool

    public init(item: FileOutboxItem, wasInserted: Bool) {
        self.item = item
        self.wasInserted = wasInserted
    }
}

public enum DurablePayloadEnqueueAccounting {
    public static func durableItemCount(
        initialItemIDs: Set<String>,
        finalItemIDs: Set<String>?,
        successfulEnqueueCount: Int,
        enqueueWasAttempted: Bool
    ) -> Int {
        if let finalItemIDs {
            return finalItemIDs.subtracting(initialItemIDs).count
        }
        return max(successfulEnqueueCount, enqueueWasAttempted ? 1 : 0)
    }
}

public struct DurablePayloadEnqueueFailure: Error, LocalizedError {
    public let durableItemCount: Int
    public let underlyingError: Error

    public init(durableItemCount: Int, underlyingError: Error) {
        self.durableItemCount = durableItemCount
        self.underlyingError = underlyingError
    }

    public var errorDescription: String? {
        underlyingError.localizedDescription
    }
}

public struct FileOutboxFlushSummary: Equatable, Sendable {
    public let attemptedCount: Int
    public let uploadedCount: Int
    public let failedItemIDs: [String]
    public let failedDescriptions: [String]
    public let mailboxDeliveryDiagnosticLine: String

    public var failedCount: Int { failedItemIDs.count }

    public init(
        attemptedCount: Int,
        uploadedCount: Int,
        failedItemIDs: [String],
        failedDescriptions: [String] = [],
        mailboxDeliveryDiagnosticLine: String = ""
    ) {
        self.attemptedCount = attemptedCount
        self.uploadedCount = uploadedCount
        self.failedItemIDs = failedItemIDs
        self.failedDescriptions = failedDescriptions
        self.mailboxDeliveryDiagnosticLine = mailboxDeliveryDiagnosticLine
    }
}

public struct FileOutboxFlushError: Error, Equatable, LocalizedError, Sendable {
    public let summary: FileOutboxFlushSummary

    public init(summary: FileOutboxFlushSummary) {
        self.summary = summary
    }

    public var errorDescription: String? {
        var description = "Outbox upload incomplete: attempted \(summary.attemptedCount), uploaded \(summary.uploadedCount), failed \(summary.failedCount)."
        if let firstFailure = summary.failedDescriptions.first, !firstFailure.isEmpty {
            description += " First failure: \(firstFailure)"
        }
        return description
    }
}

public struct FileOutboxDestructiveRecoveryResult {
    public let outbox: FileOutbox
    public let removedPayloadCount: Int

    public init(outbox: FileOutbox, removedPayloadCount: Int) {
        self.outbox = outbox
        self.removedPayloadCount = removedPayloadCount
    }
}

public final class FileOutbox {
    private struct SequenceEntry: Codable, Equatable {
        let sequence: UInt64
        let id: String
        var receiverIdentity: String?
        var mailboxBinding: FileOutboxMailboxBindingV1?
        var deliveryState: FileOutboxDeliveryStateV1?
    }

    private struct SequenceManifest: Codable, Equatable {
        static let directOnlyVersion = 3
        static let mailboxVersion = 4

        var version: Int
        var nextSequence: UInt64
        var entries: [SequenceEntry]

        static var empty: SequenceManifest {
            SequenceManifest(version: directOnlyVersion, nextSequence: 1, entries: [])
        }
    }

    private struct MailboxEnvelopeFinalizationIntent: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let itemID: String
        let payloadSHA256: String
        let envelopeSHA256: String
        let stagedFilename: String
        let envelopeFilename: String
    }

    private struct ManifestVersion: Decodable {
        let version: Int
    }

    private struct EnqueueTransaction: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let entries: [SequenceEntry]
        let cursorCheckpoint: FileOutboxCursorCheckpoint?
    }

    private struct OrphanPayload {
        let id: String
        let modificationDate: Date
    }

    private enum SequenceError: Error {
        case exhausted
        case invalidManifest
    }

    private static let sequenceFilename = ".fifo-sequence"
    private static let clearIntentFilename = ".clear-intent"
    private static let enqueueTransactionFilename = ".enqueue-transaction"
    private static let mailboxEnvelopeIntentFilename = ".mailbox-envelope-intent"
    private let directory: URL
    private let fileManager: FileManager

    public var directoryURL: URL { directory }
    public var clearIntentIsActive: Bool {
        fileManager.fileExists(atPath: clearIntentURL.path)
    }

    public static func beginDestructiveRecovery(
        directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try applySensitiveFileAttributes(to: directory, fileManager: fileManager)
        let intentURL = directory.appendingPathComponent(clearIntentFilename)
        if !fileManager.fileExists(atPath: intentURL.path) {
            try Data("clear".utf8).write(to: intentURL, options: [.atomic])
        }
        try applySensitiveFileAttributes(to: intentURL, fileManager: fileManager)
    }

    public static func completeDestructiveRecovery(
        directory: URL,
        fileManager: FileManager = .default
    ) throws -> FileOutboxDestructiveRecoveryResult {
        let intentURL = directory.appendingPathComponent(clearIntentFilename)
        guard fileManager.fileExists(atPath: intentURL.path) else {
            throw FileOutboxClearIntentError.clearIntentRequired
        }
        guard try downgradeReadiness(directory: directory, fileManager: fileManager) == .ready else {
            throw FileOutboxMailboxError.mailboxArtifactsRequireHold
        }
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        var removedPayloadCount = 0
        for child in children where child.lastPathComponent != clearIntentFilename {
            if child.pathExtension == "json" {
                removedPayloadCount += 1
            }
            try fileManager.removeItem(at: child)
        }
        let outbox = try FileOutbox(directory: directory, fileManager: fileManager)
        try outbox.finishClearIntent()
        return FileOutboxDestructiveRecoveryResult(
            outbox: outbox,
            removedPayloadCount: removedPayloadCount
        )
    }

    public init(directory: URL, fileManager: FileManager = .default) throws {
        self.directory = directory
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.applySensitiveFileAttributes(to: directory, fileManager: fileManager)
        try hardenExistingPayloads()
        if clearIntentIsActive {
            try Self.applySensitiveFileAttributes(to: clearIntentURL, fileManager: fileManager)
        }
        try recoverMailboxEnvelopeFinalizationIfNeeded()
        _ = try reconciledManifest()
    }

    public func enqueue(
        _ payload: Data,
        receiverIdentity: String
    ) throws -> FileOutboxItem {
        try requireUploadAdmission()
        var manifest = try reconciledManifest()
        let sequence = manifest.nextSequence
        guard sequence < UInt64.max else { throw SequenceError.exhausted }
        let id = String(format: "%020llu-%@", sequence, UUID().uuidString.lowercased())
        let fileURL = directory.appendingPathComponent(id).appendingPathExtension("json")

        manifest.entries.append(
            SequenceEntry(
                sequence: sequence,
                id: id,
                receiverIdentity: receiverIdentity,
                mailboxBinding: nil,
                deliveryState: nil
            )
        )
        manifest.nextSequence = sequence + 1
        try persistManifest(manifest)
        try payload.write(to: fileURL, options: [.atomic])
        try Self.applySensitiveFileAttributes(to: fileURL, fileManager: fileManager)
        return FileOutboxItem(
            id: id,
            fileURL: fileURL,
            receiverIdentity: receiverIdentity,
            deliveryState: nil
        )
    }

    public func enqueueSequence(
        _ payloads: [Data],
        receiverIdentity: String,
        cursorCheckpoint: FileOutboxCursorCheckpoint? = nil
    ) throws -> [FileOutboxItem] {
        guard !payloads.isEmpty else { return [] }
        let prepared = try prepareEnqueueTransaction(
            payloads,
            receiverIdentity: receiverIdentity,
            cursorCheckpoint: cursorCheckpoint,
            stagedPayloadCount: payloads.count
        )
        return try commitEnqueueTransaction(
            prepared.transaction,
            manifest: prepared.manifest
        )
    }

    func stageEnqueueSequenceForTesting(
        _ payloads: [Data],
        receiverIdentity: String,
        stagedPayloadCount: Int
    ) throws {
        _ = try prepareEnqueueTransaction(
            payloads,
            receiverIdentity: receiverIdentity,
            cursorCheckpoint: nil,
            stagedPayloadCount: stagedPayloadCount
        )
    }

    public func enqueueIfAbsent(
        _ payload: Data,
        receiverIdentity: String
    ) throws -> FileOutboxEnqueueResult {
        try requireUploadAdmission()
        for item in try pendingItems() {
            guard item.receiverIdentity == receiverIdentity else { continue }
            if try Data(contentsOf: item.fileURL) == payload {
                return FileOutboxEnqueueResult(item: item, wasInserted: false)
            }
        }
        return FileOutboxEnqueueResult(
            item: try enqueue(payload, receiverIdentity: receiverIdentity),
            wasInserted: true
        )
    }

    public func pendingItems() throws -> [FileOutboxItem] {
        let manifest = try reconciledManifest()
        let payloadIDs = Set(try payloadFileURLs().map { payloadID(for: $0) })
        return manifest.entries
            .sorted { $0.sequence < $1.sequence }
            .compactMap { entry in
                guard payloadIDs.contains(entry.id) else { return nil }
                let fileURL = directory
                    .appendingPathComponent(entry.id)
                    .appendingPathExtension("json")
                return FileOutboxItem(
                    id: entry.id,
                    fileURL: fileURL,
                    receiverIdentity: entry.receiverIdentity,
                    mailboxBinding: entry.mailboxBinding,
                    deliveryState: entry.deliveryState
                )
            }
    }

    @discardableResult
    public func migrateLegacyHashedReceiverIdentities(
        currentReceiverURLString: String?,
        currentBearerToken: String?,
        currentBindingID: String?
    ) throws -> Int {
        var manifest = try reconciledManifest()
        let expectedLegacyIdentity: String?
        if let currentReceiverURLString,
           let currentBearerToken,
           !currentBearerToken.isEmpty,
           let currentBindingID,
           !currentBindingID.isEmpty {
            expectedLegacyIdentity = Self.legacyReceiverIdentity(
                receiverURLString: currentReceiverURLString,
                bearerToken: currentBearerToken
            )
        } else {
            expectedLegacyIdentity = nil
        }
        guard expectedLegacyIdentity != nil else {
            return 0
        }
        var migratedCount = 0
        for index in manifest.entries.indices {
            guard let identity = manifest.entries[index].receiverIdentity,
                  Self.isLegacyHashedReceiverIdentity(identity) else {
                continue
            }
            manifest.entries[index].receiverIdentity = identity == expectedLegacyIdentity
                ? currentBindingID
                : nil
            migratedCount += 1
        }
        if migratedCount > 0 {
            try persistManifest(manifest)
        }
        return migratedCount
    }

    public func pendingCursorCheckpoint() throws -> FileOutboxCursorCheckpoint? {
        _ = try reconciledManifest()
        return try loadEnqueueTransaction()?.cursorCheckpoint
    }

    public func acknowledgeCursorCheckpoint(
        _ checkpoint: FileOutboxCursorCheckpoint
    ) throws {
        guard let transaction = try loadEnqueueTransaction(),
              transaction.cursorCheckpoint == checkpoint else {
            throw FileOutboxCursorCheckpointError.checkpointMismatch
        }
        guard let manifest = try loadManifest() else {
            throw FileOutboxCursorCheckpointError.pendingCommit
        }
        try Self.validate(manifest)
        let manifestEntries = Dictionary(
            uniqueKeysWithValues: manifest.entries.map { ($0.id, $0) }
        )
        guard transaction.entries.allSatisfy({ entry in
            guard let current = manifestEntries[entry.id],
                  Self.hasSameCollectionIdentity(current, entry),
                  !fileManager.fileExists(atPath: stagedPayloadURL(for: entry.id).path)
            else {
                return false
            }
            return fileManager.fileExists(atPath: finalPayloadURL(for: entry.id).path)
                || current.deliveryState?.phase == .committedFinalized
        }) else {
            throw FileOutboxCursorCheckpointError.pendingCommit
        }
        try removeIfExists(enqueueTransactionURL)
    }

    public func uploadablePendingItems(for receiverIdentity: String) throws -> [FileOutboxItem] {
        try requireUploadAdmission()
        if try pendingCursorCheckpoint() != nil {
            throw FileOutboxCursorCheckpointError.pendingCommit
        }
        guard !receiverIdentity.isEmpty else {
            throw ReceiverOutboxIdentityError.missingReceiverIdentity
        }
        let items = try pendingItems()
        guard let first = items.first else { return [] }
        guard let oldestReceiverIdentity = first.receiverIdentity else {
            throw ReceiverOutboxIdentityError.unknownReceiverIdentity
        }
        guard oldestReceiverIdentity == receiverIdentity else {
            throw ReceiverOutboxIdentityError.oldestItemBelongsToDifferentReceiver
        }
        return items.prefix { $0.receiverIdentity == receiverIdentity }.map { $0 }
    }

    public func pendingItem(id: String) throws -> FileOutboxItem? {
        guard id == URL(fileURLWithPath: id).lastPathComponent, !id.isEmpty else {
            return nil
        }
        return try pendingItems().first { $0.id == id }
    }

    public func markUploaded(_ item: FileOutboxItem) throws {
        let current = try reconciledManifest().entries.first { $0.id == item.id }
        let hasMailboxBinding = current?.mailboxBinding != nil
        let hasDeliveryState = current?.deliveryState != nil
        let hasEnvelope = try hasEnvelopeArtifact(for: item.id)
        let hasIntent = try loadMailboxEnvelopeFinalizationIntent()?.itemID == item.id
        if hasMailboxBinding || hasDeliveryState || hasEnvelope || hasIntent {
            throw FileOutboxMailboxError.mailboxArtifactsRequireHold
        }
        if fileManager.fileExists(atPath: item.fileURL.path) {
            try fileManager.removeItem(at: item.fileURL)
        }
        _ = try reconciledManifest()
    }

    public func beginClearIntent() throws {
        if clearIntentIsActive { return }
        guard try downgradeReadiness() == .ready else {
            throw FileOutboxMailboxError.mailboxArtifactsRequireHold
        }
        try Data("clear".utf8).write(to: clearIntentURL, options: [.atomic])
        try Self.applySensitiveFileAttributes(to: clearIntentURL, fileManager: fileManager)
    }

    public func clearPendingWhileIntentIsActive() throws -> Int {
        guard clearIntentIsActive else {
            throw FileOutboxClearIntentError.clearIntentRequired
        }
        guard try downgradeReadiness() == .ready else {
            throw FileOutboxMailboxError.mailboxArtifactsRequireHold
        }
        let items = try pendingItems()
        for item in items {
            try markUploaded(item)
        }
        return items.count
    }

    public func finishClearIntent() throws {
        if fileManager.fileExists(atPath: clearIntentURL.path) {
            try fileManager.removeItem(at: clearIntentURL)
        }
    }

    public func clearPending() throws -> Int {
        try beginClearIntent()
        let count = try clearPendingWhileIntentIsActive()
        try finishClearIntent()
        return count
    }

    public func flushPending(
        receiverIdentity: String,
        upload: (FileOutboxItem, Data) async throws -> Void
    ) async throws -> FileOutboxFlushSummary {
        let items = try uploadablePendingItems(for: receiverIdentity)
        var attemptedCount = 0
        var uploadedCount = 0
        var failedItemIDs: [String] = []
        var failedDescriptions: [String] = []

        for item in items {
            try requireUploadAdmission()
            attemptedCount += 1
            do {
                let payload = try Data(contentsOf: item.fileURL)
                try await upload(item, payload)
                try markUploaded(item)
                uploadedCount += 1
            } catch {
                failedItemIDs.append(item.id)
                failedDescriptions.append(error.localizedDescription)
                break
            }
        }

        return FileOutboxFlushSummary(
            attemptedCount: attemptedCount,
            uploadedCount: uploadedCount,
            failedItemIDs: failedItemIDs,
            failedDescriptions: failedDescriptions
        )
    }

    public func finalizeMailboxEnvelope(
        itemID: String,
        envelope: Data,
        expectedPayloadSHA256: String
    ) throws -> FileOutboxMailboxBindingV1 {
        try finalizeMailboxEnvelope(
            itemID: itemID,
            envelope: envelope,
            expectedPayloadSHA256: expectedPayloadSHA256,
            stopAfter: nil
        )
    }

    func finalizeMailboxEnvelopeForTesting(
        itemID: String,
        envelope: Data,
        expectedPayloadSHA256: String,
        through boundary: FileOutboxEnvelopeFinalizationBoundary
    ) throws -> FileOutboxMailboxBindingV1 {
        try finalizeMailboxEnvelope(
            itemID: itemID,
            envelope: envelope,
            expectedPayloadSHA256: expectedPayloadSHA256,
            stopAfter: boundary
        )
    }

    public func mailboxBinding(for itemID: String) throws -> FileOutboxMailboxBindingV1? {
        guard Self.isSafeItemID(itemID) else { return nil }
        return try reconciledManifest().entries.first(where: { $0.id == itemID })?
            .mailboxBinding
    }

    public func deliveryState(for itemID: String) throws -> FileOutboxDeliveryStateV1? {
        guard Self.isSafeItemID(itemID) else { return nil }
        return try reconciledManifest().entries.first(where: { $0.id == itemID })?
            .deliveryState
    }

    func compareAndSetDeliveryState(
        itemID: String,
        expected: FileOutboxDeliveryStateV1?,
        updated: FileOutboxDeliveryStateV1
    ) throws -> FileOutboxDeliveryStateV1 {
        guard Self.isSafeItemID(itemID), updated.isStructurallyValid else {
            throw FileOutboxMailboxError.invalidDeliveryState
        }
        var manifest = try reconciledManifest()
        guard let index = manifest.entries.firstIndex(where: { $0.id == itemID }) else {
            throw FileOutboxMailboxError.itemNotFound
        }
        let entry = manifest.entries[index]
        guard entry.deliveryState == expected else {
            throw FileOutboxMailboxError.deliveryTransitionConflict
        }
        guard let ownership = updated.ownership else {
            if updated.phase != .collected && updated.phase != .encrypted {
                throw FileOutboxMailboxError.invalidDeliveryState
            }
            manifest.entries[index].deliveryState = updated
            manifest.version = SequenceManifest.mailboxVersion
            try persistManifest(manifest)
            return updated
        }
        guard entry.receiverIdentity == ownership.receiverBindingID else {
            throw FileOutboxMailboxError.deliveryOwnershipMismatch
        }
        if updated.phase != .collected, entry.mailboxBinding == nil {
            throw FileOutboxMailboxError.invalidDeliveryState
        }
        manifest.entries[index].deliveryState = updated
        manifest.version = SequenceManifest.mailboxVersion
        try persistManifest(manifest)
        return updated
    }

    func cursorCheckpointReadyForDeliveryFinalization(
        itemID: String,
        ownership: OutboxDeliveryOwnershipV1
    ) throws -> FileOutboxCursorCheckpoint? {
        guard let transaction = try loadEnqueueTransaction(),
              let checkpoint = transaction.cursorCheckpoint,
              checkpoint.receiverIdentity == ownership.receiverBindingID,
              transaction.entries.contains(where: { $0.id == itemID }) else {
            return nil
        }
        let manifest = try reconciledManifest()
        let states = Dictionary(
            uniqueKeysWithValues: manifest.entries.compactMap { entry in
                entry.deliveryState.map { (entry.id, $0.phase) }
            }
        )
        guard transaction.entries.allSatisfy({
            states[$0.id] == .ackVerified || states[$0.id] == .committedFinalized
        }) else {
            return nil
        }
        return checkpoint
    }

    func finalizeCommittedMailboxDelivery(
        itemID: String,
        expected: FileOutboxDeliveryStateV1,
        committed: FileOutboxDeliveryStateV1,
        fault: (FileOutboxCommittedFinalizationBoundary) throws -> Void = { _ in }
    ) throws -> FileOutboxDeliveryStateV1 {
        guard expected.phase == .ackVerified,
              committed.phase == .committedFinalized,
              expected.ownership == committed.ownership,
              expected.committedReceipt == committed.committedReceipt else {
            throw FileOutboxMailboxError.invalidDeliveryState
        }
        var manifest = try reconciledManifest()
        guard let index = manifest.entries.firstIndex(where: { $0.id == itemID }) else {
            throw FileOutboxMailboxError.itemNotFound
        }
        if manifest.entries[index].deliveryState == committed {
            try retireCommittedArtifacts(for: manifest.entries[index], fault: fault)
            return committed
        }
        guard manifest.entries[index].deliveryState == expected,
              manifest.entries[index].mailboxBinding != nil else {
            throw FileOutboxMailboxError.deliveryTransitionConflict
        }
        manifest.entries[index].deliveryState = committed
        try persistManifest(manifest)
        try fault(.statePersisted)
        try retireCommittedArtifacts(for: manifest.entries[index], fault: fault)
        return committed
    }

    public func mailboxBoundItemsForAckScanning() throws -> [FileOutboxItem] {
        if fileManager.fileExists(atPath: mailboxEnvelopeIntentURL.path) {
            throw FileOutboxMailboxError.finalizationConflict
        }
        guard fileManager.fileExists(atPath: sequenceURL.path) else {
            return []
        }
        let bytes = try MailboxRegularFileReader.read(
            sequenceURL,
            maximumBytes: 64 * 1024 * 1024
        )
        let manifest = try JSONDecoder().decode(SequenceManifest.self, from: bytes)
        try Self.validate(manifest)
        return manifest.entries
            .sorted { $0.sequence < $1.sequence }
            .compactMap { entry in
                guard let binding = entry.mailboxBinding else { return nil }
                return FileOutboxItem(
                    id: entry.id,
                    fileURL: finalPayloadURL(for: entry.id),
                    receiverIdentity: entry.receiverIdentity,
                    mailboxBinding: binding,
                    deliveryState: entry.deliveryState
                )
            }
    }

    public func downgradeReadiness() throws -> FileOutboxDowngradeReadiness {
        try Self.downgradeReadiness(directory: directory, fileManager: fileManager)
    }

    public static func downgradeReadiness(
        directory: URL,
        fileManager: FileManager = .default
    ) throws -> FileOutboxDowngradeReadiness {
        let manifestURL = directory.appendingPathComponent(sequenceFilename)
        if fileManager.fileExists(atPath: manifestURL.path) {
            let header = try? JSONDecoder().decode(
                ManifestVersion.self,
                from: Data(contentsOf: manifestURL)
            )
            if let header, header.version >= SequenceManifest.mailboxVersion {
                return .hold(.v4Manifest)
            }
        }
        if fileManager.fileExists(
            atPath: directory.appendingPathComponent(mailboxEnvelopeIntentFilename).path
        ) {
            return .hold(.finalizationIntent)
        }
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        if children.contains(where: { isEnvelopeArtifact($0) }) {
            return .hold(.envelopeArtifact)
        }
        return .ready
    }

    public static func assertReadableByLegacyV3Reader(
        directory: URL,
        fileManager: FileManager = .default
    ) throws {
        let manifestURL = directory.appendingPathComponent(sequenceFilename)
        if fileManager.fileExists(atPath: manifestURL.path) {
            guard let header = try? JSONDecoder().decode(
                ManifestVersion.self,
                from: Data(contentsOf: manifestURL)
            ), header.version <= SequenceManifest.directOnlyVersion else {
                throw FileOutboxMailboxError.legacyReaderCannotOpen
            }
        }
        guard try downgradeReadiness(directory: directory, fileManager: fileManager) == .ready else {
            throw FileOutboxMailboxError.legacyReaderCannotOpen
        }
    }

    private func finalizeMailboxEnvelope(
        itemID: String,
        envelope: Data,
        expectedPayloadSHA256: String,
        stopAfter: FileOutboxEnvelopeFinalizationBoundary?
    ) throws -> FileOutboxMailboxBindingV1 {
        guard Self.isSafeItemID(itemID), Self.isSHA256(expectedPayloadSHA256) else {
            throw FileOutboxMailboxError.invalidDigest
        }
        var manifest = try reconciledManifest()
        guard let entryIndex = manifest.entries.firstIndex(where: { $0.id == itemID }) else {
            throw FileOutboxMailboxError.itemNotFound
        }
        let payloadURL = finalPayloadURL(for: itemID)
        let payload = try Data(contentsOf: payloadURL)
        let payloadSHA256 = Self.sha256(payload)
        guard payloadSHA256 == expectedPayloadSHA256 else {
            throw FileOutboxMailboxError.payloadDigestMismatch
        }
        let envelopeSHA256 = Self.sha256(envelope)
        let finalURL = finalEnvelopeURL(for: itemID)
        let stagedURL = stagedEnvelopeURL(for: itemID)
        let binding = FileOutboxMailboxBindingV1(
            payloadSHA256: payloadSHA256,
            envelopeSHA256: envelopeSHA256,
            envelopeFilename: finalURL.lastPathComponent
        )
        if let existing = manifest.entries[entryIndex].mailboxBinding {
            guard existing == binding,
                  fileManager.fileExists(atPath: finalURL.path),
                  Self.sha256(try Data(contentsOf: finalURL)) == envelopeSHA256 else {
                throw FileOutboxMailboxError.finalizationConflict
            }
            return existing
        }
        guard !(try hasEnvelopeArtifact(for: itemID)) else {
            throw FileOutboxMailboxError.finalizationConflict
        }

        let intent = MailboxEnvelopeFinalizationIntent(
            version: MailboxEnvelopeFinalizationIntent.currentVersion,
            itemID: itemID,
            payloadSHA256: payloadSHA256,
            envelopeSHA256: envelopeSHA256,
            stagedFilename: stagedURL.lastPathComponent,
            envelopeFilename: finalURL.lastPathComponent
        )
        try persistMailboxEnvelopeFinalizationIntent(intent)
        if stopAfter == .intentPersisted { return binding }

        do {
            try envelope.write(to: stagedURL, options: [.withoutOverwriting])
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
                && error.code == NSFileWriteFileExistsError {
            throw FileOutboxMailboxError.finalizationConflict
        }
        try Self.applySensitiveFileAttributes(to: stagedURL, fileManager: fileManager)
        if stopAfter == .stagedEnvelopePersisted { return binding }

        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw FileOutboxMailboxError.finalizationConflict
        }
        try fileManager.moveItem(at: stagedURL, to: finalURL)
        try hardenFinalEnvelope(finalURL)
        if stopAfter == .envelopeFinalized { return binding }

        manifest.entries[entryIndex].mailboxBinding = binding
        manifest.entries[entryIndex].deliveryState = try Self.encryptedDeliveryState(
            manifest.entries[entryIndex].deliveryState
        )
        manifest.version = SequenceManifest.mailboxVersion
        try persistManifest(manifest)
        if stopAfter == .manifestBound { return binding }

        try removeIfExists(mailboxEnvelopeIntentURL)
        return binding
    }

    private func recoverMailboxEnvelopeFinalizationIfNeeded() throws {
        guard let intent = try loadMailboxEnvelopeFinalizationIntent() else { return }
        guard !clearIntentIsActive else {
            throw FileOutboxMailboxError.finalizationConflict
        }
        let loadedManifest = try loadManifest()
        var manifest = loadedManifest ?? .empty
        guard let entryIndex = manifest.entries.firstIndex(where: { $0.id == intent.itemID }) else {
            throw FileOutboxMailboxError.invalidFinalizationIntent
        }
        let payloadURL = finalPayloadURL(for: intent.itemID)
        guard fileManager.fileExists(atPath: payloadURL.path),
              Self.sha256(try Data(contentsOf: payloadURL)) == intent.payloadSHA256 else {
            throw FileOutboxMailboxError.payloadDigestMismatch
        }
        let stagedURL = directory.appendingPathComponent(intent.stagedFilename)
        let finalURL = directory.appendingPathComponent(intent.envelopeFilename)
        let stagedExists = fileManager.fileExists(atPath: stagedURL.path)
        let finalExists = fileManager.fileExists(atPath: finalURL.path)
        guard !(stagedExists && finalExists) else {
            throw FileOutboxMailboxError.finalizationConflict
        }
        if !stagedExists && !finalExists {
            try removeIfExists(mailboxEnvelopeIntentURL)
            return
        }
        if stagedExists {
            guard Self.sha256(try Data(contentsOf: stagedURL)) == intent.envelopeSHA256 else {
                throw FileOutboxMailboxError.finalizationConflict
            }
            try fileManager.moveItem(at: stagedURL, to: finalURL)
        }
        guard Self.sha256(try Data(contentsOf: finalURL)) == intent.envelopeSHA256 else {
            throw FileOutboxMailboxError.finalizationConflict
        }
        try hardenFinalEnvelope(finalURL)
        let binding = FileOutboxMailboxBindingV1(
            payloadSHA256: intent.payloadSHA256,
            envelopeSHA256: intent.envelopeSHA256,
            envelopeFilename: intent.envelopeFilename
        )
        if let existing = manifest.entries[entryIndex].mailboxBinding, existing != binding {
            throw FileOutboxMailboxError.finalizationConflict
        }
        manifest.entries[entryIndex].mailboxBinding = binding
        manifest.entries[entryIndex].deliveryState = try Self.encryptedDeliveryState(
            manifest.entries[entryIndex].deliveryState
        )
        manifest.version = SequenceManifest.mailboxVersion
        try persistManifest(manifest)
        try removeIfExists(mailboxEnvelopeIntentURL)
    }

    private func persistMailboxEnvelopeFinalizationIntent(
        _ intent: MailboxEnvelopeFinalizationIntent
    ) throws {
        try Self.validate(intent)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try encoder.encode(intent).write(
                to: mailboxEnvelopeIntentURL,
                options: [.withoutOverwriting]
            )
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
                && error.code == NSFileWriteFileExistsError {
            throw FileOutboxMailboxError.finalizationConflict
        }
        try Self.applySensitiveFileAttributes(
            to: mailboxEnvelopeIntentURL,
            fileManager: fileManager
        )
    }

    private func loadMailboxEnvelopeFinalizationIntent()
        throws -> MailboxEnvelopeFinalizationIntent? {
        guard fileManager.fileExists(atPath: mailboxEnvelopeIntentURL.path) else {
            return nil
        }
        guard let intent = try? JSONDecoder().decode(
            MailboxEnvelopeFinalizationIntent.self,
            from: Data(contentsOf: mailboxEnvelopeIntentURL)
        ) else {
            throw FileOutboxMailboxError.invalidFinalizationIntent
        }
        try Self.validate(intent)
        return intent
    }

    private static func validate(_ intent: MailboxEnvelopeFinalizationIntent) throws {
        guard intent.version == MailboxEnvelopeFinalizationIntent.currentVersion,
              isSafeItemID(intent.itemID),
              isSHA256(intent.payloadSHA256),
              isSHA256(intent.envelopeSHA256),
              intent.stagedFilename == "\(intent.itemID).hbe-staged",
              intent.envelopeFilename == "\(intent.itemID).hbe" else {
            throw FileOutboxMailboxError.invalidFinalizationIntent
        }
    }

    private func validateEnvelopeArtifacts(for manifest: SequenceManifest) throws {
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let artifacts = children.filter { Self.isEnvelopeArtifact($0) }
        guard !artifacts.contains(where: { $0.pathExtension == "hbe-staged" }) else {
            throw FileOutboxMailboxError.finalizationConflict
        }
        let expectedFilenames = Set(
            manifest.entries.compactMap { entry in
                entry.deliveryState?.phase == .committedFinalized
                    ? nil
                    : entry.mailboxBinding?.envelopeFilename
            }
        )
        let actualFilenames = Set(artifacts.map(\.lastPathComponent))
        guard expectedFilenames == actualFilenames else {
            throw FileOutboxMailboxError.finalizationConflict
        }
        for entry in manifest.entries {
            if entry.deliveryState?.phase == .committedFinalized { continue }
            guard let binding = entry.mailboxBinding else { continue }
            let payloadURL = finalPayloadURL(for: entry.id)
            let envelopeURL = directory.appendingPathComponent(binding.envelopeFilename)
            guard fileManager.fileExists(atPath: payloadURL.path),
                  fileManager.fileExists(atPath: envelopeURL.path),
                  Self.sha256(try Data(contentsOf: payloadURL)) == binding.payloadSHA256,
                  Self.sha256(try Data(contentsOf: envelopeURL)) == binding.envelopeSHA256 else {
                throw FileOutboxMailboxError.finalizationConflict
            }
            try hardenFinalEnvelope(envelopeURL)
        }
    }

    private func hasEnvelopeArtifact(for itemID: String) throws -> Bool {
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return children.contains { fileURL in
            Self.isEnvelopeArtifact(fileURL)
                && (fileURL.lastPathComponent == "\(itemID).hbe"
                    || fileURL.lastPathComponent == "\(itemID).hbe-staged")
        }
    }

    private static func isEnvelopeArtifact(_ fileURL: URL) -> Bool {
        fileURL.pathExtension == "hbe" || fileURL.pathExtension == "hbe-staged"
    }

    private func stagedEnvelopeURL(for itemID: String) -> URL {
        directory.appendingPathComponent(itemID).appendingPathExtension("hbe-staged")
    }

    private func finalEnvelopeURL(for itemID: String) -> URL {
        directory.appendingPathComponent(itemID).appendingPathExtension("hbe")
    }

    private static func encryptedDeliveryState(
        _ state: FileOutboxDeliveryStateV1?
    ) throws -> FileOutboxDeliveryStateV1 {
        guard let state else {
            return .stable(.encrypted, ownership: nil)
        }
        switch state.phase {
        case .collected:
            return .stable(.encrypted, ownership: state.ownership)
        case .encrypted:
            return state
        case .published, .providerObserved, .ackVerified, .committedFinalized,
             .retryableFailure, .terminalFailure:
            throw FileOutboxMailboxError.deliveryTransitionConflict
        }
    }

    private func retireCommittedArtifacts(
        for entry: SequenceEntry,
        fault: (FileOutboxCommittedFinalizationBoundary) throws -> Void
    ) throws {
        guard entry.deliveryState?.phase == .committedFinalized,
              let binding = entry.mailboxBinding,
              binding.envelopeFilename == "\(entry.id).hbe" else {
            throw FileOutboxMailboxError.invalidDeliveryState
        }
        try removeIfExists(finalPayloadURL(for: entry.id))
        try fault(.payloadRetired)
        try removeIfExists(directory.appendingPathComponent(binding.envelopeFilename))
        try fault(.envelopeRetired)
    }

    private func hardenFinalEnvelope(_ fileURL: URL) throws {
        try Self.applySensitiveFileAttributes(to: fileURL, fileManager: fileManager)
        try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fileURL.path)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func hardenExistingPayloads() throws {
        for fileURL in try payloadFileURLs() {
            try Self.applySensitiveFileAttributes(to: fileURL, fileManager: fileManager)
        }
    }

    private var sequenceURL: URL {
        directory.appendingPathComponent(Self.sequenceFilename)
    }

    private var clearIntentURL: URL {
        directory.appendingPathComponent(Self.clearIntentFilename)
    }

    private var enqueueTransactionURL: URL {
        directory.appendingPathComponent(Self.enqueueTransactionFilename)
    }

    private var mailboxEnvelopeIntentURL: URL {
        directory.appendingPathComponent(Self.mailboxEnvelopeIntentFilename)
    }

    private func stagedPayloadURL(for id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("staged")
    }

    private func finalPayloadURL(for id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("json")
    }

    public func requireUploadAdmission() throws {
        if clearIntentIsActive {
            throw FileOutboxClearIntentError.clearInProgress
        }
    }

    private func payloadFileURLs() throws -> [URL] {
        try fileManager
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    private func payloadID(for fileURL: URL) -> String {
        fileURL.deletingPathExtension().lastPathComponent
    }

    private func prepareEnqueueTransaction(
        _ payloads: [Data],
        receiverIdentity: String,
        cursorCheckpoint: FileOutboxCursorCheckpoint?,
        stagedPayloadCount: Int
    ) throws -> (transaction: EnqueueTransaction, manifest: SequenceManifest) {
        try requireUploadAdmission()
        guard (0 ... payloads.count).contains(stagedPayloadCount) else {
            throw SequenceError.invalidManifest
        }
        var manifest = try reconciledManifest()
        if try loadEnqueueTransaction()?.cursorCheckpoint != nil {
            throw FileOutboxCursorCheckpointError.pendingCommit
        }
        var entries: [SequenceEntry] = []
        for _ in payloads {
            let sequence = manifest.nextSequence
            guard sequence < UInt64.max else { throw SequenceError.exhausted }
            let id = String(
                format: "%020llu-%@",
                sequence,
                UUID().uuidString.lowercased()
            )
            entries.append(
                SequenceEntry(
                    sequence: sequence,
                    id: id,
                    receiverIdentity: receiverIdentity,
                    mailboxBinding: nil,
                    deliveryState: nil
                )
            )
            manifest.nextSequence = sequence + 1
        }
        let transaction = EnqueueTransaction(
            version: EnqueueTransaction.currentVersion,
            entries: entries,
            cursorCheckpoint: cursorCheckpoint
        )
        try persistEnqueueTransaction(transaction)
        for (entry, payload) in zip(entries, payloads).prefix(stagedPayloadCount) {
            let stagedURL = stagedPayloadURL(for: entry.id)
            try payload.write(to: stagedURL, options: [.atomic])
            try Self.applySensitiveFileAttributes(
                to: stagedURL,
                fileManager: fileManager
            )
        }
        return (transaction, manifest)
    }

    private func commitEnqueueTransaction(
        _ transaction: EnqueueTransaction,
        manifest initialManifest: SequenceManifest
    ) throws -> [FileOutboxItem] {
        guard transaction.version == EnqueueTransaction.currentVersion,
              !transaction.entries.isEmpty else {
            throw SequenceError.invalidManifest
        }
        var manifest = initialManifest
        var knownIDs = Set(manifest.entries.map(\.id))
        for entry in transaction.entries {
            let stagedURL = stagedPayloadURL(for: entry.id)
            let finalURL = finalPayloadURL(for: entry.id)
            let existing = manifest.entries.first { $0.id == entry.id }
            if fileManager.fileExists(atPath: stagedURL.path) {
                try Self.applySensitiveFileAttributes(
                    to: stagedURL,
                    fileManager: fileManager
                )
                if fileManager.fileExists(atPath: finalURL.path) {
                    try fileManager.removeItem(at: stagedURL)
                } else {
                    try fileManager.moveItem(at: stagedURL, to: finalURL)
                }
            }
            guard fileManager.fileExists(atPath: finalURL.path)
                || existing?.deliveryState?.phase == .committedFinalized else {
                throw SequenceError.invalidManifest
            }
            if fileManager.fileExists(atPath: finalURL.path) {
                try Self.applySensitiveFileAttributes(
                    to: finalURL,
                    fileManager: fileManager
                )
            }
            if knownIDs.insert(entry.id).inserted {
                manifest.entries.append(entry)
            }
            guard entry.sequence < UInt64.max else {
                throw SequenceError.exhausted
            }
            manifest.nextSequence = max(manifest.nextSequence, entry.sequence + 1)
        }
        try persistManifest(manifest)
        if transaction.cursorCheckpoint == nil {
            try removeIfExists(enqueueTransactionURL)
        }
        return transaction.entries.map { entry in
            FileOutboxItem(
                id: entry.id,
                fileURL: finalPayloadURL(for: entry.id),
                receiverIdentity: entry.receiverIdentity,
                mailboxBinding: entry.mailboxBinding,
                deliveryState: entry.deliveryState
            )
        }
    }

    private func persistEnqueueTransaction(_ transaction: EnqueueTransaction) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(transaction).write(
            to: enqueueTransactionURL,
            options: [.atomic]
        )
        try Self.applySensitiveFileAttributes(
            to: enqueueTransactionURL,
            fileManager: fileManager
        )
    }

    private func loadEnqueueTransaction() throws -> EnqueueTransaction? {
        guard fileManager.fileExists(atPath: enqueueTransactionURL.path) else {
            return nil
        }
        let transaction = try JSONDecoder().decode(
            EnqueueTransaction.self,
            from: Data(contentsOf: enqueueTransactionURL)
        )
        guard transaction.version == EnqueueTransaction.currentVersion,
              !transaction.entries.isEmpty,
              Set(transaction.entries.map(\.id)).count == transaction.entries.count,
              Set(transaction.entries.map(\.sequence)).count == transaction.entries.count else {
            throw SequenceError.invalidManifest
        }
        return transaction
    }

    private func recoverEnqueueTransactionIfNeeded() throws {
        guard let transaction = try loadEnqueueTransaction() else { return }
        let loadedManifest = try loadManifest()
        var manifest = loadedManifest ?? .empty
        try Self.validate(manifest)
        let manifestEntries = Dictionary(
            uniqueKeysWithValues: manifest.entries.map { ($0.id, $0) }
        )
        let allPayloadsAreRecoverable = !clearIntentIsActive
            && transaction.entries.allSatisfy { entry in
                fileManager.fileExists(atPath: stagedPayloadURL(for: entry.id).path)
                    || fileManager.fileExists(atPath: finalPayloadURL(for: entry.id).path)
                    || manifestEntries[entry.id]?.deliveryState?.phase == .committedFinalized
            }
        if allPayloadsAreRecoverable {
            _ = try commitEnqueueTransaction(transaction, manifest: manifest)
            return
        }
        if transaction.entries.contains(where: {
            manifestEntries[$0.id]?.deliveryState?.phase == .committedFinalized
        }) {
            throw FileOutboxCursorCheckpointError.pendingCommit
        }

        let transactionIDs = Set(transaction.entries.map(\.id))
        for entry in transaction.entries {
            try removeIfExists(stagedPayloadURL(for: entry.id))
            try removeIfExists(finalPayloadURL(for: entry.id))
        }
        manifest.entries.removeAll { transactionIDs.contains($0.id) }
        if manifest != loadedManifest {
            try persistManifest(manifest)
        }
        try removeIfExists(enqueueTransactionURL)
    }

    private func removeIfExists(_ fileURL: URL) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func reconciledManifest() throws -> SequenceManifest {
        try recoverEnqueueTransactionIfNeeded()
        let loadedManifest = try loadManifest()
        var manifest = loadedManifest ?? .empty
        try Self.validate(manifest)
        if manifest.version < SequenceManifest.directOnlyVersion {
            manifest.version = SequenceManifest.directOnlyVersion
        }
        if manifest.version == SequenceManifest.mailboxVersion {
            for index in manifest.entries.indices
                where manifest.entries[index].deliveryState == nil {
                manifest.entries[index].deliveryState = .stable(
                    manifest.entries[index].mailboxBinding == nil ? .collected : .encrypted,
                    ownership: nil
                )
            }
        }
        for entry in manifest.entries
            where entry.deliveryState?.phase == .committedFinalized {
            try retireCommittedArtifacts(for: entry, fault: { _ in })
        }
        let payloadURLs = try payloadFileURLs()
        let payloadIDs = Set(payloadURLs.map(payloadID))

        if manifest.entries.contains(where: {
            !payloadIDs.contains($0.id)
                && $0.deliveryState?.phase != .committedFinalized
                && ($0.mailboxBinding != nil || $0.deliveryState != nil)
        }) {
            throw FileOutboxMailboxError.finalizationConflict
        }
        manifest.entries.removeAll {
            $0.mailboxBinding == nil
                && $0.deliveryState == nil
                && !payloadIDs.contains($0.id)
        }
        let knownIDs = Set(manifest.entries.map(\.id))
        let orphanIDs = try payloadURLs
            .map { fileURL -> OrphanPayload in
                let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                let modificationDate = attributes[.modificationDate] as? Date
                    ?? attributes[.creationDate] as? Date
                    ?? .distantPast
                return OrphanPayload(
                    id: payloadID(for: fileURL),
                    modificationDate: modificationDate
                )
            }
            .filter { !knownIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.modificationDate == rhs.modificationDate {
                    return lhs.id < rhs.id
                }
                return lhs.modificationDate < rhs.modificationDate
            }
            .map(\.id)

        for id in orphanIDs {
            let sequence = manifest.nextSequence
            guard sequence < UInt64.max else { throw SequenceError.exhausted }
            manifest.entries.append(
                SequenceEntry(
                    sequence: sequence,
                    id: id,
                    receiverIdentity: nil,
                    mailboxBinding: nil,
                    deliveryState: manifest.version == SequenceManifest.mailboxVersion
                        ? .stable(.collected, ownership: nil)
                        : nil
                )
            )
            manifest.nextSequence = sequence + 1
        }

        try Self.validate(manifest)
        try validateEnvelopeArtifacts(for: manifest)
        if manifest != loadedManifest {
            try persistManifest(manifest)
        }
        return manifest
    }

    private func loadManifest() throws -> SequenceManifest? {
        guard fileManager.fileExists(atPath: sequenceURL.path) else { return nil }
        let manifest = try JSONDecoder().decode(
            SequenceManifest.self,
            from: Data(contentsOf: sequenceURL)
        )
        try Self.validate(manifest)
        try Self.applySensitiveFileAttributes(to: sequenceURL, fileManager: fileManager)
        return manifest
    }

    private func persistManifest(_ manifest: SequenceManifest) throws {
        try Self.validate(manifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: sequenceURL, options: [.atomic])
        try Self.applySensitiveFileAttributes(to: sequenceURL, fileManager: fileManager)
    }

    private static func validate(_ manifest: SequenceManifest) throws {
        let ids = manifest.entries.map(\.id)
        let sequences = manifest.entries.map(\.sequence)
        let mailboxBindings = manifest.entries.compactMap(\.mailboxBinding)
        let deliveryStates = manifest.entries.compactMap(\.deliveryState)
        guard (1 ... SequenceManifest.mailboxVersion).contains(manifest.version),
              manifest.nextSequence > 0,
              ids.allSatisfy(isSafeItemID),
              Set(ids).count == ids.count,
              Set(sequences).count == sequences.count,
              sequences.allSatisfy({ $0 > 0 }),
              (sequences.max().map { manifest.nextSequence > $0 } ?? true),
              (manifest.version == SequenceManifest.mailboxVersion
                  ? !mailboxBindings.isEmpty || !deliveryStates.isEmpty
                  : mailboxBindings.isEmpty && deliveryStates.isEmpty),
              manifest.entries.allSatisfy({ entry in
                  let bindingIsValid = entry.mailboxBinding.map { binding in
                      isSHA256(binding.payloadSHA256)
                      && isSHA256(binding.envelopeSHA256)
                      && binding.envelopeFilename == "\(entry.id).hbe"
                  } ?? true
                  return bindingIsValid && deliveryStateIsValid(for: entry)
              }) else {
            throw SequenceError.invalidManifest
        }
    }

    private static func deliveryStateIsValid(for entry: SequenceEntry) -> Bool {
        guard let state = entry.deliveryState else { return true }
        guard state.isStructurallyValid,
              state.ownership?.receiverBindingID == entry.receiverIdentity
                || state.ownership == nil else {
            return false
        }
        switch state.phase {
        case .collected:
            return entry.mailboxBinding == nil
        case .encrypted, .published, .providerObserved, .ackVerified,
             .committedFinalized, .retryableFailure, .terminalFailure:
            return entry.mailboxBinding != nil
        }
    }

    private static func hasSameCollectionIdentity(
        _ lhs: SequenceEntry,
        _ rhs: SequenceEntry
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.sequence == rhs.sequence
            && lhs.receiverIdentity == rhs.receiverIdentity
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    private static func isSafeItemID(_ id: String) -> Bool {
        !id.isEmpty && id == URL(fileURLWithPath: id).lastPathComponent
    }

    private static func isLegacyHashedReceiverIdentity(_ identity: String) -> Bool {
        identity.utf8.count == 64 && identity.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    private static func legacyReceiverIdentity(
        receiverURLString: String,
        bearerToken: String
    ) -> String {
        let material = Data("\(receiverURLString)\u{0}\(bearerToken)".utf8)
        return SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func applySensitiveFileAttributes(to url: URL, fileManager: FileManager) throws {
        let existingResourceValues = try url.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        if existingResourceValues.isExcludedFromBackup != true {
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(resourceValues)
        }

        #if os(iOS)
        let existingAttributes = try fileManager.attributesOfItem(atPath: url.path)
        if existingAttributes[.protectionKey] as? FileProtectionType
            != .completeUntilFirstUserAuthentication {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        }
        #endif
    }
}

#if !HEALTH_BRIDGE_MAILBOX_QA
public protocol SyncCursorStoring {
    func cursorValue(receiverBindingID: String, sourceKey: String, cursorKind: String) throws -> String?
    func saveCursorValue(
        _ cursorValue: String,
        receiverBindingID: String,
        sourceKey: String,
        cursorKind: String
    ) throws
}

public enum FileSyncCursorStoreError: Error, Equatable {
    case invalidData
}

public final class CoreLaneUploadProofStore {
    public enum Lane: String, CaseIterable, Sendable {
        case steps
        case workouts
    }

    private let userDefaults: UserDefaults
    private let keyPrefix = "coreLaneUploadedRecords"
    private let versionedKeyPrefix = "coreLaneUploadedRecords.receiver_binding_v1"

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        for key in userDefaults.dictionaryRepresentation().keys
            where key.hasPrefix("\(keyPrefix).") && !key.hasPrefix("\(versionedKeyPrefix).") {
            userDefaults.removeObject(forKey: key)
        }
    }

    public func hasUploadedRecords(lane: Lane, receiverBindingID: String) -> Bool {
        userDefaults.bool(forKey: key(for: lane, receiverBindingID: receiverBindingID))
    }

    public func markUploadedRecords(lane: Lane, receiverBindingID: String) {
        userDefaults.set(true, forKey: key(for: lane, receiverBindingID: receiverBindingID))
    }

    public func resetAll() {
        for key in userDefaults.dictionaryRepresentation().keys where key.hasPrefix("\(keyPrefix).") {
            userDefaults.removeObject(forKey: key)
        }
    }

    private func key(for lane: Lane, receiverBindingID: String) -> String {
        "\(versionedKeyPrefix).\(receiverBindingID).\(lane.rawValue)"
    }
}

public final class FileSyncCursorStore: SyncCursorStoring {
    private static let versionedKeyPrefix = "receiver_binding_v1#"

    public let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) throws {
        self.fileURL = fileURL
        self.fileManager = fileManager
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.applySensitiveFileAttributes(to: directory, fileManager: fileManager)
        if !fileManager.fileExists(atPath: fileURL.path) {
            try Data("{}".utf8).write(to: fileURL, options: [.atomic])
        }
        try Self.applySensitiveFileAttributes(to: fileURL, fileManager: fileManager)
        try discardLegacyUnscopedValues()
    }

    public static func replaceWithEmptyStore(
        fileURL: URL,
        fileManager: FileManager = .default
    ) throws -> FileSyncCursorStore {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try applySensitiveFileAttributes(to: directory, fileManager: fileManager)
        try Data("{}".utf8).write(to: fileURL, options: [.atomic])
        try applySensitiveFileAttributes(to: fileURL, fileManager: fileManager)
        return try FileSyncCursorStore(fileURL: fileURL, fileManager: fileManager)
    }

    public func cursorValue(
        receiverBindingID: String,
        sourceKey: String,
        cursorKind: String
    ) throws -> String? {
        try loadAll()[Self.key(
            receiverBindingID: receiverBindingID,
            sourceKey: sourceKey,
            cursorKind: cursorKind
        )]
    }

    public func saveCursorValue(
        _ cursorValue: String,
        receiverBindingID: String,
        sourceKey: String,
        cursorKind: String
    ) throws {
        var cursors = try loadAll()
        cursors[Self.key(
            receiverBindingID: receiverBindingID,
            sourceKey: sourceKey,
            cursorKind: cursorKind
        )] = cursorValue
        try persist(cursors)
    }

    public func validateReadableAndWritable() throws {
        _ = try loadAll()
        let probeURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".cursor-probe-\(UUID().uuidString.lowercased())")
        defer { try? fileManager.removeItem(at: probeURL) }
        try Data("{}".utf8).write(to: probeURL, options: [.atomic])
        try Self.applySensitiveFileAttributes(to: probeURL, fileManager: fileManager)
    }

    public func resetAll() throws {
        try persist([:])
    }

    private func loadAll() throws -> [String: String] {
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { throw FileSyncCursorStoreError.invalidData }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw FileSyncCursorStoreError.invalidData
        }
    }

    private func discardLegacyUnscopedValues() throws {
        let cursors = try loadAll()
        let scoped = cursors.filter { $0.key.hasPrefix(Self.versionedKeyPrefix) }
        if scoped.count != cursors.count {
            try persist(scoped)
        }
    }

    private func persist(_ cursors: [String: String]) throws {
        let data = try JSONEncoder().encode(cursors)
        try data.write(to: fileURL, options: [.atomic])
        try Self.applySensitiveFileAttributes(to: fileURL, fileManager: fileManager)
    }

    private static func key(receiverBindingID: String, sourceKey: String, cursorKind: String) -> String {
        "\(versionedKeyPrefix)\(receiverBindingID)#\(sourceKey)#\(cursorKind)"
    }

    private static func applySensitiveFileAttributes(to url: URL, fileManager: FileManager) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)

        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}

public struct SleepSyncPendingTransition: Codable, Equatable, Sendable {
    public let id: String
    public let payload: Data
    public let manifest: SleepSyncManifest
    public let receiverBindingID: String
    public let connectionGeneration: String
    public let outboxItemID: String?
    public let rejectedMinimumResetEpoch: UInt64?

    public init(
        id: String = UUID().uuidString.lowercased(),
        payload: Data,
        manifest: SleepSyncManifest,
        receiverBindingID: String,
        connectionGeneration: String,
        outboxItemID: String? = nil,
        rejectedMinimumResetEpoch: UInt64? = nil
    ) {
        self.id = id
        self.payload = payload
        self.manifest = manifest
        self.receiverBindingID = receiverBindingID
        self.connectionGeneration = connectionGeneration
        self.outboxItemID = outboxItemID
        self.rejectedMinimumResetEpoch = rejectedMinimumResetEpoch
    }

    public func assigningOutboxItemID(_ outboxItemID: String) -> SleepSyncPendingTransition {
        SleepSyncPendingTransition(
            id: id,
            payload: payload,
            manifest: manifest,
            receiverBindingID: receiverBindingID,
            connectionGeneration: connectionGeneration,
            outboxItemID: outboxItemID,
            rejectedMinimumResetEpoch: rejectedMinimumResetEpoch
        )
    }

    public func markingRejected(
        minimumResetEpoch: UInt64
    ) -> SleepSyncPendingTransition {
        SleepSyncPendingTransition(
            id: id,
            payload: payload,
            manifest: manifest,
            receiverBindingID: receiverBindingID,
            connectionGeneration: connectionGeneration,
            outboxItemID: outboxItemID,
            rejectedMinimumResetEpoch: minimumResetEpoch
        )
    }
}

public protocol SleepSyncManifestStoring {
    func loadManifest() throws -> SleepSyncManifest?
    func saveManifest(_ manifest: SleepSyncManifest) throws
    func loadPendingTransition() throws -> SleepSyncPendingTransition?
    func savePendingTransition(_ transition: SleepSyncPendingTransition) throws
    func clearPendingTransition(id: String) throws
    func resetSynchronizationState() throws
}

public final class FileSleepSyncManifestStore: SleepSyncManifestStoring {
    private let fileURL: URL
    private let pendingTransitionFileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) throws {
        self.fileURL = fileURL
        self.pendingTransitionFileURL = fileURL.appendingPathExtension("pending")
        self.fileManager = fileManager
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.applySensitiveFileAttributes(
            to: directory,
            permissions: 0o700,
            fileManager: fileManager
        )
        if fileManager.fileExists(atPath: fileURL.path) {
            try Self.applySensitiveFileAttributes(
                to: fileURL,
                permissions: 0o600,
                fileManager: fileManager
            )
        }
        if fileManager.fileExists(atPath: pendingTransitionFileURL.path) {
            try Self.applySensitiveFileAttributes(
                to: pendingTransitionFileURL,
                permissions: 0o600,
                fileManager: fileManager
            )
        }
    }

    public func loadManifest() throws -> SleepSyncManifest? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(SleepSyncManifest.self, from: data)
    }

    public func saveManifest(_ manifest: SleepSyncManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: fileURL, options: [.atomic])
        try Self.applySensitiveFileAttributes(
            to: fileURL,
            permissions: 0o600,
            fileManager: fileManager
        )
    }

    public func loadPendingTransition() throws -> SleepSyncPendingTransition? {
        guard fileManager.fileExists(atPath: pendingTransitionFileURL.path) else { return nil }
        let data = try Data(contentsOf: pendingTransitionFileURL)
        return try JSONDecoder().decode(SleepSyncPendingTransition.self, from: data)
    }

    public func savePendingTransition(_ transition: SleepSyncPendingTransition) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(transition)
        try data.write(to: pendingTransitionFileURL, options: [.atomic])
        try Self.applySensitiveFileAttributes(
            to: pendingTransitionFileURL,
            permissions: 0o600,
            fileManager: fileManager
        )
    }

    public func clearPendingTransition(id: String) throws {
        guard let pending = try loadPendingTransition() else { return }
        guard pending.id == id else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.removeItem(at: pendingTransitionFileURL)
    }

    public func resetSynchronizationState() throws {
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        if fileManager.fileExists(atPath: pendingTransitionFileURL.path) {
            try fileManager.removeItem(at: pendingTransitionFileURL)
        }
    }

    private static func applySensitiveFileAttributes(
        to url: URL,
        permissions: Int,
        fileManager: FileManager
    ) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
        try fileManager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )

        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}

public protocol ReceiverTokenStoring {
    func loadToken() throws -> String
    func saveToken(_ token: String) throws
}

public enum SleepResetEpochStoreError: Error, Equatable {
    case invalidStoredEpoch
    case exhausted
}

public final class SleepResetEpochStore {
    private let tokenStore: ReceiverTokenStoring
    private let epochFloorProvider: @Sendable () -> UInt64

    public init(
        tokenStore: ReceiverTokenStoring = KeychainReceiverTokenStore(
            service: "dev.healthbridge.companion",
            account: "sleep-reset-epoch"
        ),
        epochFloorProvider: @escaping @Sendable () -> UInt64 = {
            UInt64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.tokenStore = tokenStore
        self.epochFloorProvider = epochFloorProvider
    }

    public func reserveEpoch(after minimumEpoch: UInt64 = 0) throws -> UInt64 {
        let stored = try tokenStore.loadToken()
        let currentEpoch: UInt64
        if stored.isEmpty {
            currentEpoch = 0
        } else if let parsed = UInt64(stored) {
            currentEpoch = parsed
        } else {
            throw SleepResetEpochStoreError.invalidStoredEpoch
        }
        let durableFloor = max(currentEpoch, minimumEpoch)
        guard durableFloor < UInt64.max else {
            throw SleepResetEpochStoreError.exhausted
        }
        let next = max(durableFloor + 1, epochFloorProvider())
        try tokenStore.saveToken(String(next))
        return next
    }
}

public enum SleepBaselineRejectionRecoveryError: Error, Equatable {
    case missingPendingTransition
    case mismatchedOutboxItem
}

public enum SleepBaselineRejectionRecovery {
    public static func recover(
        itemID: String,
        minimumResetEpoch: UInt64,
        outbox: FileOutbox,
        manifestStore: SleepSyncManifestStoring,
        epochStore: SleepResetEpochStore
    ) throws {
        guard var pendingTransition = try manifestStore.loadPendingTransition() else {
            throw SleepBaselineRejectionRecoveryError.missingPendingTransition
        }
        var matchingItems = try matchingOutboxItems(
            pendingTransition,
            in: outbox
        )
        guard itemID.isEmpty
            || pendingTransition.outboxItemID == itemID
            || matchingItems.contains(where: { $0.id == itemID }) else {
            throw SleepBaselineRejectionRecoveryError.mismatchedOutboxItem
        }
        if pendingTransition.outboxItemID == nil,
           let rejectedItem = matchingItems.first(where: { $0.id == itemID }) {
            pendingTransition = pendingTransition.assigningOutboxItemID(rejectedItem.id)
        }
        let rejectedTransition = pendingTransition.markingRejected(
            minimumResetEpoch: max(
                minimumResetEpoch,
                pendingTransition.rejectedMinimumResetEpoch ?? 0
            )
        )
        try manifestStore.savePendingTransition(rejectedTransition)
        _ = try epochStore.reserveEpoch(
            after: rejectedTransition.rejectedMinimumResetEpoch ?? 0
        )
        matchingItems = try matchingOutboxItems(rejectedTransition, in: outbox)
        for item in matchingItems {
            try outbox.markUploaded(item)
        }
        try manifestStore.resetSynchronizationState()
    }

    private static func matchingOutboxItems(
        _ pendingTransition: SleepSyncPendingTransition,
        in outbox: FileOutbox
    ) throws -> [FileOutboxItem] {
        try outbox.pendingItems().filter { item in
            if item.id == pendingTransition.outboxItemID {
                return true
            }
            guard item.receiverIdentity == pendingTransition.receiverBindingID else {
                return false
            }
            return try Data(contentsOf: item.fileURL) == pendingTransition.payload
        }
    }
}

public enum KeychainReceiverTokenStoreError: Error, Equatable, LocalizedError {
    case unavailable
    case invalidData
    case unexpectedStatus(Int32)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Keychain is not available on this platform."
        case .invalidData:
            "Keychain item data is missing or invalid."
        case .unexpectedStatus(let status):
            "Keychain operation failed with status \(status)."
        }
    }
}

public final class KeychainReceiverTokenStore: ReceiverTokenStoring {
    private let service: String
    private let account: String

    public init(service: String = HealthBridgeAppIdentity.keychainServiceName, account: String = "bearer-token") {
        self.service = service
        self.account = account
    }

    static func decodeTokenData(_ data: Data?) throws -> String {
        guard let data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            throw KeychainReceiverTokenStoreError.invalidData
        }
        return token
    }

    public func loadToken() throws -> String {
        #if canImport(Security)
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return ""
        }
        guard status == errSecSuccess else {
            throw KeychainReceiverTokenStoreError.unexpectedStatus(status)
        }
        return try Self.decodeTokenData(item as? Data)
        #else
        throw KeychainReceiverTokenStoreError.unavailable
        #endif
    }

    public func saveToken(_ token: String) throws {
        #if canImport(Security)
        let data = Data(token.utf8)
        var query = baseQuery()
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw KeychainReceiverTokenStoreError.unexpectedStatus(status)
            }
            return
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainReceiverTokenStoreError.unexpectedStatus(updateStatus)
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainReceiverTokenStoreError.unexpectedStatus(addStatus)
        }
        #else
        throw KeychainReceiverTokenStoreError.unavailable
        #endif
    }

    #if canImport(Security)
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
    #endif
}

public struct ReceiverPendingPairing: Codable, Equatable, Sendable {
    public let label: String
    public let receiverURLString: String
    public let redeemURLString: String
    public let invitationSecret: String?
    public let invitationCode: String?
    public let installationID: String
    public let deviceCredential: String
    public let platform: String
    public let transport: ReceiverPairingTransport

    public init(
        label: String,
        receiverURLString: String,
        redeemURLString: String,
        invitationSecret: String?,
        invitationCode: String?,
        installationID: String,
        deviceCredential: String,
        platform: String,
        transport: ReceiverPairingTransport = .direct
    ) {
        self.label = label
        self.receiverURLString = receiverURLString
        self.redeemURLString = redeemURLString
        self.invitationSecret = invitationSecret
        self.invitationCode = invitationCode
        self.installationID = installationID
        self.deviceCredential = deviceCredential
        self.platform = platform
        self.transport = transport
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case receiverURLString
        case redeemURLString
        case invitationSecret
        case invitationCode
        case installationID
        case deviceCredential
        case platform
        case transport
        case mailboxProtocolVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        receiverURLString = try container.decode(String.self, forKey: .receiverURLString)
        redeemURLString = try container.decode(String.self, forKey: .redeemURLString)
        invitationSecret = try container.decodeIfPresent(String.self, forKey: .invitationSecret)
        invitationCode = try container.decodeIfPresent(String.self, forKey: .invitationCode)
        installationID = try container.decode(String.self, forKey: .installationID)
        deviceCredential = try container.decode(String.self, forKey: .deviceCredential)
        platform = try container.decode(String.self, forKey: .platform)
        let decodedTransport = try container.decodeIfPresent(
            ReceiverPairingTransport.self,
            forKey: .transport
        )
        let legacyMailboxProtocolVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .mailboxProtocolVersion
        )
        switch (decodedTransport, legacyMailboxProtocolVersion) {
        case (.some(.direct), nil), (nil, nil):
            transport = .direct
        case (.some(.mailbox), nil), (.some(.mailbox), 1):
            transport = .mailbox
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .transport,
                in: container,
                debugDescription: "Pending pairing transport is inconsistent."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(receiverURLString, forKey: .receiverURLString)
        try container.encode(redeemURLString, forKey: .redeemURLString)
        try container.encodeIfPresent(invitationSecret, forKey: .invitationSecret)
        try container.encodeIfPresent(invitationCode, forKey: .invitationCode)
        try container.encode(installationID, forKey: .installationID)
        try container.encode(deviceCredential, forKey: .deviceCredential)
        try container.encode(platform, forKey: .platform)
        try container.encode(transport, forKey: .transport)
        if transport == .mailbox {
            try container.encode(1, forKey: .mailboxProtocolVersion)
        }
    }

    func matches(
        receiverURLString: String,
        redeemURLString: String,
        invitationSecret: String?,
        invitationCode: String?,
        transport: ReceiverPairingTransport = .direct
    ) -> Bool {
        self.receiverURLString == receiverURLString
            && self.redeemURLString == redeemURLString
            && self.invitationSecret == invitationSecret
            && self.invitationCode == invitationCode
            && self.transport == transport
            && platform == "ios"
    }
}

public enum ReceiverPairingStateError: LocalizedError, Equatable {
    case pendingPairingConflict
    case legacyCancellationRequiresRetry

    public var errorDescription: String? {
        switch self {
        case .pendingPairingConflict:
            "A different pairing is already pending. Resume or cancel it before starting another pairing."
        case .legacyCancellationRequiresRetry:
            "A cancellation from an older app version has unknown connection scope. Confirm Cancel Pending Pairing again to clear it safely."
        }
    }
}

public final class ReceiverPairingStateStore {
    private static let legacyCancellationToken = "cancel-requested"
    private static let cancellationGenerationPrefix = "generation:"
    private let pendingStore: ReceiverTokenStoring
    private let installationIDStore: ReceiverTokenStoring
    private let cancellationStore: ReceiverTokenStoring
    private let installationIDGenerator: () -> String
    private let deviceCredentialGenerator: () -> String

    public init(
        pendingStore: ReceiverTokenStoring = KeychainReceiverTokenStore(account: "pending-pairing"),
        installationIDStore: ReceiverTokenStoring = KeychainReceiverTokenStore(account: "pairing-installation-id"),
        cancellationStore: ReceiverTokenStoring = KeychainReceiverTokenStore(account: "pairing-cancellation"),
        installationIDGenerator: @escaping () -> String = { UUID().uuidString.lowercased() },
        deviceCredentialGenerator: @escaping () -> String = {
            var generator = SystemRandomNumberGenerator()
            let suffix = (0..<32).map { _ in
                String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
            }.joined()
            return "hb_\(suffix)"
        }
    ) {
        self.pendingStore = pendingStore
        self.installationIDStore = installationIDStore
        self.cancellationStore = cancellationStore
        self.installationIDGenerator = installationIDGenerator
        self.deviceCredentialGenerator = deviceCredentialGenerator
    }

    public func stage(invitation: ReceiverPairingInvitation) throws -> ReceiverPendingPairing {
        try stage(
            label: invitation.label,
            receiverURLString: invitation.receiverURLString,
            redeemURLString: invitation.redeemURLString,
            invitationSecret: invitation.invitationSecret,
            invitationCode: nil,
            transport: invitation.transport
        )
    }

    public func stage(manualPairing: ReceiverManualPairing) throws -> ReceiverPendingPairing {
        try stage(
            label: "iOS companion",
            receiverURLString: manualPairing.receiverURL.absoluteString,
            redeemURLString: manualPairing.redeemURL.absoluteString,
            invitationSecret: nil,
            invitationCode: manualPairing.invitationCode,
            transport: .direct
        )
    }

    public func loadPending() throws -> ReceiverPendingPairing? {
        let encoded = try pendingStore.loadToken()
        guard !encoded.isEmpty else { return nil }
        return try JSONDecoder().decode(ReceiverPendingPairing.self, from: Data(encoded.utf8))
    }

    public func clearPending() throws {
        try pendingStore.saveToken("")
    }

    public func resetPrivatePairingState() throws {
        try clearPending()
        try finishPendingCancellation()
    }

    public func loadOrCreateInstallationID() throws -> String {
        var installationID = try installationIDStore.loadToken()
        if installationID.isEmpty {
            installationID = installationIDGenerator()
            try installationIDStore.saveToken(installationID)
        }
        return installationID
    }

    public func hasPendingCancellation() throws -> Bool {
        try !cancellationStore.loadToken().isEmpty
    }

    public func pendingCancellationExpectedGeneration() throws -> String? {
        let marker = try cancellationStore.loadToken()
        guard marker.hasPrefix(Self.cancellationGenerationPrefix) else { return nil }
        let generation = String(marker.dropFirst(Self.cancellationGenerationPrefix.count))
        return generation.isEmpty ? nil : generation
    }

    public func beginPendingCancellation(expectedGeneration: String) throws {
        try cancellationStore.saveToken(
            Self.cancellationGenerationPrefix + expectedGeneration
        )
    }

    @available(*, deprecated, message: "Use beginPendingCancellation(expectedGeneration:) so the marker cannot clear a later connection.")
    public func beginPendingCancellation() throws {
        try cancellationStore.saveToken(Self.legacyCancellationToken)
    }

    public func finishPendingCancellation() throws {
        try cancellationStore.saveToken("")
    }

    private func stage(
        label: String,
        receiverURLString: String,
        redeemURLString: String,
        invitationSecret: String?,
        invitationCode: String?,
        transport: ReceiverPairingTransport
    ) throws -> ReceiverPendingPairing {
        guard try !hasPendingCancellation() else {
            throw ReceiverPairingStateError.pendingPairingConflict
        }
        if let existing = try loadPending() {
            guard existing.matches(
                receiverURLString: receiverURLString,
                redeemURLString: redeemURLString,
                invitationSecret: invitationSecret,
                invitationCode: invitationCode,
                transport: transport
            ) else {
                throw ReceiverPairingStateError.pendingPairingConflict
            }
            return existing
        }
        let installationID = try loadOrCreateInstallationID()
        let pending = ReceiverPendingPairing(
            label: label,
            receiverURLString: receiverURLString,
            redeemURLString: redeemURLString,
            invitationSecret: invitationSecret,
            invitationCode: invitationCode,
            installationID: installationID,
            deviceCredential: deviceCredentialGenerator(),
            platform: "ios",
            transport: transport
        )
        let encoded = try JSONEncoder().encode(pending)
        guard let string = String(data: encoded, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try pendingStore.saveToken(string)
        return pending
    }
}

public enum ReceiverSettingsGenerationError: Error, Equatable, Sendable {
    case staleGeneration
}

public enum ReceiverSettingsRecordError: Error, Equatable, Sendable {
    case invalidRecord
    case legacyRecordRequiresRepair
    case persistenceFailed
    case destructiveResetNotRequired
    case transportSwitchRequiresCommittedEmptyOutbox
}

public enum ReceiverConnectionRecordRecoveryPolicy {
    public static func requiresDestructiveRecovery(_ error: Error) -> Bool {
        if let recordError = error as? ReceiverSettingsRecordError {
            return recordError == .invalidRecord || recordError == .legacyRecordRequiresRepair
        }
        return (error as? KeychainReceiverTokenStoreError) == .invalidData
    }
}

public enum ReceiverOutboxAdmissionPolicy {
    public static func isReady(
        pendingReceiverIdentities: [String?],
        currentBindingID: String?,
        hasBearerToken: Bool
    ) -> Bool {
        if let currentBindingID, hasBearerToken {
            return pendingReceiverIdentities.allSatisfy { $0 == currentBindingID }
        }
        guard currentBindingID == nil, !hasBearerToken else {
            return false
        }
        return pendingReceiverIdentities.isEmpty
    }
}

public enum ReceiverConnectionTransitionPolicy {
    public static func pairingCommitBarrierFailure(
        outboxIdentityAdmissionReady: Bool,
        pendingItemCount: Int,
        clearIntentIsActive: Bool
    ) -> ReceiverPairingCommitBarrierError? {
        if !outboxIdentityAdmissionReady { return .outboxIdentityAdmissionNotReady }
        if pendingItemCount != 0 { return .outboxNotEmpty }
        if clearIntentIsActive { return .outboxClearIntentActive }
        return nil
    }

    public static func canBegin(
        outboxIdentityAdmissionReady: Bool,
        pendingItemCount: Int,
        clearIntentIsActive: Bool
    ) -> Bool {
        pairingCommitBarrierFailure(
            outboxIdentityAdmissionReady: outboxIdentityAdmissionReady,
            pendingItemCount: pendingItemCount,
            clearIntentIsActive: clearIntentIsActive
        ) == nil
    }
}

public struct ReceiverLocalConnectionScopeV1: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let bindingID: String

    public init(generation: UInt64, bindingID: String) {
        self.generation = generation
        self.bindingID = bindingID
    }
}

public enum MailboxConnectionIdentityUnavailableReason: String, Codable, Equatable, Sendable {
    case notProvisionedByLegacyHTTPPairing
}

public struct MailboxConnectionIdentityV1: Codable, Equatable, Sendable {
    public let receiverID: String
    public let deviceID: String
    public let devicePrincipal: String
    public let deviceSigningKeyID: String
    public let deviceAgreementKeyID: String
    public let receiverSigningKeyID: String
    public let receiverAgreementKeyID: String
    public let receiverSigningPublicKey: String
    public let receiverAgreementPublicKey: String
    public let opaqueBinding: String
    public let connectionGeneration: UInt64

    public init(
        receiverID: String,
        deviceID: String,
        devicePrincipal: String,
        deviceSigningKeyID: String,
        deviceAgreementKeyID: String,
        receiverSigningKeyID: String,
        receiverAgreementKeyID: String,
        receiverSigningPublicKey: String,
        receiverAgreementPublicKey: String,
        opaqueBinding: String,
        connectionGeneration: UInt64
    ) {
        self.receiverID = receiverID
        self.deviceID = deviceID
        self.devicePrincipal = devicePrincipal
        self.deviceSigningKeyID = deviceSigningKeyID
        self.deviceAgreementKeyID = deviceAgreementKeyID
        self.receiverSigningKeyID = receiverSigningKeyID
        self.receiverAgreementKeyID = receiverAgreementKeyID
        self.receiverSigningPublicKey = receiverSigningPublicKey
        self.receiverAgreementPublicKey = receiverAgreementPublicKey
        self.opaqueBinding = opaqueBinding
        self.connectionGeneration = connectionGeneration
    }
}

public enum MailboxConnectionIdentityAvailability: Codable, Equatable, Sendable {
    case unavailable(MailboxConnectionIdentityUnavailableReason)
    case available(MailboxConnectionIdentityV1)

    private enum CodingKeys: String, CodingKey {
        case availability
        case reason
        case identity
    }

    private enum Availability: String, Codable {
        case unavailable
        case available
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Availability.self, forKey: .availability) {
        case .unavailable:
            guard !container.contains(.identity) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .identity,
                    in: container,
                    debugDescription: "Unavailable mailbox identity cannot contain identity data."
                )
            }
            self = .unavailable(
                try container.decode(
                    MailboxConnectionIdentityUnavailableReason.self,
                    forKey: .reason
                )
            )
        case .available:
            guard !container.contains(.reason) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .reason,
                    in: container,
                    debugDescription: "Available mailbox identity cannot contain an unavailable reason."
                )
            }
            self = .available(
                try container.decode(MailboxConnectionIdentityV1.self, forKey: .identity)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unavailable(let reason):
            try container.encode(Availability.unavailable, forKey: .availability)
            try container.encode(reason, forKey: .reason)
        case .available(let identity):
            try container.encode(Availability.available, forKey: .availability)
            try container.encode(identity, forKey: .identity)
        }
    }
}

public enum ReceiverTransportKind: String, Codable, Equatable, Hashable, Sendable {
    case directHTTP
    case mailbox
}

public enum ReceiverTransportActivation: String, Codable, Equatable, Sendable {
    case active
    case inactive
}

public struct DirectHTTPConnectionConfigurationV1: Codable, Equatable, Sendable {
    public let receiverURLString: String
    public let bearerToken: String

    public init(receiverURLString: String, bearerToken: String) {
        self.receiverURLString = receiverURLString
        self.bearerToken = bearerToken
    }
}

public struct MailboxConnectionConfigurationV1: Codable, Equatable, Sendable {
    public let protocolVersion: Int

    public init(protocolVersion: Int = 1) {
        self.protocolVersion = protocolVersion
    }
}

public enum ReceiverTransportConfigurationV1: Codable, Equatable, Sendable {
    case directHTTP(
        activation: ReceiverTransportActivation,
        configuration: DirectHTTPConnectionConfigurationV1
    )
    case mailbox(
        activation: ReceiverTransportActivation,
        configuration: MailboxConnectionConfigurationV1
    )

    public var transport: ReceiverTransportKind {
        switch self {
        case .directHTTP: .directHTTP
        case .mailbox: .mailbox
        }
    }

    public var activation: ReceiverTransportActivation {
        switch self {
        case .directHTTP(let activation, _), .mailbox(let activation, _): activation
        }
    }
}

public enum ReceiverConnectionActivationV2: Codable, Equatable, Sendable {
    case unpaired
    case paired(activeTransport: ReceiverTransportKind)

    private enum CodingKeys: String, CodingKey {
        case state
        case activeTransport
    }

    private enum State: String, Codable {
        case unpaired
        case paired
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .unpaired:
            guard !container.contains(.activeTransport) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .activeTransport,
                    in: container,
                    debugDescription: "Unpaired state cannot name an active transport."
                )
            }
            self = .unpaired
        case .paired:
            self = .paired(
                activeTransport: try container.decode(
                    ReceiverTransportKind.self,
                    forKey: .activeTransport
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unpaired:
            try container.encode(State.unpaired, forKey: .state)
        case .paired(let activeTransport):
            try container.encode(State.paired, forKey: .state)
            try container.encode(activeTransport, forKey: .activeTransport)
        }
    }
}

public struct ReceiverConnectionRecordV2: Codable, Equatable, Sendable {
    public let version: Int
    public let localScope: ReceiverLocalConnectionScopeV1
    public let mailboxIdentity: MailboxConnectionIdentityAvailability
    public let activation: ReceiverConnectionActivationV2
    public let transportConfigurations: [ReceiverTransportConfigurationV1]

    public init(
        localScope: ReceiverLocalConnectionScopeV1,
        mailboxIdentity: MailboxConnectionIdentityAvailability,
        activation: ReceiverConnectionActivationV2,
        transportConfigurations: [ReceiverTransportConfigurationV1]
    ) {
        version = 2
        self.localScope = localScope
        self.mailboxIdentity = mailboxIdentity
        self.activation = activation
        self.transportConfigurations = transportConfigurations
    }
}

public final class ReceiverSettingsStore {
    public static let defaultReceiverURLString = "http://127.0.0.1:8765/v1/batches"

    private struct ConnectionRecordV1: Codable {
        let version: Int
        let receiverURLString: String
        let bearerToken: String
        let generation: UInt64
        let bindingID: String
    }

    private struct StrictConnectionRecordV1JSONParser {
        private let bytes: [UInt8]
        private var index = 0

        init(data: Data) {
            bytes = Array(data)
        }

        mutating func parse() throws -> ConnectionRecordV1 {
            try consume(0x7B)
            var seen = Set<String>()
            var version: UInt64?
            var receiverURLString: String?
            var bearerToken: String?
            var generation: UInt64?
            var bindingID: String?

            for memberIndex in 0 ..< 5 {
                if memberIndex > 0 {
                    try consume(0x2C)
                }
                skipWhitespace()
                let key = try parseString()
                guard seen.insert(key).inserted else {
                    throw ReceiverSettingsRecordError.invalidRecord
                }
                try consume(0x3A)
                skipWhitespace()
                switch key {
                case "version":
                    version = try parseUnsignedInteger()
                case "receiverURLString":
                    receiverURLString = try parseString()
                case "bearerToken":
                    bearerToken = try parseString()
                case "generation":
                    generation = try parseUnsignedInteger()
                case "bindingID":
                    bindingID = try parseString()
                default:
                    throw ReceiverSettingsRecordError.invalidRecord
                }
            }

            try consume(0x7D)
            skipWhitespace()
            guard index == bytes.count,
                  version == 1,
                  let receiverURLString,
                  let bearerToken,
                  let generation,
                  let bindingID else {
                throw ReceiverSettingsRecordError.invalidRecord
            }
            return ConnectionRecordV1(
                version: 1,
                receiverURLString: receiverURLString,
                bearerToken: bearerToken,
                generation: generation,
                bindingID: bindingID
            )
        }

        private mutating func parseString() throws -> String {
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw ReceiverSettingsRecordError.invalidRecord
            }
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case 0x22:
                    let encoded = Data(bytes[start ..< index])
                    guard let value = try? JSONDecoder().decode(String.self, from: encoded) else {
                        throw ReceiverSettingsRecordError.invalidRecord
                    }
                    return value
                case 0x5C:
                    try consumeStringEscape()
                case 0x00 ..< 0x20:
                    throw ReceiverSettingsRecordError.invalidRecord
                default:
                    continue
                }
            }
            throw ReceiverSettingsRecordError.invalidRecord
        }

        private mutating func consumeStringEscape() throws {
            guard index < bytes.count else {
                throw ReceiverSettingsRecordError.invalidRecord
            }
            let escaped = bytes[index]
            index += 1
            if escaped == 0x75 {
                for _ in 0 ..< 4 {
                    guard index < bytes.count, Self.isHexDigit(bytes[index]) else {
                        throw ReceiverSettingsRecordError.invalidRecord
                    }
                    index += 1
                }
                return
            }
            guard [0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escaped) else {
                throw ReceiverSettingsRecordError.invalidRecord
            }
        }

        private mutating func parseUnsignedInteger() throws -> UInt64 {
            guard index < bytes.count, Self.isDigit(bytes[index]) else {
                throw ReceiverSettingsRecordError.invalidRecord
            }
            if bytes[index] == 0x30 {
                index += 1
                guard index == bytes.count || !Self.isDigit(bytes[index]) else {
                    throw ReceiverSettingsRecordError.invalidRecord
                }
                return 0
            }
            var value: UInt64 = 0
            while index < bytes.count, Self.isDigit(bytes[index]) {
                let digit = UInt64(bytes[index] - 0x30)
                let multiplied = value.multipliedReportingOverflow(by: 10)
                let added = multiplied.partialValue.addingReportingOverflow(digit)
                guard !multiplied.overflow, !added.overflow else {
                    throw ReceiverSettingsRecordError.invalidRecord
                }
                value = added.partialValue
                index += 1
            }
            return value
        }

        private mutating func consume(_ expected: UInt8) throws {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == expected else {
                throw ReceiverSettingsRecordError.invalidRecord
            }
            index += 1
        }

        private mutating func skipWhitespace() {
            while index < bytes.count,
                  bytes[index] == 0x20 || bytes[index] == 0x09
                    || bytes[index] == 0x0A || bytes[index] == 0x0D {
                index += 1
            }
        }

        private static func isDigit(_ byte: UInt8) -> Bool {
            byte >= 0x30 && byte <= 0x39
        }

        private static func isHexDigit(_ byte: UInt8) -> Bool {
            isDigit(byte)
                || (byte >= 0x41 && byte <= 0x46)
                || (byte >= 0x61 && byte <= 0x66)
        }
    }

    private enum StoredConnectionRecord {
        case v1(record: ConnectionRecordV1, raw: String)
        case v2(ReceiverConnectionRecordV2)
    }

    private static let recordPrefixV1 = "health-bridge-connection-v1:"
    private static let recordPrefixV2 = "health-bridge-connection-v2:"
    private let userDefaults: UserDefaults
    private let tokenStore: ReceiverTokenStoring
    private let preCutoverBackupStore: ReceiverTokenStoring
    private let synchronizeUserDefaults: () -> Bool
    private let receiverURLKey = "receiverURLString"
    private let receiverSettingsGenerationKey = "receiverSettingsGeneration"
    private let terminalCancellationGenerationKey = "receiverTerminalCancellationGeneration"

    public init(
        userDefaults: UserDefaults = .standard,
        tokenStore: ReceiverTokenStoring = KeychainReceiverTokenStore(),
        preCutoverBackupStore: ReceiverTokenStoring = KeychainReceiverTokenStore(
            account: "pre-v2-connection-record-backup"
        ),
        synchronize: (() -> Bool)? = nil
    ) {
        self.userDefaults = userDefaults
        self.tokenStore = tokenStore
        self.preCutoverBackupStore = preCutoverBackupStore
        self.synchronizeUserDefaults = synchronize ?? { userDefaults.synchronize() }
    }

    public var receiverURLString: String {
        if let stored = try? loadStoredConnectionRecord() {
            return directHTTPConfiguration(in: stored)?.receiverURLString
                ?? Self.defaultReceiverURLString
        }
        return userDefaults.string(forKey: receiverURLKey) ?? Self.defaultReceiverURLString
    }

    public var receiverSettingsGeneration: UInt64 {
        if let stored = try? loadStoredConnectionRecord() {
            return localScope(in: stored).generation
        }
        return UInt64(max(0, userDefaults.integer(forKey: receiverSettingsGenerationKey)))
    }

    public var receiverSettingsGenerationToken: String {
        "g\(receiverSettingsGeneration)"
    }

    public var receiverBindingID: String? {
        guard let stored = try? loadStoredConnectionRecord(),
              let direct = directHTTPConfiguration(in: stored),
              !direct.bearerToken.isEmpty,
              !localScope(in: stored).bindingID.isEmpty else {
            return nil
        }
        return localScope(in: stored).bindingID
    }

    public var activeTransport: ReceiverTransportKind? {
        guard let record = try? currentConnectionRecordV2() else { return nil }
        guard case .paired(let activeTransport) = record.activation else { return nil }
        return activeTransport
    }

    @discardableResult
    public func ensureAtomicConnectionRecord() throws -> String? {
        if let stored = try loadStoredConnectionRecord() {
            let record: ReceiverConnectionRecordV2
            switch stored {
            case .v1(let legacy, _):
                record = projectedV2(from: legacy)
            case .v2(let current):
                try restorePreCutoverV1IfExactMatch(current)
                record = current
            }
            return directHTTPConfiguration(in: record)?.bearerToken.isEmpty == false
                ? record.localScope.bindingID
                : nil
        }
        let legacyToken = try tokenStore.loadToken()
        let explicitLegacyURL = userDefaults.string(forKey: receiverURLKey)
        if legacyToken.isEmpty, explicitLegacyURL == nil {
            return nil
        }
        guard !legacyToken.isEmpty,
              let explicitLegacyURL,
              !explicitLegacyURL.isEmpty else {
            throw ReceiverSettingsRecordError.invalidRecord
        }
        // Older app versions wrote URL and token separately. Even when both values
        // are present, there is no durable proof that they belong together. Never
        // send a legacy token to an unverifiable URL; require an explicit reset and
        // re-pair instead.
        throw ReceiverSettingsRecordError.legacyRecordRequiresRepair
    }

    public func currentConnectionRecordV2() throws -> ReceiverConnectionRecordV2? {
        _ = try ensureAtomicConnectionRecord()
        guard let stored = try loadStoredConnectionRecord() else { return nil }
        switch stored {
        case .v1(let legacy, _):
            return projectedV2(from: legacy)
        case .v2(let record):
            return record
        }
    }

    @discardableResult
    public func invalidateReceiverSettingsGeneration() throws -> String {
        let current = try authoritativeRecordForMutation()
        let record = ReceiverConnectionRecordV2(
            localScope: ReceiverLocalConnectionScopeV1(
                generation: try Self.nextGeneration(after: current.localScope.generation),
                bindingID: current.localScope.bindingID
            ),
            mailboxIdentity: current.mailboxIdentity,
            activation: current.activation,
            transportConfigurations: current.transportConfigurations
        )
        try persist(record)
        return "g\(record.localScope.generation)"
    }

    public func loadBearerToken() throws -> String {
        if let stored = try loadStoredConnectionRecord() {
            return directHTTPConfiguration(in: stored)?.bearerToken ?? ""
        }
        return try tokenStore.loadToken()
    }

    public func receiverSettingsAreCleared() throws -> Bool {
        if let stored = try loadStoredConnectionRecord() {
            switch stored {
            case .v1(let record, _):
                return record.receiverURLString == Self.defaultReceiverURLString
                    && record.bearerToken.isEmpty
                    && record.bindingID.isEmpty
            case .v2(let record):
                return record.activation == .unpaired
                    && record.transportConfigurations.isEmpty
                    && record.localScope.bindingID.isEmpty
            }
        }
        let legacyToken = try tokenStore.loadToken()
        let explicitLegacyURL = userDefaults.string(forKey: receiverURLKey)
        return legacyToken.isEmpty
            && (explicitLegacyURL == nil || explicitLegacyURL == Self.defaultReceiverURLString)
    }

    public func save(
        receiverURLString newReceiverURLString: String,
        bearerToken newBearerToken: String,
        rotateBindingID: Bool = false
    ) throws {
        let previous = try authoritativeRecordForMutation()
        if case .paired(activeTransport: .mailbox) = previous.activation {
            throw ReceiverSettingsRecordError.transportSwitchRequiresCommittedEmptyOutbox
        }
        let previousDirect = directHTTPConfiguration(in: previous)
        let settingsChanged = rotateBindingID
            || previousDirect?.receiverURLString != newReceiverURLString
            || previousDirect?.bearerToken != newBearerToken
        let record = ReceiverConnectionRecordV2(
            localScope: ReceiverLocalConnectionScopeV1(
                generation: settingsChanged
                    ? try Self.nextGeneration(after: previous.localScope.generation)
                    : previous.localScope.generation,
                bindingID: settingsChanged || previous.localScope.bindingID.isEmpty
                ? UUID().uuidString.lowercased()
                : previous.localScope.bindingID
            ),
            mailboxIdentity: .unavailable(.notProvisionedByLegacyHTTPPairing),
            activation: .paired(activeTransport: .directHTTP),
            transportConfigurations: [
                .directHTTP(
                    activation: .active,
                    configuration: DirectHTTPConnectionConfigurationV1(
                        receiverURLString: newReceiverURLString,
                        bearerToken: newBearerToken
                    )
                ),
            ]
        )
        try persist(record)
    }

    public func saveMailboxPairing(
        receiverURLString: String,
        bearerToken: String,
        mailboxIdentity: MailboxConnectionIdentityV1,
        expectedGeneration: String
    ) throws {
        let previous = try authoritativeRecordForMutation()
        guard "g\(previous.localScope.generation)" == expectedGeneration else {
            throw ReceiverSettingsGenerationError.staleGeneration
        }
        let direct = DirectHTTPConnectionConfigurationV1(
            receiverURLString: receiverURLString,
            bearerToken: bearerToken
        )
        if case .paired(activeTransport: .mailbox) = previous.activation {
            let expected = ReceiverConnectionRecordV2(
                localScope: previous.localScope,
                mailboxIdentity: .available(mailboxIdentity),
                activation: .paired(activeTransport: .mailbox),
                transportConfigurations: [
                    .directHTTP(activation: .inactive, configuration: direct),
                    .mailbox(
                        activation: .active,
                        configuration: MailboxConnectionConfigurationV1()
                    ),
                ]
            )
            guard previous == expected else {
                throw ReceiverSettingsRecordError
                    .transportSwitchRequiresCommittedEmptyOutbox
            }
            return
        }
        let record = ReceiverConnectionRecordV2(
            localScope: ReceiverLocalConnectionScopeV1(
                generation: try Self.nextGeneration(after: previous.localScope.generation),
                bindingID: mailboxIdentity.opaqueBinding
            ),
            mailboxIdentity: .available(mailboxIdentity),
            activation: .paired(activeTransport: .mailbox),
            transportConfigurations: [
                .directHTTP(activation: .inactive, configuration: direct),
                .mailbox(
                    activation: .active,
                    configuration: MailboxConnectionConfigurationV1()
                ),
            ]
        )
        try persist(record)
    }

    public func save(
        receiverURLString newReceiverURLString: String,
        bearerToken newBearerToken: String,
        expectedGeneration: String,
        rotateBindingID: Bool = false
    ) throws {
        try requireCurrentGeneration(expectedGeneration)
        try save(
            receiverURLString: newReceiverURLString,
            bearerToken: newBearerToken,
            rotateBindingID: rotateBindingID
        )
    }

    public func clearReceiverSettings() throws {
        let previous = try authoritativeRecordForMutation()
        if case .paired(activeTransport: .mailbox) = previous.activation {
            throw ReceiverSettingsRecordError.transportSwitchRequiresCommittedEmptyOutbox
        }
        let settingsChanged = previous.activation != .unpaired
            || !previous.transportConfigurations.isEmpty
        let record = ReceiverConnectionRecordV2(
            localScope: ReceiverLocalConnectionScopeV1(
                generation: settingsChanged
                    ? try Self.nextGeneration(after: previous.localScope.generation)
                    : previous.localScope.generation,
                bindingID: ""
            ),
            mailboxIdentity: .unavailable(.notProvisionedByLegacyHTTPPairing),
            activation: .unpaired,
            transportConfigurations: []
        )
        try persist(record)
    }

    public func clearReceiverSettings(expectedGeneration: String) throws {
        try requireCurrentGeneration(expectedGeneration)
        try clearReceiverSettings()
    }

    public func resetInvalidConnectionRecord() throws {
        do {
            if try loadStoredConnectionRecord() != nil {
                throw ReceiverSettingsRecordError.destructiveResetNotRequired
            }
            let legacyToken = try tokenStore.loadToken()
            let explicitLegacyURL = userDefaults.string(forKey: receiverURLKey)
            if legacyToken.isEmpty, explicitLegacyURL == nil {
                throw ReceiverSettingsRecordError.destructiveResetNotRequired
            }
            // Any legacy tuple is unverifiable because older app versions wrote
            // URL and token separately. It is safe to reset only after the caller
            // has put the app into explicit private-state recovery.
        } catch ReceiverSettingsRecordError.invalidRecord {
            // A malformed prefixed atomic record is also confirmed invalid.
        } catch KeychainReceiverTokenStoreError.invalidData {
            // Empty or non-UTF8 Keychain data cannot be interpreted, but can be
            // overwritten by the explicit recovery action.
        }
        let mirroredGeneration = UInt64(max(0, userDefaults.integer(forKey: receiverSettingsGenerationKey)))
        var replacementGeneration = UInt64.random(in: 1 ... UInt64(Int.max))
        while replacementGeneration == mirroredGeneration {
            replacementGeneration = UInt64.random(in: 1 ... UInt64(Int.max))
        }
        let record = ReceiverConnectionRecordV2(
            localScope: ReceiverLocalConnectionScopeV1(
                generation: replacementGeneration,
                bindingID: ""
            ),
            mailboxIdentity: .unavailable(.notProvisionedByLegacyHTTPPairing),
            activation: .unpaired,
            transportConfigurations: []
        )
        try persist(record, preservingCurrentV1: false)
        userDefaults.removeObject(forKey: terminalCancellationGenerationKey)
        guard synchronizeUserDefaults() else {
            throw ReceiverSettingsRecordError.persistenceFailed
        }
    }

    public func beginTerminalCancellationIntent(expectedGeneration: String) throws {
        userDefaults.set(expectedGeneration, forKey: terminalCancellationGenerationKey)
        guard synchronizeUserDefaults() else {
            throw ReceiverSettingsRecordError.persistenceFailed
        }
    }

    public var terminalCancellationExpectedGeneration: String? {
        userDefaults.string(forKey: terminalCancellationGenerationKey)
    }

    public func finishTerminalCancellationIntent() throws {
        let pendingGeneration = userDefaults.string(
            forKey: terminalCancellationGenerationKey
        )
        userDefaults.removeObject(forKey: terminalCancellationGenerationKey)
        guard synchronizeUserDefaults() else {
            if let pendingGeneration {
                userDefaults.set(
                    pendingGeneration,
                    forKey: terminalCancellationGenerationKey
                )
            }
            throw ReceiverSettingsRecordError.persistenceFailed
        }
    }

    public func resolveTerminalCancellationForPrivateReset() throws {
        guard let cancellationGeneration = terminalCancellationExpectedGeneration else {
            return
        }
        if cancellationGeneration == receiverSettingsGenerationToken {
            try clearReceiverSettings(expectedGeneration: cancellationGeneration)
        }
        try finishTerminalCancellationIntent()
    }

    private func loadStoredConnectionRecord() throws -> StoredConnectionRecord? {
        let raw = try tokenStore.loadToken()
        if raw.hasPrefix(Self.recordPrefixV2) {
            let encoded = String(raw.dropFirst(Self.recordPrefixV2.count))
            guard let data = Data(base64Encoded: encoded),
                  data.base64EncodedString() == encoded,
                  let record = try? JSONDecoder().decode(
                      ReceiverConnectionRecordV2.self,
                      from: data
                  ) else {
                throw ReceiverSettingsRecordError.invalidRecord
            }
            try Self.validate(record)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let canonical = try? encoder.encode(record), canonical == data else {
                throw ReceiverSettingsRecordError.invalidRecord
            }
            return .v2(record)
        }
        if raw.hasPrefix(Self.recordPrefixV1) {
            let record = try decodeStrictV1(raw)
            return .v1(record: record, raw: raw)
        }
        return nil
    }

    private func authoritativeRecordForMutation() throws -> ReceiverConnectionRecordV2 {
        if let stored = try loadStoredConnectionRecord() {
            switch stored {
            case .v1(let legacy, _):
                return projectedV2(from: legacy)
            case .v2(let record):
                return record
            }
        }
        let legacyToken = try tokenStore.loadToken()
        let explicitLegacyURL = userDefaults.string(forKey: receiverURLKey)
        if !legacyToken.isEmpty,
           let explicitLegacyURL,
           !explicitLegacyURL.isEmpty {
            throw ReceiverSettingsRecordError.legacyRecordRequiresRepair
        }
        guard legacyToken.isEmpty, explicitLegacyURL == nil else {
            throw ReceiverSettingsRecordError.invalidRecord
        }
        return ReceiverConnectionRecordV2(
            localScope: ReceiverLocalConnectionScopeV1(
                generation: UInt64(
                    max(0, userDefaults.integer(forKey: receiverSettingsGenerationKey))
                ),
                bindingID: ""
            ),
            mailboxIdentity: .unavailable(.notProvisionedByLegacyHTTPPairing),
            activation: .unpaired,
            transportConfigurations: []
        )
    }

    private func projectedV2(from legacy: ConnectionRecordV1) -> ReceiverConnectionRecordV2 {
        let isUnpaired = legacy.receiverURLString == Self.defaultReceiverURLString
            && legacy.bearerToken.isEmpty
            && legacy.bindingID.isEmpty
        return ReceiverConnectionRecordV2(
            localScope: ReceiverLocalConnectionScopeV1(
                generation: legacy.generation,
                bindingID: legacy.bindingID
            ),
            mailboxIdentity: .unavailable(.notProvisionedByLegacyHTTPPairing),
            activation: isUnpaired ? .unpaired : .paired(activeTransport: .directHTTP),
            transportConfigurations: isUnpaired
                ? []
                : [
                    .directHTTP(
                        activation: .active,
                        configuration: DirectHTTPConnectionConfigurationV1(
                            receiverURLString: legacy.receiverURLString,
                            bearerToken: legacy.bearerToken
                        )
                    ),
                ]
        )
    }

    private func restorePreCutoverV1IfExactMatch(
        _ current: ReceiverConnectionRecordV2
    ) throws {
        guard legacyV1Representation(of: current) != nil else {
            return
        }
        let raw = try preCutoverBackupStore.loadToken()
        guard !raw.isEmpty else { return }
        let legacy = try decodeStrictV1(raw)
        guard current == projectedV2(from: legacy) else { return }
        try tokenStore.saveToken(raw)
        mirror(current)
    }

    private func decodeStrictV1(_ raw: String) throws -> ConnectionRecordV1 {
        guard raw.hasPrefix(Self.recordPrefixV1) else {
            throw ReceiverSettingsRecordError.invalidRecord
        }
        let encoded = String(raw.dropFirst(Self.recordPrefixV1.count))
        guard let data = Data(base64Encoded: encoded),
              data.base64EncodedString() == encoded else {
            throw ReceiverSettingsRecordError.invalidRecord
        }
        var parser = StrictConnectionRecordV1JSONParser(data: data)
        let record = try parser.parse()
        try Self.validate(record)
        return record
    }

    private func persist(
        _ record: ReceiverConnectionRecordV2,
        preservingCurrentV1: Bool = true
    ) throws {
        try Self.validate(record)
        if let legacy = legacyV1Representation(of: record) {
            try persistV1(
                legacy,
                projection: record,
                inspectCurrent: preservingCurrentV1
            )
            return
        }
        try persistV2(record, preservingCurrentV1: preservingCurrentV1)
    }

    private func persistV1(
        _ legacy: ConnectionRecordV1,
        projection: ReceiverConnectionRecordV2,
        inspectCurrent: Bool
    ) throws {
        try Self.validate(legacy)
        let current = inspectCurrent ? try loadStoredConnectionRecord() : nil
        let existingBackup = try preCutoverBackupStore.loadToken()
        let currentRaw: String?
        if let current, case .v1(_, let raw) = current {
            currentRaw = raw
        } else {
            currentRaw = nil
        }

        let targetRaw: String
        if let current,
           case .v1(let currentLegacy, let raw) = current,
           projectedV2(from: currentLegacy) == projection {
            targetRaw = raw
        } else if !existingBackup.isEmpty,
                  let backupLegacy = try? decodeStrictV1(existingBackup),
                  projectedV2(from: backupLegacy) == projection {
            targetRaw = existingBackup
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(legacy)
            targetRaw = Self.recordPrefixV1 + data.base64EncodedString()
        }

        let primaryChanged = currentRaw != targetRaw
        let backupIsStale = !existingBackup.isEmpty && existingBackup != targetRaw
        if backupIsStale {
            try preCutoverBackupStore.saveToken("")
        }
        if primaryChanged {
            try tokenStore.saveToken(targetRaw)
        }
        guard primaryChanged || backupIsStale else { return }
        mirror(projection)
    }

    private func persistV2(
        _ record: ReceiverConnectionRecordV2,
        preservingCurrentV1: Bool
    ) throws {
        if preservingCurrentV1,
           case .v1(_, let raw) = try loadStoredConnectionRecord() {
            let existingBackup = try preCutoverBackupStore.loadToken()
            if existingBackup.isEmpty {
                try preCutoverBackupStore.saveToken(raw)
            } else if existingBackup != raw {
                throw ReceiverSettingsRecordError.persistenceFailed
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        try tokenStore.saveToken(Self.recordPrefixV2 + data.base64EncodedString())
        mirror(record)
    }

    private func legacyV1Representation(
        of record: ReceiverConnectionRecordV2
    ) -> ConnectionRecordV1? {
        guard record.mailboxIdentity
                == .unavailable(.notProvisionedByLegacyHTTPPairing) else {
            return nil
        }
        switch record.activation {
        case .unpaired:
            guard record.transportConfigurations.isEmpty else { return nil }
            return ConnectionRecordV1(
                version: 1,
                receiverURLString: Self.defaultReceiverURLString,
                bearerToken: "",
                generation: record.localScope.generation,
                bindingID: ""
            )
        case .paired(activeTransport: .directHTTP):
            guard record.transportConfigurations.count == 1,
                  case .directHTTP(.active, let direct)
                    = record.transportConfigurations[0] else {
                return nil
            }
            return ConnectionRecordV1(
                version: 1,
                receiverURLString: direct.receiverURLString,
                bearerToken: direct.bearerToken,
                generation: record.localScope.generation,
                bindingID: record.localScope.bindingID
            )
        case .paired(activeTransport: .mailbox):
            return nil
        }
    }

    private func mirror(_ record: ReceiverConnectionRecordV2) {
        let direct = directHTTPConfiguration(in: record)
        if direct?.receiverURLString == nil
            || direct?.receiverURLString == Self.defaultReceiverURLString {
            userDefaults.removeObject(forKey: receiverURLKey)
        } else {
            userDefaults.set(direct?.receiverURLString, forKey: receiverURLKey)
        }
        userDefaults.set(Int(record.localScope.generation), forKey: receiverSettingsGenerationKey)
    }

    private static func validate(_ record: ConnectionRecordV1) throws {
        let isUnpaired = record.receiverURLString == defaultReceiverURLString
            && record.bearerToken.isEmpty
            && record.bindingID.isEmpty
        let isPaired = !record.receiverURLString.isEmpty
            && !record.bearerToken.isEmpty
            && !record.bindingID.isEmpty
        guard record.version == 1,
              record.generation <= UInt64(Int.max),
              isUnpaired || isPaired else {
            throw ReceiverSettingsRecordError.invalidRecord
        }
    }

    private static func validate(_ record: ReceiverConnectionRecordV2) throws {
        guard record.version == 2,
              record.localScope.generation <= UInt64(Int.max),
              Set(record.transportConfigurations.map(\.transport)).count
                == record.transportConfigurations.count else {
            throw ReceiverSettingsRecordError.invalidRecord
        }
        for configuration in record.transportConfigurations {
            switch configuration {
            case .directHTTP(_, let direct):
                guard !direct.receiverURLString.isEmpty, !direct.bearerToken.isEmpty else {
                    throw ReceiverSettingsRecordError.invalidRecord
                }
            case .mailbox(_, let mailbox):
                guard mailbox.protocolVersion == 1 else {
                    throw ReceiverSettingsRecordError.invalidRecord
                }
                guard case .available = record.mailboxIdentity else {
                    throw ReceiverSettingsRecordError.invalidRecord
                }
            }
        }
        if case .available(let identity) = record.mailboxIdentity {
            let identifiers = [
                identity.receiverID,
                identity.deviceID,
                identity.devicePrincipal,
                identity.deviceSigningKeyID,
                identity.deviceAgreementKeyID,
                identity.receiverSigningKeyID,
                identity.receiverAgreementKeyID,
                identity.receiverSigningPublicKey,
                identity.receiverAgreementPublicKey,
                identity.opaqueBinding,
            ]
            guard identity.connectionGeneration > 0,
                  identifiers.allSatisfy({ !$0.isEmpty }),
                  Data(hexV1: identity.receiverID)?.count == 16,
                  Data(hexV1: identity.deviceID)?.count == 16,
                  let receiverSigning = Data(
                      strictBase64URL: identity.receiverSigningPublicKey,
                      count: 32
                  ),
                  let receiverAgreement = Data(
                      strictBase64URL: identity.receiverAgreementPublicKey,
                      count: 32
                  ),
                  Data(strictBase64URL: identity.opaqueBinding, count: 32) != nil,
                  mailboxKeyIdentifier(
                      algorithm: "ed25519",
                      publicKey: receiverSigning
                  ) == identity.receiverSigningKeyID,
                  mailboxKeyIdentifier(
                      algorithm: "x25519",
                      publicKey: receiverAgreement
                  ) == identity.receiverAgreementKeyID else {
                throw ReceiverSettingsRecordError.invalidRecord
            }
        }
        switch record.activation {
        case .unpaired:
            guard record.localScope.bindingID.isEmpty,
                  record.transportConfigurations.isEmpty else {
                throw ReceiverSettingsRecordError.invalidRecord
            }
        case .paired(let activeTransport):
            guard !record.localScope.bindingID.isEmpty,
                  record.transportConfigurations.filter({ $0.activation == .active }).count == 1,
                  record.transportConfigurations.contains(where: {
                      $0.transport == activeTransport && $0.activation == .active
                  }) else {
                throw ReceiverSettingsRecordError.invalidRecord
            }
        }
    }

    private func localScope(in stored: StoredConnectionRecord) -> ReceiverLocalConnectionScopeV1 {
        switch stored {
        case .v1(let record, _):
            ReceiverLocalConnectionScopeV1(
                generation: record.generation,
                bindingID: record.bindingID
            )
        case .v2(let record): record.localScope
        }
    }

    private func directHTTPConfiguration(
        in stored: StoredConnectionRecord
    ) -> DirectHTTPConnectionConfigurationV1? {
        switch stored {
        case .v1(let record, _):
            guard !record.bearerToken.isEmpty else { return nil }
            return DirectHTTPConnectionConfigurationV1(
                receiverURLString: record.receiverURLString,
                bearerToken: record.bearerToken
            )
        case .v2(let record):
            return directHTTPConfiguration(in: record)
        }
    }

    private func directHTTPConfiguration(
        in record: ReceiverConnectionRecordV2
    ) -> DirectHTTPConnectionConfigurationV1? {
        for configuration in record.transportConfigurations {
            if case .directHTTP(_, let direct) = configuration {
                return direct
            }
        }
        return nil
    }

    private static func nextGeneration(after generation: UInt64) throws -> UInt64 {
        guard generation < UInt64(Int.max) else {
            throw ReceiverSettingsRecordError.invalidRecord
        }
        return generation + 1
    }

    private func requireCurrentGeneration(_ expectedGeneration: String) throws {
        guard receiverSettingsGenerationToken == expectedGeneration else {
            throw ReceiverSettingsGenerationError.staleGeneration
        }
    }
}
#endif
