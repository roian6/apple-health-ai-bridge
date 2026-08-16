import Darwin
import Foundation

extension MailboxAckFileReader {
    static func nameAttributes(includeReturnedAttributes: Bool = false) -> attrlist {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_NAME)
        if includeReturnedAttributes {
            attributes.commonattr |= attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        }
        return attributes
    }

    static func windowBufferSize(maximumEntries: Int) throws -> Int {
        let bytesPerEntry = MemoryLayout<UInt32>.size
            + MemoryLayout<attrreference_t>.size
            + (Int(NAME_MAX) * 3) + 1
        let (bufferSize, overflow) = maximumEntries.multipliedReportingOverflow(
            by: bytesPerEntry
        )
        guard !overflow else {
            throw MailboxAckFileError.unavailable
        }
        return bufferSize
    }

    static func directoryState(_ directory: Int32) throws
        -> MailboxAckDirectoryState
    {
        var metadata = stat()
        guard fstat(directory, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw MailboxAckFileError.unavailable
        }
        return MailboxAckDirectoryState(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            changedSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    static func classifiedWindow(
        names: [String],
        inspectedEntryCount: Int,
        checkpoint: String
    ) -> MailboxAckLaneWindowEnumeration {
        var finalNames: [String] = []
        var temporaryCount = 0
        var invalidCount = 0
        for name in names {
            do {
                switch try MailboxLayoutV1.classify(
                    fileName: name,
                    in: .acks,
                    byteCount: 0
                ) {
                case .temporary:
                    temporaryCount += 1
                case .final(kind: .acknowledgment, identifier: _):
                    finalNames.append(name)
                case .final:
                    invalidCount += 1
                }
            } catch {
                invalidCount += 1
            }
        }
        return MailboxAckLaneWindowEnumeration(
            finalNames: finalNames,
            ignoredTemporaryCount: temporaryCount,
            invalidNameCount: invalidCount,
            inspectedEntryCount: inspectedEntryCount,
            nextCheckpoint: checkpoint
        )
    }

    static func emptyWindow(
        inspectedEntryCount: Int,
        checkpoint: String
    ) -> MailboxAckLaneWindowEnumeration {
        MailboxAckLaneWindowEnumeration(
            finalNames: [],
            ignoredTemporaryCount: 0,
            invalidNameCount: 0,
            inspectedEntryCount: inspectedEntryCount,
            nextCheckpoint: checkpoint
        )
    }

    static func advanceMailboxAckRecord(
        storage: [UInt8],
        recordOffset: inout Int
    ) throws {
        let lengthSize = MemoryLayout<UInt32>.size
        guard recordOffset <= storage.count - lengthSize else {
            throw MailboxAckFileError.unavailable
        }
        let recordLength = storage.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: recordOffset, as: UInt32.self)
        }
        guard recordLength >= UInt32(lengthSize + MemoryLayout<attrreference_t>.size),
              recordLength <= UInt32(storage.count - recordOffset) else {
            throw MailboxAckFileError.unavailable
        }
        recordOffset += Int(recordLength)
    }

    static func mailboxAckEntryName(
        storage: [UInt8],
        recordOffset: inout Int,
        includesReturnedAttributes: Bool = false
    ) throws -> String {
        let initialOffset = recordOffset
        try advanceMailboxAckRecord(storage: storage, recordOffset: &recordOffset)
        let returnedAttributesOffset = initialOffset + MemoryLayout<UInt32>.size
        var referenceOffset = returnedAttributesOffset
        if includesReturnedAttributes {
            guard returnedAttributesOffset
                <= storage.count - MemoryLayout<attribute_set_t>.size else {
                throw MailboxAckFileError.unavailable
            }
            let returned = storage.withUnsafeBytes {
                $0.loadUnaligned(
                    fromByteOffset: returnedAttributesOffset,
                    as: attribute_set_t.self
                )
            }
            guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else {
                throw MailboxAckFileError.unavailable
            }
            referenceOffset += MemoryLayout<attribute_set_t>.size
        }
        let reference = storage.withUnsafeBytes {
            $0.loadUnaligned(
                fromByteOffset: referenceOffset,
                as: attrreference_t.self
            )
        }
        let dataOffset = Int(reference.attr_dataoffset)
        let nameLength = Int(reference.attr_length)
        guard dataOffset >= 0,
              nameLength > 0,
              nameLength <= (Int(NAME_MAX) * 3) + 1 else {
            throw MailboxAckFileError.unavailable
        }
        let nameOffset = referenceOffset + dataOffset
        guard nameOffset >= initialOffset,
              nameOffset <= storage.count - nameLength,
              nameOffset + nameLength <= recordOffset else {
            throw MailboxAckFileError.unavailable
        }
        let nameBytes = storage[nameOffset ..< nameOffset + nameLength]
        guard nameBytes.last == 0 else {
            throw MailboxAckFileError.unavailable
        }
        return String(decoding: nameBytes.dropLast(), as: UTF8.self)
    }
}

enum MailboxAckWindowReadError: Error {
    case unsupported
}

struct MailboxAckAttributeCheckpoint {
    let offset: off_t
    let state: UInt32
}

struct MailboxAckBulkCheckpoint {
    let pageOffset: off_t
    let nextIndex: Int
    let state: MailboxAckDirectoryState
}

struct MailboxAckDirectoryState: Equatable {
    let device: UInt64
    let inode: UInt64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

enum MailboxAckDirectoryCheckpoint {
    case attributes(offset: off_t, state: UInt32)
    case bulk(pageOffset: off_t, nextIndex: Int, state: MailboxAckDirectoryState)

    var usesBulkReader: Bool {
        if case .bulk = self { return true }
        return false
    }

    var attributeCheckpoint: MailboxAckAttributeCheckpoint? {
        guard case let .attributes(offset, state) = self else { return nil }
        return MailboxAckAttributeCheckpoint(offset: offset, state: state)
    }

    var bulkCheckpoint: MailboxAckBulkCheckpoint? {
        guard case let .bulk(pageOffset, nextIndex, state) = self else { return nil }
        return MailboxAckBulkCheckpoint(
            pageOffset: pageOffset,
            nextIndex: nextIndex,
            state: state
        )
    }

    var encoded: String {
        switch self {
        case let .attributes(offset, state):
            return "v2:a:\(offset):\(state)"
        case let .bulk(pageOffset, nextIndex, state):
            return "v2:b:\(pageOffset):\(nextIndex):\(state.device):\(state.inode):"
                + "\(state.changedSeconds):\(state.changedNanoseconds)"
        }
    }

    static func decode(_ encoded: String?) -> Self? {
        guard let encoded else { return nil }
        let parts = encoded.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 4,
           parts[0] == "v2", parts[1] == "a",
           let offset = off_t(parts[2]), offset >= 0,
           let state = UInt32(parts[3]) {
            return .attributes(offset: offset, state: state)
        }
        if parts.count == 8,
           parts[0] == "v2", parts[1] == "b",
           let pageOffset = off_t(parts[2]), pageOffset >= 0,
           let nextIndex = Int(parts[3]), nextIndex >= 0,
           let device = UInt64(parts[4]),
           let inode = UInt64(parts[5]),
           let changedSeconds = Int64(parts[6]),
           let changedNanoseconds = Int64(parts[7]) {
            return .bulk(
                pageOffset: pageOffset,
                nextIndex: nextIndex,
                state: MailboxAckDirectoryState(
                    device: device,
                    inode: inode,
                    changedSeconds: changedSeconds,
                    changedNanoseconds: changedNanoseconds
                )
            )
        }
        return nil
    }
}
