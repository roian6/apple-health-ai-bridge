import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ReceiverUploadRequestFactoryError: Error, Equatable, LocalizedError, Sendable {
    case emptyBearerToken

    public var errorDescription: String? {
        switch self {
        case .emptyBearerToken:
            "Bearer token is empty."
        }
    }
}

public enum ReceiverUploadRequestFactory {
    public static func makeJSONPostRequest(url: URL, bearerToken: String) throws -> URLRequest {
        let trimmedToken = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw ReceiverUploadRequestFactoryError.emptyBearerToken
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}

public enum BackgroundOutboxTaskDescriptorError: Error, Equatable, LocalizedError, Sendable {
    case unsafeItemID
    case unsafeReceiverGeneration
    case unsafeReceiverBindingID

    public var errorDescription: String? {
        switch self {
        case .unsafeItemID:
            "Outbox item ID is not safe for a background upload task descriptor."
        case .unsafeReceiverGeneration:
            "Receiver settings generation is not safe for a background upload task descriptor."
        case .unsafeReceiverBindingID:
            "Receiver binding ID is not safe for a background upload task descriptor."
        }
    }
}

public enum BackgroundOutboxTaskDescriptor {
    public static let prefix = "healthbridge.outbox."
    private static let separator = "@"

    public static func taskDescription(
        forItemID itemID: String,
        receiverGeneration: String,
        receiverBindingID: String
    ) throws -> String {
        guard isSafeItemID(itemID) else {
            throw BackgroundOutboxTaskDescriptorError.unsafeItemID
        }
        guard isSafeReceiverGeneration(receiverGeneration) else {
            throw BackgroundOutboxTaskDescriptorError.unsafeReceiverGeneration
        }
        guard isSafeReceiverBindingID(receiverBindingID) else {
            throw BackgroundOutboxTaskDescriptorError.unsafeReceiverBindingID
        }
        return prefix + receiverGeneration + separator + receiverBindingID + separator + itemID
    }

    public static func itemID(fromTaskDescription taskDescription: String?) -> String? {
        descriptor(fromTaskDescription: taskDescription)?.itemID
    }

    public static func receiverGeneration(fromTaskDescription taskDescription: String?) -> String? {
        descriptor(fromTaskDescription: taskDescription)?.receiverGeneration
    }

    public static func receiverBindingID(fromTaskDescription taskDescription: String?) -> String? {
        descriptor(fromTaskDescription: taskDescription)?.receiverBindingID
    }

    public static func descriptor(fromTaskDescription taskDescription: String?) -> (
        receiverGeneration: String,
        receiverBindingID: String,
        itemID: String
    )? {
        guard let taskDescription, taskDescription.hasPrefix(prefix) else {
            return nil
        }
        let body = String(taskDescription.dropFirst(prefix.count))
        let parts = body.split(separator: Character(separator), omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return nil
        }
        let receiverGeneration = String(parts[0])
        let receiverBindingID = String(parts[1])
        let itemID = String(parts[2])
        guard isSafeReceiverGeneration(receiverGeneration),
              isSafeReceiverBindingID(receiverBindingID),
              isSafeItemID(itemID) else {
            return nil
        }
        return (receiverGeneration, receiverBindingID, itemID)
    }

