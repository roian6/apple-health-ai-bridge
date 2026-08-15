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

enum MailboxAckCandidateIdentityDisposition: Equatable {
    case skipCandidate
    case unsafeMailbox
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
    let maximumCandidates: Int

    init(
        candidates: @escaping Candidates,
        availability: @escaping Availability,
        requestDownload: @escaping RequestDownload,
        wait: @escaping Wait,
        maximumWaits: Int,
        maximumCandidates: Int = .max
    ) {
        self.candidates = candidates
        self.availability = availability
        self.requestDownload = requestDownload
        self.wait = wait
        self.maximumWaits = maximumWaits
        self.maximumCandidates = maximumCandidates
    }

    func hydrate() async throws -> MailboxAckHydrationReport {
        try Task.checkCancellation()
        let discovered = try candidates()
        let selected = discovered.eligible.prefix(max(0, maximumCandidates))
        var pending: [URL] = []
        var requestedDownloadCount = 0
        for candidate in selected {
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
            eligibleCandidateCount: selected.count,
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
    static func identityFailureDisposition(
        _ error: MailboxAckFileError,
        explicitCandidate: Bool
    ) -> MailboxAckCandidateIdentityDisposition {
        switch (error, explicitCandidate) {
        case (.unsafeEntry, _), (.oversize, _):
            .skipCandidate
        case (.unavailable, true):
            .skipCandidate
        case (.replaced, _), (.unavailable, false):
            .unsafeMailbox
        }
    }

    static func make(
        lane: URL,
        candidateFileNames: [String]? = nil,
        maximumWaits: Int = 100
    ) -> MailboxAckHydrator {
        #if os(iOS)
        MailboxAckHydrator(
            candidates: {
                try candidateURLs(
                    in: lane,
                    candidateFileNames: candidateFileNames
                )
            },
            availability: availability,
            requestDownload: FileManager.default.startDownloadingUbiquitousItem,
            wait: { try await Task.sleep(for: .milliseconds(100)) },
            maximumWaits: maximumWaits
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
    private static func candidateURLs(
        in lane: URL,
        candidateFileNames: [String]?
    ) throws -> MailboxAckHydrationCandidates {
        let directory: Int32
        do {
            directory = try MailboxAckFileReader.openDirectory(lane)
        } catch {
            throw MailboxAckScannerError.unsafeMailbox
        }
        defer { _ = close(directory) }
        let names: [String]
        if let candidateFileNames {
            names = candidateFileNames
        } else {
            do {
                names = try MailboxAckFileReader.enumerate(
                    directory: directory,
                    maximumNames: MailboxAckScanner.maximumScanFiles
                ).finalNames
            } catch {
                throw MailboxAckScannerError.unsafeMailbox
            }
        }
        var eligible: [URL] = []
        var skippedUnverifiableIdentityCount = 0
        for name in names {
            guard let disposition = try? MailboxLayoutV1.classify(
                fileName: name,
                in: .acks,
                byteCount: 0
            ), case .final(kind: .acknowledgment, identifier: _) = disposition else {
                skippedUnverifiableIdentityCount += 1
                continue
            }
            do {
                _ = try MailboxAckFileReader.currentIdentity(
                    directory: directory,
                    name: name
                )
                eligible.append(lane.appendingPathComponent(name, isDirectory: false))
            } catch let error as MailboxAckFileError {
                switch identityFailureDisposition(
                    error,
                    explicitCandidate: candidateFileNames != nil
                ) {
                case .skipCandidate:
                    skippedUnverifiableIdentityCount += 1
                case .unsafeMailbox:
                    throw MailboxAckScannerError.unsafeMailbox
                }
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
