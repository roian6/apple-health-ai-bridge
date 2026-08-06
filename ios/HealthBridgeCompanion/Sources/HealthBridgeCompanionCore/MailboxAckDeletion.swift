import Darwin
import Foundation

extension MailboxAckScanner {
    public func deleteAcknowledgment(
        for event: MailboxAckEvent,
        durableFinalization: any MailboxAckDurableFinalizationVerifying
    ) throws {
        guard event.classification == .committed,
              try durableFinalization.isDurablyCommitted(event) else {
            throw MailboxAckScannerError.durableFinalizationRequired
        }
        let current = try scan()
        if current.events.contains(where: {
            $0.classification == .conflict
                && $0.handle.envelopeID == event.handle.envelopeID
        }) {
            throw MailboxAckScannerError.acknowledgmentConflict
        }
        guard current.events.contains(where: {
            $0.handle.envelopeID == event.handle.envelopeID
                && $0.handle.fileName == event.handle.fileName
                && $0.handle.acknowledgmentSHA256
                    == event.handle.acknowledgmentSHA256
        }) else {
            throw MailboxAckScannerError.acknowledgmentChanged
        }

        let locator = try resolvedLocator()
        guard let lane = locator.lanes[.acks] else {
            throw MailboxAckScannerError.unsafeMailbox
        }
        try revalidate(locator)
        let directory: Int32
        do {
            directory = try MailboxAckFileReader.openDirectory(lane)
        } catch {
            throw MailboxAckScannerError.unsafeMailbox
        }
        defer { _ = close(directory) }
        try runFault(.beforeDeletionRevalidation)
        try revalidate(locator)
        let reopened: MailboxAckFileSnapshot
        do {
            reopened = try MailboxAckFileReader.read(
                directory: directory,
                name: event.handle.fileName,
                maximumBytes: MailboxLayoutV1.maximumMetadataBytes,
                afterOpen: {}
            )
        } catch {
            throw MailboxAckScannerError.acknowledgmentChanged
        }
        guard reopened.identity == event.handle.identity,
              Self.sha256(reopened.bytes) == event.handle.acknowledgmentSHA256 else {
            throw MailboxAckScannerError.acknowledgmentChanged
        }
        try runFault(.beforeUnlink)
        try revalidate(locator)
        let currentIdentity: MailboxAckFileIdentity
        do {
            currentIdentity = try MailboxAckFileReader.currentIdentity(
                directory: directory,
                name: event.handle.fileName
            )
        } catch {
            throw MailboxAckScannerError.acknowledgmentChanged
        }
        guard currentIdentity == event.handle.identity else {
            throw MailboxAckScannerError.acknowledgmentChanged
        }
        let unlinked = event.handle.fileName.withCString {
            unlinkat(directory, $0, 0)
        }
        guard unlinked == 0 else {
            throw MailboxAckScannerError.acknowledgmentChanged
        }
        if fsync(directory) != 0, errno != EINVAL, errno != ENOTSUP {
            throw MailboxAckScannerError.unsafeMailbox
        }
    }

    func resolvedLocator() throws -> MailboxResolvedLocatorV1 {
        do {
            return try locate()
        } catch {
            throw MailboxAckScannerError.unsafeMailbox
        }
    }

    func revalidate(_ locator: MailboxResolvedLocatorV1) throws {
        do {
            try MailboxLocatorV1.revalidate(locator)
        } catch {
            throw MailboxAckScannerError.unsafeMailbox
        }
    }

    func runFault(_ boundary: MailboxAckScanBoundary) throws {
        do {
            try fault(boundary)
        } catch {
            throw MailboxAckScannerError.unsafeMailbox
        }
    }
}
