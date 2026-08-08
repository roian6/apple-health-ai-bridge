import Foundation

public enum MailboxLaneV1: String, CaseIterable, Hashable, Sendable {
    case deliveries
    case acks
    case pairing
    case quarantine
}
public enum MailboxArtifactKindV1: String, CaseIterable, Sendable {
    case delivery = "hbd"
    case acknowledgment = "hba"
    case invitation = "hbi"
    case completion = "hbc"
    case quarantine = "hbq"

    fileprivate var lane: MailboxLaneV1 {
        switch self {
        case .delivery:
            .deliveries
        case .acknowledgment:
            .acks
        case .invitation, .completion:
            .pairing
        case .quarantine:
            .quarantine
        }
    }

    fileprivate var maximumBytes: Int64 {
        switch self {
        case .delivery:
            MailboxLayoutV1.maximumDeliveryBytes
        case .acknowledgment, .invitation, .completion, .quarantine:
            MailboxLayoutV1.maximumMetadataBytes
        }
    }
}

public enum MailboxEntryDispositionV1: Equatable, Sendable {
    case final(kind: MailboxArtifactKindV1, identifier: String)
    case temporary
}

public enum MailboxLayoutError: Error, Equatable, Sendable {
    case invalidOpaqueComponent
    case invalidFileName
    case invalidFileSize
    case unknownExtension
    case wrongLane
    case oversized
}

public enum MailboxLayoutV1 {
    public static let rootDirectoryName = "HealthBridgeMailbox"
    public static let versionDirectoryName = "v1"
    public static let maximumDeliveryBytes: Int64 = 2_097_152
    public static let maximumMetadataBytes: Int64 = 65_536
    public static let temporarySuffix = "tmp"

    public static func opaqueComponent(_ candidate: String) throws -> String {
        guard candidate.count == 32,
              candidate.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              })
        else {
            throw MailboxLayoutError.invalidOpaqueComponent
        }
        return candidate
    }

    public static func finalFileName(
        identifier: String,
        kind: MailboxArtifactKindV1
    ) throws -> String {
        "\(try opaqueComponent(identifier)).\(kind.rawValue)"
    }

    public static func classify(
        fileName: String,
        in lane: MailboxLaneV1,
        byteCount: Int64
    ) throws -> MailboxEntryDispositionV1 {
        guard byteCount >= 0 else {
            throw MailboxLayoutError.invalidFileSize
        }
        let parts = fileName.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts[3] == Substring(temporarySuffix) {
            _ = try opaqueComponent(String(parts[0]))
            let kind = try artifactKind(extension: parts[1])
            guard kind.lane == lane else {
                throw MailboxLayoutError.wrongLane
            }
            _ = try opaqueComponent(String(parts[2]))
            return .temporary
        }
        guard parts.count == 2 else {
            throw MailboxLayoutError.invalidFileName
        }
        let identifier = try opaqueComponent(String(parts[0]))
        let kind = try artifactKind(extension: parts[1])
        guard kind.lane == lane else {
            throw MailboxLayoutError.wrongLane
        }
        guard byteCount <= kind.maximumBytes else {
            throw MailboxLayoutError.oversized
        }
        return .final(kind: kind, identifier: identifier)
    }

    private static func artifactKind(
        extension value: Substring
    ) throws -> MailboxArtifactKindV1 {
        guard let kind = MailboxArtifactKindV1(rawValue: String(value)) else {
            throw MailboxLayoutError.unknownExtension
        }
        return kind
    }
}
