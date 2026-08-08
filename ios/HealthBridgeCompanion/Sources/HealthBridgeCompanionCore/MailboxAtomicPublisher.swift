import Darwin
import Foundation

enum MailboxPublicationError: Error, Equatable {
    case retryable
    case conflict
    case unsafeDestination
}

enum MailboxPublicationBoundary: CaseIterable, Equatable {
    case createTemporary
    case writeTemporary
    case syncTemporary
    case closeTemporary
    case renameTemporary
    case syncDirectory
}

protocol MailboxEnvelopePublishing {
    func publish(
        _ envelope: Data,
        finalName: String,
        locator: MailboxResolvedLocatorV1
    ) throws -> URL
}

struct MailboxFileProviderPublicationExecutor {
    private let queue = DispatchQueue(
        label: "com.example.HealthBridgeCompanion.mailbox.file-provider-publication"
    )

    func run<T>(_ operation: () throws -> T) rethrows -> T {
        try queue.sync(execute: operation)
    }
}

struct FileProviderMailboxEnvelopePublisher: MailboxEnvelopePublishing {
    private let executor = MailboxFileProviderPublicationExecutor()

    func publish(
        _ envelope: Data,
        finalName: String,
        locator: MailboxResolvedLocatorV1
    ) throws -> URL {
        guard Int64(envelope.count) <= MailboxLayoutV1.maximumDeliveryBytes,
              case .final(kind: .delivery, identifier: _) = try MailboxLayoutV1.classify(
                  fileName: finalName,
                  in: .deliveries,
                  byteCount: Int64(envelope.count)
              ),
              let lane = locator.lanes[.deliveries] else {
            throw MailboxPublicationError.unsafeDestination
        }
        try revalidate(locator)
        let finalURL = lane.appendingPathComponent(finalName)
        if let existing = try existingFinal(at: finalURL, expected: envelope) {
            guard existing else { throw MailboxPublicationError.conflict }
            return finalURL
        }

        #if os(iOS)
        try executor.run {
            try publishWithUbiquityManager(
                envelope,
                to: finalURL,
                locator: locator
            )
        }
        #else
        let temporaryID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let temporaryName = "\(finalName).\(temporaryID).tmp"
        guard case .temporary = try MailboxLayoutV1.classify(
            fileName: temporaryName,
            in: .deliveries,
            byteCount: 0
        ) else {
            throw MailboxPublicationError.unsafeDestination
        }
        let temporaryURL = lane.appendingPathComponent(temporaryName)
        var ownsTemporary = true
        defer {
            if ownsTemporary { try? FileManager.default.removeItem(at: temporaryURL) }
        }
        do {
            try envelope.write(to: temporaryURL, options: [.withoutOverwriting])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            try sync(finalURL: temporaryURL, lane: lane)
            try revalidate(locator)
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
            ownsTemporary = false
        } catch {
            if let existing = try existingFinal(at: finalURL, expected: envelope) {
                guard existing else { throw MailboxPublicationError.conflict }
                return finalURL
            }
            throw MailboxPublicationError.retryable
        }
        #endif
        do {
            try sync(finalURL: finalURL, lane: lane)
            try revalidate(locator)
            guard try existingFinal(at: finalURL, expected: envelope) == true else {
                throw MailboxPublicationError.conflict
            }
            return finalURL
        } catch let error as MailboxPublicationError {
            throw error
        } catch {
            throw MailboxPublicationError.retryable
        }
    }

    #if os(iOS)
    private func publishWithUbiquityManager(
        _ envelope: Data,
        to finalURL: URL,
        locator: MailboxResolvedLocatorV1
    ) throws {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-bridge-mailbox-qa", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let sourceURL = stagingRoot.appendingPathComponent("envelope.hbe", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        do {
            try FileManager.default.createDirectory(
                at: stagingRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try envelope.write(to: sourceURL, options: [.withoutOverwriting])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: sourceURL.path
            )
            try sync(finalURL: sourceURL, lane: stagingRoot)
            try revalidate(locator)
            try FileManager.default.setUbiquitous(
                true,
                itemAt: sourceURL,
                destinationURL: finalURL
            )
        } catch {
            if let existing = try existingFinal(at: finalURL, expected: envelope) {
                guard existing else { throw MailboxPublicationError.conflict }
                return
            }
            throw MailboxPublicationError.retryable
        }
    }
    #endif

    private func existingFinal(at url: URL, expected: Data) throws -> Bool? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw MailboxPublicationError.conflict
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size == off_t(expected.count) else {
            throw MailboxPublicationError.conflict
        }
        do {
            let bytes = try MailboxRegularFileReader.read(
                url,
                maximumBytes: MailboxLayoutV1.maximumDeliveryBytes
            )
            return bytes == expected
        } catch {
            throw MailboxPublicationError.conflict
        }
    }

    private func sync(finalURL: URL, lane: URL) throws {
        let file = open(finalURL.path, O_RDONLY | O_NOFOLLOW)
        guard file >= 0 else { throw MailboxPublicationError.retryable }
        defer { _ = close(file) }
        if fsync(file) != 0, errno != EINVAL, errno != ENOTSUP {
            throw MailboxPublicationError.retryable
        }
        let directory = open(lane.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw MailboxPublicationError.retryable }
        defer { _ = close(directory) }
        if fsync(directory) != 0, errno != EINVAL, errno != ENOTSUP {
            throw MailboxPublicationError.retryable
        }
    }

    private func revalidate(_ locator: MailboxResolvedLocatorV1) throws {
        do {
            try MailboxLocatorV1.revalidate(locator)
        } catch {
            throw MailboxPublicationError.unsafeDestination
        }
    }
}

