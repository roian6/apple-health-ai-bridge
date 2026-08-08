import CryptoKit
import Foundation

struct MailboxProvisioningAnchor: Codable, Equatable {
    let anchorSHA256: String
    let domain: String
    let expected: ExpectedIdentityAnchor
    let generation: Int
    let v: Int

    enum CodingKeys: String, CodingKey {
        case anchorSHA256 = "anchor_sha256"
        case domain
        case expected
        case generation
        case v
    }
}

func validate(_ provisioning: MailboxProvisioningAnchor) throws {
    guard provisioning.v == 1,
          provisioning.domain == MailboxKeyConstants.provisioningDomain,
          provisioning.generation >= 1,
          provisioning.expected.generation == provisioning.generation,
          try provisioningFor(provisioning.expected) == provisioning
    else {
        throw MailboxKeyStoreError.malformedState
    }
    try validate(provisioning.expected)
}

func provisioningFor(
    _ anchor: ExpectedIdentityAnchor
) throws -> MailboxProvisioningAnchor {
    MailboxProvisioningAnchor(
        anchorSHA256: SHA256.hash(data: try mailboxCanonicalJSON(anchor)).map {
            String(format: "%02x", $0)
        }.joined(),
        domain: MailboxKeyConstants.provisioningDomain,
        expected: anchor,
        generation: anchor.generation,
        v: 1
    )
}

struct MailboxReconciliationWrites {
    let anchor: ExpectedIdentityAnchor?
    let provisioning: MailboxProvisioningAnchor?
}

func requiredMailboxReconciliation(
    stored: StoredMailboxKeys,
    anchor: ExpectedIdentityAnchor,
    provisioning: MailboxProvisioningAnchor
) throws -> MailboxReconciliationWrites {
    let committed = provisioning.expected
    let generation = provisioning.generation
    if stored.generation == generation, anchor.generation == generation - 1 {
        try validateForwardTransition(committed: anchor, stored: stored)
        guard try anchorFor(stored) == committed else { throw rollback() }
        return MailboxReconciliationWrites(anchor: committed, provisioning: nil)
    }
    guard stored.generation >= generation,
          anchor.generation >= generation,
          stored.generation <= generation + 1,
          anchor.generation <= generation + 1,
          anchor.generation <= stored.generation
    else {
        throw rollback()
    }
    if anchor.generation == generation, anchor != committed {
        throw rollback()
    }
    if stored.generation == generation {
        guard anchor.generation == generation,
              try anchorFor(stored) == committed
        else {
            throw rollback()
        }
        return MailboxReconciliationWrites(anchor: nil, provisioning: nil)
    }
    try validateForwardTransition(committed: committed, stored: stored)
    let desired = try anchorFor(stored)
    let anchorWrite: ExpectedIdentityAnchor?
    if anchor.generation == generation {
        anchorWrite = desired
    } else if anchor == desired {
        anchorWrite = nil
    } else {
        throw rollback()
    }
    return MailboxReconciliationWrites(
        anchor: anchorWrite,
        provisioning: try provisioningFor(desired)
    )
}

private func validateForwardTransition(
    committed: ExpectedIdentityAnchor,
    stored: StoredMailboxKeys
) throws {
    guard stored.generation == committed.generation + 1,
          committed.state == .active
    else {
        throw rollback()
    }
    let old = try publicIdentity(committed)
    let current = try publicIdentity(stored)
    switch stored.state {
    case .active:
        guard let continuity = stored.continuity else { throw rollback() }
        try verifyMailboxKeyContinuity(continuity)
        guard continuityMatches(continuity, old: old, new: current) else {
            throw rollback()
        }
    case .revoked:
        guard current == old, stored.continuity == committed.continuity else {
            throw rollback()
        }
    case .lost, .notInitialized:
        throw MailboxKeyStoreError.malformedState
    }
}

private func rollback() -> MailboxKeyStoreError {
    .rollbackDetected
}
