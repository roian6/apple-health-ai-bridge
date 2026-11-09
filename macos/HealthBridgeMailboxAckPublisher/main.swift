import CryptoKit
import Darwin
import Foundation

#if !HEALTH_BRIDGE_ISOLATED_HELPER_TEST_HOST
import Security

private func requiredInfoValue(_ key: String) -> String {
    guard
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
        !value.isEmpty,
        value.count <= 255,
        value.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        })
    else {
        fatalError("missing required helper build setting")
    }
    return value
}

private let containerIdentifier = requiredInfoValue(
    "HealthBridgeICloudContainerIdentifier"
)
private let expectedBundleIdentifier = requiredInfoValue(
    "HealthBridgeExpectedBundleIdentifier"
)

private func requiredStringArrayEntitlement(_ key: String) -> [String] {
    guard
        let task = SecTaskCreateFromSelf(nil),
        let rawValue = SecTaskCopyValueForEntitlement(
            task,
            key as CFString,
            nil
        ),
        let values = rawValue as? [String]
    else {
        fatalError("missing required helper entitlement")
    }
    return values
}

#endif

private let protocolVersion = 1
private let maximumRequestBytes = 8_192
private let maximumAckBytes = 1_048_576

private struct PublishRequest: Codable {
    let version: Int
    let requestID: String
    let receiver: String
    let device: String
    let finalName: String
    let byteCount: Int
    let sha256: String
}

private struct PublishReceipt: Codable {
    let version: Int
    let requestID: String
    let receiver: String
    let device: String
    let finalName: String
    let byteCount: Int
    let sha256: String
    let published: Bool
    let exactBytes: Bool
    let isUbiquitous: Bool
    let uploadErrorAbsent: Bool
    let sourceOutsideProvider: Bool
    let errorDomain: String?
    let errorCode: Int?

    private enum CodingKeys: String, CodingKey {
        case version, requestID, receiver, device, finalName, byteCount, sha256
        case published, exactBytes, isUbiquitous, uploadErrorAbsent
        case sourceOutsideProvider, errorDomain, errorCode
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(requestID, forKey: .requestID)
        try values.encode(receiver, forKey: .receiver)
        try values.encode(device, forKey: .device)
        try values.encode(finalName, forKey: .finalName)
        try values.encode(byteCount, forKey: .byteCount)
        try values.encode(sha256, forKey: .sha256)
        try values.encode(published, forKey: .published)
        try values.encode(exactBytes, forKey: .exactBytes)
        try values.encode(isUbiquitous, forKey: .isUbiquitous)
        try values.encode(uploadErrorAbsent, forKey: .uploadErrorAbsent)
        try values.encode(sourceOutsideProvider, forKey: .sourceOutsideProvider)
        if let errorDomain {
            try values.encode(errorDomain, forKey: .errorDomain)
        } else {
            try values.encodeNil(forKey: .errorDomain)
        }
        if let errorCode {
            try values.encode(errorCode, forKey: .errorCode)
        } else {
            try values.encodeNil(forKey: .errorCode)
        }
    }
}

private enum HelperError: Error {
    case invalidArguments
    case invalidRequest
    case unsafeFile
    case sizeMismatch
    case digestMismatch
    case containerUnavailable
    case destinationConflict
    case publicationIncomplete
}

private func isHex(_ value: String, count: Int) -> Bool {
    guard value.utf8.count == count else { return false }
    return value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
    }
}

private func validate(_ request: PublishRequest, expectedID: String) throws {
    guard request.version == protocolVersion,
          request.requestID == expectedID,
          isHex(request.requestID, count: 32),
          isHex(request.receiver, count: 32),
          isHex(request.device, count: 32),
          request.finalName.hasSuffix(".hba"),
          isHex(String(request.finalName.dropLast(4)), count: 32),
          request.byteCount > 0,
          request.byteCount <= maximumAckBytes,
          isHex(request.sha256, count: 64)
    else { throw HelperError.invalidRequest }
}

private func readRegularOwnerOnly(_ url: URL, maximumBytes: Int) throws -> Data {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw HelperError.unsafeFile }
    defer { _ = Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_uid == geteuid(),
          (metadata.st_mode & 0o077) == 0,
          metadata.st_size >= 0,
          metadata.st_size <= maximumBytes
    else { throw HelperError.unsafeFile }
    var result = Data()
    result.reserveCapacity(Int(metadata.st_size))
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { break }
        guard count > 0 else {
            if errno == EINTR { continue }
            throw HelperError.unsafeFile
        }
        result.append(buffer, count: count)
        guard result.count <= maximumBytes else { throw HelperError.unsafeFile }
    }
    return result
}

private func digestHex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func writeOwnerOnly<T: Encodable>(_ value: T, to url: URL) throws {
    let data = try JSONEncoder().encode(value)
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: url.path
    )
}

