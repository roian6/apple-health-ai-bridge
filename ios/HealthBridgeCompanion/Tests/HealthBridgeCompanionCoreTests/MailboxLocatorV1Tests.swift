import Foundation
import Testing
@testable import HealthBridgeCompanionCore

@Suite("Mailbox V1 secure locator")
struct MailboxLocatorV1Tests {
    private let receiver = "0123456789abcdef0123456789abcdef"
    private let device = "fedcba9876543210fedcba9876543210"

    @Test("creates only the app-owned topology and a private local record")
    func resolveWhenProviderIsAvailable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let locator = try MailboxLocatorV1.resolve(
            providerRoot: fixture.providerRoot,
            containerIdentifier: "iCloud.com.example.HealthBridgeCompanion",
            receiverComponent: receiver,
            deviceComponent: device,
            localRecordURL: fixture.localRecord
        )

        #expect(locator.relativeDevicePath == "HealthBridgeMailbox/v1/\(receiver)/\(device)")
        #expect(Set(locator.lanes.keys) == Set(MailboxLaneV1.allCases))
        for url in locator.lanes.values {
            #expect(try permissions(of: url) == 0o700)
        }
        #expect(try permissions(of: fixture.localRecord) == 0o600)
        #expect(!fixture.localRecord.path.hasPrefix(fixture.providerRoot.path + "/"))
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: locator.deviceRoot.path
        ).sorted() == MailboxLaneV1.allCases.map(\.rawValue).sorted())
    }

    @Test("fails closed when the ubiquitous container is unavailable")
    func resolveWhenAccountOrContainerIsLost() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(throws: MailboxLocatorError.containerUnavailable) {
            try MailboxLocatorV1.resolve(
                providerRoot: nil,
                containerIdentifier: "iCloud.com.example.HealthBridgeCompanion",
                receiverComponent: receiver,
                deviceComponent: device,
                localRecordURL: fixture.localRecord
            )
        }
    }

    @Test("detects a lane replaced by a symlink after resolution")
    func revalidateWhenLaneIsReplaced() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let locator = try MailboxLocatorV1.resolve(
            providerRoot: fixture.providerRoot,
            containerIdentifier: "iCloud.com.example.HealthBridgeCompanion",
            receiverComponent: receiver,
            deviceComponent: device,
            localRecordURL: fixture.localRecord
        )
        let delivery = try #require(locator.lanes[.deliveries])
        let replacement = fixture.root.appending(path: "replacement", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: delivery)
        try FileManager.default.createSymbolicLink(at: delivery, withDestinationURL: replacement)

        #expect(throws: MailboxLocatorError.pathReplaced) {
            try MailboxLocatorV1.revalidate(locator)
        }
    }

    @Test("refuses a local locator record replaced by a symlink")
    func resolveWhenLocalRecordIsSymlink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try MailboxLocatorV1.resolve(
            providerRoot: fixture.providerRoot,
            containerIdentifier: "iCloud.com.example.HealthBridgeCompanion",
            receiverComponent: receiver,
            deviceComponent: device,
            localRecordURL: fixture.localRecord
        )
        try FileManager.default.removeItem(at: fixture.localRecord)
        try FileManager.default.createSymbolicLink(
            at: fixture.localRecord,
            withDestinationURL: fixture.providerRoot
        )

        #expect(throws: MailboxLocatorError.symbolicLink) {
            try MailboxLocatorV1.resolve(
                providerRoot: fixture.providerRoot,
                containerIdentifier: "iCloud.com.example.HealthBridgeCompanion",
                receiverComponent: receiver,
                deviceComponent: device,
                localRecordURL: fixture.localRecord
            )
        }
    }
}

private struct Fixture {
    let root: URL
    let providerRoot: URL
    let localRecord: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        providerRoot = root.appending(path: "provider", directoryHint: .isDirectory)
        localRecord = root
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "mailbox-locator-v1.json", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: providerRoot, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let value = try #require(attributes[.posixPermissions] as? NSNumber)
    return value.intValue & 0o777
}
