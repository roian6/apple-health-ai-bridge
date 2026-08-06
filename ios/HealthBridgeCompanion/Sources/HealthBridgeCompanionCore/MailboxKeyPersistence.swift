import Foundation
import Security

final class MailboxKeyPersistence {
    private static let identityAccount = "identity-v1"
    private static let initializedAccount = "initialized-v1"
    private static let initializedMarker = Data("health-bridge-mailbox-keys-v1".utf8)

    private let service: String
    private let keychain: MailboxKeychainClient

    init(service: String, keychain: MailboxKeychainClient) {
        self.service = service
        self.keychain = keychain
    }

    func exclusively<T>(_ body: () throws -> T) throws -> T {
        do {
            return try keychain.withExclusiveAccess(service: service, body)
        } catch let error as MailboxKeychainBackendError {
            throw Self.mappedError(status: error.status)
        }
    }

    func readState() throws -> LoadedMailboxState {
        let identity = try data(account: Self.identityAccount)
        let marker = try data(account: Self.initializedAccount)
        let anchorData = try trustData(record: .expectedIdentity)
        let provisioningData = try trustData(record: .monotonicGeneration)
        guard (identity == nil) == (marker == nil) else {
            throw MailboxKeyStoreError.keyMaterialLost
        }
        if let marker {
            guard marker.count <= MailboxKeyConstants.maximumStateBytes,
                  marker == Self.initializedMarker
            else {
                throw MailboxKeyStoreError.malformedState
            }
        }
        let stored: StoredMailboxKeys? = try identity.map(strictDecode)
        let anchor: ExpectedIdentityAnchor? = try anchorData.map(strictDecode)
        let provisioning: MailboxProvisioningAnchor? = try provisioningData.map(
            strictDecode
        )
        guard (stored == nil) == (anchor == nil),
              (stored == nil) == (provisioning == nil)
        else {
            throw MailboxKeyStoreError.keyMaterialLost
        }
        if let stored { try validate(stored) }
        if let anchor { try validate(anchor) }
        if let provisioning { try validate(provisioning) }
        return LoadedMailboxState(
            stored: stored,
            anchor: anchor,
            provisioning: provisioning
        )
    }

    func writeInitializedMarker() throws {
        try store(Self.initializedMarker, account: Self.initializedAccount)
    }

    func write(_ stored: StoredMailboxKeys) throws {
        try store(try mailboxCanonicalJSON(stored), account: Self.identityAccount)
    }

    func write(_ anchor: ExpectedIdentityAnchor) throws {
        try storeTrust(try mailboxCanonicalJSON(anchor), record: .expectedIdentity)
    }

    func write(_ provisioning: MailboxProvisioningAnchor) throws {
        try storeTrust(
            try mailboxCanonicalJSON(provisioning),
            record: .monotonicGeneration
        )
    }

    func writeTransition(_ stored: StoredMailboxKeys) throws {
        let anchor = try anchorFor(stored)
        try write(stored)
        try write(anchor)
        try write(try provisioningFor(anchor))
    }

    func removeAllKeyMaterial() throws {
        try remove(account: Self.identityAccount)
        try remove(account: Self.initializedAccount)
        try removeTrust(record: .expectedIdentity)
        try removeTrust(record: .monotonicGeneration)
    }

    private func data(account: String) throws -> Data? {
        do {
            return try keychain.data(service: service, account: account)
        } catch let error as MailboxKeychainBackendError {
            throw Self.mappedError(status: error.status)
        }
    }

    private func store(_ value: Data, account: String) throws {
        do {
            try keychain.store(value, service: service, account: account)
        } catch let error as MailboxKeychainBackendError {
            throw Self.mappedError(status: error.status)
        }
    }

    private func remove(account: String) throws {
        do {
            try keychain.remove(service: service, account: account)
        } catch let error as MailboxKeychainBackendError {
            throw Self.mappedError(status: error.status)
        }
    }

    private func trustData(record: MailboxTrustRecord) throws -> Data? {
        do {
            return try keychain.trustData(service: service, record: record)
        } catch let error as MailboxKeychainBackendError {
            throw Self.mappedError(status: error.status)
        }
    }

    private func storeTrust(_ value: Data, record: MailboxTrustRecord) throws {
        do {
            try keychain.storeTrust(value, service: service, record: record)
        } catch let error as MailboxKeychainBackendError {
            throw Self.mappedError(status: error.status)
        }
    }

    private func removeTrust(record: MailboxTrustRecord) throws {
        do {
            try keychain.removeTrust(service: service, record: record)
        } catch let error as MailboxKeychainBackendError {
            throw Self.mappedError(status: error.status)
        }
    }

    private static func mappedError(status: OSStatus) -> MailboxKeyStoreError {
        switch status {
        case errSecInteractionNotAllowed:
            return .keychainLocked
        case errSecAuthFailed, errSecUserCanceled:
            return .keychainAccessDenied
        case errSecMissingEntitlement, errSecNotAvailable:
            return .keychainUnavailable
        default:
            return .keychainUnavailable
        }
    }
}