#if !HEALTH_BRIDGE_ISOLATED_HELPER_TEST_HOST
private func applicationRoot() throws -> URL {
    guard let support = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first else { throw HelperError.unsafeFile }
    let root = support.appendingPathComponent(
        "HealthBridgeAckPublisher",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    return root
}

#endif

private func receiptURL(root: URL, requestID: String) -> URL {
    root.appendingPathComponent("receipts", isDirectory: true)
        .appendingPathComponent("\(requestID).json")
}

private func ensureProtocolDirectories(root: URL) throws {
    for name in ["requests", "staging", "receipts"] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

private func destination(
    root: URL,
    request: PublishRequest
) -> (receiver: URL, final: URL) {
    let receiver = root.appendingPathComponent("Documents", isDirectory: true)
        .appendingPathComponent("HealthBridgeMailbox", isDirectory: true)
        .appendingPathComponent("v1", isDirectory: true)
        .appendingPathComponent(request.receiver, isDirectory: true)
    let mailbox = receiver.appendingPathComponent(request.device, isDirectory: true)
    let final = mailbox.appendingPathComponent("acks", isDirectory: true)
        .appendingPathComponent(request.finalName)
    return (receiver, final)
}

// Explicit operations keep the filesystem body shared with the isolated host.
struct HelperPublicationIO {
    let providerRoot: () throws -> URL
    let publish: (URL, URL) throws -> Void
    let observe: (URL) throws -> (isUbiquitous: Bool, uploadError: String?)
    let wait: () -> Void
    var replaceMetadata: (Data, URL, () throws -> Void) throws -> Void = coordinatedCapabilityReplacement
}

#if !HEALTH_BRIDGE_ISOLATED_HELPER_TEST_HOST
private func productionPublicationIO() -> HelperPublicationIO {
    HelperPublicationIO(
        providerRoot: {
            guard let root = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier)
            else { throw HelperError.containerUnavailable }
            return root
        },
        publish: { source, final in
            try FileManager.default.setUbiquitous(true, itemAt: source, destinationURL: final)
        },
        observe: { final in
            let values = try final.resourceValues(
                forKeys: [.isUbiquitousItemKey, .ubiquitousItemUploadingErrorKey]
            )
            let error = (values.ubiquitousItemUploadingError as NSError?).map { "\($0.domain):\($0.code)" }
            return (values.isUbiquitousItem == true, error)
        },
        wait: { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
    )
}
#endif

private func publishAndObserve(
    source: URL,
    final: URL,
    payload: Data,
    maximumBytes: Int,
    io: HelperPublicationIO,
    validatePaths: () throws -> Void = {}
) throws {
    try validatePaths()
    if try entryExists(final) {
        guard try readRegularOwnerOnly(final, maximumBytes: maximumBytes) == payload
        else { throw HelperError.destinationConflict }
    } else {
        try validatePaths()
        try io.publish(source, final)
        try validatePaths()
    }
    let finalData = try readRegularOwnerOnly(final, maximumBytes: maximumBytes)
    let exactBytes = finalData == payload
    var isUbiquitous = false
    var uploadErrorAbsent = false
    var uploadErrorSummary = "none"
    let deadline = Date().addingTimeInterval(60)
    repeat {
        try validatePaths()
        let observation = try io.observe(final)
        isUbiquitous = observation.isUbiquitous
        uploadErrorAbsent = observation.uploadError == nil
        uploadErrorSummary = observation.uploadError ?? "none"
        if exactBytes && isUbiquitous && uploadErrorAbsent { break }
        io.wait()
    } while Date() < deadline
    guard exactBytes && isUbiquitous && uploadErrorAbsent
    else { throw HelperError.publicationIncomplete }
    try validatePaths()
    guard try readRegularOwnerOnly(final, maximumBytes: maximumBytes) == payload else {
        throw HelperError.publicationIncomplete
    }
}

private let maximumPairingBytes = 65_536

private struct PairingPublishRequest: Decodable {
    let version: Int
    let requestID: String
    let invitationID: String
    let finalName: String
    let byteCount: Int
    let sha256: String
}

private struct PairingPublishReceipt: Encodable {
    let version: Int
    let requestID: String
    let invitationID: String
    let finalName: String
    let byteCount: Int
    let sha256: String
    let published: Bool
    let bootstrapVersion: Int
}

private struct DirectoryIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

// Roots come from the existing application/provider owners. Every relative
// component is opened without following links; native publication creates none.
private func checkedDirectoryChain(
    root: URL,
    components: [String],
    ownerOnly: Bool
) throws -> [DirectoryIdentity] {
    guard root.isFileURL else { throw HelperError.unsafeFile }
    var descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw HelperError.unsafeFile }
    defer { _ = Darwin.close(descriptor) }
    var identities: [DirectoryIdentity] = []
    for index in 0...components.count {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              (metadata.st_mode & (ownerOnly ? 0o077 : 0o022)) == 0 else {
            throw HelperError.unsafeFile
        }
        identities.append(DirectoryIdentity(device: metadata.st_dev, inode: metadata.st_ino))
        if index < components.count {
            let component = components[index]
            guard !component.isEmpty, component != ".", component != "..",
                  !component.contains("/") else { throw HelperError.unsafeFile }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw HelperError.unsafeFile }
            _ = Darwin.close(descriptor)
            descriptor = next
        }
    }
    return identities
}

private func entryExists(_ url: URL) throws -> Bool {
    var metadata = stat()
    if lstat(url.path, &metadata) == 0 { return true }
    guard errno == ENOENT else { throw HelperError.unsafeFile }
    return false
}

