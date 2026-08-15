import Darwin
import Foundation

struct MailboxAckLaneWindowEnumeration {
    let finalNames: [String]
    let ignoredTemporaryCount: Int
    let invalidNameCount: Int
    let inspectedEntryCount: Int
    let nextCheckpoint: String?
}

enum MailboxAckWindowEnumerationStrategy: Equatable, Sendable {
    case automatic
    case bulkOnly
    case forceAttributeUnsupported
}

extension MailboxAckFileReader {
    static func enumerateWindow(
        directory: Int32,
        maximumEntries: Int,
        afterCheckpoint: String?,
        strategy: MailboxAckWindowEnumerationStrategy = .automatic
    ) throws -> MailboxAckLaneWindowEnumeration {
        guard 1 ... MailboxAckScanner.maximumScanFiles ~= maximumEntries else {
            throw MailboxAckFileError.unavailable
        }
        try Task.checkCancellation()
        let checkpoint = MailboxAckDirectoryCheckpoint.decode(afterCheckpoint)
        if strategy == .bulkOnly || checkpoint?.usesBulkReader == true {
            return try enumerateBulkWindow(
                directory: directory,
                maximumEntries: maximumEntries,
                checkpoint: checkpoint?.bulkCheckpoint
            )
        }
        do {
            if strategy == .forceAttributeUnsupported {
                throw MailboxAckWindowReadError.unsupported
            }
            return try enumerateAttributeWindow(
                directory: directory,
                maximumEntries: maximumEntries,
                checkpoint: checkpoint?.attributeCheckpoint
            )
        } catch MailboxAckWindowReadError.unsupported {
            return try enumerateBulkWindow(
                directory: directory,
                maximumEntries: maximumEntries,
                checkpoint: nil
            )
        }
    }

    private static func enumerateAttributeWindow(
        directory: Int32,
        maximumEntries: Int,
        checkpoint: MailboxAckAttributeCheckpoint?
    ) throws -> MailboxAckLaneWindowEnumeration {
        guard lseek(directory, checkpoint?.offset ?? 0, SEEK_SET) >= 0 else {
            throw MailboxAckFileError.unavailable
        }
        var attributes = nameAttributes()
        var storage = [UInt8](
            repeating: 0,
            count: try windowBufferSize(maximumEntries: maximumEntries)
        )
        var count = UInt32(maximumEntries)
        var base = UInt32(0)
        var state = UInt32(0)
        errno = 0
        let result = storage.withUnsafeMutableBytes { buffer in
            getdirentriesattr(
                directory,
                &attributes,
                buffer.baseAddress,
                buffer.count,
                &count,
                &base,
                &state,
                0
            )
        }
        if result < 0 {
            switch errno {
            case ENOTSUP, ENOSYS:
                throw MailboxAckWindowReadError.unsupported
            default:
                throw MailboxAckFileError.unavailable
            }
        }
        guard count <= UInt32(maximumEntries) else {
            throw MailboxAckFileError.unavailable
        }
        if let checkpoint, checkpoint.state != state {
            return emptyWindow(
                inspectedEntryCount: Int(count),
                checkpoint: MailboxAckDirectoryCheckpoint.attributes(
                    offset: 0,
                    state: state
                ).encoded
            )
        }
        var recordOffset = 0
        var names: [String] = []
        names.reserveCapacity(Int(count))
        for _ in 0 ..< Int(count) {
            try Task.checkCancellation()
            names.append(
                try mailboxAckEntryName(
                    storage: storage,
                    recordOffset: &recordOffset
                )
            )
        }
        return classifiedWindow(
            names: names,
            inspectedEntryCount: Int(count),
            checkpoint: MailboxAckDirectoryCheckpoint.attributes(
                offset: result == 1 ? 0 : off_t(base),
                state: state
            ).encoded
        )
    }

    private static func enumerateBulkWindow(
        directory: Int32,
        maximumEntries: Int,
        checkpoint: MailboxAckBulkCheckpoint?
    ) throws -> MailboxAckLaneWindowEnumeration {
        let before = try directoryState(directory)
        let usableCheckpoint = checkpoint?.state == before ? checkpoint : nil
        let pageOffset = usableCheckpoint?.pageOffset ?? 0
        let firstIndex = usableCheckpoint?.nextIndex ?? 0
        guard lseek(directory, pageOffset, SEEK_SET) >= 0 else {
            throw MailboxAckFileError.unavailable
        }
        var attributes = nameAttributes(includeReturnedAttributes: true)
        var storage = [UInt8](
            repeating: 0,
            count: try windowBufferSize(maximumEntries: maximumEntries)
        )
        errno = 0
        let result = storage.withUnsafeMutableBytes { buffer in
            getattrlistbulk(
                directory,
                &attributes,
                buffer.baseAddress,
                buffer.count,
                0
            )
        }
        guard result >= 0 else {
            throw MailboxAckFileError.unavailable
        }
        let after = try directoryState(directory)
        guard before == after else {
            return emptyWindow(
                inspectedEntryCount: 0,
                checkpoint: MailboxAckDirectoryCheckpoint.bulk(
                    pageOffset: 0,
                    nextIndex: 0,
                    state: after
                ).encoded
            )
        }
        guard result > 0 else {
            return emptyWindow(
                inspectedEntryCount: 0,
                checkpoint: MailboxAckDirectoryCheckpoint.bulk(
                    pageOffset: 0,
                    nextIndex: 0,
                    state: after
                ).encoded
            )
        }
        let returnedCount = Int(result)
        guard firstIndex <= returnedCount else {
            return emptyWindow(
                inspectedEntryCount: 0,
                checkpoint: MailboxAckDirectoryCheckpoint.bulk(
                    pageOffset: 0,
                    nextIndex: 0,
                    state: after
                ).encoded
            )
        }
        var recordOffset = 0
        for _ in 0 ..< firstIndex {
            try advanceMailboxAckRecord(storage: storage, recordOffset: &recordOffset)
        }
        let inspectedCount = min(maximumEntries, returnedCount - firstIndex)
        var names: [String] = []
        names.reserveCapacity(inspectedCount)
        for _ in 0 ..< inspectedCount {
            try Task.checkCancellation()
            names.append(
                try mailboxAckEntryName(
                    storage: storage,
                    recordOffset: &recordOffset,
                    includesReturnedAttributes: true
                )
            )
        }
        let nextCheckpoint: MailboxAckDirectoryCheckpoint
        if firstIndex + inspectedCount < returnedCount {
            nextCheckpoint = .bulk(
                pageOffset: pageOffset,
                nextIndex: firstIndex + inspectedCount,
                state: after
            )
        } else {
            let nextPageOffset = lseek(directory, 0, SEEK_CUR)
            guard nextPageOffset >= 0 else {
                throw MailboxAckFileError.unavailable
            }
            nextCheckpoint = .bulk(
                pageOffset: nextPageOffset,
                nextIndex: 0,
                state: after
            )
        }
        return classifiedWindow(
            names: names,
            inspectedEntryCount: inspectedCount,
            checkpoint: nextCheckpoint.encoded
        )
    }

}
