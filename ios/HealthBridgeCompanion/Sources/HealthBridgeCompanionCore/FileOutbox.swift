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

    public init(id: String, fileURL: URL, receiverIdentity: String? = nil) {
        self.id = id
        self.fileURL = fileURL
        self.receiverIdentity = receiverIdentity
    }
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

    public var failedCount: Int { failedItemIDs.count }

    public init(
        attemptedCount: Int,
        uploadedCount: Int,
        failedItemIDs: [String],
        failedDescriptions: [String] = []
    ) {
        self.attemptedCount = attemptedCount
        self.uploadedCount = uploadedCount
        self.failedItemIDs = failedItemIDs
        self.failedDescriptions = failedDescriptions
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
    }

    private struct SequenceManifest: Codable, Equatable {
        static let currentVersion = 3

        var version: Int
        var nextSequence: UInt64
        var entries: [SequenceEntry]

        static var empty: SequenceManifest {
            SequenceManifest(version: currentVersion, nextSequence: 1, entries: [])
        }
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
            SequenceEntry(sequence: sequence, id: id, receiverIdentity: receiverIdentity)
        )
        manifest.nextSequence = sequence + 1
        try persistManifest(manifest)
        try payload.write(to: fileURL, options: [.atomic])
        try Self.applySensitiveFileAttributes(to: fileURL, fileManager: fileManager)
        return FileOutboxItem(
            id: id,
            fileURL: fileURL,
            receiverIdentity: receiverIdentity
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
                    receiverIdentity: entry.receiverIdentity
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
            manifestEntries[entry.id] == entry
                && fileManager.fileExists(atPath: finalPayloadURL(for: entry.id).path)
                && !fileManager.fileExists(atPath: stagedPayloadURL(for: entry.id).path)
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
        if fileManager.fileExists(atPath: item.fileURL.path) {
            try fileManager.removeItem(at: item.fileURL)
        }
        _ = try reconciledManifest()
    }

    public func beginClearIntent() throws {
        if clearIntentIsActive { return }
        try Data("clear".utf8).write(to: clearIntentURL, options: [.atomic])
        try Self.applySensitiveFileAttributes(to: clearIntentURL, fileManager: fileManager)
    }

    public func clearPendingWhileIntentIsActive() throws -> Int {
        guard clearIntentIsActive else {
            throw FileOutboxClearIntentError.clearIntentRequired
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
                    receiverIdentity: receiverIdentity
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
            guard fileManager.fileExists(atPath: finalURL.path) else {
                throw SequenceError.invalidManifest
            }
            try Self.applySensitiveFileAttributes(
                to: finalURL,
                fileManager: fileManager
            )
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
                receiverIdentity: entry.receiverIdentity
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
        let allPayloadsAreRecoverable = !clearIntentIsActive
            && transaction.entries.allSatisfy { entry in
                fileManager.fileExists(atPath: stagedPayloadURL(for: entry.id).path)
                    || fileManager.fileExists(atPath: finalPayloadURL(for: entry.id).path)
            }
        if allPayloadsAreRecoverable {
            _ = try commitEnqueueTransaction(transaction, manifest: manifest)
            return
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
        let payloadURLs = try payloadFileURLs()
        let payloadIDs = Set(payloadURLs.map(payloadID))
        let loadedManifest = try loadManifest()
        var manifest = loadedManifest ?? .empty
        try Self.validate(manifest)
        if manifest.version < SequenceManifest.currentVersion {
            manifest.version = SequenceManifest.currentVersion
        }

        manifest.entries.removeAll { !payloadIDs.contains($0.id) }
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
                SequenceEntry(sequence: sequence, id: id, receiverIdentity: nil)
            )
            manifest.nextSequence = sequence + 1
        }

        try Self.validate(manifest)
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
        guard (1 ... SequenceManifest.currentVersion).contains(manifest.version),
              manifest.nextSequence > 0,
              ids.allSatisfy(isSafeItemID),
              Set(ids).count == ids.count,
              Set(sequences).count == sequences.count,
              sequences.allSatisfy({ $0 > 0 }),
              (sequences.max().map { manifest.nextSequence > $0 } ?? true) else {
            throw SequenceError.invalidManifest
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

    public init(
        label: String,
        receiverURLString: String,
        redeemURLString: String,
        invitationSecret: String?,
        invitationCode: String?,
        installationID: String,
        deviceCredential: String,
        platform: String
    ) {
        self.label = label
        self.receiverURLString = receiverURLString
        self.redeemURLString = redeemURLString
        self.invitationSecret = invitationSecret
        self.invitationCode = invitationCode
        self.installationID = installationID
        self.deviceCredential = deviceCredential
        self.platform = platform
    }

    func matches(
        receiverURLString: String,
        redeemURLString: String,
        invitationSecret: String?,
        invitationCode: String?
    ) -> Bool {
        self.receiverURLString == receiverURLString
            && self.redeemURLString == redeemURLString
            && self.invitationSecret == invitationSecret
            && self.invitationCode == invitationCode
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
            invitationCode: nil
        )
    }

    public func stage(manualPairing: ReceiverManualPairing) throws -> ReceiverPendingPairing {
        try stage(
            label: "iOS companion",
            receiverURLString: manualPairing.receiverURL.absoluteString,
            redeemURLString: manualPairing.redeemURL.absoluteString,
            invitationSecret: nil,
            invitationCode: manualPairing.invitationCode
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
        invitationCode: String?
    ) throws -> ReceiverPendingPairing {
        guard try !hasPendingCancellation() else {
            throw ReceiverPairingStateError.pendingPairingConflict
        }
        if let existing = try loadPending() {
            guard existing.matches(
                receiverURLString: receiverURLString,
                redeemURLString: redeemURLString,
                invitationSecret: invitationSecret,
                invitationCode: invitationCode
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
            platform: "ios"
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
    public static func canBegin(
        outboxIdentityAdmissionReady: Bool,
        pendingItemCount: Int,
        clearIntentIsActive: Bool
    ) -> Bool {
        outboxIdentityAdmissionReady
            && pendingItemCount == 0
            && !clearIntentIsActive
    }
}

public final class ReceiverSettingsStore {
    public static let defaultReceiverURLString = "http://127.0.0.1:8765/v1/batches"

    private struct ConnectionRecord: Codable {
        let version: Int
        let receiverURLString: String
        let bearerToken: String
        let generation: UInt64
        let bindingID: String
    }

    private static let recordPrefix = "health-bridge-connection-v1:"
    private let userDefaults: UserDefaults
    private let tokenStore: ReceiverTokenStoring
    private let synchronizeUserDefaults: () -> Bool
    private let receiverURLKey = "receiverURLString"
    private let receiverSettingsGenerationKey = "receiverSettingsGeneration"
    private let terminalCancellationGenerationKey = "receiverTerminalCancellationGeneration"

    public init(
        userDefaults: UserDefaults = .standard,
        tokenStore: ReceiverTokenStoring = KeychainReceiverTokenStore(),
        synchronize: (() -> Bool)? = nil
    ) {
        self.userDefaults = userDefaults
        self.tokenStore = tokenStore
        self.synchronizeUserDefaults = synchronize ?? { userDefaults.synchronize() }
    }

    public var receiverURLString: String {
        if let record = try? loadConnectionRecord() {
            return record.receiverURLString
        }
        return userDefaults.string(forKey: receiverURLKey) ?? Self.defaultReceiverURLString
    }

    public var receiverSettingsGeneration: UInt64 {
        if let record = try? loadConnectionRecord() {
            return record.generation
        }
        return UInt64(max(0, userDefaults.integer(forKey: receiverSettingsGenerationKey)))
    }

    public var receiverSettingsGenerationToken: String {
        "g\(receiverSettingsGeneration)"
    }

    public var receiverBindingID: String? {
        guard let record = try? loadConnectionRecord(),
              !record.bearerToken.isEmpty,
              !record.bindingID.isEmpty else {
            return nil
        }
        return record.bindingID
    }

    @discardableResult
    public func ensureAtomicConnectionRecord() throws -> String? {
        if let record = try loadConnectionRecord() {
            mirror(record)
            return record.bearerToken.isEmpty ? nil : record.bindingID
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

    @discardableResult
    public func invalidateReceiverSettingsGeneration() throws -> String {
        let current = try authoritativeRecordForMutation()
        let record = ConnectionRecord(
            version: 1,
            receiverURLString: current.receiverURLString,
            bearerToken: current.bearerToken,
            generation: try Self.nextGeneration(after: current.generation),
            bindingID: current.bindingID
        )
        try persist(record)
        return "g\(record.generation)"
    }

    public func loadBearerToken() throws -> String {
        if let record = try loadConnectionRecord() {
            return record.bearerToken
        }
        return try tokenStore.loadToken()
    }

    public func receiverSettingsAreCleared() throws -> Bool {
        if let record = try loadConnectionRecord() {
            return record.receiverURLString == Self.defaultReceiverURLString
                && record.bearerToken.isEmpty
                && record.bindingID.isEmpty
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
        let settingsChanged = rotateBindingID
            || previous.receiverURLString != newReceiverURLString
            || previous.bearerToken != newBearerToken
        let record = ConnectionRecord(
            version: 1,
            receiverURLString: newReceiverURLString,
            bearerToken: newBearerToken,
            generation: settingsChanged
                ? try Self.nextGeneration(after: previous.generation)
                : previous.generation,
            bindingID: settingsChanged || previous.bindingID.isEmpty
                ? UUID().uuidString.lowercased()
                : previous.bindingID
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
        let settingsChanged = previous.receiverURLString != Self.defaultReceiverURLString || !previous.bearerToken.isEmpty
        let record = ConnectionRecord(
            version: 1,
            receiverURLString: Self.defaultReceiverURLString,
            bearerToken: "",
            generation: settingsChanged
                ? try Self.nextGeneration(after: previous.generation)
                : previous.generation,
            bindingID: ""
        )
        try persist(record)
    }

    public func clearReceiverSettings(expectedGeneration: String) throws {
        try requireCurrentGeneration(expectedGeneration)
        try clearReceiverSettings()
    }

    public func resetInvalidConnectionRecord() throws {
        do {
            if try loadConnectionRecord() != nil {
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
        let record = ConnectionRecord(
            version: 1,
            receiverURLString: Self.defaultReceiverURLString,
            bearerToken: "",
            generation: replacementGeneration,
            bindingID: ""
        )
        try persist(record)
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

    private func loadConnectionRecord() throws -> ConnectionRecord? {
        let raw = try tokenStore.loadToken()
        guard raw.hasPrefix(Self.recordPrefix) else { return nil }
        let encoded = String(raw.dropFirst(Self.recordPrefix.count))
        guard let data = Data(base64Encoded: encoded),
              let record = try? JSONDecoder().decode(ConnectionRecord.self, from: data) else {
            throw ReceiverSettingsRecordError.invalidRecord
        }
        try Self.validate(record)
        return record
    }

    private func authoritativeRecordForMutation() throws -> ConnectionRecord {
        if let record = try loadConnectionRecord() {
            return record
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
        return ConnectionRecord(
            version: 1,
            receiverURLString: Self.defaultReceiverURLString,
            bearerToken: "",
            generation: UInt64(max(0, userDefaults.integer(forKey: receiverSettingsGenerationKey))),
            bindingID: ""
        )
    }

    private func persist(_ record: ConnectionRecord) throws {
        try Self.validate(record)
        let data = try JSONEncoder().encode(record)
        try tokenStore.saveToken(Self.recordPrefix + data.base64EncodedString())
        mirror(record)
    }

    private func mirror(_ record: ConnectionRecord) {
        if record.receiverURLString == Self.defaultReceiverURLString {
            userDefaults.removeObject(forKey: receiverURLKey)
        } else {
            userDefaults.set(record.receiverURLString, forKey: receiverURLKey)
        }
        userDefaults.set(Int(record.generation), forKey: receiverSettingsGenerationKey)
    }

    private static func validate(_ record: ConnectionRecord) throws {
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
