import CryptoKit
import Darwin
import Foundation

public enum MailboxReceiverCapabilities {
    public static let filename = "receiver-capabilities.json"
    public static let maximumBytes = 8_192
    private static let domain = Data("health-bridge/mailbox/v1/receiver-capabilities/signature".utf8)
    private static let fields: Set<String> = [
        "v", "kind", "receiver_id", "device_id", "connection_generation",
        "receiver_signing_key_id", "capabilities", "signature"
    ]

    public static func decode(_ data: Data, identity: MailboxConnectionIdentityV1) throws -> ReceiverCapabilities {
        var raw = try DeliveryProtocolV1.object(data, fields: fields, limit: maximumBytes)
        guard identity.connectionGeneration <= UInt64(Int64.max),
              try DeliveryProtocolV1.integer(raw, "v") == 1,
              try DeliveryProtocolV1.string(raw, "kind") == "receiver_capabilities",
              try DeliveryProtocolV1.requireID(DeliveryProtocolV1.string(raw, "receiver_id"))
                == DeliveryProtocolV1.requireID(identity.receiverID),
              try DeliveryProtocolV1.requireID(DeliveryProtocolV1.string(raw, "device_id"))
                == DeliveryProtocolV1.requireID(identity.deviceID),
              try DeliveryProtocolV1.integer(raw, "connection_generation") == Int64(identity.connectionGeneration),
              try DeliveryProtocolV1.string(raw, "receiver_signing_key_id") == identity.receiverSigningKeyID else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation:
            DeliveryProtocolV1.unb64(identity.receiverSigningPublicKey, length: 32))
        guard try DeliveryProtocolV1.keyID(algorithm: "ed25519", publicKey: key.rawRepresentation) == identity.receiverSigningKeyID else {
            throw DeliveryProtocolV1Error.authenticationFailed
        }
        let signature = try DeliveryProtocolV1.unb64(DeliveryProtocolV1.string(raw, "signature"), length: 64)
        raw.removeValue(forKey: "signature")
        guard key.isValidSignature(signature, for: try DeliveryProtocolV1.signaturePreimage(domain, raw)),
              let capabilities = raw["capabilities"] else { throw DeliveryProtocolV1Error.authenticationFailed }
        // Unknown nested fields remain in the authenticated preimage above.
        return try ReceiverCapabilities.decodeAuthenticated(capabilities)
    }

    struct IO: Sendable {
        var isLocal: @Sendable (URL) throws -> Bool = localAvailability
        var requestDownload: @Sendable (URL) throws -> Void = { try FileManager.default.startDownloadingUbiquitousItem(at: $0) }
        var readBytes: @Sendable (URL) throws -> Data = { try MailboxRegularFileReader.read($0, maximumBytes: Int64(maximumBytes)) }
    }

    static func read(
        identity: MailboxConnectionIdentityV1,
        locate: @escaping @Sendable () throws -> MailboxResolvedLocatorV1,
        io: IO = IO()
    ) async throws -> ReceiverCapabilities? {
        try Task.checkCancellation()
        let cancellation = CapabilityReadCancellation()
        let work = Task.detached(priority: Task.currentPriority) { () throws -> ReceiverCapabilities? in
            do {
                try Task.checkCancellation()
                let locator = try locate()
                try MailboxLocatorV1.revalidate(locator)
                let chain = try directoryChain(locator)
                let target = locator.deviceRoot.appendingPathComponent(filename)
                if try !io.isLocal(target) {
                    try Task.checkCancellation()
                    try validate(locator, chain: chain)
                    try? io.requestDownload(target)
                    try Task.checkCancellation()
                    return nil
                }
                let coordinator = NSFileCoordinator(filePresenter: nil)
                try cancellation.bind(coordinator)
                defer { cancellation.clear() }
                var error: NSError?
                var result: Result<Data, Error> = .failure(DeliveryProtocolV1Error.authenticationFailed)
                coordinator.coordinate(readingItemAt: target, options: .withoutChanges, error: &error) { url in
                    result = Result {
                        try Task.checkCancellation()
                        guard url.standardizedFileURL == target.standardizedFileURL else {
                            throw DeliveryProtocolV1Error.authenticationFailed
                        }
                        try validate(locator, chain: chain)
                        let data = try io.readBytes(url)
                        try validate(locator, chain: chain)
                        try Task.checkCancellation()
                        return data
                    }
                }
                try Task.checkCancellation()
                if let error { throw error }
                let data = try result.get()
                try validate(locator, chain: chain)
                return try decode(data, identity: identity)
            } catch is CancellationError { throw CancellationError() }
            catch { return nil }
        }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            work.cancel()
            cancellation.cancel()
        }
    }

    private static func validate(_ locator: MailboxResolvedLocatorV1, chain: [MailboxDirectoryIdentityV1]) throws {
        try MailboxLocatorV1.revalidate(locator)
        guard try directoryChain(locator) == chain else { throw MailboxLocatorError.pathReplaced }
    }

    private static func directoryChain(_ locator: MailboxResolvedLocatorV1) throws -> [MailboxDirectoryIdentityV1] {
        var url = locator.providerRoot
        var result: [MailboxDirectoryIdentityV1] = []
        let components = ["Documents"] + locator.relativeDevicePath.split(separator: "/").map(String.init)
        for index in 0...components.count {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw MailboxLocatorError.pathReplaced
            }
            result.append(MailboxDirectoryIdentityV1(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino)))
            if index < components.count { url.appendPathComponent(components[index], isDirectory: true) }
        }
        guard url.standardizedFileURL == locator.deviceRoot.standardizedFileURL else { throw MailboxLocatorError.pathReplaced }
        return result
    }

    private static func localAvailability(_ url: URL) throws -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return false }
            throw MailboxLocatorError.storageFailure
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_nlink == 1,
              metadata.st_size >= 0, metadata.st_size <= maximumBytes else { throw MailboxLocatorError.storageFailure }
        let values = try url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemHasUnresolvedConflictsKey
        ])
        guard values.ubiquitousItemHasUnresolvedConflicts != true else { throw MailboxLocatorError.storageFailure }
        guard values.isUbiquitousItem == true else { return true }
        return values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded
    }
}

// Only cancellation crosses threads; the operation creates and uses its own coordinator.
private final class CapabilityReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var coordinator: NSFileCoordinator?
    private var cancelled = false
    func bind(_ value: NSFileCoordinator) throws {
        try lock.withLock {
            guard !cancelled else { value.cancel(); throw CancellationError() }
            coordinator = value
        }
    }
    func clear() { lock.withLock { coordinator = nil } }
    func cancel() {
        lock.withLock { cancelled = true; coordinator?.cancel() }
    }
}
