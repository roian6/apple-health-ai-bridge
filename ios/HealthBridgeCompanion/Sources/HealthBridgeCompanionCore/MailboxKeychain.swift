import Foundation
import Security

struct MailboxKeychainBackendError: Error, Equatable {
    let status: OSStatus
}

protocol MailboxKeychainClient: AnyObject {
    func withExclusiveAccess<T>(service: String, _ body: () throws -> T) throws -> T
    func data(service: String, account: String) throws -> Data?
    func store(_ data: Data, service: String, account: String) throws
    func remove(service: String, account: String) throws
    func trustData(service: String, record: MailboxTrustRecord) throws -> Data?
    func storeTrust(_ data: Data, service: String, record: MailboxTrustRecord) throws
    func removeTrust(service: String, record: MailboxTrustRecord) throws
}

final class SystemMailboxKeychain: MailboxKeychainClient {
    private let fileStorage: MailboxKeyFileStorage?

    convenience init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        self.init(applicationSupportDirectory: support)
    }

    init(
        applicationSupportDirectory: URL,
        filesystemKind: @escaping (URL) -> MailboxStorageKind = systemMailboxStorageKind
    ) {
        fileStorage = MailboxKeyFileStorage(
            applicationSupportDirectory: applicationSupportDirectory,
            filesystemKind: filesystemKind
        )
    }

    private init(applicationSupportDirectory: URL?) {
        if let applicationSupportDirectory {
            fileStorage = MailboxKeyFileStorage(
                applicationSupportDirectory: applicationSupportDirectory,
                filesystemKind: systemMailboxStorageKind
            )
        } else {
            fileStorage = nil
        }
    }

    func withExclusiveAccess<T>(service: String, _ body: () throws -> T) throws -> T {
        guard let fileStorage else {
            throw MailboxKeychainBackendError(status: errSecNotAvailable)
        }
        return try fileStorage.withExclusiveAccess(service: service, body)
    }

    func data(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw MailboxKeychainBackendError(status: errSecDecode)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw MailboxKeychainBackendError(status: status)
        }
    }

    func store(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addition = query
            addition.merge(attributes) { _, replacement in replacement }
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw MailboxKeychainBackendError(status: addStatus)
            }
        default:
            throw MailboxKeychainBackendError(status: updateStatus)
        }
    }

    func remove(service: String, account: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MailboxKeychainBackendError(status: status)
        }
    }

    func trustData(service: String, record: MailboxTrustRecord) throws -> Data? {
        guard let fileStorage else {
            throw MailboxKeychainBackendError(status: errSecNotAvailable)
        }
        return try fileStorage.data(service: service, record: record)
    }

    func storeTrust(_ data: Data, service: String, record: MailboxTrustRecord) throws {
        guard let fileStorage else {
            throw MailboxKeychainBackendError(status: errSecNotAvailable)
        }
        try fileStorage.store(data, service: service, record: record)
    }

    func removeTrust(service: String, record: MailboxTrustRecord) throws {
        guard let fileStorage else {
            throw MailboxKeychainBackendError(status: errSecNotAvailable)
        }
        try fileStorage.remove(service: service, record: record)
    }
}