struct POSIXMailboxEnvelopePublisher: MailboxEnvelopePublishing {
    typealias Fault = (MailboxPublicationBoundary) throws -> Void

    private let fault: Fault
    private let temporaryIdentifier: () -> String

    init(
        _ fault: @escaping Fault = { _ in },
        temporaryIdentifier: @escaping () -> String = {
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
    ) {
        self.fault = fault
        self.temporaryIdentifier = temporaryIdentifier
    }

    func publish(
        _ envelope: Data,
        finalName: String,
        locator: MailboxResolvedLocatorV1
    ) throws -> URL {
        guard Int64(envelope.count) <= MailboxLayoutV1.maximumDeliveryBytes,
              case .final(kind: .delivery, identifier: _) = try MailboxLayoutV1.classify(
                  fileName: finalName,
                  in: .deliveries,
                  byteCount: Int64(envelope.count)
              ),
              let lane = locator.lanes[.deliveries] else {
            throw MailboxPublicationError.unsafeDestination
        }
        try revalidate(locator)
        let directory = open(lane.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw mappedOpenError() }
        defer { _ = close(directory) }
        try revalidate(locator)
        if let existing = try existingFinal(
            directory: directory,
            name: finalName,
            expected: envelope
        ) {
            guard existing else { throw MailboxPublicationError.conflict }
            try revalidate(locator)
            return lane.appendingPathComponent(finalName)
        }

        let temporaryID: String
        do {
            temporaryID = try MailboxLayoutV1.opaqueComponent(temporaryIdentifier())
        } catch {
            throw MailboxPublicationError.unsafeDestination
        }
        let temporaryName = "\(finalName).\(temporaryID).tmp"
        guard case .temporary = try MailboxLayoutV1.classify(
            fileName: temporaryName,
            in: .deliveries,
            byteCount: 0
        ) else {
            throw MailboxPublicationError.unsafeDestination
        }
        try runFault(.createTemporary)
        let temporary = temporaryName.withCString {
            openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard temporary >= 0 else { throw mappedCreateError() }
        var descriptor = temporary
        var ownsTemporary = true
        defer {
            if descriptor >= 0 { _ = close(descriptor) }
            if ownsTemporary {
                temporaryName.withCString { _ = unlinkat(directory, $0, 0) }
            }
        }

        try runFault(.writeTemporary)
        try writeAll(envelope, descriptor: descriptor)
        try runFault(.syncTemporary)
        try bestEffortSync(descriptor)
        guard close(descriptor) == 0 else {
            descriptor = -1
            throw MailboxPublicationError.retryable
        }
        descriptor = -1
        try runFault(.closeTemporary)
        try runFault(.renameTemporary)
        let renamed = temporaryName.withCString { temporaryPointer in
            finalName.withCString { finalPointer in
                renameatx_np(
                    directory,
                    temporaryPointer,
                    directory,
                    finalPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if renamed != 0 {
            if errno == EEXIST,
               try existingFinal(
                   directory: directory,
                   name: finalName,
                   expected: envelope
               ) == true {
                try revalidate(locator)
                return lane.appendingPathComponent(finalName)
            }
            throw errno == EEXIST
                ? MailboxPublicationError.conflict
                : MailboxPublicationError.retryable
        }
        ownsTemporary = false
        try runFault(.syncDirectory)
        try bestEffortSync(directory)
        try revalidate(locator)
        guard try existingFinal(
            directory: directory,
            name: finalName,
            expected: envelope
        ) == true else {
            throw MailboxPublicationError.conflict
        }
        return lane.appendingPathComponent(finalName)
    }

    private func existingFinal(
        directory: Int32,
        name: String,
        expected: Data
    ) throws -> Bool? {
        let descriptor = name.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw MailboxPublicationError.conflict
        }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size == off_t(expected.count) else {
            throw MailboxPublicationError.conflict
        }
        return try readAll(descriptor: descriptor, count: expected.count) == expected
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    data.count - offset
                )
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw MailboxPublicationError.retryable }
            offset += written
        }
    }

    private func readAll(descriptor: Int32, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    count - offset
                )
            }
            if received < 0, errno == EINTR { continue }
            guard received > 0 else { throw MailboxPublicationError.retryable }
            offset += received
        }
        return Data(bytes)
    }

    private func bestEffortSync(_ descriptor: Int32) throws {
        guard fsync(descriptor) != 0 else { return }
        if errno != EINVAL && errno != ENOTSUP {
            throw MailboxPublicationError.retryable
        }
    }

    private func runFault(_ boundary: MailboxPublicationBoundary) throws {
        do {
            try fault(boundary)
        } catch {
            throw MailboxPublicationError.retryable
        }
    }

    private func revalidate(_ locator: MailboxResolvedLocatorV1) throws {
        do {
            try MailboxLocatorV1.revalidate(locator)
        } catch {
            throw MailboxPublicationError.unsafeDestination
        }
    }

    private func mappedOpenError() -> MailboxPublicationError {
        [ENOENT, ENOSPC, EDQUOT, EIO].contains(errno) ? .retryable : .unsafeDestination
    }

    private func mappedCreateError() -> MailboxPublicationError {
        [EEXIST, ENOSPC, EDQUOT, EIO].contains(errno) ? .retryable : .unsafeDestination
    }
}