private func publishPairing(
    requestID: String, appRoot: URL, io: HelperPublicationIO,
    validatePrivate: () throws -> Void = {}
) throws -> PairingPublishReceipt {
    guard isHex(requestID, count: 32) else { throw HelperError.invalidArguments }
    let protocolLanes = ["requests", "staging", "receipts"]
    let protocolIdentities = try protocolLanes.map {
        try checkedDirectoryChain(root: appRoot, components: [$0], ownerOnly: true)
    }
    let requestData = try readRegularOwnerOnly(
        appRoot.appendingPathComponent("requests/\(requestID).json"),
        maximumBytes: maximumRequestBytes
    )
    guard let fields = try JSONSerialization.jsonObject(with: requestData) as? [String: Any],
          Set(fields.keys) == Set(["version", "requestID", "invitationID", "finalName", "byteCount", "sha256"]) else {
        throw HelperError.invalidRequest
    }
    let request = try JSONDecoder().decode(PairingPublishRequest.self, from: requestData)
    guard request.version == protocolVersion,
          request.requestID == requestID,
          isHex(request.invitationID, count: 32),
          ["completion.hbp", "cancelled.hbp"].contains(request.finalName),
          request.byteCount > 0, request.byteCount <= maximumPairingBytes,
          isHex(request.sha256, count: 64) else { throw HelperError.invalidRequest }
    let source = appRoot.appendingPathComponent("staging/\(requestID).hbp")
    let payload = try readRegularOwnerOnly(source, maximumBytes: maximumPairingBytes)
    guard payload.count == request.byteCount else { throw HelperError.sizeMismatch }
    guard digestHex(payload) == request.sha256 else { throw HelperError.digestMismatch }
    let providerRoot = try io.providerRoot()
    let providerPath = providerRoot.resolvingSymlinksInPath().standardizedFileURL.path
    let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
    guard sourcePath != providerPath, !sourcePath.hasPrefix(providerPath + "/") else {
        throw HelperError.unsafeFile
    }
    let components = ["Documents", "HealthBridgeMailbox", "v1", "pairing", request.invitationID]
    let providerIdentities = try checkedDirectoryChain(
        root: providerRoot, components: components, ownerOnly: false
    )
    let directory = components.reduce(providerRoot) { $0.appendingPathComponent($1, isDirectory: true) }
    let final = directory.appendingPathComponent(request.finalName)
    func requireAttachedPaths() throws {
        try validatePrivate()
        guard try protocolLanes.map({
            try checkedDirectoryChain(root: appRoot, components: [$0], ownerOnly: true)
        }) == protocolIdentities,
        try checkedDirectoryChain(root: providerRoot, components: components, ownerOnly: false) == providerIdentities else {
            throw HelperError.unsafeFile
        }
    }
    try requireAttachedPaths()
    try publishAndObserve(
        source: source, final: final, payload: payload, maximumBytes: maximumPairingBytes,
        io: io, validatePaths: requireAttachedPaths
    )
    try requireAttachedPaths()
    return PairingPublishReceipt(
        version: protocolVersion, requestID: requestID, invitationID: request.invitationID,
        finalName: request.finalName, byteCount: request.byteCount, sha256: request.sha256,
        published: true, bootstrapVersion: protocolVersion
    )
}

