import Darwin
import Foundation

public enum MailboxLocatorError: Error, Equatable, Sendable {
    case containerUnavailable
    case containerIdentityMismatch
    case invalidProviderRoot
    case localRecordInsideContainer
    case pathNotDirectory
    case pathReplaced
    case symbolicLink
    case storageFailure
}

public struct MailboxDirectoryIdentityV1: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
}

public struct MailboxResolvedLocatorV1: Sendable {
    public let containerIdentifier: String
    public let providerRoot: URL
    public let deviceRoot: URL
    public let relativeDevicePath: String
    public let lanes: [MailboxLaneV1: URL]

    fileprivate let deviceRootIdentity: MailboxDirectoryIdentityV1
    fileprivate let laneIdentities: [MailboxLaneV1: MailboxDirectoryIdentityV1]
}

private struct MailboxLocatorRecordV1: Codable {
    let v: Int
    let kind: String
    let containerIdentifier: String
    let relativeDevicePath: String

    enum CodingKeys: String, CodingKey {
        case v
        case kind
        case containerIdentifier = "container_identifier"
        case relativeDevicePath = "relative_device_path"
    }
}

public enum MailboxLocatorV1 {
    #if !HEALTH_BRIDGE_MAILBOX_QA
    public static func resolve(
        receiverComponent: String,
        deviceComponent: String,
        fileManager: FileManager = .default
    ) throws -> MailboxResolvedLocatorV1 {
        let identifier = HealthBridgeAppIdentity.ubiquityContainerIdentifier
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw MailboxLocatorError.storageFailure
        }
        let localRecordURL = applicationSupport
            .appending(path: "HealthBridgeCompanion", directoryHint: .isDirectory)
            .appending(path: "mailbox-locator-v1.json", directoryHint: .notDirectory)
        return try resolve(
            providerRoot: fileManager.url(forUbiquityContainerIdentifier: identifier),
            containerIdentifier: identifier,
            receiverComponent: receiverComponent,
            deviceComponent: deviceComponent,
            localRecordURL: localRecordURL,
            fileManager: fileManager
        )
    }
    #endif

    public static func resolve(
        providerRoot: URL?,
        containerIdentifier: String,
        receiverComponent: String,
        deviceComponent: String,
        localRecordURL: URL,
        fileManager: FileManager = .default
    ) throws -> MailboxResolvedLocatorV1 {
        #if !HEALTH_BRIDGE_MAILBOX_QA
        guard containerIdentifier == HealthBridgeAppIdentity.ubiquityContainerIdentifier else {
            throw MailboxLocatorError.containerIdentityMismatch
        }
        #endif
        return try resolveIsolated(
            providerRoot: providerRoot,
            containerIdentifier: containerIdentifier,
            receiverComponent: receiverComponent,
            deviceComponent: deviceComponent,
            localRecordURL: localRecordURL,
            fileManager: fileManager
        )
    }

    public static func resolveIsolated(
        providerRoot: URL?,
        containerIdentifier: String,
        receiverComponent: String,
        deviceComponent: String,
        localRecordURL: URL,
        fileManager: FileManager = .default
    ) throws -> MailboxResolvedLocatorV1 {
        guard !containerIdentifier.isEmpty else {
            throw MailboxLocatorError.containerIdentityMismatch
        }
        guard let providerRoot else {
            throw MailboxLocatorError.containerUnavailable
        }
        let provider = providerRoot.standardizedFileURL
        guard provider.isFileURL else {
            throw MailboxLocatorError.invalidProviderRoot
        }
        _ = try directoryIdentity(at: provider)
        let receiver = try MailboxLayoutV1.opaqueComponent(receiverComponent)
        let device = try MailboxLayoutV1.opaqueComponent(deviceComponent)
        let relativeParts = [
            MailboxLayoutV1.rootDirectoryName,
            MailboxLayoutV1.versionDirectoryName,
            receiver,
            device,
        ]
        var current = provider.appending(path: "Documents", directoryHint: .isDirectory)
        try ensureDirectory(at: current, fileManager: fileManager)
        for part in relativeParts {
            current.append(path: part, directoryHint: .isDirectory)
            try ensureDirectory(at: current, fileManager: fileManager)
        }
        let deviceRoot = current
        let deviceIdentity = try directoryIdentity(at: deviceRoot)
        var lanes: [MailboxLaneV1: URL] = [:]
        var laneIdentities: [MailboxLaneV1: MailboxDirectoryIdentityV1] = [:]
        for lane in MailboxLaneV1.allCases {
            let laneURL = deviceRoot.appending(path: lane.rawValue, directoryHint: .isDirectory)
            try ensureDirectory(at: laneURL, fileManager: fileManager)
            lanes[lane] = laneURL
            laneIdentities[lane] = try directoryIdentity(at: laneURL)
        }
        let relativeDevicePath = relativeParts.joined(separator: "/")
        try writeLocalRecord(
            to: localRecordURL,
            providerRoot: provider,
            record: MailboxLocatorRecordV1(
                v: 1,
                kind: "mailbox_locator",
                containerIdentifier: containerIdentifier,
                relativeDevicePath: relativeDevicePath
            ),
            fileManager: fileManager
        )
        return MailboxResolvedLocatorV1(
            containerIdentifier: containerIdentifier,
            providerRoot: provider,
            deviceRoot: deviceRoot,
            relativeDevicePath: relativeDevicePath,
            lanes: lanes,
            deviceRootIdentity: deviceIdentity,
            laneIdentities: laneIdentities
        )
    }

    public static func revalidate(_ locator: MailboxResolvedLocatorV1) throws {
        guard (try? directoryIdentity(at: locator.deviceRoot)) == locator.deviceRootIdentity else {
            throw MailboxLocatorError.pathReplaced
        }
        for lane in MailboxLaneV1.allCases {
            guard let url = locator.lanes[lane],
                  let expected = locator.laneIdentities[lane],
                  (try? directoryIdentity(at: url)) == expected
            else {
                throw MailboxLocatorError.pathReplaced
            }
        }
    }

    private static func ensureDirectory(at url: URL, fileManager: FileManager) throws {
        do {
            let identity = try directoryIdentity(at: url)
            _ = identity
        } catch let error as POSIXError where error.code == .ENOENT {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw MailboxLocatorError.storageFailure
            }
            _ = try directoryIdentity(at: url)
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
        } catch {
            throw MailboxLocatorError.storageFailure
        }
    }

    private static func directoryIdentity(at url: URL) throws -> MailboxDirectoryIdentityV1 {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let fileType = metadata.st_mode & mode_t(S_IFMT)
        if fileType == mode_t(S_IFLNK) {
            throw MailboxLocatorError.symbolicLink
        }
        guard fileType == mode_t(S_IFDIR) else {
            throw MailboxLocatorError.pathNotDirectory
        }
        return MailboxDirectoryIdentityV1(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    private static func writeLocalRecord(
        to requestedURL: URL,
        providerRoot: URL,
        record: MailboxLocatorRecordV1,
        fileManager: FileManager
    ) throws {
        let recordURL = requestedURL.standardizedFileURL
        let providerPrefix = providerRoot.path + "/"
        guard recordURL.path != providerRoot.path,
              !recordURL.path.hasPrefix(providerPrefix)
        else {
            throw MailboxLocatorError.localRecordInsideContainer
        }
        do {
            try ensureDirectory(
                at: recordURL.deletingLastPathComponent(),
                fileManager: fileManager
            )
            try requireRegularOrMissingRecord(at: recordURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(to: recordURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: recordURL.path
            )
        } catch let error as MailboxLocatorError {
            throw error
        } catch {
            throw MailboxLocatorError.storageFailure
        }
    }

    private static func requireRegularOrMissingRecord(at url: URL) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw MailboxLocatorError.storageFailure
            }
            return
        }
        let fileType = metadata.st_mode & mode_t(S_IFMT)
        if fileType == mode_t(S_IFLNK) {
            throw MailboxLocatorError.symbolicLink
        }
        guard fileType == mode_t(S_IFREG) else {
            throw MailboxLocatorError.storageFailure
        }
    }
}