    private static func isSafeItemID(_ itemID: String) -> Bool {
        guard !itemID.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return itemID.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isSafeReceiverGeneration(_ receiverGeneration: String) -> Bool {
        guard !receiverGeneration.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return receiverGeneration.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isSafeReceiverBindingID(_ receiverBindingID: String) -> Bool {
        guard !receiverBindingID.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return receiverBindingID.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

public struct BackgroundOutboxUploadPlan: Equatable, Sendable {
    public let itemID: String
    public let receiverGeneration: String
    public let receiverBindingID: String
    public let fileURL: URL
    public let request: URLRequest
    public let taskDescription: String

    public init(
        itemID: String,
        receiverGeneration: String,
        receiverBindingID: String,
        fileURL: URL,
        request: URLRequest,
        taskDescription: String
    ) {
        self.itemID = itemID
        self.receiverGeneration = receiverGeneration
        self.receiverBindingID = receiverBindingID
        self.fileURL = fileURL
        self.request = request
        self.taskDescription = taskDescription
    }
}

public enum BackgroundOutboxUploadPlannerError: Error, Equatable, LocalizedError, Sendable {
    case invalidMaxTaskCount

    public var errorDescription: String? {
        switch self {
        case .invalidMaxTaskCount:
            "Background upload task cap must be greater than zero."
        }
    }
}

public enum BackgroundOutboxUploadPlanner {
    public static let defaultMaxTaskCount = 1

    public static func plan(
        pendingItems: [FileOutboxItem],
        receiverURL: URL,
        bearerToken: String,
        receiverGeneration: String,
        receiverBindingID: String,
        alreadyScheduledItemIDs: Set<String>,
        maxTaskCount: Int = defaultMaxTaskCount
    ) throws -> [BackgroundOutboxUploadPlan] {
        guard maxTaskCount > 0 else {
            throw BackgroundOutboxUploadPlannerError.invalidMaxTaskCount
        }
        guard alreadyScheduledItemIDs.isEmpty else {
            return []
        }

        let request = try ReceiverUploadRequestFactory.makeJSONPostRequest(
            url: receiverURL,
            bearerToken: bearerToken
        )

        return try pendingItems
            .filter { !alreadyScheduledItemIDs.contains($0.id) }
            .prefix(maxTaskCount)
            .map { item in
                try BackgroundOutboxUploadPlan(
                    itemID: item.id,
                    receiverGeneration: receiverGeneration,
                    receiverBindingID: receiverBindingID,
                    fileURL: item.fileURL,
                    request: request,
                    taskDescription: BackgroundOutboxTaskDescriptor.taskDescription(
                        forItemID: item.id,
                        receiverGeneration: receiverGeneration,
                        receiverBindingID: receiverBindingID
                    )
                )
            }
    }
}

public struct BackgroundUploadTaskCompletion: Codable, Equatable, Sendable {
    public let statusCode: Int?
    public let hadTransportError: Bool
    public let sleepMinimumResetEpoch: UInt64?

    public init(
        statusCode: Int?,
        hadTransportError: Bool,
        sleepMinimumResetEpoch: UInt64?
    ) {
        self.statusCode = statusCode
        self.hadTransportError = hadTransportError
        self.sleepMinimumResetEpoch = sleepMinimumResetEpoch
    }
}

public struct BackgroundUploadTaskOwnership: Codable, Equatable, Sendable {
    public let taskID: Int
    public let itemID: String
    public let receiverGeneration: String
    public let receiverBindingID: String
    public let completion: BackgroundUploadTaskCompletion?

    public init(
        taskID: Int,
        itemID: String,
        receiverGeneration: String,
        receiverBindingID: String,
        completion: BackgroundUploadTaskCompletion? = nil
    ) {
        self.taskID = taskID
        self.itemID = itemID
        self.receiverGeneration = receiverGeneration
        self.receiverBindingID = receiverBindingID
        self.completion = completion
    }

    fileprivate func recording(
        _ completion: BackgroundUploadTaskCompletion
    ) -> BackgroundUploadTaskOwnership {
        BackgroundUploadTaskOwnership(
            taskID: taskID,
            itemID: itemID,
            receiverGeneration: receiverGeneration,
            receiverBindingID: receiverBindingID,
            completion: completion
        )
    }
}

public enum BackgroundUploadTaskOwnershipStoreError: Error, Equatable {
    case duplicateTaskID
    case missingTaskID
    case invalidManifest
}

public final class FileBackgroundUploadTaskOwnershipStore: @unchecked Sendable {
    private struct Manifest: Codable {
        static let currentVersion = 1

        let version: Int
        var records: [BackgroundUploadTaskOwnership]
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(fileURL: URL, fileManager: FileManager = .default) throws {
        self.fileURL = fileURL
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
    }

    public func records() throws -> [BackgroundUploadTaskOwnership] {
        lock.lock()
        defer { lock.unlock() }
        return try loadManifest().records.sorted { $0.taskID < $1.taskID }
    }

    public func record(forTaskID taskID: Int) throws -> BackgroundUploadTaskOwnership? {
        try records().first { $0.taskID == taskID }
    }

    public func begin(_ record: BackgroundUploadTaskOwnership) throws {
        try mutate { manifest in
            guard !manifest.records.contains(where: { $0.taskID == record.taskID }) else {
                throw BackgroundUploadTaskOwnershipStoreError.duplicateTaskID
            }
            manifest.records.append(record)
        }
    }

    public func recordCompletion(
        _ completion: BackgroundUploadTaskCompletion,
        forTaskID taskID: Int
    ) throws {
        try mutate { manifest in
            guard let index = manifest.records.firstIndex(where: { $0.taskID == taskID }) else {
                throw BackgroundUploadTaskOwnershipStoreError.missingTaskID
            }
            manifest.records[index] = manifest.records[index].recording(completion)
        }
    }

    public func remove(taskID: Int) throws {
        try mutate { manifest in
            manifest.records.removeAll { $0.taskID == taskID }
        }
    }

    private func mutate(_ update: (inout Manifest) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var manifest = try loadManifest()
        try update(&manifest)
        try persist(manifest)
    }

    private func loadManifest() throws -> Manifest {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return Manifest(version: Manifest.currentVersion, records: [])
        }
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: fileURL)
        )
        guard manifest.version == Manifest.currentVersion,
              Set(manifest.records.map(\.taskID)).count == manifest.records.count,
              manifest.records.allSatisfy({ $0.taskID >= 0 }) else {
            throw BackgroundUploadTaskOwnershipStoreError.invalidManifest
        }
        return manifest
    }

    private func persist(_ manifest: Manifest) throws {
        if manifest.records.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: fileURL, options: [.atomic])
        try Self.applySensitiveFileAttributes(
            to: fileURL,
            permissions: 0o600,
            fileManager: fileManager
        )
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

public enum BackgroundOutboxUploadCompletionPolicy {
    private struct SleepEpochConflictResponse: Decodable {
        let error: String
        let minimumResetEpoch: UInt64

        enum CodingKeys: String, CodingKey {
            case error
            case minimumResetEpoch = "minimum_reset_epoch"
        }
    }

    public static func shouldMarkUploaded(error: Error?, httpStatusCode: Int?) -> Bool {
        guard error == nil, let httpStatusCode else {
            return false
        }
        return (200..<300).contains(httpStatusCode)
    }

    public static func shouldMarkUploaded(
        error: Error?,
        httpStatusCode: Int?,
        taskReceiverGeneration: String?,
        currentReceiverGeneration: String,
        taskReceiverBindingID: String?,
        currentReceiverBindingID: String?
    ) -> Bool {
        guard taskReceiverGeneration == currentReceiverGeneration,
              let taskReceiverBindingID,
              taskReceiverBindingID == currentReceiverBindingID else {
            return false
        }
        return shouldMarkUploaded(error: error, httpStatusCode: httpStatusCode)
    }

    public static func sleepBaselineConflictMinimumResetEpoch(
        error: Error?,
        httpStatusCode: Int?,
        responseBody: Data?
    ) -> UInt64? {
        guard error == nil,
              httpStatusCode == 409,
              let responseBody,
              let response = try? JSONDecoder().decode(
                SleepEpochConflictResponse.self,
                from: responseBody
              ),
              response.error == "sleep_baseline_reset_epoch_conflict" else {
            return nil
        }
        return response.minimumResetEpoch
    }
}

public final class BackgroundEventFinalizationCoordinator<ID: Hashable>: @unchecked Sendable {
    public struct State {
        public let pendingIDs: Set<ID>
        public let hasUnfinishedEventCycle: Bool
        public let generation: UInt64

        public var isIdle: Bool {
            pendingIDs.isEmpty && !hasUnfinishedEventCycle
        }
    }

    private let lock = NSLock()
    private var pendingIDs: Set<ID> = []
    private var eventsFinished = false
    private var completionHandlers: [() -> Void] = []
    private var generation: UInt64 = 0

    public init() {}

    public func setCompletionHandler(_ handler: @escaping () -> Void) -> (() -> Void)? {
        lock.lock()
        let joinsExistingCycle = !completionHandlers.isEmpty
        completionHandlers.append(handler)
        if !joinsExistingCycle {
            eventsFinished = false
        }
        generation &+= 1
        let readyHandler = takeReadyHandlerLocked()
        lock.unlock()
        return readyHandler
    }

    public func begin(_ id: ID) {
        lock.lock()
        if pendingIDs.insert(id).inserted {
            generation &+= 1
        }
        lock.unlock()
    }

    public func complete(_ id: ID) -> (() -> Void)? {
        lock.lock()
        if pendingIDs.remove(id) != nil {
            generation &+= 1
        }
        let readyHandler = takeReadyHandlerLocked()
        lock.unlock()
        return readyHandler
    }

    public func pendingIDsSnapshot() -> Set<ID> {
        lock.lock()
        let snapshot = pendingIDs
        lock.unlock()
        return snapshot
    }

    public func stateSnapshot() -> State {
        lock.lock()
        let state = State(
            pendingIDs: pendingIDs,
            hasUnfinishedEventCycle: !completionHandlers.isEmpty,
            generation: generation
        )
        lock.unlock()
        return state
    }

    public func markEventsFinished() -> (() -> Void)? {
        lock.lock()
        guard !completionHandlers.isEmpty else {
            eventsFinished = false
            lock.unlock()
            return nil
        }
        eventsFinished = true
        generation &+= 1
        let readyHandler = takeReadyHandlerLocked()
        lock.unlock()
        return readyHandler
    }

    private func takeReadyHandlerLocked() -> (() -> Void)? {
        guard eventsFinished, pendingIDs.isEmpty, !completionHandlers.isEmpty else {
            return nil
        }
        let readyHandlers = completionHandlers
        completionHandlers.removeAll()
        eventsFinished = false
        generation &+= 1
        return {
            readyHandlers.forEach { $0() }
        }
    }
}