private func publish(
    requestID: String, appRoot: URL, io: HelperPublicationIO,
    validatePrivate: (() throws -> Void)? = nil
) throws -> PublishReceipt {
    guard isHex(requestID, count: 32) else { throw HelperError.invalidArguments }
    let manager = FileManager.default
    if validatePrivate == nil { try ensureProtocolDirectories(root: appRoot) }
    let requestData = try readRegularOwnerOnly(
        appRoot.appendingPathComponent("requests/\(requestID).json"),
        maximumBytes: maximumRequestBytes
    )
    let request = try JSONDecoder().decode(PublishRequest.self, from: requestData)
    try validate(request, expectedID: requestID)
    let source = appRoot.appendingPathComponent("staging/\(requestID).hba")
    let payload = try readRegularOwnerOnly(source, maximumBytes: maximumAckBytes)
    guard payload.count == request.byteCount else { throw HelperError.sizeMismatch }
    guard digestHex(payload) == request.sha256 else { throw HelperError.digestMismatch }
    let providerRoot = try io.providerRoot()
    let providerPath = providerRoot.resolvingSymlinksInPath().standardizedFileURL.path
    let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
    let sourceOutsideProvider = sourcePath != providerPath && !sourcePath.hasPrefix(providerPath + "/")
    guard sourceOutsideProvider else { throw HelperError.unsafeFile }
    let urls = destination(root: providerRoot, request: request)
    let mailbox = urls.receiver.appendingPathComponent(request.device, isDirectory: true)
    let components = ["Documents", "HealthBridgeMailbox", "v1", request.receiver, request.device]
    for lane in ["deliveries", "acks", "quarantine"] {
        if validatePrivate != nil {
            try createACKDirectoryChain(root: providerRoot, components: components + [lane])
        } else {
            try manager.createDirectory(
                at: mailbox.appendingPathComponent(lane, isDirectory: true),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
    let identities = try validatePrivate.map { _ in
        try checkedDirectoryChain(root: providerRoot, components: components + ["acks"], ownerOnly: false)
    }
    try publishAndObserve(
        source: source, final: urls.final, payload: payload, maximumBytes: maximumAckBytes, io: io,
        validatePaths: {
            try validatePrivate?()
            if let identities {
                guard try checkedDirectoryChain(root: providerRoot, components: components + ["acks"], ownerOnly: false)
                    == identities else { throw HelperError.unsafeFile }
            }
        }
    )
    return PublishReceipt(
        version: protocolVersion,
        requestID: request.requestID,
        receiver: request.receiver,
        device: request.device,
        finalName: request.finalName,
        byteCount: request.byteCount,
        sha256: request.sha256,
        published: true,
        exactBytes: true,
        isUbiquitous: true,
        uploadErrorAbsent: true,
        sourceOutsideProvider: sourceOutsideProvider,
        errorDomain: nil,
        errorCode: nil
    )
}

private let maximumCapabilitiesBytes = 8_192
private let capabilitiesFilename = "receiver-capabilities.json"

private struct CapabilitiesRequest: Codable {
    let version: Int
    let operation: String
    let requestID: String
    let receiver: String
    let device: String
    let byteCount: Int
    let sha256: String
}

private struct CapabilitiesReceipt: Encodable {
    let version: Int
    let operation: String
    let requestID: String
    let receiver: String
    let device: String
    let byteCount: Int
    let sha256: String
    let stored = true
    let exactBytes = true
    let isUbiquitous = true
}

private struct CapabilityFileSnapshot: Equatable {
    let bytes: Data
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let owner: uid_t
    let links: nlink_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(bytes: Data, metadata: stat) {
        self.bytes = bytes
        device = metadata.st_dev; inode = metadata.st_ino; mode = metadata.st_mode
        owner = metadata.st_uid; links = metadata.st_nlink; size = metadata.st_size
        modifiedSeconds = metadata.st_mtimespec.tv_sec; modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
        changedSeconds = metadata.st_ctimespec.tv_sec; changedNanoseconds = metadata.st_ctimespec.tv_nsec
    }
}

private func readCapabilityFile(_ url: URL) throws -> CapabilityFileSnapshot {
    var before = stat()
    guard lstat(url.path, &before) == 0,
          (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1 else { throw HelperError.unsafeFile }
    let bytes = try readRegularOwnerOnly(url, maximumBytes: maximumCapabilitiesBytes)
    let snapshot = CapabilityFileSnapshot(bytes: bytes, metadata: before)
    var after = stat()
    guard lstat(url.path, &after) == 0,
          CapabilityFileSnapshot(bytes: bytes, metadata: after) == snapshot else { throw HelperError.unsafeFile }
    return snapshot
}

private func readCapabilityBytes(_ url: URL) throws -> Data {
    try readCapabilityFile(url).bytes
}

// Both production and the isolated helper host execute this same atomic replacement.
func coordinatedCapabilityReplacement(_ payload: Data, _ final: URL, _ validatePaths: () throws -> Void) throws {
    let manager = FileManager.default
    try validatePaths()
    let scratch = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                  appropriateFor: final.deletingLastPathComponent(), create: true)
    defer { try? manager.removeItem(at: scratch) }
    let staged = scratch.appendingPathComponent("receiver-capabilities.tmp")
    try payload.write(to: staged, options: .withoutOverwriting)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
    let descriptor = Darwin.open(staged.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw HelperError.unsafeFile }
    defer { _ = Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else { throw HelperError.publicationIncomplete }
    var stagedMetadata = stat(), directoryMetadata = stat()
    guard fstat(descriptor, &stagedMetadata) == 0,
          lstat(final.deletingLastPathComponent().path, &directoryMetadata) == 0,
          stagedMetadata.st_dev == directoryMetadata.st_dev else { throw HelperError.unsafeFile }
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var result: Result<Void, Error> = .failure(HelperError.publicationIncomplete)
    coordinator.coordinate(writingItemAt: final, options: .forReplacing, error: &coordinationError) { coordinated in
        result = Result {
            guard coordinated.standardizedFileURL == final.standardizedFileURL else { throw HelperError.unsafeFile }
            try validatePaths()
            guard try readCapabilityBytes(staged) == payload else { throw HelperError.digestMismatch }
            if try entryExists(final) {
                _ = try readCapabilityBytes(final)
                _ = try manager.replaceItemAt(final, withItemAt: staged, backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try manager.moveItem(at: staged, to: final)
            }
            try validatePaths()
            guard try readCapabilityBytes(final) == payload else { throw HelperError.publicationIncomplete }
        }
    }
    if let coordinationError { throw coordinationError }
    try result.get()
}

private func publishCapabilities(
    requestID: String, appRoot: URL, io: HelperPublicationIO,
    validatePrivate: () throws -> Void = {}
) throws -> CapabilitiesReceipt {
    guard isHex(requestID, count: 32) else { throw HelperError.invalidArguments }
    let lanes = ["requests", "staging", "receipts"]
    let protocolIdentities = try lanes.map { try checkedDirectoryChain(root: appRoot, components: [$0], ownerOnly: true) }
    let requestURL = appRoot.appendingPathComponent("requests/\(requestID).json")
    let requestSnapshot = try readCapabilityFile(requestURL)
    let encoded = requestSnapshot.bytes
    guard let fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
          Set(fields.keys) == Set(["version", "operation", "requestID", "receiver", "device", "byteCount", "sha256"]),
          try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]) == encoded else {
        throw HelperError.invalidRequest
    }
    let request = try JSONDecoder().decode(CapabilitiesRequest.self, from: encoded)
    guard request.version == protocolVersion, request.operation == "receiver_capabilities",
          request.requestID == requestID, isHex(request.receiver, count: 32), isHex(request.device, count: 32),
          request.byteCount > 0, request.byteCount <= maximumCapabilitiesBytes, isHex(request.sha256, count: 64) else {
        throw HelperError.invalidRequest
    }
    let source = appRoot.appendingPathComponent("staging/\(requestID).json")
    let sourceSnapshot = try readCapabilityFile(source)
    let payload = sourceSnapshot.bytes
    guard payload.count == request.byteCount, digestHex(payload) == request.sha256 else { throw HelperError.digestMismatch }
    let provider = try io.providerRoot()
    let providerPath = provider.resolvingSymlinksInPath().standardizedFileURL.path
    let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
    guard sourcePath != providerPath, !sourcePath.hasPrefix(providerPath + "/") else { throw HelperError.unsafeFile }
    let components = ["Documents", "HealthBridgeMailbox", "v1", request.receiver, request.device]
    let identities = try checkedDirectoryChain(root: provider, components: components, ownerOnly: false)
    let final = components.reduce(provider) { $0.appendingPathComponent($1, isDirectory: true) }.appendingPathComponent(capabilitiesFilename)
    func validatePaths() throws {
        try validatePrivate()
        guard try lanes.map({ try checkedDirectoryChain(root: appRoot, components: [$0], ownerOnly: true) }) == protocolIdentities,
              try checkedDirectoryChain(root: provider, components: components, ownerOnly: false) == identities,
              try readCapabilityFile(requestURL) == requestSnapshot,
              try readCapabilityFile(source) == sourceSnapshot else { throw HelperError.unsafeFile }
    }
    try validatePaths()
    let current = try entryExists(final) ? readCapabilityBytes(final) : nil
    if current != payload { try io.replaceMetadata(payload, final, validatePaths) }
    try validatePaths()
    guard try readCapabilityBytes(final) == payload else { throw HelperError.publicationIncomplete }
    let observation = try io.observe(final)
    guard observation.isUbiquitous, observation.uploadError == nil else { throw HelperError.publicationIncomplete }
    try validatePaths()
    guard try readCapabilityBytes(final) == payload else { throw HelperError.publicationIncomplete }
    return CapabilitiesReceipt(version: 1, operation: request.operation, requestID: requestID,
        receiver: request.receiver, device: request.device, byteCount: request.byteCount, sha256: request.sha256)
}

// IPC transport has one bounded request and one bounded response, not a service.
struct PublicationIPCResult {
    let response: Data
    let exitCode: Int32
}

private enum PublicationIPCError: String, Error {
    case invalidRequest = "invalid_request"
    case unsafeStorage = "unsafe_storage"
    case storageAccessDenied = "storage_access_denied"
    case storageIOFailed = "storage_io_failed"
    case helperBusy = "helper_busy"
    case providerUnavailable = "provider_unavailable"
    case destinationConflict = "destination_conflict"
    case publicationFailed = "publication_failed"
}

// The deadline covers every partial read/write and EINTR, and is never reset.
// Descriptors are borrowed; the process host owns their lifetime.
final class PublicationIPCPipe {
    private let descriptor: Int32
    private let flags: Int32
    private let deadline: TimeInterval

    init(descriptor: Int32, deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 10) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { throw PublicationIPCError.invalidRequest }
        self.descriptor = descriptor
        self.flags = flags
        self.deadline = deadline
    }

    deinit { _ = fcntl(descriptor, F_SETFL, flags) }

    private func ready(_ events: Int16) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw PublicationIPCError.invalidRequest }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let timeout = Int32(min(ceil(remaining * 1_000), Double(Int32.max)))
            let result = poll(&item, 1, timeout)
            if result < 0 && errno == EINTR { continue }
            guard result > 0, item.revents & Int16(POLLNVAL) == 0 else {
                throw PublicationIPCError.invalidRequest
            }
            return
        }
    }

    func read(_ maximum: Int) throws -> Data {
        guard maximum > 0, maximum <= maximumAckBytes else { throw PublicationIPCError.invalidRequest }
        var bytes = [UInt8](repeating: 0, count: min(maximum, 16_384))
        while true {
            try ready(Int16(POLLIN))
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count >= 0 else { throw PublicationIPCError.invalidRequest }
            return Data(bytes.prefix(count))
        }
    }

    func write(_ data: Data) throws {
        guard data.count <= maximumRequestBytes + 4 else { throw PublicationIPCError.invalidRequest }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try ready(Int16(POLLOUT))
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                guard count > 0 else { throw PublicationIPCError.invalidRequest }
                offset += count
            }
        }
    }
}

