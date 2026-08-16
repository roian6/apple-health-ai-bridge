import CryptoKit
import Darwin
import Foundation
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

private func publish(requestID: String) throws -> PublishReceipt {
    guard isHex(requestID, count: 32) else { throw HelperError.invalidArguments }
    let manager = FileManager.default
    let appRoot = try applicationRoot()
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
    guard let providerRoot = manager.url(
        forUbiquityContainerIdentifier: containerIdentifier
    ) else { throw HelperError.containerUnavailable }
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
    if manager.fileExists(atPath: urls.final.path) {
        guard try readRegularOwnerOnly(urls.final, maximumBytes: maximumAckBytes) == payload
        else { throw HelperError.destinationConflict }
    } else {
        try manager.setUbiquitous(true, itemAt: source, destinationURL: urls.final)
    }
    let finalData = try readRegularOwnerOnly(urls.final, maximumBytes: maximumAckBytes)
    let exactBytes = finalData == payload
    var isUbiquitous = false
    var uploadErrorAbsent = false
    var uploadErrorSummary = "none"
    let deadline = Date().addingTimeInterval(60)
    repeat {
        let values = try urls.final.resourceValues(
            forKeys: [.isUbiquitousItemKey, .ubiquitousItemUploadingErrorKey]
        )
        isUbiquitous = values.isUbiquitousItem == true
        if let uploadError = values.ubiquitousItemUploadingError as NSError? {
            uploadErrorAbsent = false
            uploadErrorSummary = "\(uploadError.domain):\(uploadError.code)"
        } else {
            uploadErrorAbsent = true
            uploadErrorSummary = "none"
        }
        if exactBytes && isUbiquitous && uploadErrorAbsent { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    } while Date() < deadline
    guard exactBytes && isUbiquitous && uploadErrorAbsent
    else { throw HelperError.publicationIncomplete }
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
    if arguments.count == 1, let requestID = arguments.first {
        let appRoot = try applicationRoot()
        try ensureProtocolDirectories(root: appRoot)
        let receipt = try publish(requestID: String(requestID))
        try writeOwnerOnly(
            receipt,
            to: receiptURL(root: appRoot, requestID: String(requestID))
        )
    } else {
        throw HelperError.invalidArguments
    }
    Darwin.exit(0)
} catch {
    let value = error as NSError
    fputs("helper_error=\(value.domain):\(value.code)\n", stderr)
    Darwin.exit(3)
}
