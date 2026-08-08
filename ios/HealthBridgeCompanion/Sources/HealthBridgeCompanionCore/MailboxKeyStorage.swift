import CryptoKit
import Darwin
import Foundation
import Security

enum MailboxStorageKind {
    case local
    case network
    case unknown
}

enum MailboxTrustRecord: String {
    case expectedIdentity = "expected-identity-v1"
    case monotonicGeneration = "monotonic-generation-v1"
}

final class MailboxKeyFileStorage {
    private let root: URL
    private let filesystemKind: (URL) -> MailboxStorageKind

    init(
        applicationSupportDirectory: URL,
        filesystemKind: @escaping (URL) -> MailboxStorageKind
    ) {
        root = canonicalExistingURL(applicationSupportDirectory)
        self.filesystemKind = filesystemKind
    }

    func withExclusiveAccess<T>(service: String, _ body: () throws -> T) throws -> T {
        let directory = try privateDirectory(named: "KeychainLocks")
        let path = directory.appendingPathComponent("\(serviceDigest(service)).lock")
        let existed = FileManager.default.fileExists(atPath: path.path)
        let descriptor = open(path.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw unavailable() }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == geteuid(),
              (!existed || metadata.st_mode & 0o777 == 0o600),
              fchmod(descriptor, 0o600) == 0,
              flock(descriptor, LOCK_EX) == 0
        else {
            throw unavailable()
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    func data(service: String, record: MailboxTrustRecord) throws -> Data? {
        let path = try recordPath(service: service, record: record)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw unavailable() }
        defer { close(descriptor) }
        let metadata = try validatedFile(descriptor)
        guard metadata.st_size <= MailboxKeyConstants.maximumStateBytes else {
            throw unavailable()
        }
        var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
        let count = bytes.withUnsafeMutableBytes { buffer in
            read(descriptor, buffer.baseAddress, buffer.count)
        }
        guard count == bytes.count else { throw unavailable() }
        return Data(bytes)
    }

    func store(_ data: Data, service: String, record: MailboxTrustRecord) throws {
        guard data.count <= MailboxKeyConstants.maximumStateBytes else {
            throw unavailable()
        }
        let path = try recordPath(service: service, record: record)
        try validateExistingFile(path)
        let temporary = path.deletingLastPathComponent().appendingPathComponent(
            ".\(path.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { throw unavailable() }
        var keepTemporary = true
        defer {
            close(descriptor)
            if keepTemporary { unlink(temporary.path) }
        }
        let written = data.withUnsafeBytes { buffer in
            write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == data.count, fsync(descriptor) == 0,
              rename(temporary.path, path.path) == 0
        else {
            throw unavailable()
        }
        keepTemporary = false
        let directoryDescriptor = open(path.deletingLastPathComponent().path, O_RDONLY)
        guard directoryDescriptor >= 0 else { throw unavailable() }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw unavailable() }
    }

    func remove(service: String, record: MailboxTrustRecord) throws {
        let path = try recordPath(service: service, record: record)
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        try validateExistingFile(path)
        guard unlink(path.path) == 0 else { throw unavailable() }
        let directoryDescriptor = open(path.deletingLastPathComponent().path, O_RDONLY)
        guard directoryDescriptor >= 0 else { throw unavailable() }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw unavailable() }
    }

    private func recordPath(service: String, record: MailboxTrustRecord) throws -> URL {
        let directoryName: String
        switch record {
        case .expectedIdentity:
            directoryName = "IdentityAnchors"
        case .monotonicGeneration:
            directoryName = "IdentityGeneration"
        }
        return try privateDirectory(named: directoryName)
            .appendingPathComponent("\(serviceDigest(service)).json")
    }

    private func privateDirectory(named name: String) throws -> URL {
        try validateLocalRoot()
        let healthBridge = root.appendingPathComponent("HealthBridge", isDirectory: true)
        try createOrValidatePrivateDirectory(healthBridge)
        let directory = healthBridge.appendingPathComponent(name, isDirectory: true)
        try createOrValidatePrivateDirectory(directory)
        return directory
    }

    private func validateLocalRoot() throws {
        var existing = root
        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent != existing else { throw unavailable() }
            existing = parent
        }
        guard filesystemKind(existing) == .local else { throw unavailable() }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in root.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            guard FileManager.default.fileExists(atPath: current.path) else { break }
            var metadata = stat()
            guard lstat(current.path, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) != S_IFLNK
            else {
                throw unavailable()
            }
        }
    }

    private func createOrValidatePrivateDirectory(_ directory: URL) throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                guard FileManager.default.fileExists(atPath: directory.path) else {
                    throw unavailable()
                }
            }
        }
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o777 == 0o700
        else {
            throw unavailable()
        }
    }

    private func validateExistingFile(_ path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw unavailable() }
        defer { close(descriptor) }
        _ = try validatedFile(descriptor)
    }

    private func validatedFile(_ descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o777 == 0o600
        else {
            throw unavailable()
        }
        return metadata
    }
}

func systemMailboxStorageKind(_ url: URL) -> MailboxStorageKind {
    var metadata = statfs()
    guard statfs(url.path, &metadata) == 0 else { return .unknown }
    return metadata.f_flags & UInt32(MNT_LOCAL) == 0 ? .network : .local
}

private func serviceDigest(_ service: String) -> String {
    SHA256.hash(data: Data(service.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func unavailable() -> MailboxKeychainBackendError {
    MailboxKeychainBackendError(status: errSecNotAvailable)
}

private func canonicalExistingURL(_ url: URL) -> URL {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else {
        return url.standardizedFileURL
    }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
}