private enum IPCOperation: String, Codable {
    case ack, pairing, receiverCapabilities = "receiver_capabilities", storageProbe = "storage_probe"
}

private struct IPCRequest: Codable {
    let version: Int
    let operation: IPCOperation
    let requestID: String
    let byteCount: Int
    let sha256: String
    let receiver: String?
    let device: String?
    let invitationID: String?
    let finalName: String?

    var sourceExtension: String {
        switch operation {
        case .ack: return "hba"
        case .pairing: return "hbp"
        case .receiverCapabilities, .storageProbe: return "json"
        }
    }

    func fields() throws -> [String: Any] {
        guard let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any]
        else { throw PublicationIPCError.invalidRequest }
        return fields
    }

    static func parse(_ data: Data) throws -> IPCRequest {
        guard data.allSatisfy({ $0 < 128 }),
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PublicationIPCError.invalidRequest
        }
        let value = try JSONDecoder().decode(IPCRequest.self, from: data)
        var keys: Set<String> = ["version", "operation", "requestID", "byteCount", "sha256"]
        let limit: Int
        switch value.operation {
        case .ack:
            keys.formUnion(["receiver", "device", "finalName"]); limit = maximumAckBytes
            guard let name = value.finalName, name.hasSuffix(".hba"),
                  isHex(String(name.dropLast(4)), count: 32) else { throw PublicationIPCError.invalidRequest }
        case .pairing:
            keys.formUnion(["invitationID", "finalName"]); limit = maximumPairingBytes
            guard isHex(value.invitationID ?? "", count: 32),
                  ["completion.hbp", "cancelled.hbp"].contains(value.finalName ?? "") else {
                throw PublicationIPCError.invalidRequest
            }
        case .receiverCapabilities:
            keys.formUnion(["receiver", "device"]); limit = maximumCapabilitiesBytes
        case .storageProbe: limit = 0
        }
        if value.operation == .ack || value.operation == .receiverCapabilities {
            guard isHex(value.receiver ?? "", count: 32), isHex(value.device ?? "", count: 32) else {
                throw PublicationIPCError.invalidRequest
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard Set(fields.keys) == keys, value.version == 1, isHex(value.requestID, count: 32),
              isHex(value.sha256, count: 64), value.byteCount <= limit,
              value.byteCount >= (value.operation == .storageProbe ? 0 : 1),
              try encoder.encode(value) == data else { throw PublicationIPCError.invalidRequest }
        return value
    }
}

private func ipcResponse(_ fields: [String: Any], exitCode: Int32) throws -> PublicationIPCResult {
    let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
    guard (1...maximumRequestBytes).contains(data.count) else { throw PublicationIPCError.invalidRequest }
    let count = UInt32(data.count)
    let prefix = Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
    return PublicationIPCResult(response: prefix + data, exitCode: exitCode)
}

private func privateIOError(_ code: Int32 = errno) -> PublicationIPCError {
    switch code {
    case EACCES, EPERM: return .storageAccessDenied
    case ELOOP, ENOTDIR: return .unsafeStorage
    default: return .storageIOFailed
    }
}

