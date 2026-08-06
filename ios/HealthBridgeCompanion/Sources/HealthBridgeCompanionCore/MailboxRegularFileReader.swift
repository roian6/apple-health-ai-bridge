import Darwin
import Foundation

enum MailboxRegularFileReader {
    static func read(
        _ url: URL,
        maximumBytes: Int64,
        afterOpen: () throws -> Void = {}
    ) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MailboxTransportError.envelopeConflict }
        defer { _ = close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_nlink == 1,
              opened.st_size >= 0,
              opened.st_size <= maximumBytes else {
            throw MailboxTransportError.envelopeConflict
        }
        try afterOpen()
        var bytes = [UInt8](repeating: 0, count: Int(opened.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let received = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    remaining
                )
            }
            if received < 0, errno == EINTR { continue }
            guard received > 0 else { throw MailboxTransportError.envelopeConflict }
            offset += received
        }
        var final = stat()
        var current = stat()
        guard fstat(descriptor, &final) == 0,
              lstat(url.path, &current) == 0,
              sameIdentity(opened, final),
              sameIdentity(opened, current) else {
            throw MailboxTransportError.envelopeConflict
        }
        return Data(bytes)
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
