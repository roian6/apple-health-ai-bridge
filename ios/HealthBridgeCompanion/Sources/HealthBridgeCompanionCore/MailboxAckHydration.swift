import Foundation

#if os(iOS)
import Darwin
#endif

enum MailboxAckAvailability {
    case available
    case remote
}

public struct MailboxAckHydrationReport: Equatable, Sendable {
    public let eligibleCandidateCount: Int
    public let requestedDownloadCount: Int
    public let remainingUnavailableCount: Int
    public let skippedUnverifiableIdentityCount: Int
}

struct MailboxAckHydrationCandidates {
    let eligible: [URL]
    let skippedUnverifiableIdentityCount: Int
}

struct MailboxAckHydrator {
    typealias Candidates = () throws -> MailboxAckHydrationCandidates
    typealias Availability = (URL) throws -> MailboxAckAvailability
    typealias RequestDownload = (URL) throws -> Void
    typealias Wait = () async throws -> Void

    let candidates: Candidates
    let availability: Availability
    let requestDownload: RequestDownload
    let wait: Wait
    let maximumWaits: Int

    func hydrate() async throws -> MailboxAckHydrationReport {
        try Task.checkCancellation()
        let discovered = try candidates()
        var pending: [URL] = []
        var requestedDownloadCount = 0
        for candidate in discovered.eligible {
            try Task.checkCancellation()
            guard !isAvailable(candidate) else { continue }
            try Task.checkCancellation()
            pending.append(candidate)
            try? requestDownload(candidate)
            requestedDownloadCount += 1
        }
        for _ in 0 ..< maximumWaits where !pending.isEmpty {
            try Task.checkCancellation()
            try await wait()
            var remaining: [URL] = []
            remaining.reserveCapacity(pending.count)
            for candidate in pending {
                try Task.checkCancellation()
                if !isAvailable(candidate) {
                    remaining.append(candidate)
                }
            }
            pending = remaining
        }
        return MailboxAckHydrationReport(
            eligibleCandidateCount: discovered.eligible.count,
            requestedDownloadCount: requestedDownloadCount,
            remainingUnavailableCount: pending.count,
            skippedUnverifiableIdentityCount: discovered.skippedUnverifiableIdentityCount
        )
    }

    private func isAvailable(_ url: URL) -> Bool {
        (try? availability(url)) == .available
    }
}

enum ProductionMailboxAckHydration {
    static func make(lane: URL) -> MailboxAckHydrator {
        #if os(iOS)
        MailboxAckHydrator(
            candidates: { try candidateURLs(in: lane) },
            availability: availability,
            requestDownload: FileManager.default.startDownloadingUbiquitousItem,
            wait: { try await Task.sleep(for: .milliseconds(100)) },
            maximumWaits: 100
        )
        #else
        MailboxAckHydrator(
            candidates: {
                MailboxAckHydrationCandidates(
                    eligible: [],
                    skippedUnverifiableIdentityCount: 0
                )
            },
            availability: { _ in .available },
            requestDownload: { _ in },
            wait: {},
            maximumWaits: 0
        )
        #endif
    }

    #if os(iOS)
    private static func candidateURLs(in lane: URL) throws -> MailboxAckHydrationCandidates {
        let directory: Int32
        do {
            directory = try MailboxAckFileReader.openDirectory(lane)
        } catch {
            throw MailboxAckScannerError.unsafeMailbox
        }
        defer { _ = close(directory) }
        let enumeration: MailboxAckLaneEnumeration
        do {
            enumeration = try MailboxAckFileReader.enumerate(
                directory: directory,
                maximumNames: MailboxAckScanner.maximumScanFiles
            )
        } catch {
            throw MailboxAckScannerError.unsafeMailbox
        }
        var eligible: [URL] = []
        var skippedUnverifiableIdentityCount = 0
        for name in enumeration.finalNames {
            do {
                _ = try MailboxAckFileReader.currentIdentity(
                    directory: directory,
                    name: name
                )
                eligible.append(lane.appendingPathComponent(name, isDirectory: false))
            } catch MailboxAckFileError.unsafeEntry,
                    MailboxAckFileError.oversize {
                skippedUnverifiableIdentityCount += 1
            } catch {
                throw MailboxAckScannerError.unsafeMailbox
            }
        }
        return MailboxAckHydrationCandidates(
            eligible: eligible,
            skippedUnverifiableIdentityCount: skippedUnverifiableIdentityCount
        )
    }

    private static func availability(_ url: URL) throws -> MailboxAckAvailability {
        let values = try url.resourceValues(
            forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        )
        guard values.isUbiquitousItem == true else { return .available }
        return values.ubiquitousItemDownloadingStatus == .current
            ? .available
            : .remote
    }
    #endif
}