private final class IPCDescriptor {
    let raw: Int32
    init(_ raw: Int32) throws {
        guard raw >= 0 else { throw privateIOError() }
        self.raw = raw
    }
    deinit { _ = Darwin.close(raw) }
}

private func ipcMetadata(_ descriptor: Int32, directory: Bool, maximum: Int = 0) throws -> stat {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else { throw privateIOError() }
    guard (metadata.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG),
          metadata.st_uid == geteuid(),
          (metadata.st_mode & 0o7777) == (directory ? 0o700 : 0o600),
          directory || (metadata.st_nlink == 1 && metadata.st_size >= 0 && metadata.st_size <= maximum) else {
        throw PublicationIPCError.unsafeStorage
    }
    return metadata
}

private func sameIdentity(_ first: stat, _ second: stat) -> Bool {
    first.st_dev == second.st_dev && first.st_ino == second.st_ino
}

private func ipcDirectory(_ parent: Int32, _ name: String) throws -> IPCDescriptor {
    if mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw privateIOError() }
    let result = try IPCDescriptor(openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
    _ = try ipcMetadata(result.raw, directory: true)
    guard fsync(parent) == 0 else { throw privateIOError() }
    return result
}

private struct IPCStagedFile {
    let lane: String
    let name: String
    let descriptor: IPCDescriptor
    let bytes: Data
}

private final class IPCWorkspace {
    let url: URL
    private let applicationURL: URL
    private let application: IPCDescriptor
    private let directory: IPCDescriptor
    private let lock: IPCDescriptor
    private let lanes: [String: IPCDescriptor]
    private var staged: [IPCStagedFile] = []

    init(root: URL) throws {
        guard root.isFileURL else { throw PublicationIPCError.unsafeStorage }
        applicationURL = root
        application = try IPCDescriptor(Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        _ = try ipcMetadata(application.raw, directory: true)
        directory = try ipcDirectory(application.raw, "ipc-v1")
        url = root.appendingPathComponent("ipc-v1", isDirectory: true)
        lock = try IPCDescriptor(openat(directory.raw, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600))
        _ = try ipcMetadata(lock.raw, directory: false)
        if flock(lock.raw, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK { throw PublicationIPCError.helperBusy }
            throw privateIOError()
        }
        let pinnedLock = try ipcMetadata(lock.raw, directory: false)
        var namedLock = stat()
        guard fstatat(directory.raw, "lock", &namedLock, AT_SYMLINK_NOFOLLOW) == 0 else { throw privateIOError() }
        guard sameIdentity(pinnedLock, namedLock) else { throw PublicationIPCError.unsafeStorage }
        var values: [String: IPCDescriptor] = [:]
        for lane in ["requests", "staging", "receipts"] { values[lane] = try ipcDirectory(directory.raw, lane) }
        lanes = values
        try attached()
    }

    // Closing the pinned lock descriptor releases flock, including on throws.
    private func attachedEntry(parent: Int32, name: String, descriptor: Int32, directory: Bool, maximum: Int = 0) throws {
        let pinned = try ipcMetadata(descriptor, directory: directory, maximum: maximum)
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw privateIOError() }
        guard sameIdentity(pinned, current) else { throw PublicationIPCError.unsafeStorage }
    }

    func attached() throws {
        let pinned = try ipcMetadata(application.raw, directory: true)
        var current = stat()
        guard lstat(applicationURL.path, &current) == 0 else { throw privateIOError() }
        guard sameIdentity(pinned, current) else { throw PublicationIPCError.unsafeStorage }
        try attachedEntry(parent: application.raw, name: "ipc-v1", descriptor: directory.raw, directory: true)
        try attachedEntry(parent: directory.raw, name: "lock", descriptor: lock.raw, directory: false)
        for (name, descriptor) in lanes {
            try attachedEntry(parent: directory.raw, name: name, descriptor: descriptor.raw, directory: true)
        }
    }

    private func lane(_ name: String) -> Int32 { lanes[name]!.raw }

    private func checkedFile(lane: String, name: String, maximum: Int) throws -> IPCDescriptor {
        let file = try IPCDescriptor(openat(self.lane(lane), name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
        try attachedEntry(parent: self.lane(lane), name: name, descriptor: file.raw, directory: false, maximum: maximum)
        return file
    }

    func sweep() throws {
        try attached()
        var remnants: [(String, String, IPCDescriptor, Int)] = []
        for name in ["requests", "staging", "receipts"] {
            // openat(".") supplies an independent directory offset, not dup's shared offset.
            let scanFD = openat(lane(name), ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard scanFD >= 0 else { throw privateIOError() }
            guard let stream = fdopendir(scanFD) else {
                let code = errno; _ = Darwin.close(scanFD); throw privateIOError(code)
            }
            defer { closedir(stream) }
            var entries: [String] = []
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw privateIOError() }
                    break
                }
                let value = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if value == "." || value == ".." { continue }
                entries.append(value)
                guard entries.count <= 1 else { throw PublicationIPCError.unsafeStorage }
            }
            for entry in entries {
                let maximum: Int
                if entry == ".storage-probe" { maximum = 64 }
                else {
                    let parts = entry.split(separator: ".", omittingEmptySubsequences: false)
                    guard parts.count == 2, isHex(String(parts[0]), count: 32),
                          (name == "requests" && parts[1] == "json")
                            || (name == "staging" && ["hba", "hbp", "json"].contains(String(parts[1]))) else {
                        throw PublicationIPCError.unsafeStorage
                    }
                    maximum = name == "requests" ? maximumRequestBytes : maximumAckBytes
                }
                remnants.append((name, entry, try checkedFile(lane: name, name: entry, maximum: maximum), maximum))
            }
        }
        // Validate the entire bounded inventory before deleting any entry.
        for (lane, name, descriptor, maximum) in remnants {
            try attached()
            try attachedEntry(parent: self.lane(lane), name: name, descriptor: descriptor.raw, directory: false, maximum: maximum)
            guard unlinkat(self.lane(lane), name, 0) == 0, fsync(self.lane(lane)) == 0 else { throw privateIOError() }
        }
        try attached()
    }

