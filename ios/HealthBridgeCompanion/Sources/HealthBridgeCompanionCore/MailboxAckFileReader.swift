import Darwin
import Foundation

enum MailboxAckFileError: Error, Equatable {
    case unsafeEntry
    case oversize
    case replaced
    case unavailable
}

struct MailboxAckFileSnapshot {
    let bytes: Data
    let identity: MailboxAckFileIdentity
}

struct MailboxAckLaneEnumeration {
    let finalNames: [String]
    let ignoredTemporaryCount: Int
    let invalidNameCount: Int
}

enum MailboxAckFileReader {
    static func openDirectory(_ url: URL) throws -> Int32 {
        var before = stat()
        guard lstat(url.path, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFDIR else {
            throw MailboxAckFileError.unavailable
        }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MailboxAckFileError.unavailable
        }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              sameDirectory(before, opened) else {
            _ = close(descriptor)
            throw MailboxAckFileError.replaced
        }
        return descriptor
    }

    static func enumerate(
        directory: Int32,
        maximumNames: Int
    ) throws -> MailboxAckLaneEnumeration {
        let duplicate = dup(directory)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { _ = close(duplicate) }
            throw MailboxAckFileError.unavailable
        }
        defer { _ = closedir(stream) }
        var heap = MailboxAckNameHeap(capacity: maximumNames)
        var temporaryCount = 0
        var invalidCount = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            do {
                switch try MailboxLayoutV1.classify(
                    fileName: name,
                    in: .acks,
                    byteCount: 0
                ) {
                case .temporary:
                    temporaryCount += 1
                case .final(kind: .acknowledgment, identifier: _):
                    heap.insert(name)
                case .final:
                    invalidCount = min(invalidCount + 1, 1_001)
                }
            } catch {
                invalidCount = min(invalidCount + 1, 1_001)
            }
        }
        return MailboxAckLaneEnumeration(
            finalNames: heap.sortedValues(),
            ignoredTemporaryCount: temporaryCount,
            invalidNameCount: invalidCount
        )
    }

    static func read(
        directory: Int32,
        name: String,
        maximumBytes: Int64,
        afterOpen: () throws -> Void
    ) throws -> MailboxAckFileSnapshot {
        var initial = stat()
        let initialResult = name.withCString {
            fstatat(directory, $0, &initial, AT_SYMLINK_NOFOLLOW)
        }
        guard initialResult == 0 else {
            throw MailboxAckFileError.unavailable
        }
        try requireRegular(initial, maximumBytes: maximumBytes)
        let descriptor = name.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw MailboxAckFileError.unsafeEntry
        }
        defer { _ = close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              sameFile(initial, opened) else {
            throw MailboxAckFileError.replaced
        }
        try afterOpen()

        var storage = [UInt8](repeating: 0, count: Int(opened.st_size))
        var offset = 0
        while offset < storage.count {
            let remaining = storage.count - offset
            let received = storage.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    remaining
                )
            }
            if received < 0, errno == EINTR { continue }
            guard received > 0 else {
                throw MailboxAckFileError.replaced
            }
            offset += received
        }
        var final = stat()
        var current = stat()
        let currentResult = name.withCString {
            fstatat(directory, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &final) == 0,
              currentResult == 0,
              sameFile(opened, final),
              sameFile(opened, current) else {
            throw MailboxAckFileError.replaced
        }
        return MailboxAckFileSnapshot(
            bytes: Data(storage),
            identity: identity(opened)
        )
    }

    static func currentIdentity(
        directory: Int32,
        name: String
    ) throws -> MailboxAckFileIdentity {
        var metadata = stat()
        let result = name.withCString {
            fstatat(directory, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            throw MailboxAckFileError.unavailable
        }
        try requireRegular(
            metadata,
            maximumBytes: MailboxLayoutV1.maximumMetadataBytes
        )
        return identity(metadata)
    }

    private static func requireRegular(
        _ metadata: stat,
        maximumBytes: Int64
    ) throws {
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1 else {
            throw MailboxAckFileError.unsafeEntry
        }
        guard metadata.st_size >= 0,
              metadata.st_size <= off_t(maximumBytes) else {
            throw MailboxAckFileError.oversize
        }
    }

    private static func sameDirectory(_ lhs: stat, _ rhs: stat) -> Bool {
        (rhs.st_mode & S_IFMT) == S_IFDIR
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        identity(lhs) == identity(rhs)
    }

    private static func identity(_ value: stat) -> MailboxAckFileIdentity {
        MailboxAckFileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: Int64(value.st_size),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changedSeconds: Int64(value.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }
}

private struct MailboxAckNameHeap {
    private let capacity: Int
    private var values: [String] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func insert(_ value: String) {
        guard capacity > 0 else { return }
        if values.count < capacity {
            values.append(value)
            siftUp(values.count - 1)
        } else if let largest = values.first, value < largest {
            values[0] = value
            siftDown(0)
        }
    }

    func sortedValues() -> [String] {
        values.sorted()
    }

    private mutating func siftUp(_ requestedIndex: Int) {
        var index = requestedIndex
        while index > 0 {
            let parent = (index - 1) / 2
            guard values[parent] < values[index] else { return }
            values.swapAt(parent, index)
            index = parent
        }
    }

    private mutating func siftDown(_ requestedIndex: Int) {
        var index = requestedIndex
        while true {
            let left = index * 2 + 1
            guard left < values.count else { return }
            let right = left + 1
            let child = right < values.count && values[left] < values[right]
                ? right
                : left
            guard values[index] < values[child] else { return }
            values.swapAt(index, child)
            index = child
        }
    }
}
