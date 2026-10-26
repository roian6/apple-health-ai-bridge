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

private func publishPairing(requestID: String, appRoot: URL, io: HelperPublicationIO) throws {
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
    let receiptPath = receiptURL(root: appRoot, requestID: requestID)
    func requireAttachedPaths() throws {
        guard try protocolLanes.map({
            try checkedDirectoryChain(root: appRoot, components: [$0], ownerOnly: true)
        }) == protocolIdentities,
        try checkedDirectoryChain(root: providerRoot, components: components, ownerOnly: false) == providerIdentities else {
            throw HelperError.unsafeFile
        }
    }
    try requireAttachedPaths()
    if try entryExists(receiptPath) {
        _ = try readRegularOwnerOnly(receiptPath, maximumBytes: maximumRequestBytes)
    }
    try publishAndObserve(
        source: source, final: final, payload: payload, maximumBytes: maximumPairingBytes,
        io: io, validatePaths: requireAttachedPaths
    )
    try requireAttachedPaths()
    try writeOwnerOnly(PairingPublishReceipt(
        version: protocolVersion, requestID: requestID, invitationID: request.invitationID,
        finalName: request.finalName, byteCount: request.byteCount, sha256: request.sha256,
        published: true, bootstrapVersion: protocolVersion
    ), to: receiptPath)
}

private func publish(requestID: String, appRoot: URL, io: HelperPublicationIO) throws -> PublishReceipt {
    guard isHex(requestID, count: 32) else { throw HelperError.invalidArguments }
    let manager = FileManager.default
    try ensureProtocolDirectories(root: appRoot)
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
    let sourceOutsideProvider = !source.path.hasPrefix(providerRoot.path + "/")
    guard sourceOutsideProvider else { throw HelperError.unsafeFile }
    let urls = destination(root: providerRoot, request: request)
    let mailbox = urls.receiver.appendingPathComponent(request.device, isDirectory: true)
    for lane in ["deliveries", "acks", "quarantine"] {
        try manager.createDirectory(
            at: mailbox.appendingPathComponent(lane, isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
    try publishAndObserve(
        source: source, final: urls.final, payload: payload, maximumBytes: maximumAckBytes, io: io
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

private func publishCapabilities(requestID: String, appRoot: URL, io: HelperPublicationIO) throws {
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
        guard try lanes.map({ try checkedDirectoryChain(root: appRoot, components: [$0], ownerOnly: true) }) == protocolIdentities,
              try checkedDirectoryChain(root: provider, components: components, ownerOnly: false) == identities,
              try readCapabilityFile(requestURL) == requestSnapshot,
              try readCapabilityFile(source) == sourceSnapshot else { throw HelperError.unsafeFile }
    }
    let receipt = receiptURL(root: appRoot, requestID: requestID)
    if try entryExists(receipt) { _ = try readCapabilityBytes(receipt) }
    try validatePaths()
    let current = try entryExists(final) ? readCapabilityBytes(final) : nil
    if current != payload { try io.replaceMetadata(payload, final, validatePaths) }
    try validatePaths()
    guard try readCapabilityBytes(final) == payload else { throw HelperError.publicationIncomplete }
    let observation = try io.observe(final)
    guard observation.isUbiquitous, observation.uploadError == nil else { throw HelperError.publicationIncomplete }
    try validatePaths()
    guard try readCapabilityBytes(final) == payload else { throw HelperError.publicationIncomplete }
    try writeOwnerOnly(CapabilitiesReceipt(version: 1, operation: request.operation, requestID: requestID,
        receiver: request.receiver, device: request.device, byteCount: request.byteCount, sha256: request.sha256), to: receipt)
}

func runHelper(arguments: [String], applicationRoot: () throws -> URL, io: HelperPublicationIO) throws -> String {
    guard arguments.count == 1, let requestID = arguments.first else { throw HelperError.invalidArguments }
    if requestID == "--native-pairing-cancellation-v1" {
        return "native-pairing-cancellation-v1:available"
    }
    if requestID.hasPrefix("capabilities:") {
        let identifier = String(requestID.dropFirst("capabilities:".count))
        guard isHex(identifier, count: 32) else { throw HelperError.invalidArguments }
        try publishCapabilities(requestID: identifier, appRoot: applicationRoot(), io: io)
        return ""
    }
    if requestID.hasPrefix("pairing:") {
        let nativeID = String(requestID.dropFirst("pairing:".count))
        guard isHex(nativeID, count: 32) else { throw HelperError.invalidArguments }
        try publishPairing(requestID: nativeID, appRoot: applicationRoot(), io: io)
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