    func stage(_ bytes: Data, lane: String, name: String) throws {
        try attached()
        let descriptor = try IPCDescriptor(openat(self.lane(lane), name,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
        // Track before writing so a partial write can also be cleaned under the lock.
        staged.append(IPCStagedFile(lane: lane, name: name, descriptor: descriptor, bytes: bytes))
        _ = try ipcMetadata(descriptor.raw, directory: false, maximum: bytes.count)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor.raw, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw privateIOError() }
                offset += count
            }
        }
        guard fsync(descriptor.raw) == 0, fsync(self.lane(lane)) == 0 else { throw privateIOError() }
        try validateStaged()
    }

    func validateStaged() throws {
        try attached()
        for file in staged {
            var current = stat()
            if fstatat(lane(file.lane), file.name, &current, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT && file.lane == "staging" { continue } // setUbiquitous may consume it.
                throw privateIOError()
            }
            try attachedEntry(parent: lane(file.lane), name: file.name, descriptor: file.descriptor.raw,
                directory: false, maximum: file.bytes.count)
            var bytes = Data(count: file.bytes.count)
            let count = try bytes.withUnsafeMutableBytes { buffer -> Int in
                var offset = 0
                while offset < buffer.count {
                    let count = pread(file.descriptor.raw, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0 else { throw privateIOError() }
                    if count == 0 { break }
                    offset += count
                }
                return offset
            }
            guard count == file.bytes.count, bytes == file.bytes else { throw PublicationIPCError.unsafeStorage }
        }
    }

    func cleanup() throws {
        try attached()
        for file in staged {
            var current = stat()
            if fstatat(lane(file.lane), file.name, &current, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT && file.lane == "staging" { continue }
                throw privateIOError()
            }
            try attachedEntry(parent: lane(file.lane), name: file.name, descriptor: file.descriptor.raw,
                directory: false, maximum: file.bytes.count)
            guard unlinkat(lane(file.lane), file.name, 0) == 0 else { throw privateIOError() }
        }
        for descriptor in lanes.values {
            guard fsync(descriptor.raw) == 0 else { throw privateIOError() }
        }
        staged.removeAll()
        try attached()
    }

    func probe() throws {
        for lane in ["requests", "staging", "receipts"] {
            try stage(Data("health-bridge-ipc-v1".utf8), lane: lane, name: ".storage-probe")
            try validateStaged()
            try cleanup()
        }
    }
}

private func createACKDirectoryChain(root: URL, components: [String]) throws {
    var descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw HelperError.unsafeFile }
    defer { _ = Darwin.close(descriptor) }
    for index in 0...components.count {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == geteuid(),
              (metadata.st_mode & S_IFMT) == S_IFDIR, (metadata.st_mode & 0o022) == 0 else {
            throw HelperError.unsafeFile
        }
        if index < components.count {
            let name = components[index]
            if mkdirat(descriptor, name, 0o700) != 0 && errno != EEXIST { throw HelperError.unsafeFile }
            let next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw HelperError.unsafeFile }
            _ = Darwin.close(descriptor); descriptor = next
        }
    }
}

private func publicationCode(_ error: Error) -> PublicationIPCError {
    if let value = error as? PublicationIPCError { return value }
    switch error as? HelperError {
    case .containerUnavailable: return .providerUnavailable
    case .destinationConflict: return .destinationConflict
    default: return .publicationFailed
    }
}

