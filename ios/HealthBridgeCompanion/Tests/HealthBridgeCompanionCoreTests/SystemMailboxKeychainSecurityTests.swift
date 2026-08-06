import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import HealthBridgeCompanionCore

final class SystemMailboxKeychainSecurityTests: XCTestCase {
    func testProductionLockUsesPrivateLocalRegularFile() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SystemMailboxKeychain(applicationSupportDirectory: root)

        let observed = try client.withExclusiveAccess(service: "synthetic") { 7 }

        XCTAssertEqual(observed, 7)
        let lock = try XCTUnwrap(lockFiles(root: root).first)
        XCTAssertEqual(posixMode(lock), 0o600)
        XCTAssertEqual(posixMode(lock.deletingLastPathComponent()), 0o700)
    }

    func testProductionLockRejectsUnsafeExistingDirectoryMode() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockDirectory = root
            .appendingPathComponent("HealthBridge", isDirectory: true)
            .appendingPathComponent("KeychainLocks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lockDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(chmod(lockDirectory.path, 0o755), 0)
        let client = SystemMailboxKeychain(applicationSupportDirectory: root)

        XCTAssertThrowsError(
            try client.withExclusiveAccess(service: "synthetic") { 7 }
        ) { error in
            XCTAssertTrue(error is MailboxKeychainBackendError)
        }
    }

    func testProductionLockRejectsUnsafeExistingFileMode() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SystemMailboxKeychain(applicationSupportDirectory: root)
        _ = try client.withExclusiveAccess(service: "synthetic") { 7 }
        let lock = try XCTUnwrap(lockFiles(root: root).first)
        XCTAssertEqual(chmod(lock.path, 0o644), 0)

        XCTAssertThrowsError(
            try client.withExclusiveAccess(service: "synthetic") { 7 }
        ) { error in
            XCTAssertTrue(error is MailboxKeychainBackendError)
        }
    }

    func testProductionLockRejectsSymlinkedAncestor() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("HealthBridge"),
            withDestinationURL: destination
        )
        let client = SystemMailboxKeychain(applicationSupportDirectory: root)

        XCTAssertThrowsError(
            try client.withExclusiveAccess(service: "synthetic") { 7 }
        ) { error in
            XCTAssertTrue(error is MailboxKeychainBackendError)
        }
    }

    func testProductionLockRejectsUnknownFilesystemClassification() throws {
        let root = try makePrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SystemMailboxKeychain(
            applicationSupportDirectory: root,
            filesystemKind: { _ in .unknown }
        )

        XCTAssertThrowsError(
            try client.withExclusiveAccess(service: "synthetic") { 7 }
        ) { error in
            XCTAssertTrue(error is MailboxKeychainBackendError)
        }
    }
}

private func makePrivateTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "mailbox-key-storage-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    XCTAssertEqual(chmod(root.path, 0o700), 0)
    return root
}

private func lockFiles(root: URL) -> [URL] {
    let directory = root
        .appendingPathComponent("HealthBridge", isDirectory: true)
        .appendingPathComponent("KeychainLocks", isDirectory: true)
    return (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )) ?? []
}

private func posixMode(_ url: URL) -> mode_t {
    var metadata = stat()
    XCTAssertEqual(lstat(url.path, &metadata), 0)
    return metadata.st_mode & 0o777
}