// Shared by the signed executable and the separately compiled actual-process host.
// input returns at most its requested count; empty means EOF. It must have a deadline.
func runPublicationIPC(
    input: (Int) throws -> Data, applicationRoot: () throws -> URL, io: HelperPublicationIO
) -> PublicationIPCResult {
    var accepted: IPCRequest?
    func failure(_ code: PublicationIPCError) -> PublicationIPCResult {
        do {
            var fields = try accepted?.fields() ?? ["version": 1, "operation": NSNull(), "requestID": NSNull()]
            fields["status"] = "error"; fields["code"] = code.rawValue
            return try ipcResponse(fields, exitCode: 3)
        } catch {
            // Constant, canonical, unbound failure; no filesystem or raw error output.
            let body = Data("{\"code\":\"invalid_request\",\"operation\":null,\"requestID\":null,\"status\":\"error\",\"version\":1}".utf8)
            return PublicationIPCResult(response: Data([0, 0, 0, UInt8(body.count)]) + body, exitCode: 3)
        }
    }
    func readExactly(_ count: Int) throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            let part = try input(count - bytes.count)
            guard !part.isEmpty, part.count <= count - bytes.count else { throw PublicationIPCError.invalidRequest }
            bytes.append(part)
        }
        return bytes
    }
    let request: IPCRequest
    let payload: Data
    do {
        let length = try readExactly(4).reduce(0) { ($0 << 8) | Int($1) }
        guard (1...maximumRequestBytes).contains(length) else { throw PublicationIPCError.invalidRequest }
        request = try IPCRequest.parse(readExactly(length))
        accepted = request
        payload = try readExactly(request.byteCount)
        guard try input(1).isEmpty, digestHex(payload) == request.sha256 else { throw PublicationIPCError.invalidRequest }
    } catch { return failure(.invalidRequest) }
    do {
        let root: URL
        do { root = try applicationRoot() }
        catch {
            let error = error as NSError
            let posix = error.domain == NSPOSIXErrorDomain ? error : error.userInfo[NSUnderlyingErrorKey] as? NSError
            if let posix, posix.domain == NSPOSIXErrorDomain { throw privateIOError(Int32(posix.code)) }
            throw PublicationIPCError.storageIOFailed
        }
        let workspace = try IPCWorkspace(root: root)
        try workspace.sweep()
        let result: PublicationIPCResult
        do {
            var fields = try request.fields()
            if request.operation == .storageProbe {
                try workspace.probe()
                fields["storageReady"] = true
            } else {
                var legacy = fields
                if request.operation != .receiverCapabilities { legacy.removeValue(forKey: "operation") }
                let metadata = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys, .withoutEscapingSlashes])
                try workspace.stage(metadata, lane: "requests", name: "\(request.requestID).json")
                try workspace.stage(payload, lane: "staging", name: "\(request.requestID).\(request.sourceExtension)")
                let encoded: Data
                let encoder = JSONEncoder()
                switch request.operation {
                case .ack:
                    encoded = try encoder.encode(publish(requestID: request.requestID, appRoot: workspace.url,
                        io: io, validatePrivate: workspace.validateStaged))
                case .pairing:
                    encoded = try encoder.encode(publishPairing(requestID: request.requestID, appRoot: workspace.url,
                        io: io, validatePrivate: workspace.validateStaged))
                case .receiverCapabilities:
                    encoded = try encoder.encode(publishCapabilities(requestID: request.requestID, appRoot: workspace.url,
                        io: io, validatePrivate: workspace.validateStaged))
                case .storageProbe: throw PublicationIPCError.invalidRequest
                }
                guard let receipt = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                    throw PublicationIPCError.publicationFailed
                }
                for (key, value) in legacy {
                    guard (receipt[key] as? NSObject) == (value as? NSObject) else { throw PublicationIPCError.publicationFailed }
                }
                fields.merge(receipt) { _, value in value }
            }
            fields["status"] = "ok"
            result = try ipcResponse(fields, exitCode: 0)
        } catch {
            let result = failure(publicationCode(error))
            try workspace.cleanup()
            return result
        }
        try workspace.cleanup()
        return result
    } catch { return failure(publicationCode(error)) }
}

func runHelper(arguments: [String], applicationRoot: () throws -> URL, io: HelperPublicationIO) throws -> String {
    guard arguments.count == 1, let requestID = arguments.first else { throw HelperError.invalidArguments }
    if requestID == "--publication-ipc-v1-capabilities" {
        return "publication-ipc-v1:ack,pairing,receiver_capabilities,storage_probe"
    }
    if requestID == "--native-pairing-cancellation-v1" {
        return "native-pairing-cancellation-v1:available"
    }
    if requestID.hasPrefix("capabilities:") {
        let identifier = String(requestID.dropFirst("capabilities:".count))
        guard isHex(identifier, count: 32) else { throw HelperError.invalidArguments }
        let root = try applicationRoot()
        let path = receiptURL(root: root, requestID: identifier)
        if try entryExists(path) { _ = try readCapabilityBytes(path) }
        let receipt = try publishCapabilities(requestID: identifier, appRoot: root, io: io)
        try writeOwnerOnly(receipt, to: path)
        return ""
    }
    if requestID.hasPrefix("pairing:") {
        let nativeID = String(requestID.dropFirst("pairing:".count))
        guard isHex(nativeID, count: 32) else { throw HelperError.invalidArguments }
        let root = try applicationRoot()
        let path = receiptURL(root: root, requestID: nativeID)
        if try entryExists(path) { _ = try readRegularOwnerOnly(path, maximumBytes: maximumRequestBytes) }
        let receipt = try publishPairing(requestID: nativeID, appRoot: root, io: io)
        try writeOwnerOnly(receipt, to: path)
        return ""
    }
    let appRoot = try applicationRoot()
    try ensureProtocolDirectories(root: appRoot)
    let receipt = try publish(requestID: requestID, appRoot: appRoot, io: io)
    try writeOwnerOnly(receipt, to: receiptURL(root: appRoot, requestID: requestID))
    return ""
}

#if HEALTH_BRIDGE_ISOLATED_HELPER_TEST_HOST
NativePairingLocalFakeTests.runAll()
#else
precondition(Bundle.main.bundleIdentifier == expectedBundleIdentifier)
precondition(
    requiredStringArrayEntitlement(
        "com.apple.developer.icloud-container-identifiers"
    ) == [containerIdentifier]
)
precondition(
    requiredStringArrayEntitlement(
        "com.apple.developer.ubiquity-container-identifiers"
    ) == [containerIdentifier]
)
precondition(
    requiredStringArrayEntitlement("com.apple.developer.icloud-services")
        == ["CloudDocuments"]
)

let arguments = CommandLine.arguments.dropFirst()
if Array(arguments) == ["--publication-ipc-v1"] {
    do {
        let input = Result { try PublicationIPCPipe(descriptor: STDIN_FILENO) }
        let result = runPublicationIPC(input: { try input.get().read($0) },
            applicationRoot: applicationRoot, io: productionPublicationIO())
        let output = try PublicationIPCPipe(descriptor: STDOUT_FILENO)
        try output.write(result.response)
        Darwin.exit(result.exitCode)
    } catch {
        // A broken/expired output pipe cannot carry a receipt. Never log its error.
        Darwin.exit(3)
    }
}
do {
    let output = try runHelper(
        arguments: Array(arguments), applicationRoot: applicationRoot, io: productionPublicationIO()
    )
    if !output.isEmpty { print(output) }
    Darwin.exit(0)
} catch {
    let value = error as NSError
    fputs("helper_error=\(value.domain):\(value.code)\n", stderr)
    Darwin.exit(3)
}

#endif
